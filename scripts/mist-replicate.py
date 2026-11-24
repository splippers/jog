#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

FOG_ENV = os.environ.get("Brume_FOG_API_ENV", os.environ.get("JOG_FOG_API_ENV", "/etc/mist/fog-api.env"))
JOG_ENV = os.environ.get("Brume_ENV_FILE", os.environ.get("JOG_ENV_FILE", "/etc/mist/mist.env"))
BUILD_STATUS = "/var/www/html/mist-replicator-build.status"
IMAGE_NAME = "mist-replicator"
SOURCE_VM = "mist-replicator"
VM_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,63}$")
MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")


def emit(payload):
    print(json.dumps(payload, sort_keys=True))


def fail(message):
    emit({"ok": False, "error": message})
    sys.exit(1)


def run(cmd, timeout=30, check=True):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        fail("command timed out: %s" % " ".join(cmd))


def sql(query):
    p = run(["mysql", "-N", "-B", "fog", "-e", query])
    if p.returncode:
        fail("FOG database query failed: %s" % p.stderr.strip()[:300])
    return [line.split("\t") for line in p.stdout.splitlines() if line.strip()]


def scalar(query):
    rows = sql(query)
    return rows[0][0] if rows and rows[0] else ""


def q(value):
    return str(value).replace("\\", "\\\\").replace("'", "\\'")


