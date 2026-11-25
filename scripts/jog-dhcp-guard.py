#!/usr/bin/env python3
import os
import random
import re
import socket
import struct
import sys
import time

MAGIC = b"\x63\x82\x53\x63"


def fail(message, code=1):
    sys.stderr.write(f"jog-dhcp-guard: {message}\n")
    raise SystemExit(code)


def sysfs(iface, name):
    try:
        with open(f"/sys/class/net/{iface}/{name}", encoding="ascii") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def allowed_onboard():
    """Interface explicitly permitted as a non-USB imaging NIC (JOG_ALLOW_ONBOARD_NIC), or ''.
    Read from the environment, else from /etc/jog/jog.env. Exactly one named interface, never a pattern."""
    value = os.environ.get("JOG_ALLOW_ONBOARD_NIC", "")
    if not value:
        try:
            with open(os.environ.get("JOG_ENV", "/etc/jog/jog.env"), encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("JOG_ALLOW_ONBOARD_NIC="):
                        value = line.split("=", 1)[1].strip().strip('"').strip("'")
        except OSError:
            pass
    return value


def valid_usb_ethernet(iface):
    base = f"/sys/class/net/{iface}"
    if not os.path.isdir(base):
        return False, f"no such interface: {iface}"
    if sysfs(iface, "type") != "1":
        return False, f"{iface} is not Ethernet"
    if os.path.isdir(f"{base}/wireless"):
        return False, f"{iface} is wireless"
    device = os.path.realpath(f"{base}/device")
    if not re.search(r"/usb\d+/", device):
        # Exception: an onboard (physical, wired) port the operator named explicitly. The DHCP-server
        # probe in 'check' still runs, so DHCP stays off if another server answers on that link.
        if iface == allowed_onboard() and os.path.exists(f"{base}/device"):
            return True, f"{device} (onboard, explicitly allowed)"
        return False, f"{iface} is not USB-attached ({device})"
    return True, device


def list_usb_ethernet():
    try:
        names = sorted(os.listdir("/sys/class/net"))
    except OSError as error:
        fail(f"cannot list interfaces: {error}", 2)
    for name in names:
        ok, _ = valid_usb_ethernet(name)
        if ok:
            print(name)
    return 0


def parse_options(data):
    options = {}
    index = 0
    while index < len(data):
        code = data[index]
        if code == 255:
            break
        if code == 0:
            index += 1
            continue
        if index + 1 >= len(data):
            break
        length = data[index + 1]
        options[code] = data[index + 2:index + 2 + length]
        index += 2 + length
    return options


def parse_bootp(payload):
    if len(payload) < 240 or payload[236:240] != MAGIC:
        return None
    options = parse_options(payload[240:])
    message_type = options[53][0] if 53 in options and options[53] else None
    server_id = socket.inet_ntoa(options[54][:4]) if 54 in options and len(options[54]) >= 4 else None
    return {
        "op": payload[0],
        "xid": struct.unpack("!I", payload[4:8])[0],
        "siaddr": socket.inet_ntoa(payload[20:24]),
        "chaddr": payload[28:34],
        "type": message_type,
        "server_id": server_id,
    }


def parse_frame(frame):
    if len(frame) < 14:
        return None
    ethertype = struct.unpack("!H", frame[12:14])[0]
    offset = 14
    if ethertype == 0x8100:
        if len(frame) < 18:
            return None
        ethertype = struct.unpack("!H", frame[16:18])[0]
        offset = 18
    if ethertype != 0x0800:
        return None
    ip = frame[offset:]
    if len(ip) < 20 or ip[0] >> 4 != 4 or ip[9] != 17:
        return None
    ihl = (ip[0] & 0x0F) * 4
    if len(ip) < ihl + 8:
        return None
    udp = ip[ihl:]
    src_port, dst_port, length, _ = struct.unpack("!HHHH", udp[:8])
    payload = udp[8:length] if 8 <= length <= len(udp) else udp[8:]
    return src_port, dst_port, payload


def checksum(data):
    if len(data) % 2:
        data += b"\x00"
    total = sum(struct.unpack("!H", data[i:i + 2])[0] for i in range(0, len(data), 2))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def mac_bytes(iface):
    address = sysfs(iface, "address")
    try:
        return bytes(int(part, 16) for part in address.split(":"))
    except ValueError:
        fail(f"invalid MAC address for {iface}: {address}", 2)


def build_discover(iface, xid):
    mac = mac_bytes(iface)
    options = bytes([53, 1, 1, 55, 3, 1, 3, 6, 255])
    bootp = struct.pack(
        "!BBBBIHH4s4s4s4s16s64s128s",
        1, 6, 6, 0, xid, 0, 0x8000,
        b"\x00" * 4, b"\x00" * 4, b"\x00" * 4, b"\x00" * 4,
        mac + b"\x00" * 10, b"\x00" * 64, b"\x00" * 128,
    ) + MAGIC + options
    total_length = 20 + 8 + len(bootp)
    header = struct.pack(
        "!BBHHHBBH4s4s",
        0x45, 0, total_length, 0x1234, 0, 64, 17, 0,
        socket.inet_aton("0.0.0.0"), socket.inet_aton("255.255.255.255"),
    )
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    udp = struct.pack("!HHHH", 68, 67, 8 + len(bootp), 0)
    return b"\xff" * 6 + mac + b"\x08\x00" + header + udp + bootp


def server_reply(iface, seconds, ignore_ip):
    try:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
        sock.bind((iface, 0))
    except OSError as error:
        fail(f"cannot open {iface} for DHCP monitoring: {error}", 2)
    try:
        sock.settimeout(0.25)
        xid = random.randint(1, 0xFFFFFFFF)
        frame = build_discover(iface, xid)
        our_mac = mac_bytes(iface)
        sock.send(frame)
        probes = 1
        next_probe = time.monotonic() + seconds / 2
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            now = time.monotonic()
            if probes < 2 and now >= next_probe:
                sock.send(frame)
                probes += 1
                next_probe = now + seconds
                continue
            try:
                data, _ = sock.recvfrom(2048)
            except socket.timeout:
                continue
            parsed = parse_frame(data)
            if not parsed:
                continue
            src_port, dst_port, payload = parsed
            if src_port != 67 or dst_port != 68:
                continue
            reply = parse_bootp(payload)
            if not reply or reply["op"] != 2 or reply["type"] in (1, 3, 4):
                continue
            server = reply["server_id"] or reply["siaddr"]
            if ignore_ip and server == ignore_ip:
                continue
            if reply["chaddr"] == our_mac and ignore_ip and server == ignore_ip:
                continue
            return True, f"DHCP server reply from {server or 'unknown'}"
        return False, "no DHCP server reply detected"
    finally:
        sock.close()


def main():
    if len(sys.argv) < 2:
        fail("usage: jog-dhcp-guard.py list|validate IFACE|check IFACE [IGNORE_IP]", 2)
    mode = sys.argv[1]
    if mode == "list":
        return list_usb_ethernet()
    if len(sys.argv) < 3:
        fail("usage: jog-dhcp-guard.py list|validate IFACE|check IFACE [IGNORE_IP]", 2)
    iface = sys.argv[2]
    ok, reason = valid_usb_ethernet(iface)
    if not ok:
        fail(reason, 3 if mode == "validate" else 4)
    if mode == "validate":
        print(reason)
        return 0
    if mode != "check":
        fail(f"unknown mode: {mode}", 2)
    ignore_ip = sys.argv[3] if len(sys.argv) > 3 else os.environ.get("JOG_IMAGING_IP", "")
    try:
        seconds = float(os.environ.get("JOG_DHCP_PROBE_SECONDS", "2"))
    except ValueError:
        fail("JOG_DHCP_PROBE_SECONDS must be a number", 2)
    seconds = max(0.5, min(seconds, 30.0))
    conflict, detail = server_reply(iface, seconds, ignore_ip)
    if conflict:
        fail(detail, 5)
    print(detail)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
