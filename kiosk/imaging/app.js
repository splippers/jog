(function () {
  "use strict";
  var POLL_MS = 2000;
  var grid = document.getElementById("grid");
  var empty = document.getElementById("empty");
  var banner = document.getElementById("banner");
  var conn = document.getElementById("conn");
  var cards = {}; // task id -> element refs

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function stat(label) {
    var w = el("div"), v = el("b", null, "–");
    w.appendChild(v); w.appendChild(document.createTextNode(label));
    return { wrap: w, val: v };
  }
  function build(d) {
    var card = el("article", "card");
    var top = el("div", "row"), host = el("span", "host"), pill = el("span", "pill");
    top.appendChild(host); top.appendChild(pill);
    var sub = el("div", "sub2"), image = el("span"), kind = el("span"), mac = el("span", "mac");
    sub.appendChild(image); sub.appendChild(kind); sub.appendChild(mac);
    var prow = el("div", "row"), pct = el("span", "pct"), copied = el("span", "sub2");
    prow.appendChild(pct); prow.appendChild(copied);
    var track = el("div", "track"), fill = el("div", "fill");
    track.setAttribute("role", "progressbar"); track.setAttribute("aria-valuemin", "0"); track.setAttribute("aria-valuemax", "100");
    track.appendChild(fill);
    var stats = el("div", "stats"), s1 = stat("Rate"), s2 = stat("Elapsed"), s3 = stat("Remaining");
    stats.appendChild(s1.wrap); stats.appendChild(s2.wrap); stats.appendChild(s3.wrap);
    [top, sub, prow, track, stats].forEach(function (n) { card.appendChild(n); });
    return { card: card, host: host, pill: pill, image: image, kind: kind, mac: mac, pct: pct, copied: copied, track: track, fill: fill, rate: s1.val, elapsed: s2.val, remaining: s3.val };
  }
  function fill(c, d) {
    c.card.className = "card " + d.phase;
    c.host.textContent = d.host;
    c.pill.textContent = d.state || d.phase;
    c.image.textContent = d.image || "No image assigned";
    c.kind.textContent = d.kind;
    c.mac.textContent = d.mac;
    var showPct = d.phase === "imaging" || d.phase === "complete" || d.phase === "failed";
    c.pct.className = showPct ? "pct" : "pct wait";
    c.pct.textContent = showPct ? Math.round(d.percent) + "%" : "Waiting for device";
    c.copied.textContent = d.copied ? d.copied + (d.total ? " of " + d.total : "") : "";
    c.fill.style.width = (showPct ? d.percent : 0) + "%";
    c.track.setAttribute("aria-valuenow", String(Math.round(d.percent)));
    c.rate.textContent = d.rate || "–";
    c.elapsed.textContent = d.elapsed || "–";
    c.remaining.textContent = d.remaining || "–";
  }
  function render(data) {
    var s = data.summary || {};
    ["imaging", "queued", "complete", "failed"].forEach(function (k) {
      document.getElementById("n-" + k).textContent = s[k] || 0;
    });
    var seen = {};
    data.devices.forEach(function (d) {
      var key = String(d.id);
      seen[key] = true;
      if (!cards[key]) { cards[key] = build(d); }
      fill(cards[key], d);
    });
    Object.keys(cards).forEach(function (k) {
      if (!seen[k]) { cards[k].card.remove(); delete cards[k]; }
    });
    // keep DOM order equal to server order without rebuilding nodes
    data.devices.forEach(function (d, i) {
      var node = cards[String(d.id)].card;
      if (grid.children[i] !== node) grid.insertBefore(node, grid.children[i] || null);
    });
    empty.hidden = data.devices.length > 0;
    var m = document.getElementById("mode");
    m.hidden = data.mode !== "demo"; m.textContent = "Demo data";
  }
  function setConn(state, text) {
    conn.className = "conn " + state;
    conn.lastChild.textContent = text;
  }
  function poll() {
    fetch("/api/devices", { cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
      .then(function (data) {
        if (data.ok) { banner.hidden = true; setConn("ok", "Live"); }
        else { banner.hidden = false; banner.textContent = data.error || "Cannot read imaging state"; setConn("bad", "No data"); }
        render(data);
      })
      .catch(function (e) { banner.hidden = false; banner.textContent = "Lost contact with the appliance service (" + e.message + ")"; setConn("bad", "Offline"); })
      .then(function () { setTimeout(poll, POLL_MS); });
  }
  function tick() {
    var d = new Date();
    document.getElementById("clock").textContent = d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" }) + "  " + d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  }
  tick(); setInterval(tick, 1000); poll();
})();
