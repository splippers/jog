# Live imaging view

The first kiosk tab: every device that is queued, imaging, complete or failed, with progress, rate and time remaining.

```
Chromium kiosk ──▶ http://127.0.0.1:8088/  (kiosk/imaging/)
                          │  GET /api/devices every 2s
                  jog-imaging-api.py  ──▶  FOG  GET /fog/task/active   (tokens read server-side)
```

- `scripts/jog-imaging-api.py` serves the page and a normalized `/api/devices`. It binds to `127.0.0.1` only and the FOG tokens never reach the browser.
- `systemd/jog-imaging-api.service` runs it as a dynamic user with a private copy of `/etc/jog/fog-api.env` (`LoadCredential`).
- `kiosk/chromium-jog.sh` opens it as the first tab (`JOG_IMAGING_URL`; empty to omit).

## Setup

1. In the FOG web UI enable **Settings > API System** and copy the system token.
2. Create a dedicated user with the lowest rights that can list tasks, enable its API, and copy its API token.
3. Put both in `/etc/jog/fog-api.env` (root, mode 0600; template: `config/fog-api.env.example`).
4. `sudo systemctl restart jog-imaging-api`

If the tokens are missing or wrong the page says so instead of showing an empty list.

## Design and testing without FOG

`jog-imaging-api.py --demo` serves generated devices so the page can be developed and screenshotted without a FOG server.

## Known limits

- Shows active tasks only. Complete and failed counts only include tasks FOG still lists as active; a history view needs FOG's task history API and is not built.
- Field names are read tolerantly (`percent`/`pct`, `bpm`, `timeElapsed`, ...) because they were taken from FOG's task model, not from a live response. Verify against a real running task and adjust `normalize_task` if a value stays empty.
- No imaging-network safety indicator yet; it will be added with the Network Safety Framework rather than shown before the check exists.