def load_env(path):
    out = {}
    try:
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    out[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def valid_vm(name):
    return bool(VM_RE.match(name or ""))


def vm_state(name):
    p = run(["virsh", "domstate", "--domain", name], check=False)
    return p.stdout.strip() if p.returncode == 0 else ""


def vm_exists(name):
    return bool(vm_state(name))


def vm_mac(name):
    p = run(["virsh", "domiflist", "--domain", name], check=False)
    if p.returncode:
        fail("could not read NICs from %s" % name)
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 5 and MAC_RE.match(parts[4]):
            return parts[4].lower()
    fail("no usable MAC address found on %s" % name)


def host_name_for(vm, mac):
    base = re.sub(r"[^A-Za-z0-9_.-]", "-", vm)[:15] or "jogrep"
    rows = sql("SELECT hostID FROM hosts WHERE hostName='%s' LIMIT 1" % q(base))
    if not rows or rows[0][0]:
        return base
    suffix = mac.replace(":", "")[-4:]
    return (base[:10] + "-" + suffix)[:15]


def find_host_id(mac):
    rows = sql("SELECT hmHostID FROM hostMAC WHERE hmMAC='%s' LIMIT 1" % q(mac))
    return int(rows[0][0]) if rows and rows[0][0] else 0


def ensure_image(name=IMAGE_NAME):
    rows = sql("SELECT imageID FROM images WHERE imageName='%s' LIMIT 1" % q(name))
    if rows and rows[0][0]:
        return int(rows[0][0])
    path = re.sub(r"[^A-Za-z0-9_.-]", "-", name).strip("-") or "mist-image"
    sql(
        "INSERT INTO images "
        "(imageName,imageDesc,imagePath,imageCreateBy,imageTypeID,imagePartitionTypeID,imageOSID,imageFormat,imageCompress,imageEnabled,imageReplicate,imageSectorSize,imageArchID) "
        "VALUES ('%s','Brume replicator system image','%s','jogreplicate',1,1,50,5,6,1,0,512,2)"
        % (q(name), q(path))
    )
    image_id = scalar("SELECT imageID FROM images WHERE imageName='%s' LIMIT 1" % q(name))
    if not image_id:
        fail("could not create FOG image %s" % name)
    return int(image_id)


def ensure_host(vm, image_id):
    mac = vm_mac(vm)
    host_id = find_host_id(mac)
    if host_id:
        sql(
            "UPDATE hosts SET hostImage=%d,hostInfoLock=0,hostSecToken='',hostSecTime=NULL,hostSecTokenPrev='',hostEnforce=1 WHERE hostID=%d"
            % (image_id, host_id)
        )
        sql("UPDATE hostMAC SET hmPrimary=1,hmPending=0,hmIgnoreImaging=0 WHERE hmHostID=%d AND hmMAC='%s'" % (host_id, q(mac)))
        return host_id, mac
    name = host_name_for(vm, mac)
    sql(
        "INSERT INTO hosts (hostName,hostDesc,hostIP,hostImage,hostCreateBy,hostArchID,hostEnforce) "
        "VALUES ('%s','Brume managed VM','',%d,'jogreplicate',2,1)" % (q(name), image_id)
    )
    host_id = int(scalar("SELECT hostID FROM hosts WHERE hostName='%s' LIMIT 1" % q(name)) or 0)
    if not host_id:
        fail("could not create FOG host for %s" % vm)
    sql("INSERT INTO hostMAC (hmHostID,hmMAC,hmPrimary) VALUES (%d,'%s',1)" % (host_id, q(mac)))
    return host_id, mac


def add_host_id(host_id):
    try:
        with open(JOG_ENV) as handle:
            lines = handle.read().splitlines()
    except OSError:
        lines = []
    ids = []
    replaced = False
    kept = []
    for line in lines:
        if line.startswith("JOG_FOG_HOST_IDS="):
            replaced = True
            ids.extend(part.strip() for part in line.split("=", 1)[1].split(",") if part.strip().isdigit())
        else:
            kept.append(line)
    if str(host_id) not in ids:
        ids.append(str(host_id))
    if not replaced:
        kept.append("JOG_FOG_HOST_IDS=%s" % ",".join(ids))
    else:
        kept.append("JOG_FOG_HOST_IDS=%s" % ",".join(ids))
    temp = JOG_ENV + ".mist-replicate.tmp"
    with open(temp, "w") as handle:
        handle.write("\n".join(kept) + "\n")
    os.chmod(temp, 0o644)
    os.replace(temp, JOG_ENV)


def clear_tasks(host_id):
    sql("DELETE FROM taskLog WHERE taskID IN (SELECT taskID FROM tasks WHERE taskHostID=%d)" % host_id)
    sql("DELETE FROM tasks WHERE taskHostID=%d" % host_id)
    sql("UPDATE hosts SET hostInfoLock=0,hostSecToken='',hostSecTime=NULL,hostSecTokenPrev='' WHERE hostID=%d" % host_id)


def queue_task(host_id, image_id, kind):
    type_id = {"deploy": 1, "capture": 2}.get(kind)
    if not type_id:
        fail("unsupported task kind: %s" % kind)
    env = load_env(FOG_ENV)
    base = env.get("JOG_FOG_API_URL", "").rstrip("/")
    api = env.get("FOG_API_TOKEN", "")
    user = env.get("FOG_USER_TOKEN", "")
    if not base or not api or not user:
        fail("FOG API is not configured")
    headers = {
        "fog-api-token": api,
        "fog-user-token": user,
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    payload = json.dumps({"taskTypeID": type_id, "imageID": image_id, "shutdown": True}).encode()
    request = urllib.request.Request(base + "/host/%d/task" % host_id, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            response.read()
    except urllib.error.HTTPError as error:
        fail("FOG task create failed: %s" % error.read().decode("utf-8", "replace")[:200])
    except (urllib.error.URLError, OSError) as error:
        fail("FOG API unreachable: %s" % error)
    return int(scalar("SELECT MAX(taskID) FROM tasks WHERE taskHostID=%d" % host_id) or 0)


def prepare_vm(name):
    p = run(["/usr/local/sbin/mist-portal-network.sh", "vm", "fog-capture", name, "fog-capture", "0"], timeout=90)
    if p.returncode:
        fail("could not prepare %s for FOG boot: %s" % (name, (p.stderr or p.stdout).strip()[:300]))


def refresh_default():
    run(["/usr/local/sbin/mist-fog-task-default.sh"], timeout=30, check=False)


def start_vm(name):
    state = vm_state(name)
    if state.lower().startswith(("running", "paused")):
        fail("VM %s is %s; shut it down first" % (name, state))
    p = run(["virsh", "start", name], timeout=60)
    if p.returncode:
        fail("task queued but virsh start failed: %s" % p.stderr.strip()[:300])


def read_build_status():
    try:
        with open(BUILD_STATUS) as handle:
            return handle.read().strip()[:500]
    except OSError:
        return ""


def status(name=SOURCE_VM):
    image_id = int(scalar("SELECT imageID FROM images WHERE imageName='%s' LIMIT 1" % q(IMAGE_NAME)) or 0)
    mac = ""
    host_id = 0
    if vm_exists(name):
        mac = vm_mac(name)
        host_id = find_host_id(mac)
    task = []
    if host_id:
        task = sql("SELECT taskID,taskStateID,COALESCE(taskCheckIn,''),taskPCT FROM tasks WHERE taskHostID=%d ORDER BY taskID DESC LIMIT 1" % host_id)
    emit({
        "ok": True,
        "image": IMAGE_NAME,
        "imageId": image_id,
        "sourceVm": name,
        "vmExists": vm_exists(name),
        "vmState": vm_state(name),
        "mac": mac,
        "hostId": host_id,
        "buildStatus": read_build_status(),
        "task": {
            "id": int(task[0][0]) if task and task[0][0] else 0,
            "stateId": int(task[0][1]) if task and task[0][1] else 0,
            "checkIn": task[0][2] if task and len(task[0]) > 2 else "",
            "percent": task[0][3] if task and len(task[0]) > 3 else "",
        } if task else None,
    })


def cycle(kind, name):
    if not valid_vm(name):
        fail("invalid VM name")
    if not vm_exists(name):
        fail("domain not found: %s" % name)
    image_id = ensure_image()
    host_id, mac = ensure_host(name, image_id)
    add_host_id(host_id)
    clear_tasks(host_id)
    prepare_vm(name)
    task_id = queue_task(host_id, image_id, kind)
    refresh_default()
    start_vm(name)
    emit({
        "ok": True,
        "action": kind,
        "vm": name,
        "mac": mac,
        "hostId": host_id,
        "imageId": image_id,
        "image": IMAGE_NAME,
        "taskId": task_id,
        "started": True,
    })


def main():
    if len(sys.argv) < 2:
        fail("usage: mist-replicate.py status|capture|deploy [vm]")
    command = sys.argv[1]
    if command == "status":
        status(sys.argv[2] if len(sys.argv) > 2 else SOURCE_VM)
    elif command == "capture":
        cycle("capture", sys.argv[2] if len(sys.argv) > 2 else SOURCE_VM)
    elif command == "deploy":
        if len(sys.argv) < 3:
            fail("usage: mist-replicate.py deploy <targetVm>")
        cycle("deploy", sys.argv[2])
    else:
        fail("unknown command: %s" % command)


if __name__ == "__main__":
    main()
