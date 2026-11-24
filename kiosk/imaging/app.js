if(typeof Warning==="undefined"){window.Warning=class Warning extends Error{constructor(m){super(m);this.name="Warning";}};}
const state = {
  mode: "live",
  adminUser: "haaradmin",
  devices: [],
  hosts: [],
  images: [],
  sessions: [],
  multicast: null,
  replicator: null,
  interfaces: [],
  vms: [],
  isos: [],
  boot: null,
  networks: [],
  nics: [],
  disks: [],
  usb: [],
  hardware: null,
  fogNetwork: null,
  selectedVm: "",
  lastWarning: "",
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = String(text);
  return node;
}

function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function banner(message, isError = false) {
  const node = $("#banner");
  node.textContent = message;
  node.classList.toggle("error", isError);
  node.hidden = !message;
  if (message && !isError) setTimeout(() => { node.hidden = true; }, 6000);
}

function warn(message) {
  if (!message) {
    state.lastWarning = "";
    return;
  }
  if (message !== state.lastWarning) {
    state.lastWarning = message;
    banner(message, true);
  }
}

function connection(ok) {
  const node = $("#conn");
  node.classList.toggle("online", ok);
  node.classList.toggle("offline", !ok);
  node.lastElementChild.textContent = ok ? "Portal online" : "Portal offline";
}

function safetyChip(safety) {
  const node = $("#safe");
  if (!safety) return;
  node.textContent = "Safety: " + (safety.state === "safe" ? "armed" : "review");
  node.classList.toggle("ok", safety.state === "safe");
  node.classList.toggle("bad", safety.state !== "safe");
}

async function request(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    cache: "no-store",
    ...options,
  });
  let data;
  try {
    data = await response.json();
  } catch (error) {
    throw new Error("Invalid response from portal (" + response.status + ")");
  }
  if (!response.ok || data.ok === false) throw new Error(data.error || "Request failed (" + response.status + ")");
  connection(true);
  warn(data.warning);
  return data;
}

let sudoResolver = null;

function sudoPrompt(reason) {
  return new Promise((resolve) => {
    sudoResolver = resolve;
    $("#sudo-reason").textContent = reason || "This action needs root privileges. Enter a sudo-capable local account.";
    $("#sudo-user").value = state.adminUser || "haaradmin";
    $("#sudo-pass").value = "";
    $("#sudo-error").hidden = true;
    $("#sudo-modal").hidden = false;
    setTimeout(() => $("#sudo-pass").focus(), 20);
  });
}

function closeSudo(value) {
  $("#sudo-modal").hidden = true;
  $("#sudo-pass").value = "";
  const resolver = sudoResolver;
  sudoResolver = null;
  if (resolver) resolver(value);
}

async function sudoRequest(path, payload = {}, reason) {
  const creds = await sudoPrompt(reason);
  if (!creds) return null;
  const body = { ...payload, username: creds.username, password: creds.password };
  return request(path, { method: "POST", body: JSON.stringify(body) });
}

function value(node) {
  return node ? node.value.trim() : "";
}

function setBusy(node, busy) {
  if (!node) return;
  node.disabled = Boolean(busy);
  node.classList.toggle("busy", Boolean(busy));
}

function setStatus(selector, message, kind = "notice") {
  const node = $(selector);
  if (!node) return;
  node.textContent = message || "";
  node.hidden = !message;
  node.classList.remove("error", "notice", "busy");
  if (message) node.classList.add(kind);
}

function readHwField(node) {
  if (node.type === "checkbox") return node.checked;
  if (node.dataset.hwJson) {
    try {
      const parsed = JSON.parse(node.value);
      return parsed === null || parsed === "" ? [] : parsed;
    } catch (error) {
      throw new Error("Enter valid JSON for " + (node.dataset.hwKey || "this field"));
    }
  }
  if (node.dataset.hwList) return node.value.split(",").map((part) => part.trim()).filter(Boolean);
  const text = node.value.trim();
  if (node.dataset.hwInt) return text === "" ? "" : Number(text);
  return text;
}

function buildHwPatch(section) {
  const container = document.querySelector('[data-hw-group="' + section + '"]');
  const patch = {};
  if (!container) return patch;
  container.querySelectorAll("[data-hw-key]").forEach((node) => {
    const parsed = readHwField(node);
    if (parsed === "" || parsed === undefined || parsed === null) return;
    patch[node.dataset.hwKey] = parsed;
  });
  return patch;
}

function fillHwForms(hardware) {
  if (!hardware) return;
  Object.entries(hardware).forEach(([section, values]) => {
    const container = document.querySelector('[data-hw-group="' + section + '"]');
    if (!container || !values || typeof values !== "object") return;
    container.querySelectorAll("[data-hw-key]").forEach((node) => {
      const current = values[node.dataset.hwKey];
      if (current === undefined || current === null) return;
      if (node.type === "checkbox") node.checked = Boolean(current);
      else if (node.dataset.hwJson) node.value = JSON.stringify(current);
      else if (node.dataset.hwList) node.value = (current || []).join(", ");
      else node.value = String(current);
    });
  });
}

function renderHardware(name, hardware) {
  const summary = $("#vm-hw-summary");
  const devices = $("#vm-hw-devices");
  if (!name || !hardware) {
    renderKV(summary, { vm: "-" });
    if (devices) clear(devices);
    return;
  }
  const machine = hardware.machine || {};
  const cpu = hardware.cpu || {};
  const memory = hardware.memory || {};
  const video = hardware.video || {};
  const graphics = hardware.graphics || {};
  const rng = hardware.rng || {};
  const watchdog = hardware.watchdog || {};
  const boot = hardware.boot || {};
  const deviceRows = hardware.devices || {};
  renderKV(summary, {
    vm: name,
    machine: [machine.type, machine.firmware, machine.secureBoot ? "secure boot" : "no secure boot", "TPM " + (machine.tpm || "none")].filter(Boolean).join(" / "),
    cpu: [cpu.model, cpu.sockets + "s" + (cpu.cores || 0) + "c" + (cpu.threads || 0) + "t", (cpu.features || []).length + " features"].filter(Boolean).join(" / "),
    memory: (memory.ramMiB || 0) + " MiB max / " + (memory.currentMiB || 0) + " MiB current / balloon " + (memory.balloonEnabled ? "on" : "off"),
    video: (video.model || "-") + " / " + (video.vramMiB || 0) + " MiB / " + (video.heads || 0) + " heads / 3D " + (video.accel3d ? "on" : "off"),
    audio: (hardware.audio || {}).model || "-",
    input: Object.entries(hardware.input || {}).filter(([, present]) => present).map(([kind]) => kind).join(", ") || "none",
    usbController: (hardware.usbController || {}).model || "none",
    graphics: (graphics.type || "-") + " " + (graphics.listen || "") + ":" + (graphics.port || "-1"),
    rng: rng.enabled ? "enabled / " + (rng.model || "-") : "disabled",
    watchdog: watchdog.enabled ? (watchdog.model || "-") + " / " + (watchdog.action || "-") : "disabled",
    boot: ((boot.order || []).join(" -> ") || "-") + (boot.menu ? " / menu on" : ""),
    devices: (deviceRows.disks || []).length + " disks, " + (deviceRows.nics || []).length + " NICs, " + (deviceRows.hostdevs || []).length + " hostdevs, " + (deviceRows.controllers || []).length + " controllers",
  });
  const rows = [];
  (deviceRows.disks || []).forEach((row) => rows.push({ kind: "disk", name: row.target, detail: row.device + " / " + (row.bus || "-") + " / " + (row.path || "-") }));
  (deviceRows.nics || []).forEach((row) => rows.push({ kind: "nic", name: row.mac || row.target, detail: (row.type || "-") + " / " + (row.source || "-") + " / " + (row.model || "-") }));
  (deviceRows.hostdevs || []).forEach((row) => rows.push({ kind: "hostdev", name: row.type || "usb", detail: [row.vendorId, row.productId].filter(Boolean).join(":") || "bus " + (row.bus || "-") + " port " + (row.device || "-") }));
  (deviceRows.controllers || []).forEach((row) => rows.push({ kind: "controller", name: row.type + ":" + (row.index || "-"), detail: row.model || "-" }));
  renderTable(devices, rows, [
    { get: (row) => row.kind },
    { get: (row) => row.name },
    { get: (row) => row.detail, className: "muted" },
  ]);
  fillHwForms(hardware);
}

function renderDevices(container, devices) {
  clear(container);
  if (!devices.length) {
    container.appendChild(element("div", "muted", "No active or recent tasks."));
    return;
  }
  devices.forEach((device) => {
    const card = element("div", "device " + device.phase);
    card.appendChild(element("div", "host", device.host));
    card.appendChild(element("div", "sub", [device.kind, device.image].filter(Boolean).join(" - ")));
    const bar = element("div", "bar-progress");
    const fill = element("span");
    fill.style.width = Number(device.percent || 0) + "%";
    bar.appendChild(fill);
    card.appendChild(bar);
    const detail = element("div", "sub", device.state + "  " + Math.round(Number(device.percent || 0)) + "%" + (device.rate ? "  " + device.rate : ""));
    card.appendChild(detail);
    if (device.elapsed || device.remaining) card.appendChild(element("div", "sub", "Elapsed " + (device.elapsed || "-") + " / remaining " + (device.remaining || "-")));
    if (device.canCancel && device.id) {
      const cancel = element("button", "btn danger", "Cancel task");
      cancel.addEventListener("click", () => deleteTask(device.id, device.host));
      card.appendChild(cancel);
    }
    container.appendChild(card);
  });
}

function renderKV(container, pairs) {
  clear(container);
  Object.entries(pairs).forEach(([key, val]) => {
    const row = element("div", "kv-row");
    row.appendChild(element("span", "", key));
    const valueNode = element("span", "", val === undefined || val === "" ? "-" : val);
    row.appendChild(valueNode);
    container.appendChild(row);
  });
}

