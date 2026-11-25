"""One-time Haarmetry enrollment and hostapd per-station PSK management."""

import base64
import fcntl
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import sqlite3
import subprocess
import tempfile
import time
import uuid

MAC_RE = re.compile(r"^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$", re.IGNORECASE)
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$")
ROLES = {"phone", "tablet", "technician", "monitor", "kiosk"}
WILDCARD_MAC = "00:00:00:00:00:00"


class EnrollmentError(Exception):
    pass


def secret_hash(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def derive_psk(ssid, passphrase):
    if not 1 <= len(ssid.encode("utf-8")) <= 32:
        raise EnrollmentError("Wi-Fi SSID must be 1 to 32 bytes")
    if not 8 <= len(passphrase) <= 63:
        raise EnrollmentError("Wi-Fi passphrase must be 8 to 63 characters")
    return hashlib.pbkdf2_hmac(
        "sha1", passphrase.encode("utf-8"), ssid.encode("utf-8"), 4096, 32
    ).hex()


class EnrollmentStore:
    def __init__(self, path, derivation_key, clock=time.time):
        if len(derivation_key) < 32:
            raise EnrollmentError("enrollment derivation key must be at least 32 bytes")
        self.path = path
        self.derivation_key = derivation_key
        self.clock = clock
        self._initialize()

    def _connect(self):
        connection = sqlite3.connect(self.path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        return connection

    def _initialize(self):
        parent = os.path.dirname(self.path)
        os.makedirs(parent, mode=0o770, exist_ok=True)
        with self._connect() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS bootstrap (
                    token_hash TEXT PRIMARY KEY,
                    ssid TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    used_mac TEXT,
                    retry_until INTEGER
                );
                CREATE TABLE IF NOT EXISTS agents (
                    agent_id TEXT PRIMARY KEY,
                    label TEXT NOT NULL,
                    role TEXT NOT NULL,
                    bootstrap_hash TEXT UNIQUE,
                    ssid TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER,
                    revoked_at INTEGER,
                    last_seen_at INTEGER
                );
                CREATE TABLE IF NOT EXISTS clients (
                    client_id TEXT PRIMARY KEY,
                    mac TEXT NOT NULL UNIQUE,
                    token_hash TEXT NOT NULL UNIQUE,
                    created_at INTEGER NOT NULL,
                    revoked_at INTEGER
                );
                """
            )
            columns = {row["name"] for row in connection.execute("PRAGMA table_info(clients)")}
            if "agent_id" not in columns:
                connection.execute("ALTER TABLE clients ADD COLUMN agent_id TEXT")
        os.chmod(self.path, 0o660)

    def issue_bootstrap(self, ssid, ttl_seconds=300):
        if not 1 <= len(ssid.encode("utf-8")) <= 32:
            raise EnrollmentError("Wi-Fi SSID must be 1 to 32 bytes")
        token = secrets.token_urlsafe(32)
        now = int(self.clock())
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "UPDATE bootstrap SET expires_at = ? WHERE used_mac IS NULL",
                (now,),
            )
            connection.execute(
                "INSERT INTO bootstrap(token_hash, ssid, expires_at) VALUES (?, ?, ?)",
                (secret_hash(token), ssid, now + ttl_seconds),
            )
        return token

    def _derived(self, token, mac):
        message = token.encode("utf-8") + b"\0" + mac.encode("ascii")
        api_token = hmac.new(
            self.derivation_key, b"api\0" + message, hashlib.sha256
        ).hexdigest()
        wifi_key = hmac.new(
            self.derivation_key, b"wifi\0" + message, hashlib.sha256
        ).digest()
        wifi_psk = base64.urlsafe_b64encode(wifi_key).decode("ascii").rstrip("=")
        return api_token, wifi_psk

    def bootstrap_passphrase(self, token):
        key = hmac.new(
            self.derivation_key,
            b"bootstrap-passphrase\0" + token.encode("utf-8"),
            hashlib.sha256,
        ).digest()[:24]
        return base64.urlsafe_b64encode(key).decode("ascii").rstrip("=")

    def redeem(self, token, mac, psk_manager):
        if not isinstance(token, str) or not 32 <= len(token) <= 128:
            raise EnrollmentError("invalid enrollment token")
        if not MAC_RE.fullmatch(mac or "") or mac.lower() == WILDCARD_MAC:
            raise EnrollmentError("invalid access point station")
        mac = mac.lower()
        now = int(self.clock())
        old_psk_file = None
        token_hash = secret_hash(token)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            agent = connection.execute(
                "SELECT agent_id FROM agents WHERE bootstrap_hash = ?",
                (token_hash,),
            ).fetchone()
            agent_id = agent["agent_id"] if agent else None
            row = connection.execute(
                "SELECT ssid, expires_at, used_mac, retry_until FROM bootstrap "
                "WHERE token_hash = ?",
                (token_hash,),
            ).fetchone()
            if row is None:
                raise EnrollmentError("enrollment QR is invalid or has already expired")
            if row["used_mac"] is None:
                if now > row["expires_at"]:
                    raise EnrollmentError("enrollment QR has expired")
            elif row["used_mac"] != mac or now > row["retry_until"]:
                raise EnrollmentError("enrollment QR has already been used")

            existing = connection.execute(
                "SELECT client_id, token_hash, revoked_at, agent_id FROM clients WHERE mac = ?",
                (mac,),
            ).fetchone()
            if existing and existing["revoked_at"] is None:
                # The same station can safely retry if its first response was lost.
                api_token, _ = self._derived(token, mac)
                wifi_psk = self.bootstrap_passphrase(token)
                if not hmac.compare_digest(existing["token_hash"], secret_hash(api_token)):
                    raise EnrollmentError("this station is already enrolled")
                if agent_id and existing["agent_id"] != agent_id:
                    raise EnrollmentError("this station is already linked to another agent")
                if agent_id:
                    connection.execute(
                        "UPDATE clients SET agent_id = ? WHERE client_id = ?",
                        (agent_id, existing["client_id"]),
                    )
                    connection.execute(
                        "UPDATE agents SET last_seen_at = ? WHERE agent_id = ?",
                        (now, agent_id),
                    )
                return {
                    "clientId": existing["client_id"],
                    "agentId": agent_id,
                    "token": api_token,
                    "ssid": row["ssid"],
                    "psk": wifi_psk,
                }
            api_token, _ = self._derived(token, mac)
            wifi_psk = self.bootstrap_passphrase(token)
            client_id = str(uuid.uuid4())
            old_psk_file = psk_manager.enroll_station(mac, row["ssid"], wifi_psk)
            try:
                if existing:
                    connection.execute(
                        "UPDATE clients SET client_id = ?, token_hash = ?, created_at = ?, "
                        "revoked_at = NULL, agent_id = ? WHERE client_id = ?",
                        (client_id, secret_hash(api_token), now, agent_id, existing["client_id"]),
                    )
                else:
                    connection.execute(
                        "INSERT INTO clients(client_id, mac, token_hash, created_at, agent_id) "
                        "VALUES (?, ?, ?, ?, ?)",
                        (client_id, mac, secret_hash(api_token), now, agent_id),
                    )
                connection.execute(
                    "UPDATE bootstrap SET used_mac = ?, retry_until = ? "
                    "WHERE token_hash = ?",
                    (mac, now + 300, token_hash),
                )
                if agent_id:
                    connection.execute(
                        "UPDATE agents SET last_seen_at = ?, expires_at = ? WHERE agent_id = ?",
                        (now, now, agent_id),
                    )
            except Exception:
                psk_manager.restore(old_psk_file)
                raise
        return {
            "clientId": client_id,
            "agentId": agent_id,
            "token": api_token,
            "ssid": row["ssid"],
            "psk": wifi_psk,
        }

    def authorize(self, token):
        if not token:
            return None
        hashed = secret_hash(token)
        with self._connect() as connection:
            row = connection.execute(
                "SELECT client_id, agent_id FROM clients "
                "WHERE token_hash = ? AND revoked_at IS NULL",
                (hashed,),
            ).fetchone()
            if not row:
                return None
            if row["agent_id"]:
                connection.execute(
                    "UPDATE agents SET last_seen_at = ? WHERE agent_id = ?",
                    (int(self.clock()), row["agent_id"]),
                )
            return row["client_id"]

    def authorize_bootstrap(self, token):
        if not token:
            return None
        hashed = secret_hash(token)
        now = int(self.clock())
        with self._connect() as connection:
            row = connection.execute(
                "SELECT a.agent_id FROM bootstrap b "
                "JOIN agents a ON a.bootstrap_hash = b.token_hash "
                "WHERE b.token_hash = ? AND b.used_mac IS NULL AND b.expires_at >= ? "
                "AND a.revoked_at IS NULL AND (a.expires_at IS NULL OR a.expires_at >= ?)",
                (hashed, now, now),
            ).fetchone()
        return row["agent_id"] if row else None

    def list_clients(self):
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT client_id, mac, created_at, revoked_at "
                "FROM clients ORDER BY created_at, client_id"
            ).fetchall()
        return [dict(row) for row in rows]

    def _agent_fields(self, label, role, ssid):
        label = str(label or "").strip()
        role = str(role or "phone").strip().lower()
        ssid = str(ssid or "").strip()
        if not LABEL_RE.fullmatch(label):
            raise EnrollmentError("agent label must be 1 to 80 safe characters")
        if role not in ROLES:
            raise EnrollmentError("unsupported agent role")
        if not 1 <= len(ssid.encode("utf-8")) <= 32:
            raise EnrollmentError("Wi-Fi SSID must be 1 to 32 bytes")
        return label, role, ssid

    def issue_agent(self, label, role, ssid, ttl_seconds=600, agent_id=None):
        label, role, ssid = self._agent_fields(label, role, ssid)
        token = secrets.token_urlsafe(32)
        now = int(self.clock())
        agent_id = agent_id or str(uuid.uuid4())
        token_hash = secret_hash(token)
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT label, role, revoked_at FROM agents WHERE agent_id = ?",
                (agent_id,),
            ).fetchone()
            if existing and existing["revoked_at"] is not None:
                raise EnrollmentError("agent has been revoked")
            if existing:
                connection.execute(
                    "UPDATE agents SET label = ?, role = ?, ssid = ?, bootstrap_hash = ?, "
                    "expires_at = ?, revoked_at = NULL WHERE agent_id = ?",
                    (label, role, ssid, token_hash, now + ttl_seconds, agent_id),
                )
            else:
                connection.execute(
                    "INSERT INTO agents(agent_id, label, role, bootstrap_hash, ssid, "
                    "created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (agent_id, label, role, token_hash, ssid, now, now + ttl_seconds),
                )
            connection.execute(
                "INSERT INTO bootstrap(token_hash, ssid, expires_at) VALUES (?, ?, ?)",
                (token_hash, ssid, now + ttl_seconds),
            )
        passphrase = self.bootstrap_passphrase(token)
        return {
            "agentId": agent_id,
            "label": label,
            "role": role,
            "bootstrapToken": token,
            "bootstrapPassphrase": passphrase,
            "ssid": ssid,
            "expiresAt": now + ttl_seconds,
        }

    def reissue_agent(self, agent_id, ssid, ttl_seconds=600):
        with self._connect() as connection:
            row = connection.execute(
                "SELECT label, role, revoked_at FROM agents WHERE agent_id = ?",
                (agent_id,),
            ).fetchone()
            if row is None:
                raise EnrollmentError("unknown agent")
            if row["revoked_at"] is not None:
                raise EnrollmentError("agent has been revoked")
            client = connection.execute(
                "SELECT client_id FROM clients WHERE agent_id = ? AND revoked_at IS NULL",
                (agent_id,),
            ).fetchone()
            if client:
                raise EnrollmentError("agent is already enrolled; revoke it before reissuing")
        return self.issue_agent(row["label"], row["role"], ssid, ttl_seconds, agent_id)

    def list_agents(self):
        now = int(self.clock())
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT a.agent_id, a.label, a.role, a.ssid, a.created_at, a.expires_at, "
                "a.revoked_at AS agent_revoked_at, a.last_seen_at, "
                "c.client_id, c.mac, c.created_at AS enrolled_at, c.revoked_at AS client_revoked_at "
                "FROM agents a LEFT JOIN clients c ON c.agent_id = a.agent_id "
                "ORDER BY a.created_at, a.agent_id"
            ).fetchall()
        out = []
        for row in rows:
            item = dict(row)
            if item["agent_revoked_at"] or item["client_revoked_at"]:
                status = "revoked"
            elif item["client_id"]:
                status = "enrolled"
            elif item["expires_at"] and now > item["expires_at"]:
                status = "expired"
            else:
                status = "pending"
            item["status"] = status
            out.append(item)
        return out

    def revoke_agent(self, agent_id, psk_manager):
        with self._connect() as connection:
            agent = connection.execute(
                "SELECT revoked_at FROM agents WHERE agent_id = ?", (agent_id,)
            ).fetchone()
            if agent is None:
                raise EnrollmentError("unknown agent")
            if agent["revoked_at"] is not None:
                return False
            client = connection.execute(
                "SELECT client_id FROM clients WHERE agent_id = ? AND revoked_at IS NULL",
                (agent_id,),
            ).fetchone()
        if client:
            self.revoke(client["client_id"], psk_manager)
        with self._connect() as connection:
            connection.execute(
                "UPDATE agents SET revoked_at = ?, bootstrap_hash = NULL, expires_at = ? "
                "WHERE agent_id = ?",
                (int(self.clock()), int(self.clock()), agent_id),
            )
        return True

    def revoke(self, client_id, psk_manager):
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT mac, revoked_at FROM clients WHERE client_id = ?",
                (client_id,),
            ).fetchone()
            if row is None:
                raise EnrollmentError("unknown device")
            if row["revoked_at"] is not None:
                return False
            old_psk_file = psk_manager.revoke_station(row["mac"])
            try:
                connection.execute(
                    "UPDATE clients SET revoked_at = ? WHERE client_id = ?",
                    (int(self.clock()), client_id),
                )
            except Exception:
                psk_manager.restore(old_psk_file)
                raise
        return True


class ApPskManager:
    def __init__(self, psk_file, interface, control_dir="/run/hostapd",
                 command_runner=subprocess.run):
        self.psk_file = psk_file
        self.interface = interface
        self.control_dir = control_dir
        self.command_runner = command_runner

    def _read(self):
        try:
            with open(self.psk_file, "rb") as handle:
                return handle.read()
        except FileNotFoundError:
            return b""

    @staticmethod
    def _entries(raw):
        entries = {}
        for line in raw.decode("ascii").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split()
            if (len(fields) != 2 or not MAC_RE.fullmatch(fields[0]) or
                    not re.fullmatch(r"[0-9a-fA-F]{64}", fields[1])):
                raise EnrollmentError("hostapd PSK file has an invalid entry")
            entries[fields[0].lower()] = fields[1].lower()
        return entries

    def _write(self, entries):
        data = "".join("%s %s\n" % item for item in sorted(entries.items()))
        directory = os.path.dirname(self.psk_file)
        os.makedirs(directory, mode=0o770, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".jog-psk-", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="ascii") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o660)
            os.replace(temporary, self.psk_file)
            directory_fd = os.open(directory, os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def _reload(self):
        try:
            result = self.command_runner(
                ["hostapd_cli", "-p", self.control_dir, "-i", self.interface,
                 "reload_wpa_psk"],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise EnrollmentError("hostapd did not reload its PSK list") from exc
        if "OK" not in (result.stdout or ""):
            raise EnrollmentError("hostapd rejected the PSK list reload")

    def _replace_and_reload(self, entries):
        previous = self._read()
        self._write(entries)
        try:
            self._reload()
        except Exception:
            self._write(self._entries(previous))
            try:
                self._reload()
            except EnrollmentError:
                pass
            raise
        return previous

    def install_bootstrap(self, ssid, passphrase):
        entries = self._entries(self._read())
        entries[WILDCARD_MAC] = derive_psk(ssid, passphrase)
        return self._replace_and_reload(entries)

    def station_for_ip(self, peer_ip):
        try:
            ipaddress.ip_address(peer_ip)
            neighbors = self.command_runner(
                ["ip", "-j", "neigh", "show", "dev", self.interface],
                check=True,
                capture_output=True,
                text=True,
                timeout=3,
            )
            records = json.loads(neighbors.stdout)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            raise EnrollmentError("could not identify the connected Wi-Fi station") from exc
        mac = None
        for item in records:
            if (item.get("dst") == peer_ip and item.get("lladdr") and
                    item.get("state") not in ("FAILED", "INCOMPLETE")):
                mac = item["lladdr"].lower()
                break
        if not mac or not MAC_RE.fullmatch(mac) or mac == WILDCARD_MAC:
            raise EnrollmentError("request must come from an associated HAAR Wi-Fi device")
        try:
            stations = self.command_runner(
                ["hostapd_cli", "-p", self.control_dir, "-i", self.interface, "all_sta"],
                check=True,
                capture_output=True,
                text=True,
                timeout=3,
            ).stdout
        except (OSError, subprocess.SubprocessError) as exc:
            raise EnrollmentError("could not verify the connected Wi-Fi station") from exc
        if not re.search(r"(?im)^" + re.escape(mac) + r"\s*$", stations):
            raise EnrollmentError("request must come from an associated HAAR Wi-Fi device")
        return mac

    def enroll_station(self, mac, ssid, passphrase):
        if not MAC_RE.fullmatch(mac) or mac == WILDCARD_MAC:
            raise EnrollmentError("invalid access point station")
        entries = self._entries(self._read())
        entries.pop(WILDCARD_MAC, None)
        entries[mac] = derive_psk(ssid, passphrase)
        return self._replace_and_reload(entries)

    def revoke_station(self, mac):
        if not MAC_RE.fullmatch(mac) or mac == WILDCARD_MAC:
            raise EnrollmentError("invalid access point station")
        entries = self._entries(self._read())
        if mac not in entries:
            raise EnrollmentError("device PSK is missing from the hostapd list")
        del entries[mac]
        previous = self._replace_and_reload(entries)
        try:
            result = self.command_runner(
                ["hostapd_cli", "-p", self.control_dir, "-i", self.interface,
                 "disassociate", mac],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            self.restore(previous)
            raise EnrollmentError("hostapd could not disconnect the revoked device") from exc
        if "OK" not in (result.stdout or ""):
            self.restore(previous)
            raise EnrollmentError("hostapd could not disconnect the revoked device")
        return previous

    def restore(self, raw):
        entries = self._entries(raw)
        self._write(entries)
        self._reload()
