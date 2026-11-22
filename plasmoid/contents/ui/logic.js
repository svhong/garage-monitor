.pragma library
// Pure helpers for the Garage Monitor plasmoid: no QML types in here, so the
// same rules can be tested with node (see plasmoid/tests/test_logic.js).
// Thresholds and status rules match hub/static/index.html.

// Levels: -1 unknown (grey), 0 ok, 1 warn, 2 bad.
var UNKNOWN = -1, OK = 0, WARN = 1, BAD = 2;

function num(v) { return typeof v === "number" && isFinite(v); }

function level(v, warn, hot) {
    if (!num(v)) return OK;
    return v >= hot ? BAD : v >= warn ? WARN : OK;
}

function fmtBytes(n) {
    if (!num(n)) return "–";
    var gb = n / Math.pow(1024, 3);
    return gb >= 1 ? gb.toFixed(1) + " GB" : Math.round(n / Math.pow(1024, 2)) + " MB";
}

function fmtRate(n) {
    if (!num(n)) return "–";
    if (n >= 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + " MB/s";
    if (n >= 1024) return Math.round(n / 1024) + " KB/s";
    return Math.round(n) + " B/s";
}

function fmtDur(s) {
    if (!num(s)) return "–";
    s = Math.max(0, Math.floor(s));
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (d) return d + "d " + h + "h";
    if (h) return h + "h " + m + "m";
    if (m) return m + "m " + (s % 60) + "s";
    return s + "s";
}

function fmtTemp(v) { return num(v) ? Math.round(v) + "°C" : "–"; }

function machineStatus(m) {
    var interval = (m.report && m.report.interval) || 2;
    var fresh = Math.max(10, interval * 5);
    if (m.age_s <= fresh) return { level: OK, label: "Online", up: true };
    if (m.age_s <= 60) return { level: WARN, label: "Delayed", up: true };
    return { level: BAD, label: "Offline", up: false };
}

function hermesStatus(h, machineUp) {
    if (!machineUp) return { level: UNKNOWN, label: "Unknown", detail: "machine offline" };
    if (h.state === "running")
        return { level: OK, label: "Running", detail: "gateway up " + fmtDur(h.gateway_uptime_s) };
    if (h.state === "restarting")
        return { level: WARN, label: "Restarting",
                 detail: num(h.gateway_uptime_s) ? "gateway up " + fmtDur(h.gateway_uptime_s)
                                                 : "gateway down, supervisor active" };
    return { level: BAD, label: "Stopped", detail: "no Hermes gateway found" };
}

// Everything one machine tile needs, already formatted.
function view(m) {
    var r = m.report || {};
    var cpu = r.cpu || {}, mem = r.mem || {}, disk = r.disk || {}, net = r.net || {}, pw = r.power || {};
    var g = r.gpu, h = r.hermes;
    var st = machineStatus(m);

    var out = {
        name: m.name,
        up: st.up,
        statusLevel: st.level,
        statusLabel: st.label,
        statusText: st.up ? "up " + fmtDur(r.uptime_s) : "last seen " + fmtDur(m.age_s) + " ago",
        meta: [cpu.model, r.os].filter(Boolean).join(" · "),
        hermes: null,
        gauges: [],
        bars: [],
        footer: [],
        history: {
            cpu: (m.history && m.history.cpu) || [],
            temp: (m.history && m.history.temp) || []
        }
    };

    if (h) {
        var hs = hermesStatus(h, st.up);
        var extra = "CPU " + (num(h.cpu_percent) ? h.cpu_percent.toFixed(1) : "–") + "% · RAM " + fmtBytes(h.rss_bytes);
        if (h.restarts) extra += " · " + h.restarts + " restart" + (h.restarts > 1 ? "s" : "");
        out.hermes = { level: hs.level, label: hs.label, detail: hs.detail, extra: extra };
    }

    // Ring gauges: CPU load, CPU temperature, then GPU (or RAM when there's no GPU data).
    var hybrid = num(cpu.p_percent) && num(cpu.e_percent);
    out.gauges.push({
        label: "CPU", value: cpu.percent, min: 0, max: 100,
        level: level(cpu.percent, 80, 95),
        text: num(cpu.percent) ? Math.round(cpu.percent) + "%" : "–",
        sub: hybrid ? "P " + Math.round(cpu.p_percent) + " · E " + Math.round(cpu.e_percent)
                    : (num(cpu.freq_mhz) ? (cpu.freq_mhz / 1000).toFixed(1) + " GHz" : "")
    });
    out.gauges.push({
        label: "Temp", value: cpu.temp, min: 30, max: 100,
        level: level(cpu.temp, 75, 90),
        text: fmtTemp(cpu.temp),
        sub: num(cpu.freq_mhz) && hybrid ? (cpu.freq_mhz / 1000).toFixed(1) + " GHz" : ""
    });
    if (g) {
        var asleep = g.vendor === "amd" ? !!g.asleep : (num(g.rc6) && g.rc6 >= 95 && (g.busy || 0) < 1);
        var gsub;
        if (asleep) gsub = "asleep";
        else if (g.vendor === "amd" && num(g.temp)) gsub = fmtTemp(g.temp);
        else gsub = num(g.freq_mhz) ? g.freq_mhz + " MHz" : "";
        out.gauges.push({
            label: "GPU", value: g.busy || 0, min: 0, max: 100,
            level: Math.max(level(g.busy, 80, 95), level(g.temp, 80, 90)),
            text: Math.round(g.busy || 0) + "%", sub: gsub
        });
    } else {
        out.gauges.push({
            label: "RAM", value: mem.percent, min: 0, max: 100,
            level: level(mem.percent, 80, 92),
            text: num(mem.percent) ? Math.round(mem.percent) + "%" : "–",
            sub: fmtBytes(mem.used)
        });
    }

    out.bars.push({
        label: "RAM", pct: mem.percent, level: level(mem.percent, 80, 92),
        text: fmtBytes(mem.used) + " / " + fmtBytes(mem.total),
        sub: num(mem.temp) ? fmtTemp(mem.temp) : "", subLevel: level(mem.temp, 70, 85)
    });
    out.bars.push({
        label: "Disk", pct: disk.percent, level: level(disk.percent, 80, 90),
        text: num(disk.percent) ? Math.round(disk.percent) + "% of " + fmtBytes(disk.total) : "–",
        sub: num(disk.temp) ? fmtTemp(disk.temp) : "", subLevel: level(disk.temp, 60, 75)
    });
    if (g && num(g.vram_total) && g.vram_total > 0) {
        var vp = 100 * g.vram_used / g.vram_total;
        out.bars.push({
            label: "VRAM", pct: vp, level: level(vp, 85, 95),
            text: fmtBytes(g.vram_used) + " / " + fmtBytes(g.vram_total), sub: "", subLevel: OK
        });
    }

    if (num(r.fan_rpm)) out.footer.push({ text: "Fan " + (r.fan_rpm ? r.fan_rpm.toLocaleString() + " rpm" : "off"), level: OK });
    out.footer.push({ text: "↓ " + fmtRate(net.rx_bps) + "  ↑ " + fmtRate(net.tx_bps), level: OK });
    if (pw.plugged === false) {
        out.footer.push({ text: "On battery" + (num(pw.battery) ? " " + pw.battery + "%" : ""),
                          level: num(pw.battery) && pw.battery < 20 ? BAD : WARN });
    } else if (num(pw.battery)) {
        out.footer.push({ text: "Battery " + pw.battery + "%", level: pw.battery < 20 ? BAD : OK });
    }

    // Worst thing on this machine: drives the tile accent and the panel icon dot.
    var worst = st.level;
    if (st.up) {
        if (out.hermes) worst = Math.max(worst, out.hermes.level);
        out.gauges.forEach(function (x) { worst = Math.max(worst, x.level); });
        out.bars.forEach(function (x) { worst = Math.max(worst, x.level, x.subLevel); });
        out.footer.forEach(function (x) { worst = Math.max(worst, x.level); });
    }
    out.worst = worst;
    return out;
}

// "hermes-box, nas" -> only those machines, in that order. Blank -> all.
function filterMachines(list, filter) {
    list = list || [];
    var names = String(filter || "").split(",").map(function (s) { return s.trim(); })
                                    .filter(function (s) { return s.length; });
    if (!names.length) return list;
    var out = [];
    names.forEach(function (n) {
        for (var i = 0; i < list.length; i++)
            if (list[i].name.toLowerCase() === n.toLowerCase()) { out.push(list[i]); break; }
    });
    return out;
}

function worstLevel(views) {
    if (!views || !views.length) return UNKNOWN;
    var w = OK;
    views.forEach(function (v) { w = Math.max(w, v.worst); });
    return w;
}

function summary(views) {
    if (!views || !views.length) return "No machines";
    return views.map(function (v) {
        var t = v.name + ": " + v.statusLabel;
        if (v.up) t += " · CPU " + v.gauges[0].text + " · " + v.gauges[1].text;
        return t;
    }).join("\n");
}

// Canvas wants CSS colours; QML colours have r/g/b/a in 0..1.
function css(c, alpha) {
    var a = alpha === undefined ? c.a : alpha;
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")";
}

// Level -> colour from the Plasma theme, so it follows light/dark themes.
function levelColor(theme, lvl) {
    if (lvl === BAD) return theme.negativeTextColor;
    if (lvl === WARN) return theme.neutralTextColor;
    if (lvl === OK) return theme.positiveTextColor;
    return theme.disabledTextColor;
}

function joinUrl(base, path) {
    return String(base || "").trim().replace(/\/+$/, "") + path;
}

// Stand-ins used for a moment when the number of machines/bars changes and a
// delegate still exists for an index that's gone.
var EMPTY_ITEM = { label: "", value: null, min: 0, max: 100, level: OK, text: "", sub: "", pct: null, subLevel: OK };
var EMPTY_VIEW = { name: "", up: false, statusLevel: UNKNOWN, statusLabel: "", statusText: "", meta: "",
                   hermes: null, gauges: [], bars: [], footer: [], history: { cpu: [], temp: [] }, worst: UNKNOWN };