function renderServices(container, services) {
  clear(container);
  const items = Array.isArray(services) ? services : Object.entries(services || {}).map(([name, state]) => ({name, unit:name, state, ok: state === "active"}));
  items.forEach((svc) => {
    const name = svc.name || svc.unit || "unknown";
    const unit = svc.unit || svc.name || name;
    const status = svc.state || (svc.ok ? "active" : "unknown");
    const line = element("div", "table-row");
    line.appendChild(element("div", "", name));
    line.appendChild(element("div", status === "active" ? "pill good" : "pill warn", status));
    const buttons = element("div", "row-buttons");
    const restart = element("button", "btn", "Restart");
    restart.addEventListener("click", async () => {
      try {
        const result = await sudoRequest("/api/system/service", { name: unit, action: "restart" }, "Restart " + name + ".");
        if (!result) return;
        banner(name + " restarted.");
        await loadOverview();
      } catch (error) { banner(error.message, true); }
    });
    const logs = element("button", "btn", "Logs");
    logs.addEventListener("click", async () => {
      try {
        const result = await sudoRequest("/api/system/logs", { unit: unit }, "Read " + name + " logs.");
        if (!result) return;
        output("#logs-output", result.output || result);
        $("#logs-unit").value = unit;
        activate("system");
      } catch (error) { banner(error.message, true); }
    });
    buttons.appendChild(restart);
    buttons.appendChild(logs);
    line.appendChild(buttons);
    container.appendChild(line);
  });
}

function renderTable(container, rows, columns) {
  clear(container);
  if (!rows.length) {
    container.appendChild(element("div", "muted", "No records found."));
    return;
  }
  rows.forEach((row) => {
    const line = element("div", "table-row");
    columns.forEach((column) => {
      const content = column.get(row);
      const className = typeof column.className === "function" ? column.className(row) : column.className || "";
      const cell = content instanceof Node ? content : element("div", className, content);
      line.appendChild(cell);
    });
    container.appendChild(line);
  });
}

function fillSelect(select, rows, placeholder, label, valueKey) {
  clear(select);
  const first = element("option", "", placeholder);
  first.value = "";
  select.appendChild(first);
  rows.forEach((row) => {
    const option = element("option", "", label(row));
    option.value = String(row[valueKey] ?? "");
    select.appendChild(option);
  });
}

async function deleteRecord(kind, id, label) {
  if (!id) return banner("Record has no ID.", true);
  try {
    const result = await sudoRequest("/api/fog/delete", { kind, id }, "Delete " + label + ".");
    if (!result) return;
    banner(label + " deleted.");
    if (kind === "hosts") await loadHosts();
    if (kind === "sessions") await loadSessions();
  } catch (error) { banner(error.message, true); }
}

async function deleteTask(id, host) {
  if (!id) return banner("Task has no ID.", true);
  try {
    const result = await sudoRequest("/api/fog/delete", { kind: "tasks", id }, "Cancel FOG task " + id + " for " + host + ".");
    if (!result) return;
    banner("Task " + id + " cancelled.");
    await loadDevices();
    await loadOverview();
  } catch (error) { banner(error.message, true); }
}

async function loadSession() {
  const data = await request("/api/session");
  state.mode = data.mode;
  state.adminUser = data.adminUser || "haaradmin";
  const chip = $("#mode");
  chip.textContent = data.mode.toUpperCase();
  chip.hidden = false;
}

async function loadOverview() {
  const data = await request("/api/overview");
  state.devices = data.devices || [];
  $("#n-imaging").textContent = data.summary.imaging || 0;
  $("#n-queued").textContent = data.summary.queued || 0;
  $("#n-complete").textContent = data.summary.complete || 0;
  $("#n-failed").textContent = data.summary.failed || 0;
  renderDevices($("#overview-grid"), state.devices.slice(0, 8));
  renderKV($("#services"), data.services || {});
  renderKV($("#safety-summary"), { interface: data.safety?.imagingInterface, usbEthernet: data.safety?.usbEthernet, dhcpEnabled: data.safety?.dhcpEnabled, state: data.safety?.state });
  renderServices($("#system-services"), data.services || {});
  renderKV($("#fog-summary"), {
    configured: data.fogApi?.configured ? "yes" : "no",
    url: data.fogApi?.url || "",
    mode: state.mode,
  });
  renderNetworkSummary(data.network || {});
  safetyChip(data.safety);
  await loadBattery();
}

function renderNetworkSummary(net) {
  const s = net.summary || net || {};
  const iface = s.defaultInterface || s.iface || "-";
  const ip = s.ip || "-";
  const gw = s.gateway || "-";
  const ssid = s.ssid || "";
  const signal = s.signal || "";
  $("#sys-network").textContent = iface + (s.signal ? "" : "");
  $("#sys-ip").textContent = (ip !== "-" ? ip : "-") + (gw !== "-" ? " / " + gw : "");
  $("#sys-wifi").textContent = ssid ? (ssid + (signal ? " (" + signal + ")" : "")) : (iface || "-");
  $("#sys-dns").textContent = s.dns || "-";
}

function batteryValue(value, fallback = "-") {
  return value === null || value === undefined || value === "" ? fallback : String(value);
}

function batteryNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function batteryTitle(value) {
  return String(value).replace(/-/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

function renderBattery(data) {
  const present = !!data && data.present === true && data.ok !== false;
  const percent = present ? batteryNumber(data.percentage) : null;
  const health = present ? batteryNumber(data.healthPercent) : null;
  const label = present ? batteryValue(data.healthLabel, "Unknown") : "Unknown";
  const bar = $("#battery-bar");
  const fill = $("#battery-bar-fill");

  $("#battery-note").hidden = present;
  $("#battery-level").textContent = percent === null ? "--" : Math.round(percent) + "%";
  fill.style.width = percent === null ? "0%" : Math.max(0, Math.min(100, percent)) + "%";
  bar.className = "battery-bar" + (percent === null ? "" : " " + (percent >= 60 ? "good" : percent >= 30 ? "fair" : "poor"));

  const healthNode = $("#battery-health");
  const healthClass = ["good", "fair", "poor"].includes(label.toLowerCase()) ? label.toLowerCase() : "";
  healthNode.className = healthClass;
  healthNode.textContent = present ? (health === null ? label : health.toFixed(1) + "% " + label) : "-";

  $("#battery-state").textContent = present && data.state ? batteryTitle(data.state) : "-";
  const device = present ? [data.vendor, data.model].filter(Boolean).join(" ").trim() : "";
  $("#battery-model").textContent = device || "-";
  const remaining = present ? data.timeToEmpty || data.timeToFull : "";
  $("#battery-time").textContent = remaining ? remaining + (data.timeToEmpty ? " to empty" : " to full") : "-";
  const warnNode = $("#battery-warning");
  if (warnNode) warnNode.textContent = present ? batteryValue(data.warning) : "-";
  const warningNode = $("#battery-warning");
  warningNode.className = /critical|low/.test(warning.toLowerCase()) ? "poor" : "";
  warningNode.textContent = warning;
}

async function loadBattery() {
  let data = null;
  try {
    const response = await fetch("/api/battery", { cache: "no-store" });
    const body = await response.json();
    if (response.ok && body.ok !== false) data = body;
  } catch (error) {
    data = null;
  }
  renderBattery(data);
}

async function loadDevices() {
  const [active, history] = await Promise.all([
    request("/api/devices"),
    request("/api/fog/tasks/history").catch((error) => ({ rows: [], warning: error.message })),
  ]);
  const merged = [];
  const seen = new Set();
  [...(active.devices || []), ...(history.rows || [])].forEach((device) => {
    const key = String(device.id || (device.host + "|" + device.image + "|" + device.started));
    if (!seen.has(key)) { seen.add(key); merged.push(device); }
  });
  const rank = { imaging: 0, queued: 1, failed: 2, complete: 3 };
  merged.sort((a, b) => (rank[a.phase] ?? 4) - (rank[b.phase] ?? 4));
  state.devices = merged;
  renderDevices($("#task-grid"), merged);
  if (history.warning) warn(history.warning);
}

async function loadHosts(search = "") {
  const data = await request("/api/fog/hosts" + (search ? "?search=" + encodeURIComponent(search) : ""));
  state.hosts = data.rows || [];
  renderTable($("#hosts-table"), state.hosts, [
    { get: (r) => r.name },
    { get: (r) => r.mac, className: "muted" },
    { get: (r) => r.description || r.image || "", className: "muted" },
    { get: (r) => {
      const button = element("button", "btn danger", "Delete");
      button.addEventListener("click", () => deleteRecord("hosts", r.id, r.name));
      return button;
    } },
  ]);
  fillSelect($("#task-host"), state.hosts, "Select host", (r) => r.name + (r.mac ? " (" + r.mac + ")" : ""), "id");
  fillSelect($("#mc-launch-host"), state.hosts, "Select host", (r) => r.name + (r.mac ? " (" + r.mac + ")" : ""), "id");
}

async function loadImages() {
  const data = await request("/api/fog/images");
  state.images = data.rows || [];
  renderTable($("#images-table"), state.images, [
    { get: (r) => r.name },
    { get: (r) => r.path, className: "muted" },
    { get: (r) => r.format, className: "muted" },
    { get: (r) => r.size || r.enabled || "", className: "muted" },
  ]);
  fillSelect($("#task-image"), state.images, "Select image", (r) => r.name, "id");
  fillSelect($("#mc-image"), state.images, "Select image", (r) => r.name, "id");
  fillSelect($("#mc-launch-image"), state.images, "Select image", (r) => r.name, "id");
}

async function loadSessions() {
  const data = await request("/api/fog/sessions");
  state.sessions = data.rows || [];
  renderTable($("#mc-table"), state.sessions, [
    { get: (r) => r.name },
    { get: (r) => r.image, className: "muted" },
    { get: (r) => "port " + (r.port || "-") + ", clients " + (r.clients || "-"), className: "muted" },
    { get: (r) => r.state, className: "muted" },
    { get: (r) => {
      const button = element("button", "btn danger", "Delete");
      button.addEventListener("click", () => deleteRecord("sessions", r.id, r.name));
      return button;
    } },
  ]);
}

async function loadMulticastStatus() {
  const data = await request("/api/fog/multicast/status");
  state.multicast = data;
  const wall = $("#mc-wall");
  wall.textContent = "";
  const sessions = data.sessions || [];
  if (!sessions.length) {
    wall.appendChild(element("div", "muted", "No multicast sessions yet. Launch one above to start a live stream."));
  }
  sessions.forEach((session) => {
    const card = element("div", "mc-session");
    const head = element("div", "mc-head");
    const title = element("strong", "", session.name || "Multicast session");
    const detail = element("span", "muted", (session.image || "image") + " · port " + (session.port || "-") + " · " + (session.logpath || ""));
    const label = element("span", "mc-pill", (session.state || "Unknown") + " " + Math.round(Number(session.percent) || 0) + "%");
    const left = element("div");
    left.appendChild(title);
    left.appendChild(detail);
    head.appendChild(left);
    head.appendChild(label);
    card.appendChild(head);
    const bar = element("div", "mc-bar");
    const fill = element("div", "mc-fill");
    fill.style.width = Math.max(0, Math.min(100, Number(session.percent) || 0)) + "%";
    bar.appendChild(fill);
    card.appendChild(bar);
    const clients = element("div", "mc-clients");
    if (!(session.clients || []).length) {
      clients.appendChild(element("div", "muted", "Waiting for clients to check in"));
    }
    (session.clients || []).forEach((client) => {
      const row = element("div", "mc-client");
      const pct = Math.round(Number(client.percent) || 0);
      row.appendChild(element("span", "", client.host || "client"));
      row.appendChild(element("span", "muted", client.state || ""));
      row.appendChild(element("span", "", pct + "%"));
      const cbar = element("div", "mc-bar");
      const cfill = element("div", "mc-fill");
      cfill.style.width = pct + "%";
      cbar.appendChild(cfill);
      row.appendChild(cbar);
      clients.appendChild(row);
    });
    card.appendChild(clients);
    wall.appendChild(card);
  });
  $("#mc-summary").textContent = (data.active || 0) + " active · " + (data.clients || 0) + " clients" + (data.throughput ? " · " + data.throughput : "");
  $("#mc-logs").textContent = (data.logs || []).slice(-14).join("\n");
}

async function loadReplicator() {
  const data = await request("/api/haar/replicate/status?vm=haar-replicator");
  state.replicator = data;
  const task = data.task || {};
  const summary = [
    data.buildStatus || "No build status",
    data.vmExists ? data.vmState || "VM present" : "Source VM missing",
    data.imageId ? "image " + data.imageId : "image not captured",
    task.id ? "task " + task.id + " state " + task.stateId : "no active task",
  ].filter(Boolean).join(" · ");
  setStatus("#rep-status", summary, data.vmExists ? "notice" : "error");
  output("#rep-detail", data);
  const source = $("#rep-source-vm");
  const target = $("#rep-target-vm");
  const options = state.vms.map((vm) => vm.name).filter(Boolean);
  fillSelect(source, options.map((name) => ({ name })), "Select VM", (r) => r.name, "name");
  fillSelect(target, options.map((name) => ({ name })), "Select VM", (r) => r.name, "name");
  if (options.includes("haar-replicator")) source.value = "haar-replicator";
  if (options.length) target.value = options.find((name) => name !== "haar-replicator") || options[0];
}

async function loadInterfaces() {
  const data = await request("/api/network/interfaces");
  state.interfaces = data.interfaces || [];
  renderTable($("#interfaces"), state.interfaces, [
    { get: (r) => r.name + (r.role ? " [" + r.role + "]" : "") },
    { get: (r) => r.ips.join(" ") || (r.wireless ? "wireless" : "no address"), className: "muted" },
    { get: (r) => r.state, className: "muted" },
    { get: (r) => [r.usb ? "USB" : "", r.wireless ? "WLAN" : r.type === "1" ? "ETH" : "", r.driver].filter(Boolean).join(" / "), className: "muted" },
    { get: (r) => (r.imagingOk ? "imaging OK" : r.hotspotOk ? "hotspot OK" : r.backhaulOk ? "backhaul OK" : "unavailable"), className: (r) => "pill " + (r.imagingOk || r.hotspotOk || r.backhaulOk ? "good" : "warn") },
  ]);
  const imaging = state.interfaces.filter((r) => r.imagingOk);
  const hotspot = state.interfaces.filter((r) => r.hotspotOk);
  const backhaul = state.interfaces.filter((r) => r.backhaulOk);
  fillSelect($("#imaging-iface"), imaging, "Select USB Ethernet", (r) => r.name + " - " + r.address, "name");
  fillSelect($("#hotspot-iface"), hotspot, "Select USB WLAN", (r) => r.name + " - " + r.address, "name");
  fillSelect($("#backhaul-iface"), backhaul, "Select interface", (r) => r.name + " - " + (r.ips.join(" ") || r.state), "name");
  const current = state.interfaces.find((r) => r.role === "imaging");
  if (current) $("#imaging-iface").value = current.name;
  const currentHotspot = state.interfaces.find((r) => r.role === "hotspot");
  if (currentHotspot) $("#hotspot-iface").value = currentHotspot.name;
  const currentBackhaul = state.interfaces.find((r) => r.role === "backhaul");
  if (currentBackhaul) $("#backhaul-iface").value = currentBackhaul.name;
}

function output(selector, text) {
  const node = $(selector);
  node.textContent = typeof text === "string" ? text : JSON.stringify(text, null, 2);
  node.hidden = false;
  return node;
}

let confirmResolver = null;

function confirmAction(message, title = "Confirm action") {
  return new Promise((resolve) => {
    confirmResolver = resolve;
    $("#confirm-title").textContent = title;
    $("#confirm-message").textContent = message;
    $("#confirm-modal").hidden = false;
    setTimeout(() => $("#confirm-ok").focus(), 20);
  });
}

function closeConfirm(value) {
  $("#confirm-modal").hidden = true;
  const resolver = confirmResolver;
  confirmResolver = null;
  if (resolver) resolver(value);
}

function formatBytes(bytes) {
  const size = Number(bytes || 0);
  if (!size) return "-";
  if (size >= 1099511627776) return (size / 1099511627776).toFixed(1) + " TiB";
  return (size / 1073741824).toFixed(1) + " GiB";
}

function vmStateClass(vmState) {
  const text = (vmState || "").toLowerCase();
  if (text.includes("running")) return "pill good";
  if (text.includes("pause") || text.includes("block")) return "pill warn";
  if (text.includes("shut") || text.includes("off")) return "pill";
  return "pill warn";
}

function vmByName(name) {
  return state.vms.find((vm) => vm.name === name) || {};
}

function setSelectedVm(name) {
  state.selectedVm = name || "";
  ["#task-vm", "#mc-launch-vm", "#vm-checkpoint-vm", "#vm-console-vm", "#vm-iso-vm", "#vm-resources-vm", "#vm-clone-source", "#vm-advanced-vm"].forEach((selector) => {
    const select = $(selector);
    if (select && name && Array.from(select.options).some((option) => option.value === name)) select.value = name;
  });
  updateVmPanels();
}

function renderCheckpoints(snapshots, vmName) {
  const container = $("#vm-checkpoint-table");
  if (!container) return;
  clear(container);
  if (!vmName) {
    container.appendChild(element("div", "muted", "Select a VM to see its checkpoints."));
    return;
  }
  if (!snapshots || !snapshots.length) {
    container.appendChild(element("div", "muted", "No checkpoints for " + vmName + " yet."));
    return;
  }
  renderTable(container, snapshots, [
    { get: (row) => row.name },
    { get: (row) => row.created || "-", className: "muted" },
    { get: (row) => row.state || "-", className: "muted" },
    { get: (row) => {
      const actions = element("div", "row-buttons");
      const restore = element("button", "btn", "Restore");
      restore.addEventListener("click", () => checkpointAction(vmName, row.name, "revert", "Restore " + vmName + " to " + row.name + "?"));
      const del = element("button", "btn danger", "Delete");
      del.addEventListener("click", () => checkpointAction(vmName, row.name, "delete", "Delete checkpoint " + row.name + "?"));
      actions.appendChild(restore);
      actions.appendChild(del);
      return actions;
    } },
  ]);
}

function updateVmPanels() {
  const vm = vmByName(state.selectedVm);
  const isoLabel = (r) => r.name + " (" + formatBytes(r.size) + ")";
  const isoSelect = $("#vm-iso-file");
  if (isoSelect) {
    const previous = isoSelect.value;
    fillSelect(isoSelect, state.isos, "Select ISO", isoLabel, "path");
    if (previous && Array.from(isoSelect.options).some((option) => option.value === previous)) isoSelect.value = previous;
  }
  renderKV($("#vm-iso-current"), {
    vm: vm.name || "-",
    attachedIso: vm.iso || "none",
    display: vm.display || "-",
  });
  renderKV($("#vm-resources-current"), {
    vm: vm.name || "-",
    state: vm.state || "-",
    ramMiB: vm.ramMiB || "-",
    vcpus: vm.vcpus === undefined ? "-" : vm.vcpus,
    disk: vm.diskPath || (vm.disk && vm.disk.path) || "-",
    diskSize: formatBytes(vm.diskSize || (vm.disk && vm.disk.size)),
    memoryUsedMiB: vm.memoryUsed === undefined ? "-" : vm.memoryUsed,
    memoryMaxMiB: vm.memoryMax === undefined ? "-" : vm.memoryMax,
  });
  const ramInput = $("#vm-resources-ram");
  const vcpuInput = $("#vm-resources-vcpus");
  if (ramInput && document.activeElement !== ramInput && vm.ramMiB) ramInput.value = vm.ramMiB;
  if (vcpuInput && document.activeElement !== vcpuInput && vm.vcpus) vcpuInput.value = vm.vcpus;
  renderCheckpoints(vm.snapshots || [], vm.name || "");
}

function renderVMCards(container, vms) {
  clear(container);
  if (!vms.length) {
    container.appendChild(element("div", "muted", "No virtual machines yet. Use Build VM to create one."));
    return;
  }
  vms.forEach((vm) => {
    const card = element("article", "vm-card");
    const head = element("div", "vm-card-head");
    head.appendChild(element("div", "vm-card-name", vm.name));
    head.appendChild(element("span", vmStateClass(vm.state), vm.state || "unknown"));
    card.appendChild(head);
    card.appendChild(element("div", "vm-card-meta", vm.osInfo || vm.osType || "Local libvirt domain"));
    const stats = element("div", "vm-card-stats");
    [
      ["RAM", vm.ramMiB ? vm.ramMiB + " MiB" : "-"],
      ["vCPUs", vm.vcpus === undefined ? "-" : vm.vcpus],
      ["IP", vm.ip || "-"],
      ["Disk", formatBytes(vm.diskSize || (vm.disk && vm.disk.size))],
      ["Snapshots", (vm.snapshots || []).length],
      ["Autostart", vm.autostart ? "on" : "off"],
    ].forEach(([label, content]) => {
      const item = element("div", "vm-stat");
      item.appendChild(element("span", "vm-stat-label", label));
      item.appendChild(element("span", "vm-stat-value", content));
      stats.appendChild(item);
    });
    card.appendChild(stats);
    const text = (vm.state || "").toLowerCase();
    const running = text.includes("running");
    const paused = text.includes("paused") || text.includes("paused (suspended)");
    const available = running || paused;
    const actions = element("div", "row-buttons");
    const start = element("button", "btn primary", "Start");
    start.disabled = available;
    start.addEventListener("click", () => vmAction(vm.name, "start", "Start " + vm.name + "."));
    const shutdown = element("button", "btn", "Shutdown");
    shutdown.disabled = !running;
    shutdown.addEventListener("click", () => vmAction(vm.name, "shutdown", "Gracefully shut down " + vm.name + "?"));
    const force = element("button", "btn danger", "Force off");
    force.disabled = !available;
    force.addEventListener("click", () => vmAction(vm.name, "force-off", "Force off " + vm.name + " without a clean shutdown?", { confirm: true }));
    const reboot = element("button", "btn", "Reboot");
    reboot.disabled = !running;
    reboot.addEventListener("click", () => vmAction(vm.name, "reboot", "Reboot " + vm.name + "?", { confirm: true }));
    const pause = element("button", "btn", paused ? "Resume" : "Pause");
    pause.disabled = !available;
    pause.addEventListener("click", () => vmAction(vm.name, paused ? "resume" : "pause", (paused ? "Resume " : "Pause ") + vm.name + "."));
    const consoleButton = element("button", "btn", "Console");
    consoleButton.addEventListener("click", () => openVMConsole(vm.name));
    const checkpoints = element("button", "btn", "Checkpoints");
    checkpoints.addEventListener("click", () => { setSelectedVm(vm.name); activate("vm-checkpoints"); });
    const media = element("button", "btn", "ISO");
    media.addEventListener("click", () => { setSelectedVm(vm.name); activate("vm-iso"); });
    const resources = element("button", "btn", "Resources");
    resources.addEventListener("click", () => { setSelectedVm(vm.name); activate("vm-resources"); });
    const clone = element("button", "btn", "Clone");
    clone.addEventListener("click", () => {
      setSelectedVm(vm.name);
      $("#vm-clone-name").value = "";
      activate("vm-build");
      banner("Source VM " + vm.name + " selected for cloning.");
    });
    const del = element("button", "btn danger", "Delete");
    del.addEventListener("click", () => vmAction(vm.name, "delete", "Permanently delete " + vm.name + " and its disks?", { confirm: true }));
    [start, shutdown, force, reboot, pause, consoleButton, checkpoints, media, resources, clone, del].forEach((button) => actions.appendChild(button));
    card.appendChild(actions);
    container.appendChild(card);
  });
}

async function vmAction(name, action, reason, options = {}) {
  if (options.confirm && !(await confirmAction(reason, "Confirm VM action"))) return;
  const payload = { name, action };
  if (options.iso) payload.iso = options.iso;
  if (options.clone) payload.clone = options.clone;
  try {
    const result = await sudoRequest("/api/vm/action", payload, reason);
    if (!result) return;
    outputIfPresent("#vm-output", result);
    banner(name + " " + action + " completed.");
    await loadVMState();
  } catch (error) {
    banner(error.message, true);
  }
}

function outputIfPresent(selector, text) {
  if ($(selector)) output(selector, text);
}

async function checkpointAction(name, checkpoint, action, reason) {
  if (action === "revert" || action === "delete") {
    if (!(await confirmAction(reason, "Confirm checkpoint action"))) return;
  }
  try {
    const result = await sudoRequest("/api/vm/checkpoint", { action, name, checkpoint }, reason);
    if (!result) return;
    output("#vm-checkpoint-output", result.snapshots || result);
    banner("Checkpoint " + action + " completed.");
    await loadVMState();
  } catch (error) {
    banner(error.message, true);
  }
}

async function loadVMConsole() {
  const name = value($("#vm-console-vm"));
  if (!name) return banner("Select a VM first.", true);
  try {
    const data = await request("/api/vm/local/console?name=" + encodeURIComponent(name));
    output("#vm-display-output", data);
    const frame = $("#vm-console-frame");
    const link = $("#vm-console-link");
    if (data.url) {
      frame.src = data.url;
      frame.hidden = false;
      link.href = data.url;
      link.hidden = false;
      link.textContent = "Open " + name + " in new tab";
      $("#vm-console-status").textContent = name + "  " + (data.display || "") + "  token " + (data.token || "");
    } else {
      frame.hidden = true;
      link.hidden = true;
      $("#vm-console-status").textContent = "No console URL returned for " + name + ".";
    }
  } catch (error) {
    banner(error.message, true);
    $("#vm-console-frame").hidden = true;
    $("#vm-console-link").hidden = true;
    $("#vm-console-status").textContent = "Console unavailable.";
  }
}

async function openVMConsole(name) {
  setSelectedVm(name);
  activate("vm-console");
  await loadVMConsole();
}

async function loadVMState() {
  const data = await request("/api/vm/local/view");
  state.vms = data.vms || [];
  state.isos = data.isos || [];
  const windowsIsos = state.isos.filter((r) => !/virtio/i.test(r.name));
  const virtioIsos = state.isos.filter((r) => /virtio/i.test(r.name));
  const isoLabel = (r) => r.name + " (" + formatBytes(r.size) + ")";
  fillSelect($("#vm-iso"), windowsIsos, "No install media (blank VM)", isoLabel, "path");
  fillSelect($("#vm-virtio"), virtioIsos.length ? virtioIsos : state.isos, "No VirtIO media", isoLabel, "path");
  const preferredWindows = windowsIsos.find((r) => /26h2|win11/i.test(r.name)) || windowsIsos[0];
  if (preferredWindows) $("#vm-iso").value = preferredWindows.path;
  if (virtioIsos[0]) $("#vm-virtio").value = virtioIsos[0].path;
  const running = state.vms.filter((r) => (r.state || "").toLowerCase().includes("running")).length;
  const paused = state.vms.filter((r) => (r.state || "").toLowerCase().includes("paused")).length;
  $("#vm-count").textContent = state.vms.length;
  $("#vm-running").textContent = running;
  $("#vm-stopped").textContent = state.vms.length - running - paused;
  $("#vm-other").textContent = paused;
  renderVMCards($("#vm-table"), state.vms);
  const vmOptions = state.vms.map((r) => ({ name: r.name }));
  ["#task-vm", "#mc-launch-vm", "#vm-checkpoint-vm", "#vm-console-vm", "#vm-iso-vm", "#vm-resources-vm", "#vm-clone-source", "#vm-advanced-vm"].forEach((selector) => {
    fillSelect($(selector), vmOptions, "Select VM", (r) => r.name, "name");
  });
  const names = state.vms.map((r) => r.name);
  setSelectedVm(names.includes(state.selectedVm) ? state.selectedVm : names[0] || "");
}

async function refreshPanel(name) {
  try {
    if (name === "overview" || name === "system") await loadOverview();
    if (["overview", "system", "safety"].includes(name)) await loadBattery();
    if (name === "tasks") await Promise.all([loadDevices(), loadHosts(), loadImages()]);
    if (name === "hosts") await loadHosts(value($("#host-search")));
    if (name === "images") await loadImages();
    if (name === "multicast") await Promise.all([loadSessions(), loadImages(), loadMulticastStatus()]);
    if (name === "replicate") await Promise.all([loadVMState(), loadReplicator()]);
    if (name === "network") await loadInterfaces();
    if (["vm-fleet", "vm-build", "vm-checkpoints", "vm-console", "vm-iso", "vm-resources", "vm-advanced"].includes(name)) await loadVMState();
    if (name === "haarmetry") await loadInterfaces();
    if (name === "safety") await loadOverview();
    if (name === "tutorial") renderTutorialProgress();
  } catch (error) {
    connection(false);
    banner(error.message, true);
  }
}

function activate(name) {
  $$(".nav button").forEach((button) => button.classList.toggle("active", button.dataset.panel === name));
  $$(".panel").forEach((panel) => panel.classList.toggle("active", panel.dataset.panel === name));
  refreshPanel(name);
}

function randomToken(bytes = 18) {
  const buffer = new Uint8Array(bytes);
  crypto.getRandomValues(buffer);
  return Array.from(buffer).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function hotspotToken() {
  const passphrase = randomToken(18);
  $("#hotspot-pass").value = passphrase;
  const bearer = randomToken(24);
  output("#hotspot-token", "HOTSPOT_SSID=Brumetry\nWPA_PASSPHRASE=" + passphrase + "\nWIFI_QR_PAYLOAD=WIFI:T:WPA;S:Brumetry;P:" + passphrase + ";H:true;;\nBrumetry_BEARER=" + bearer);
  output("#haarmetry-token-out", "WIFI_QR_PAYLOAD=WIFI:T:WPA;S:Brumetry;P:" + passphrase + ";H:true;;\nBrumetry_BEARER=" + bearer);
}

async function applyNetwork(kind, reason) {
  const iface = value($("#" + kind + "-iface"));
  if (!iface) {
    banner("Select an interface first.", true);
    return;
  }
  let payload = { iface };
  if (kind === "imaging") {
    payload = {
      ...payload,
      ip: value($("#imaging-ip")),
      prefix: value($("#imaging-prefix")),
      start: value($("#imaging-start")),
      end: value($("#imaging-end")),
      netmask: value($("#imaging-netmask")),
      router: value($("#imaging-router")),
      bootfile: value($("#imaging-bootfile")),
    };
  } else if (kind === "backhaul") {
    payload = {
      ...payload,
      mode: value($("#backhaul-mode")),
      address: value($("#backhaul-address")),
      prefix: value($("#backhaul-prefix")),
      gateway: value($("#backhaul-gateway")),
      dns: value($("#backhaul-dns")),
      ssid: value($("#backhaul-ssid")),
      password: value($("#backhaul-wifi-password")),
      hidden: $("#backhaul-hidden").checked ? "1" : "0",
    };
  } else if (kind === "hotspot") {
    payload = {
      ...payload,
      ssid: value($("#hotspot-ssid")),
      passphrase: value($("#hotspot-pass")),
      channel: value($("#hotspot-channel")),
      ip: value($("#hotspot-ip")),
      prefix: value($("#hotspot-prefix")),
      start: value($("#hotspot-start")),
      end: value($("#hotspot-end")),
    };
  }
  try {
    const result = await sudoRequest("/api/network/" + kind, payload, reason);
    if (!result) return;
    output("#network-output", result);
    banner(kind + " configuration applied.");
    await loadInterfaces();
  } catch (error) {
    banner(error.message, true);
  }
}

function updateModeVisibility() {
  const mode = value($("#backhaul-mode"));
  $$(".static-only").forEach((node) => { node.hidden = mode !== "static"; });
  $$(".wifi-only").forEach((node) => { node.hidden = mode !== "wifi"; });
}

const tutorialChapters = ["big-picture", "boot", "network", "portal", "fog", "pxe", "vm", "imaging", "gift", "ops", "troubleshoot"];

function readTutorialProgress() {
  try {
    return JSON.parse(localStorage.getItem("haar-tutorial-progress") || "{}");
  } catch (error) {
    return {};
  }
}

function writeTutorialProgress(progress) {
  try {
    localStorage.setItem("haar-tutorial-progress", JSON.stringify(progress));
  } catch (error) {
    banner("Tutorial progress cannot be saved in this browser.", true);
  }
}

function renderTutorialProgress() {
  const progress = readTutorialProgress();
  const done = tutorialChapters.filter((chapter) => progress[chapter]).length;
  $("#tutorial-progress-text").textContent = done + " of " + tutorialChapters.length + " chapters complete";
  $("#tutorial-progress-bar").style.width = Math.round((done / tutorialChapters.length) * 100) + "%";
  $$(".tutorial-tab").forEach((tab) => tab.classList.toggle("done", Boolean(progress[tab.dataset.chapter])));
}

function activateChapter(name) {
  $$(".tutorial-tab").forEach((tab) => tab.classList.toggle("active", tab.dataset.chapter === name));
  $$(".tutorial-chapter").forEach((chapter) => chapter.classList.toggle("active", chapter.dataset.chapter === name));
  const index = tutorialChapters.indexOf(name);
  const tab = $$(".tutorial-tab").find((node) => node.dataset.chapter === name);
  const label = tab ? tab.textContent.replace(/^\d+\.\s*/, "") : name;
  $("#tutorial-current").textContent = "Chapter " + (index + 1) + ": " + label;
}

function completeChapter(name) {
  const progress = readTutorialProgress();
  progress[name] = true;
  writeTutorialProgress(progress);
  renderTutorialProgress();
  banner("Chapter marked complete.");
}

function advancedVmName() {
  return value($("#vm-advanced-vm")) || state.selectedVm;
}

function renderNetworks(networks) {
  const container = $("#vm-networks-table");
  if (!container) return;
  renderTable(container, networks, [
    { get: (row) => row.name },
    { get: (row) => element("span", "pill " + (row.state === "active" ? "good" : "warn"), row.state || "-") },
    { get: (row) => row.autostart ? "yes" : "no", className: "muted" },
    { get: (row) => row.bridge || "-", className: "muted" },
    { get: (row) => row.mode + (row.forward && row.forward !== row.mode ? " / " + row.forward : ""), className: "muted" },
    { get: (row) => (row.dhcp || []).map((item) => item.start + "-" + item.end).join(", ") || "-", className: "muted" },
    { get: (row) => {
      const actions = element("div", "row-buttons");
      const toggle = element("button", "btn", row.state === "active" ? "Stop" : "Start");
      toggle.addEventListener("click", () => advancedAction("/api/vm/local/network", { name: row.name, action: row.state === "active" ? "stop" : "start" }, (row.state === "active" ? "Stop " : "Start ") + row.name + "?", { confirm: row.state === "active" }));
      const del = element("button", "btn danger", "Delete");
      del.addEventListener("click", () => advancedAction("/api/vm/local/network", { name: row.name, action: "delete" }, "Delete virtual switch " + row.name + "?", { confirm: true }));
      actions.appendChild(toggle);
      actions.appendChild(del);
      return actions;
    } },
  ]);
  const options = $("#vm-network-options");
  if (!options) return;
  clear(options);
  networks.forEach((row) => {
    const option = element("option", "", row.name);
    option.value = row.name;
    options.appendChild(option);
  });
}

function renderNics(name, nics) {
  const container = $("#vm-nics-table");
  if (!container) return;
  renderTable(container, nics, [
    { get: (row) => row.mac || row.target || "-" },
    { get: (row) => row.type + (row.source ? " / " + row.source : ""), className: "muted" },
    { get: (row) => row.model || "-", className: "muted" },
    { get: (row) => row.target || "-", className: "muted" },
    { get: (row) => element("span", "pill " + (row.state === "up" ? "good" : "warn"), row.state || "-") },
    { get: (row) => row.pci || "-", className: "muted" },
    { get: (row) => {
      const button = element("button", "btn danger", "Remove");
      button.addEventListener("click", () => advancedAction("/api/vm/local/nics", { name, action: "remove", identifier: row.mac || row.target }, "Remove NIC " + (row.mac || row.target) + " from " + name + "?", { confirm: true }));
      return button;
    } },
  ]);
  const select = $("#vm-nic-target");
  if (!select) return;
  const previous = select.value;
  const rows = nics.map((row, index) => ({ value: row.mac || row.target || String(index), label: (row.mac || row.target || "NIC " + (index + 1)) + " - " + (row.source || row.type) }));
  fillSelect(select, rows, "Select NIC", (row) => row.label, "value");
  if (previous && Array.from(select.options).some((option) => option.value === previous)) select.value = previous;
}

function renderDisks(name, disks) {
  const container = $("#vm-disks-table");
  if (!container) return;
  renderTable(container, disks, [
    { get: (row) => row.bootOrder ? element("span", "pill good", row.target + " (boot " + row.bootOrder + ")") : row.target },
    { get: (row) => row.bus + " / " + row.device, className: "muted" },
    { get: (row) => row.path || "-", className: "muted" },
    { get: (row) => row.format || "-", className: "muted" },
    { get: (row) => formatBytes(row.virtualSize), className: "muted" },
    { get: (row) => formatBytes(row.actualSize), className: "muted" },
    { get: (row) => row.readonly ? "readonly" : "writable", className: "muted" },
    { get: (row) => {
      const actions = element("div", "row-buttons");
      const boot = element("button", "btn", "Set boot");
      boot.addEventListener("click", () => advancedAction("/api/vm/local/disks", { name, action: "set-boot", target: row.target }, "Boot " + name + " from " + row.target + "?"));
      const detach = element("button", "btn danger", "Detach");
      detach.addEventListener("click", () => advancedAction("/api/vm/local/disks", { name, action: "detach", target: row.target }, "Detach " + row.target + " from " + name + " without deleting its file?", { confirm: true }));
      actions.appendChild(boot);
      actions.appendChild(detach);
      return actions;
    } },
  ]);
  const rows = disks.map((row) => ({ value: row.target, label: row.target + " - " + row.device + " " + (row.path || "") }));
  [["#vm-disk-target", "Select disk"], ["#vm-disk-detach-target", "Select disk"]].forEach(([selector, placeholder]) => {
    const select = $(selector);
    if (!select) return;
    const previous = select.value;
    fillSelect(select, rows, placeholder, (row) => row.label, "value");
    if (previous && Array.from(select.options).some((option) => option.value === previous)) select.value = previous;
  });
}

function renderUsb(name, devices) {
  const container = $("#vm-usb-table");
  if (!container) return;
  renderTable(container, devices, [
    { get: (row) => row.device },
    { get: (row) => [row.vendor, row.product].filter(Boolean).join(" / ") || "-", className: "muted" },
    { get: (row) => row.vendorId + ":" + row.productId, className: "muted" },
    { get: (row) => "bus " + (row.bus || "-") + " / port " + (row.port || "-"), className: "muted" },
    { get: (row) => row.description || "-", className: "muted" },
    { get: (row) => element("span", "pill " + ((row.attachedTo || []).includes(name) ? "good" : ""), (row.attachedTo || []).join(", ") || "available") },
    { get: (row) => {
      const attached = (row.attachedTo || []).includes(name);
      const action = attached ? "detach" : "attach";
      const button = element("button", attached ? "btn danger" : "btn primary", attached ? "Detach" : "Attach");
      const other = (row.attachedTo || []).find((item) => item !== name);
      button.disabled = Boolean(!attached && other);
      button.addEventListener("click", () => advancedAction("/api/vm/local/usb", { name, action, device: row.device }, (attached ? "Detach " : "Attach ") + row.device + (attached ? " from " : " to ") + name + "?", { confirm: attached }));
      return button;
    } },
  ]);
}

async function loadVmBoot(name) {
  if (!name) {
    renderKV($("#vm-boot-current"), { vm: "-" });
    return;
  }
  const data = await request("/api/vm/local/boot?name=" + encodeURIComponent(name));
  state.boot = data.boot || null;
  const boot = data.boot || {};
  renderKV($("#vm-boot-current"), {
    vm: data.name || name,
    order: (boot.order || []).join(" -> ") || "-",
    menu: boot.menu ? "enabled" : "disabled",
    devices: (boot.devices || []).map((item) => item.dev + (item.target ? " (" + item.target + ")" : "")).join(", ") || "-",
  });
  if ($("#vm-boot-device") && (boot.order || []).length) $("#vm-boot-device").value = boot.order[0];
  if ($("#vm-boot-menu")) $("#vm-boot-menu").value = boot.menu ? "1" : "0";
}

async function loadVmNetworks() {
  const data = await request("/api/vm/local/networks");
  state.networks = data.networks || [];
  renderNetworks(state.networks);
  if ($("#vm-nic-source") && !value($("#vm-nic-source")) && state.networks.length) $("#vm-nic-source").value = state.networks[0].name;
}

async function loadVmNics(name) {
  if (!name) return renderNics(name, []);
  const data = await request("/api/vm/local/nics?name=" + encodeURIComponent(name));
  state.nics = data.nics || [];
  renderNics(name, state.nics);
}

async function loadVmDisks(name) {
  if (!name) return renderDisks(name, []);
  const data = await request("/api/vm/local/disks?name=" + encodeURIComponent(name));
  state.disks = data.disks || [];
  renderDisks(name, state.disks);
}

async function loadVmUsb(name) {
  const data = await request("/api/vm/local/usb");
  state.usb = data.devices || [];
  renderUsb(name, state.usb);
}

async function loadVmHardware(name) {
  if (!name) {
    state.hardware = null;
    renderHardware(name, null);
    return;
  }
  const data = await request("/api/vm/local/hardware?name=" + encodeURIComponent(name));
  state.hardware = data.hardware || null;
  renderHardware(name, state.hardware);
}

async function fogEnsure() {
  const network = value($("#vm-fog-network")) || "fog-capture";
  setStatus("#vm-fog-status", "Ensuring capture network " + network + "...", "busy");
  setBusy($("#vm-fog-ensure"), true);
  try {
    const result = await request("/api/vm/local/fog-network", { method: "POST", body: JSON.stringify({ name: network }) });
    state.fogNetwork = result;
    output("#vm-advanced-output", result);
    setStatus("#vm-fog-status", "Network " + network + " is " + result.state + " on bridge " + (result.bridge || "-") + " (no libvirt DHCP).", "notice");
    await loadVmNetworks();
    return result;
  } catch (error) {
    setStatus("#vm-fog-status", error.message, "error");
    output("#vm-advanced-output", { ok: false, error: error.message });
    throw error;
  } finally {
    setBusy($("#vm-fog-ensure"), false);
  }
}

async function fogCapture() {
  const name = advancedVmName();
  if (!name) return banner("Select a VM.", true);
  const network = value($("#vm-fog-network")) || "fog-capture";
  const start = $("#vm-fog-start").checked;
  const reason = "Prepare " + name + " for FOG capture on " + network + (start ? " and start it" : "") + "?";
  if (!(await confirmAction(reason, "Confirm FOG capture boot"))) return false;
  setStatus("#vm-fog-status", "Preparing " + name + " for FOG capture...", "busy");
  setBusy($("#vm-fog-capture"), true);
  setBusy($("#vm-boot-fog"), true);
  try {
    const result = await request("/api/vm/local/fog-capture", { method: "POST", body: JSON.stringify({ name, network, start }) });
    output("#vm-advanced-output", result);
    setStatus("#vm-fog-status", "Prepared " + name + ": network boot first, menu enabled, NIC " + (result.mac || "-") + " on " + network + (result.started ? ", VM started" : "") + ".", "notice");
    banner("FOG capture boot prepared for " + name + ".");
    await loadVMState();
    await loadVmAdvanced();
    return true;
  } catch (error) {
    setStatus("#vm-fog-status", error.message, "error");
    output("#vm-advanced-output", { ok: false, error: error.message });
    banner(error.message, true);
    return false;
  } finally {
    setBusy($("#vm-fog-capture"), false);
    setBusy($("#vm-boot-fog"), false);
  }
}

async function hardwareApply(section) {
  const name = advancedVmName();
  if (!name) return banner("Select a VM.", true);
  let patch;
  try {
    patch = buildHwPatch(section);
  } catch (error) {
    setStatus("#vm-hw-status", error.message, "error");
    return banner(error.message, true);
  }
  if (!Object.keys(patch).length) return banner("No " + section + " settings to apply.", true);
  const reason = "Apply " + section + " hardware settings to " + name + "?";
  if (!(await confirmAction(reason, "Confirm hardware change"))) return false;
  const button = document.querySelector('[data-hw-apply="' + section + '"]');
  setBusy(button, true);
  setStatus("#vm-hw-status", "Applying " + section + " settings to " + name + "...", "busy");
  try {
    const result = await request("/api/vm/local/hardware", { method: "POST", body: JSON.stringify({ name, patch }) });
    output("#vm-advanced-output", result);
    setStatus("#vm-hw-status", "Applied " + (result.applied || []).join(", ") + ". Backup: " + (result.backup || "saved") + ".", "notice");
    banner("Hardware updated for " + name + ".");
    await loadVMState();
    await loadVmAdvanced();
    return true;
  } catch (error) {
    setStatus("#vm-hw-status", error.message, "error");
    output("#vm-advanced-output", { ok: false, error: error.message });
    banner(error.message, true);
    return false;
  } finally {
    setBusy(button, false);
  }
}

async function loadVmAdvanced() {
  const name = advancedVmName();
  if (!name) {
    renderKV($("#vm-boot-current"), { vm: "-" });
    renderHardware(name, null);
    renderNetworks([]);
    renderNics(name, []);
    renderDisks(name, []);
    renderUsb(name, []);
    return;
  }
  const results = await Promise.allSettled([loadVmBoot(name), loadVmHardware(name), loadVmNetworks(), loadVmNics(name), loadVmDisks(name), loadVmUsb(name)]);
  results.forEach((result) => {
    if (result.status === "rejected") warn(result.reason.message || "Advanced VM refresh failed");
  });
}

async function advancedAction(path, payload, reason, options = {}) {
  if (options.confirm && !(await confirmAction(reason, "Confirm advanced VM change"))) return false;
  try {
    const result = await request(path, { method: "POST", body: JSON.stringify(payload) });
    output("#vm-advanced-output", result);
    banner(reason.replace(/[?.]$/, "") + " completed.");
    await loadVMState();
    await loadVmAdvanced();
    return true;
  } catch (error) {
    output("#vm-advanced-output", { ok: false, error: error.message });
    banner(error.message, true);
    return false;
  }
}

function updateAdvancedModeVisibility() {
  const mode = value($("#vm-net-mode"));
  $$(".vm-net-address").forEach((node) => { node.hidden = mode === "bridge"; });
  $$(".vm-net-bridge").forEach((node) => { node.hidden = mode !== "bridge"; });
}

function updateAdvancedNicFields() {
  const action = value($("#vm-nic-action"));
  $$(".nic-model-only").forEach((node) => { node.hidden = action !== "set-model"; });
  $$(".nic-network-only").forEach((node) => { node.hidden = action !== "set-network"; });
  $$(".nic-mac-only").forEach((node) => { node.hidden = action !== "set-mac"; });
}

function wireEvents() {
  $$(".nav button").forEach((button) => button.addEventListener("click", () => activate(button.dataset.panel)));
  $$("[data-panel-link]").forEach((button) => button.addEventListener("click", () => activate(button.dataset.panelLink)));
  $$("[data-refresh]").forEach((button) => button.addEventListener("click", () => refreshPanel(button.dataset.refresh)));
  $$(".tutorial-tab").forEach((button) => button.addEventListener("click", () => activateChapter(button.dataset.chapter)));
  $$("[data-next]").forEach((button) => button.addEventListener("click", () => activateChapter(button.dataset.next)));
  $$("[data-chapter-complete]").forEach((button) => button.addEventListener("click", () => completeChapter(button.dataset.chapterComplete)));
  $("#tutorial-reset").addEventListener("click", () => {
    writeTutorialProgress({});
    renderTutorialProgress();
    banner("Tutorial progress reset.");
  });
  $("#sudo-cancel").addEventListener("click", () => closeSudo(null));
  $("#sudo-confirm").addEventListener("click", () => {
    const username = value($("#sudo-user"));
    const password = $("#sudo-pass").value;
    if (!username || !password) {
      $("#sudo-error").textContent = "Enter both username and password.";
      $("#sudo-error").hidden = false;
      return;
    }
    state.adminUser = username;
    closeSudo({ username, password });
  });
  $("#sudo-pass").addEventListener("keydown", (event) => {
    if (event.key === "Enter") $("#sudo-confirm").click();
  });
  $("#confirm-cancel").addEventListener("click", () => closeConfirm(false));
  $("#confirm-ok").addEventListener("click", () => closeConfirm(true));

  $("#task-submit").addEventListener("click", async () => {
    const hostId = value($("#task-host"));
    const imageId = value($("#task-image"));
    if (!hostId || !imageId) return banner("Select a host and image.", true);
    try {
      const result = await sudoRequest("/api/fog/tasks", {
        hostId,
        imageId,
        kind: value($("#task-kind")),
        shutdown: $("#task-shutdown").checked,
      }, "Queue a FOG imaging task.");
      if (!result) return;
      banner("Task queued.");
      await loadDevices();
    } catch (error) { banner(error.message, true); }
  });

  $("#task-run").addEventListener("click", async () => {
    const hostId = value($("#task-host"));
    const imageId = value($("#task-image"));
    const vmName = value($("#task-vm"));
    const kind = value($("#task-kind"));
    if (!hostId || !imageId || !vmName) return banner("Select a host, image and VM.", true);
    if (kind === "multicast") return banner("Run now supports deploy and capture only.", true);
    try {
      const result = await sudoRequest("/api/fog/run", {
        hostId, imageId, vmName, kind,
        network: value($("#vm-fog-network")) || "fog-capture",
        shutdown: $("#task-shutdown").checked,
      }, "Prepare " + vmName + ", queue " + kind + ", and start it now?");
      if (!result) return;
      banner("Task " + (result.taskId || "") + " queued; " + vmName + " started.");
      await Promise.all([loadDevices(), loadVMState()]);
    } catch (error) { banner(error.message, true); }
  });

  $("#host-add").addEventListener("click", async () => {
    try {
      const result = await sudoRequest("/api/fog/hosts", { name: value($("#host-name")), mac: value($("#host-mac")) }, "Register this host in FOG.");
      if (!result) return;
      banner("Host registered.");
      $("#host-name").value = "";
      $("#host-mac").value = "";
      await loadHosts();
    } catch (error) { banner(error.message, true); }
  });

  $("#host-search").addEventListener("keydown", (event) => {
    if (event.key === "Enter") loadHosts(value(event.target));
  });

  $("#image-add").addEventListener("click", async () => {
    try {
      const result = await sudoRequest("/api/fog/images", { name: value($("#image-name")), path: value($("#image-path")) }, "Create a FOG image record.");
      if (!result) return;
      banner("Image created.");
      $("#image-name").value = "";
      $("#image-path").value = "";
      await loadImages();
    } catch (error) { banner(error.message, true); }
  });

  $("#mc-launch").addEventListener("click", async () => {
    const hostId = value($("#mc-launch-host"));
    const imageId = value($("#mc-launch-image"));
    const vmName = value($("#mc-launch-vm"));
    if (!hostId || !imageId || !vmName) return banner("Select a host, image and VM for multicast.", true);
    try {
      const result = await sudoRequest("/api/fog/multicast/launch", {
        hostId, imageId,
        vmNames: [vmName],
        sessionName: value($("#mc-launch-name")) || "Brume-LIVE-" + Date.now().toString().slice(-4),
        port: value($("#mc-launch-port")) || "63100",
        clients: value($("#mc-launch-clients")) || "1",
        start: $("#mc-launch-start").checked,
      }, "Launch a multicast stream to " + vmName + "? This will redeploy the selected image.");
      if (!result) return;
      banner("Multicast session " + (result.sessionId || "") + " launched.");
      await Promise.all([loadMulticastStatus(), loadSessions(), loadDevices(), loadVMState()]);
    } catch (error) { banner(error.message, true); }
  });

  $("#mc-stop").addEventListener("click", async () => {
    try {
      const vmName = value($("#mc-launch-vm"));
      const result = await sudoRequest("/api/fog/multicast/stop", {
        vmNames: vmName ? [vmName] : [],
      }, "Stop all multicast sessions and return " + (vmName || "clients") + " to local disk?");
      if (!result) return;
      banner("Multicast stopped and cleaned up.");
      await Promise.all([loadMulticastStatus(), loadSessions(), loadDevices(), loadVMState()]);
    } catch (error) { banner(error.message, true); }
  });

  $("#mc-add").addEventListener("click", async () => {
    try {
      const result = await sudoRequest("/api/fog/sessions", {
        name: value($("#mc-name")),
        imageId: value($("#mc-image")),
        port: value($("#mc-port")),
        clients: value($("#mc-clients")),
      }, "Create a multicast session.");
      if (!result) return;
      banner("Multicast session created.");
      await loadSessions();
    } catch (error) { banner(error.message, true); }
  });

  $("#rep-capture").addEventListener("click", async () => {
    const vm = value($("#rep-source-vm")) || "haar-replicator";
    try {
      const result = await sudoRequest("/api/haar/replicate", { action: "capture", vm }, "Capture " + vm + " as the reusable Brume replicator image?");
      if (!result) return;
      banner("Task " + (result.taskId || "") + " capturing " + vm + " as haar-replicator.");
      await Promise.all([loadReplicator(), loadVMState(), loadDevices()]);
    } catch (error) { banner(error.message, true); }
  });

  $("#rep-deploy").addEventListener("click", async () => {
    const vm = value($("#rep-target-vm"));
    if (!vm || vm === "haar-replicator") return banner("Choose a target VM other than haar-replicator.", true);
    try {
      const result = await sudoRequest("/api/haar/replicate", { action: "deploy", vm }, "Deploy haar-replicator to " + vm + "? Its first boot will open the setup wizard.");
      if (!result) return;
      banner("Task " + (result.taskId || "") + " deploying haar-replicator to " + vm + ".");
      await Promise.all([loadReplicator(), loadVMState(), loadDevices()]);
    } catch (error) { banner(error.message, true); }
  });

  $("#vm-build").addEventListener("click", async () => {
    const iso = value($("#vm-iso"));
    try {
      const result = await sudoRequest("/api/vm/create", {
        name: value($("#vm-name")),
        ram: value($("#vm-ram")),
        vcpus: value($("#vm-vcpus")),
        diskGb: value($("#vm-disk")),
        iso,
        virtioIso: value($("#vm-virtio")),
        diskBus: value($("#vm-bus")),
        network: value($("#vm-network")),
        networkType: value($("#vm-network-type")),
        secureBoot: $("#vm-secure").checked ? "1" : "0",
        tpm: $("#vm-tpm").checked ? "1" : "0",
        start: $("#vm-start").checked ? "1" : "0",
      }, "Build the Windows 11 VM.");
      if (!result) return;
      output("#vm-output", result);
      state.selectedVm = value($("#vm-name"));
      banner($("#vm-start").checked ? "VM built and started." : "VM built and left shut off.");
      await loadVMState();
      activate("vm-fleet");
    } catch (error) { banner(error.message, true); }
  });

  $("#vm-clone").addEventListener("click", () => {
    const source = value($("#vm-clone-source"));
    const clone = value($("#vm-clone-name"));
    if (!source) return banner("Select a source VM.", true);
    if (!/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(clone)) return banner("Enter a valid new VM name (letters, digits, dot, underscore or dash).", true);
    return vmAction(source, "clone", "Clone " + source + " as " + clone + "?", { clone });
  });

  [["create", "Create checkpoint"], ["list", "List checkpoints"], ["restore", "Restore checkpoint"], ["delete", "Delete checkpoint"]].forEach(([action, reason]) => {
    $("#vm-checkpoint-" + action).addEventListener("click", async () => {
      const name = value($("#vm-checkpoint-vm"));
      if (!name) return banner("Select a VM.", true);
      if (action === "list") return loadVMState();
      let checkpoint = value($("#vm-checkpoint-name"));
      if (action === "create" && !checkpoint) {
        checkpoint = "cp-" + new Date().toISOString().replace(/[-:T]/g, "").slice(0, 12);
        $("#vm-checkpoint-name").value = checkpoint;
      }
      await checkpointAction(name, checkpoint, action === "restore" ? "revert" : action, reason + ".");
    });
  });

  $("#vm-console-load").addEventListener("click", loadVMConsole);
  $("#vm-console-reload").addEventListener("click", loadVMConsole);
  ["#task-vm", "#vm-console-vm", "#vm-checkpoint-vm", "#vm-iso-vm", "#vm-resources-vm", "#vm-clone-source", "#vm-advanced-vm"].forEach((selector) => {
    $(selector).addEventListener("change", (event) => setSelectedVm(value(event.target)));
  });

  $("#vm-iso-attach").addEventListener("click", () => {
    const name = value($("#vm-iso-vm"));
    const iso = value($("#vm-iso-file"));
    if (!name || !iso) return banner("Select a VM and an ISO image.", true);
    return vmAction(name, "attach-iso", "Attach " + iso.split("/").pop() + " to " + name + "?", { iso });
  });
  $("#vm-iso-detach").addEventListener("click", () => {
    const name = value($("#vm-iso-vm"));
    if (!name) return banner("Select a VM.", true);
    return vmAction(name, "detach-iso", "Eject CD-ROM media from " + name + "?", { confirm: true });
  });

  $("#vm-resources-apply").addEventListener("click", async () => {
    const name = value($("#vm-resources-vm"));
    const ram = value($("#vm-resources-ram"));
    const vcpus = value($("#vm-resources-vcpus"));
    const diskGb = value($("#vm-resources-disk"));
    if (!name) return banner("Select a VM.", true);
    if (!/^\d+$/.test(ram) || Number(ram) < 2048 || Number(ram) > 65536) return banner("RAM must be 2048-65536 MiB.", true);
    if (!/^\d+$/.test(vcpus) || Number(vcpus) < 1 || Number(vcpus) > 32) return banner("vCPUs must be 1-32.", true);
    if (diskGb && (!/^\d+$/.test(diskGb) || Number(diskGb) < 20 || Number(diskGb) > 4096)) return banner("Disk size must be 20-4096 GiB.", true);
    const reason = "Apply " + ram + " MiB RAM, " + vcpus + " vCPUs" + (diskGb ? " and " + diskGb + " GiB disk" : "") + " to " + name + "?";
    if (!(await confirmAction(reason, "Confirm resource change"))) return;
    try {
      const payload = { name, ram, vcpus };
      if (diskGb) payload.diskGb = diskGb;
      const result = await sudoRequest("/api/vm/resources", payload, reason);
      if (!result) return;
      banner("Resources updated for " + name + ".");
      await loadVMState();
    } catch (error) { banner(error.message, true); }
  });

  $("#vm-advanced-vm").addEventListener("change", (event) => {
    setSelectedVm(value(event.target));
    loadVmAdvanced();
  });
  $("#vm-advanced-console").addEventListener("click", () => openVMConsole(advancedVmName()));
  $("#vm-fog-ensure").addEventListener("click", async () => {
    try { await fogEnsure(); } catch (error) { banner(error.message, true); }
  });
  $("#vm-fog-capture").addEventListener("click", fogCapture);
  $("#vm-boot-fog").addEventListener("click", fogCapture);
  $("#vm-hw-refresh").addEventListener("click", async () => {
    const name = advancedVmName();
    if (!name) return banner("Select a VM.", true);
    setBusy($("#vm-hw-refresh"), true);
    setStatus("#vm-hw-status", "Reading hardware from " + name + "...", "busy");
    try {
      await loadVmHardware(name);
      setStatus("#vm-hw-status", "Hardware refreshed for " + name + ".", "notice");
    } catch (error) {
      setStatus("#vm-hw-status", error.message, "error");
      banner(error.message, true);
    } finally {
      setBusy($("#vm-hw-refresh"), false);
    }
  });
  $$("[data-hw-apply]").forEach((button) => button.addEventListener("click", () => hardwareApply(button.dataset.hwApply)));
  $("#vm-boot-apply").addEventListener("click", () => {
    const name = advancedVmName();
    if (!name) return banner("Select a VM.", true);
    return advancedAction("/api/vm/local/boot", { name, device: value($("#vm-boot-device")), menu: value($("#vm-boot-menu")) }, "Set boot order for " + name + "?");
  });
  $("#vm-net-mode").addEventListener("change", updateAdvancedModeVisibility);
  $("#vm-net-create").addEventListener("click", () => {
    const payload = {
      name: value($("#vm-net-name")),
      mode: value($("#vm-net-mode")),
      cidr: value($("#vm-net-cidr")),
      dhcpStart: value($("#vm-net-start")),
      dhcpEnd: value($("#vm-net-end")),
      bridge: value($("#vm-net-bridge")),
    };
    if (!payload.name) return banner("Enter a virtual switch name.", true);
    return advancedAction("/api/vm/local/networks", payload, "Create virtual switch " + payload.name + "?");
  });
  $("#vm-nic-add").addEventListener("click", () => {
    const name = advancedVmName();
    const source = value($("#vm-nic-source"));
    if (!name || !source) return banner("Select a VM and a NIC source.", true);
    const payload = { name, action: "add", sourceType: value($("#vm-nic-source-type")), source, model: value($("#vm-nic-model")) };
    const mac = value($("#vm-nic-mac"));
    if (mac) payload.mac = mac;
    return advancedAction("/api/vm/local/nics", payload, "Add a NIC to " + name + "?");
  });
  $("#vm-nic-action").addEventListener("change", updateAdvancedNicFields);
  $("#vm-nic-apply").addEventListener("click", () => {
    const name = advancedVmName();
    const identifier = value($("#vm-nic-target"));
    const action = value($("#vm-nic-action"));
    if (!name || !identifier) return banner("Select a VM and a NIC.", true);
    const payload = { name, action, identifier };
    if (action === "set-model") {
      payload.model = value($("#vm-nic-new-model"));
    } else if (action === "set-network") {
      payload.sourceType = value($("#vm-nic-new-source-type"));
      payload.source = value($("#vm-nic-new-source"));
      if (!payload.source) return banner("Enter the new NIC source.", true);
    } else if (action === "set-mac") {
      payload.newMac = value($("#vm-nic-new-mac"));
    }
    return advancedAction("/api/vm/local/nics", payload, action + " NIC " + identifier + " on " + name + "?", { confirm: action === "remove" });
  });
  $("#vm-disk-add").addEventListener("click", () => {
    const name = advancedVmName();
    if (!name) return banner("Select a VM.", true);
    const payload = { name, action: "add", sizeGiB: value($("#vm-disk-size")), bus: value($("#vm-disk-bus")), format: value($("#vm-disk-format")) };
    return advancedAction("/api/vm/local/disks", payload, "Add a disk to " + name + "?");
  });
  $("#vm-disk-resize").addEventListener("click", () => {
    const name = advancedVmName();
    const target = value($("#vm-disk-target"));
    const sizeGiB = value($("#vm-disk-resize-size"));
    if (!name || !target || !sizeGiB) return banner("Select a disk and enter the new size.", true);
    return advancedAction("/api/vm/local/disks", { name, action: "resize", target, sizeGiB }, "Resize " + target + " on " + name + " to " + sizeGiB + " GiB?");
  });
  $("#vm-disk-remove").addEventListener("click", () => {
    const name = advancedVmName();
    const target = value($("#vm-disk-target"));
    if (!name || !target) return banner("Select a disk to remove.", true);
    const deleteFile = $("#vm-disk-delete-file").checked;
    return advancedAction("/api/vm/local/disks", { name, action: "remove", target, deleteFile }, "Remove " + target + " from " + name + (deleteFile ? " and delete its image file" : "") + "?", { confirm: true });
  });
  $("#vm-disk-set-boot").addEventListener("click", () => {
    const name = advancedVmName();
    const target = value($("#vm-disk-target"));
    if (!name || !target) return banner("Select a boot disk.", true);
    return advancedAction("/api/vm/local/disks", { name, action: "set-boot", target }, "Boot " + name + " from " + target + "?");
  });
  $("#vm-disk-clear-boot").addEventListener("click", () => {
    const name = advancedVmName();
    if (!name) return banner("Select a VM.", true);
    return advancedAction("/api/vm/local/disks", { name, action: "set-boot", target: "none" }, "Clear the disk boot override on " + name + "?");
  });
  $("#vm-disk-attach").addEventListener("click", () => {
    const name = advancedVmName();
    const path = value($("#vm-disk-attach-path"));
    const target = value($("#vm-disk-attach-target"));
    if (!name || !path || !target) return banner("Enter an image path and target.", true);
    return advancedAction("/api/vm/local/disks", { name, action: "attach", path, target, bus: value($("#vm-disk-attach-bus")) }, "Attach " + path + " as " + target + " on " + name + "?");
  });
  $("#vm-disk-detach").addEventListener("click", () => {
    const name = advancedVmName();
    const target = value($("#vm-disk-detach-target"));
    if (!name || !target) return banner("Select a disk to detach.", true);
    return advancedAction("/api/vm/local/disks", { name, action: "detach", target }, "Detach " + target + " from " + name + "?", { confirm: true });
  });

  $$("[data-apply]").forEach((button) => button.addEventListener("click", () => applyNetwork(button.dataset.apply, "Apply " + button.dataset.apply + " network settings.")));
  $("#network-check").addEventListener("click", async () => {
    try {
      const result = await sudoRequest("/api/network/check", { iface: value($("#imaging-iface")), ip: value($("#imaging-ip")) }, "Run the imaging DHCP safety probe.");
      if (!result) return;
      output("#network-output", result);
      banner("Safety check passed.");
    } catch (error) { banner(error.message, true); }
  });

  $("#hotspot-generate").addEventListener("click", hotspotToken);
  $("#haarmetry-token").addEventListener("click", hotspotToken);
  $("#hotspot-clients").addEventListener("click", async () => {
    try {
      const result = await sudoRequest("/api/network/hotspot-clients", { iface: value($("#hotspot-iface")) }, "Read Brumetry hotspot clients.");
      if (!result) return;
      output("#network-output", result);
      output("#haarmetry-clients-out", result.output || result);
    } catch (error) { banner(error.message, true); }
  });
  $("#haarmetry-clients").addEventListener("click", () => $("#hotspot-clients").click());

  $("#drivers-check").addEventListener("click", async () => {
    try {
      const result = await sudoRequest("/api/drivers/check", {}, "Inspect FOG, TFTP and Windows driver shares.");
      if (!result) return;
      output("#drivers-output", result);
    } catch (error) { banner(error.message, true); }
  });

  $("#safety-run").addEventListener("click", async () => {
    try {
      const result = await sudoRequest("/api/safety/check", { iface: value($("#imaging-iface")), ip: value($("#imaging-ip")) }, "Verify that only the USB imaging NIC can offer DHCP.");
      if (!result) return;
      output("#safety-output", result);
      await loadOverview();
      banner("Network safety check passed.");
    } catch (error) {
      output("#safety-output", error.message);
      banner(error.message, true);
    }
  });

  $("#logs-load").addEventListener("click", async () => {
    try {
      const result = await sudoRequest("/api/system/logs", { unit: value($("#logs-unit")) }, "Read service logs.");
      if (!result) return;
      output("#logs-output", result.output || result);
    } catch (error) { banner(error.message, true); }
  });

  $("#backhaul-mode").addEventListener("change", updateModeVisibility);
}

async function boot() {
  wireEvents();
  updateModeVisibility();
  updateAdvancedModeVisibility();
  updateAdvancedNicFields();
  try {
    await loadSession();
    const results = await Promise.allSettled([loadOverview(), loadDevices(), loadHosts(), loadImages(), loadSessions(), loadMulticastStatus(), loadInterfaces(), loadReplicator()]);
    results.forEach((result) => {
      if (result.status === "rejected") warn(result.reason.message || "Panel load failed");
    });
  } catch (error) {
    connection(false);
    banner(error.message, true);
  }
  const tick = () => { $("#clock").textContent = new Date().toLocaleString(); };
  tick();
  setInterval(tick, 1000);
  setInterval(() => {
    const active = $(".panel.active")?.dataset.panel;
    if (active === "overview" || active === "tasks" || active === "multicast" || active === "replicate" || active === "vm-fleet") refreshPanel(active);
  }, 15000);
}

boot();
