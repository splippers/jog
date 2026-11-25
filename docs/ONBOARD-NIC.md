# Using an onboard NIC for imaging (office PC exception)

By default Haar serves DHCP/TFTP **only on a USB Ethernet adapter**, so it can never hand out addresses on a
production LAN by accident. If your only USB adapter is slow (e.g. 100 Mbit/s) you can opt in to a faster onboard
port instead:

    sudo jog-hardware-wizard --onboard            # picks the onboard port (asks if there are several)
    sudo jog-hardware-wizard --onboard=eno1       # or name it

What it does:
- Records `JOG_ALLOW_ONBOARD_NIC=<iface>` in `/etc/jog/jog.env`. The DHCP guard then accepts **that one named
  interface** (never wireless, never a pattern). Everything else is still refused.
- Keeps the port out of NetworkManager (`/etc/NetworkManager/conf.d/99-jog-unmanaged.conf`) so the static imaging
  IP is not cleared when the cable state changes.
- Chooses the uplink from the other adapters (Wi-Fi first, then the slow USB NIC), writes a MAC-based udev rule.

Safety: the guard still sends a DHCP probe on the port before serving. If another DHCP server answers (for example the
port is plugged into the office LAN) DHCP stays **disabled**. Cable the onboard port to an isolated switch or straight to
the machine being imaged, and give the PC its internet through the other adapter. `jog-imaging-internet.service`
is the NAT rule that does this: clients use Haar (`10.99.0.1`) as router/DNS and are masqueraded out the default-route
uplink; enable it with `sudo systemctl enable --now jog-imaging-internet.service`.

Undo: `sudo jog-hardware-wizard` (without `--onboard`) removes the opt-in and the NetworkManager file.
