// Tests for contents/ui/logic.js.   Run: node plasmoid/tests/test_logic.js
const fs = require("fs");
const path = require("path");
const assert = require("assert");

// logic.js starts with QML's ".pragma library"; drop it and load the rest.
const src = fs.readFileSync(path.join(__dirname, "../contents/ui/logic.js"), "utf8").replace(/^\.pragma library\s*/, "");
const L = new Function(src + "\nreturn { level, fmtBytes, fmtRate, fmtDur, machineStatus, hermesStatus, view, filterMachines, worstLevel, summary, css, joinUrl, UNKNOWN, OK, WARN, BAD };")();

let n = 0;
function test(name, fn) { fn(); n++; console.log("ok -", name); }

const sample = JSON.parse(fs.readFileSync(path.join(__dirname, "sample.json"), "utf8"));
const byName = (name) => sample.machines.find((m) => m.name === name);

test("formatting matches the web dashboard", () => {
    assert.strictEqual(L.fmtBytes(16 * 1024 ** 3), "16.0 GB");
    assert.strictEqual(L.fmtBytes(512 * 1024 ** 2), "512 MB");
    assert.strictEqual(L.fmtRate(2048), "2 KB/s");
    assert.strictEqual(L.fmtRate(null), "–");
    assert.strictEqual(L.fmtDur(90061), "1d 1h");
    assert.strictEqual(L.fmtDur(65), "1m 5s");
});

test("machine status thresholds", () => {
    assert.strictEqual(L.machineStatus({ age_s: 3, report: { interval: 2 } }).label, "Online");
    assert.strictEqual(L.machineStatus({ age_s: 30, report: { interval: 2 } }).label, "Delayed");
    assert.strictEqual(L.machineStatus({ age_s: 61, report: { interval: 2 } }).label, "Offline");
    // slow agents get a longer "fresh" window
    assert.strictEqual(L.machineStatus({ age_s: 20, report: { interval: 5 } }).label, "Online");
});

test("hermes status", () => {
    assert.strictEqual(L.hermesStatus({ state: "running", gateway_uptime_s: 60 }, true).level, L.OK);
    assert.strictEqual(L.hermesStatus({ state: "restarting" }, true).detail, "gateway down, supervisor active");
    assert.strictEqual(L.hermesStatus({ state: "stopped" }, true).level, L.BAD);
    assert.strictEqual(L.hermesStatus({ state: "running" }, false).level, L.UNKNOWN);
});

test("view of an Intel hybrid laptop with Hermes", () => {
    const v = L.view(byName("hermes-box"));
    assert.strictEqual(v.gauges.length, 3);
    assert.deepStrictEqual(v.gauges.map((g) => g.label), ["CPU", "Temp", "GPU"]);
    assert.ok(v.gauges[0].sub.startsWith("P "), v.gauges[0].sub);
    assert.ok(v.hermes && v.hermes.label);
    assert.ok(v.history.cpu.length > 0);
    assert.ok(v.footer.some((f) => f.text.startsWith("Battery")));
    assert.ok(v.worst >= L.OK);
});

test("machine without GPU data shows RAM as the third gauge", () => {
    const v = L.view(byName("living-room-pc"));
    assert.strictEqual(v.gauges[2].label, "RAM");
    assert.strictEqual(v.hermes, null);
    assert.ok(!v.footer.some((f) => /Battery|battery/.test(f.text)));
});

test("offline machine: status drives worst, metrics ignored", () => {
    const m = JSON.parse(JSON.stringify(byName("old-desktop")));
    m.age_s = 120;
    m.report.cpu.temp = 99;
    const v = L.view(m);
    assert.strictEqual(v.up, false);
    assert.strictEqual(v.statusLabel, "Offline");
    assert.ok(v.statusText.startsWith("last seen 2m"));
    assert.strictEqual(v.worst, L.BAD);
});

test("hot CPU raises the worst level", () => {
    const m = JSON.parse(JSON.stringify(byName("living-room-pc")));
    m.report.cpu.temp = 92;
    assert.strictEqual(L.view(m).worst, L.BAD);
    m.report.cpu.temp = 80;
    assert.ok(L.view(m).worst >= L.WARN);
});

test("AMD GPU: temperature, VRAM bar, asleep", () => {
    const m = JSON.parse(JSON.stringify(byName("living-room-pc")));
    m.report.gpu = { vendor: "amd", busy: 40, asleep: false, temp: 85, vram_used: 2 * 1024 ** 3, vram_total: 8 * 1024 ** 3 };
    let v = L.view(m);
    assert.strictEqual(v.gauges[2].label, "GPU");
    assert.strictEqual(v.gauges[2].sub, "85°C");
    assert.strictEqual(v.gauges[2].level, L.WARN);
    assert.ok(v.bars.some((b) => b.label === "VRAM"));
    m.report.gpu = { vendor: "amd", busy: 0, asleep: true };
    assert.strictEqual(L.view(m).gauges[2].sub, "asleep");
});

test("on battery is a warning, low battery is bad", () => {
    const m = JSON.parse(JSON.stringify(byName("hermes-box")));
    m.report.power = { battery: 50, plugged: false };
    assert.strictEqual(L.view(m).footer.find((f) => /battery/i.test(f.text)).level, L.WARN);
    m.report.power = { battery: 10, plugged: false };
    assert.strictEqual(L.view(m).worst, L.BAD);
});

test("missing fields don't throw", () => {
    const v = L.view({ name: "bare", age_s: 1, report: {} });
    assert.strictEqual(v.gauges[0].text, "–");
    L.view({ name: "nothing", age_s: 1 });
});

test("machine filter keeps the given order, case-insensitive", () => {
    const names = L.filterMachines(sample.machines, " Living-Room-PC , hermes-box, nope").map((m) => m.name);
    assert.deepStrictEqual(names, ["living-room-pc", "hermes-box"]);
    assert.strictEqual(L.filterMachines(sample.machines, "").length, sample.machines.length);
});

test("worst level, summary, helpers", () => {
    assert.strictEqual(L.worstLevel([]), L.UNKNOWN);
    const views = sample.machines.map(L.view);
    assert.ok(L.worstLevel(views) >= L.OK);
    assert.ok(L.summary(views).includes("hermes-box: Online"));
    assert.strictEqual(L.css({ r: 1, g: 0.5, b: 0, a: 1 }, 0.2), "rgba(255,128,0,0.2)");
    assert.strictEqual(L.joinUrl("http://hermes-box:8787/ ", "/api/machines"), "http://hermes-box:8787/api/machines");
});

console.log(`\n${n} tests passed`);
