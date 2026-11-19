/**
 * <GarageMonitor hubUrl="https://hermes-box.your-tailnet.ts.net" />
 *
 * Live dashboard for the garage-monitor hub, as a drop-in React component
 * (React 16.8+, no other dependencies). Copy this file and GarageMonitor.css
 * into your site.
 *
 * Security: the password is checked by the hub, not in this file, so nothing
 * secret ships with your website. The hub is also only reachable from devices
 * on your Tailscale, so the data never touches the public internet.
 *
 * Props:
 *   hubUrl   (required) the hub's HTTPS address
 *   title    heading text (default "Garage Monitor")
 *   pollMs   refresh interval in ms (default 2000)
 *   theme    "auto" | "dark" | "light" (default "auto", follows the device)
 */
import React, { useCallback, useEffect, useState } from "react";
import "./GarageMonitor.css";

const TOKEN_KEY = "gm-session";

// ---- storage (wrapped: private windows can throw) ---------------------------
function loadToken() {
  try {
    return localStorage.getItem(TOKEN_KEY) || sessionStorage.getItem(TOKEN_KEY) || "";
  } catch (e) {
    return "";
  }
}
function storeToken(token, remember) {
  try {
    localStorage.removeItem(TOKEN_KEY);
    sessionStorage.removeItem(TOKEN_KEY);
    if (token) (remember ? localStorage : sessionStorage).setItem(TOKEN_KEY, token);
  } catch (e) {
    /* storage unavailable: the session just won't survive a reload */
  }
}

// ---- formatting ---------------------------------------------------------------
const num = (v) => typeof v === "number" && isFinite(v);
function fmtBytes(n) {
  if (!num(n)) return "–";
  const gb = n / 1024 ** 3;
  return gb >= 1 ? `${gb.toFixed(1)} GB` : `${Math.round(n / 1024 ** 2)} MB`;
}
function fmtRate(n) {
  if (!num(n)) return "–";
  if (n >= 1024 ** 2) return `${(n / 1024 ** 2).toFixed(1)} MB/s`;
  if (n >= 1024) return `${Math.round(n / 1024)} KB/s`;
  return `${Math.round(n)} B/s`;
}
function fmtDur(s) {
  if (!num(s)) return "–";
  s = Math.max(0, Math.floor(s));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  if (m) return `${m}m ${s % 60}s`;
  return `${s}s`;
}
function level(v, warn, hot) {
  if (!num(v)) return "";
  return v >= hot ? "gm-hot" : v >= warn ? "gm-warn" : "";
}

// ---- status rules (same as the hub's own page) ---------------------------------
function machineStatus(m) {
  const interval = (m.report && m.report.interval) || 2;
  if (m.age_s <= Math.max(10, interval * 5)) return { cls: "green", label: "Online", up: true };
  if (m.age_s <= 60) return { cls: "yellow", label: "Delayed", up: true };
  return { cls: "red", label: "Offline", up: false };
}
function hermesStatus(h, machineUp) {
  if (!machineUp) return { cls: "", label: "Unknown", detail: "machine offline" };
  if (h.state === "running")
    return { cls: "green", label: "Running", detail: `gateway up ${fmtDur(h.gateway_uptime_s)}` };
  if (h.state === "restarting")
    return {
      cls: "yellow",
      label: "Restarting",
      detail: num(h.gateway_uptime_s) ? `gateway up ${fmtDur(h.gateway_uptime_s)}` : "gateway down, supervisor active",
    };
  return { cls: "red", label: "Stopped", detail: "no Hermes gateway found" };
}

// ---- small pieces -------------------------------------------------------------
const Dot = ({ cls }) => <span className={`gm-dot ${cls ? "gm-" + cls : ""}`} aria-hidden="true" />;

function Temp({ value, warn, hot }) {
  return num(value) ? <span className={level(value, warn, hot)}>{Math.round(value)}°C</span> : <>–</>;
}

function Bar({ pct, warn, hot }) {
  const p = num(pct) ? Math.min(100, Math.max(0, pct)) : 0;
  return (
    <div className="gm-bar">
      <i className={level(pct, warn, hot)} style={{ width: `${p}%` }} />
    </div>
  );
}

function Spark({ values, min, max }) {
  const pts = (values || []).filter(num);
  const w = 84, h = 24;
  if (pts.length < 2) return <svg className="gm-spark" aria-hidden="true" />;
  const step = w / (pts.length - 1);
  const y = (v) => h - 2 - ((Math.min(max, Math.max(min, v)) - min) / (max - min)) * (h - 4);
  const line = pts.map((v, i) => `${(i * step).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  return (
    <svg className="gm-spark" viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" aria-hidden="true">
      <polygon className="gm-area" points={`0,${h} ${line} ${w},${h}`} />
      <polyline points={line} />
    </svg>
  );
}

function CoreBars({ cpu }) {
  const pc = cpu.per_core || [];
  const group = (threads, cls, title) =>
    threads.length ? (
      <div className={`gm-core-group gm-${cls}`}>
        <div className="gm-core-bars">
          {threads.map((i) => (
            <span key={i}>
              <i style={{ height: `${Math.max(2, pc[i] || 0)}%` }} />
            </span>
          ))}
        </div>
        <div className="gm-cg-label">{title}</div>
      </div>
    ) : null;
  const pct = (v) => (num(v) ? ` ${Math.round(v)}%` : "");
  if (cpu.p_threads && cpu.e_threads) {
    return (
      <div className="gm-cores">
        {group(cpu.p_threads, "p", `Performance${pct(cpu.p_percent)}`)}
        {group(cpu.e_threads, "e", `Efficiency${pct(cpu.e_percent)}`)}
      </div>
    );
  }
  return <div className="gm-cores">{group(pc.map((_, i) => i), "p", `${pc.length} threads`)}</div>;
}

function Row({ label, children }) {
  return (
    <div className="gm-row">
      <div className="gm-label">{label}</div>
      <div className="gm-val">{children}</div>
    </div>
  );
}

// ---- machine card --------------------------------------------------------------
function MachineCard({ m }) {
  const r = m.report || {};
  const cpu = r.cpu || {}, mem = r.mem || {}, disk = r.disk || {}, net = r.net || {}, pw = r.power || {};
  const g = r.gpu, h = r.hermes;
  const st = machineStatus(m);
  const statusText = st.cls === "green" ? `up ${fmtDur(r.uptime_s)}` : `last seen ${fmtDur(m.age_s)} ago`;
  const hs = h ? hermesStatus(h, st.up) : null;

  return (
    <section className={`gm-card ${st.up ? "" : "gm-offline"}`}>
      <div className="gm-card-head">
        <div className="gm-min0">
          <div className="gm-name">{m.name}</div>
          <div className="gm-meta">{[cpu.model, r.os].filter(Boolean).join(" · ")}</div>
        </div>
        <span className="gm-status">
          <Dot cls={st.cls} />
          <b>{st.label}</b> · {statusText}
        </span>
      </div>

      {h && (
        <div className="gm-hermes">
          <div className="gm-hermes-left">
            <span className="gm-label">Hermes</span>
            <span className="gm-status">
              <Dot cls={hs.cls} />
              <b>{hs.label}</b> · {hs.detail}
            </span>
          </div>
          <span className="gm-sub">
            CPU <b>{num(h.cpu_percent) ? h.cpu_percent.toFixed(1) : "–"}%</b> · RAM <b>{fmtBytes(h.rss_bytes)}</b>
            {h.restarts ? (
              <>
                {" · "}
                <span className="gm-warn">
                  {h.restarts} restart{h.restarts > 1 ? "s" : ""}
                </span>
              </>
            ) : null}
          </span>
        </div>
      )}

      <div className="gm-rows">
        <Row label="CPU">
          <span className={`gm-big ${level(cpu.percent, 80, 95)}`}>{num(cpu.percent) ? Math.round(cpu.percent) : "–"}%</span>
          <Spark values={m.history && m.history.cpu} min={0} max={100} />
          <span className="gm-big"><Temp value={cpu.temp} warn={75} hot={90} /></span>
          <span className="gm-sub gm-push">{num(cpu.freq_mhz) ? `${(cpu.freq_mhz / 1000).toFixed(1)} GHz` : ""}</span>
          <CoreBars cpu={cpu} />
        </Row>

        <Row label="GPU">
          {g ? (
            <>
              <span className="gm-big">{Math.round(g.busy || 0)}%</span>
              <span className="gm-sub">
                {num(g.rc6) && g.rc6 >= 95 && (g.busy || 0) < 1 ? "asleep" : `${g.freq_mhz || 0} MHz`}
              </span>
              <span className="gm-sub gm-push">
                Chip power <b>{num(g.pkg_w) ? `${g.pkg_w.toFixed(1)} W` : "–"}</b>
              </span>
            </>
          ) : (
            <span className="gm-sub">{r.gpu_error || "no data"}</span>
          )}
        </Row>

        <Row label="RAM">
          <span className="gm-big">{fmtBytes(mem.used)}</span>
          <span className="gm-sub">of {fmtBytes(mem.total)}</span>
          {num(mem.temp) && <span className="gm-sub gm-push"><Temp value={mem.temp} warn={70} hot={85} /></span>}
          <Bar pct={mem.percent} warn={80} hot={92} />
        </Row>

        <Row label="Disk">
          <span className="gm-big">{num(disk.percent) ? Math.round(disk.percent) : "–"}%</span>
          <span className="gm-sub">{fmtBytes(disk.used)} of {fmtBytes(disk.total)}</span>
          {num(disk.temp) && <span className="gm-sub gm-push">SSD <Temp value={disk.temp} warn={60} hot={75} /></span>}
          <Bar pct={disk.percent} warn={80} hot={90} />
        </Row>

        <Row label="Fan">
          <span className="gm-big">{num(r.fan_rpm) ? `${r.fan_rpm.toLocaleString()} RPM` : "–"}</span>
          <span className="gm-sub gm-push">
            Net ↓ <b>{fmtRate(net.rx_bps)}</b> ↑ <b>{fmtRate(net.tx_bps)}</b>
          </span>
        </Row>

        <Row label="Power">
          {pw.plugged === false ? (
            <span className="gm-big gm-warn">On battery</span>
          ) : pw.plugged ? (
            <span className="gm-big">🔌 {pw.charger_w ? `${pw.charger_w} W` : "AC"}</span>
          ) : (
            <span className="gm-sub">No battery info</span>
          )}
          {num(pw.battery) && (
            <span className="gm-sub gm-push">
              Battery{" "}
              <b className={pw.battery < 20 ? "gm-hot" : pw.battery < 35 && pw.plugged === false ? "gm-warn" : ""}>
                {pw.battery}%
              </b>
              {pw.charge_limit && pw.charge_limit < 100 ? ` (limit ${pw.charge_limit})` : ""}
            </span>
          )}
        </Row>
      </div>
    </section>
  );
}

// ---- login --------------------------------------------------------------------
function LoginForm({ onLogin, error, busy }) {
  const [password, setPassword] = useState("");
  const [remember, setRemember] = useState(true);
  return (
    <form
      className="gm-login"
      onSubmit={(e) => {
        e.preventDefault();
        onLogin(password, remember);
        setPassword("");
      }}
    >
      <div className="gm-lock" aria-hidden="true">🔒</div>
      <h3>Private dashboard</h3>
      <p>Enter the viewer password.</p>
      <input
        type="password"
        autoComplete="current-password"
        placeholder="Password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        required
        autoFocus
      />
      <label className="gm-remember">
        <input type="checkbox" checked={remember} onChange={(e) => setRemember(e.target.checked)} />
        Remember this device
      </label>
      <button type="submit" disabled={busy}>{busy ? "Checking…" : "Unlock"}</button>
      <div className="gm-err" role="alert">{error}</div>
    </form>
  );
}

// ---- main component ----------------------------------------------------------------
export default function GarageMonitor({ hubUrl, title = "Garage Monitor", pollMs = 2000, theme = "auto" }) {
  const base = String(hubUrl || "").replace(/\/+$/, "");
  const [token, setToken] = useState(loadToken);
  // No saved session: show the lock screen without contacting the hub at all.
  const [locked, setLocked] = useState(() => !loadToken());
  const [data, setData] = useState(null);
  const [unreachable, setUnreachable] = useState(false);
  const [loginError, setLoginError] = useState("");
  const [busy, setBusy] = useState(false);
  const [updated, setUpdated] = useState(null);

  // Poll the hub while unlocked.
  useEffect(() => {
    if (locked || !base) return undefined;
    let cancelled = false;
    let loaded = false;
    let timer;
    const tick = async () => {
      if (loaded && typeof document !== "undefined" && document.hidden) {
        timer = setTimeout(tick, pollMs); // don't keep polling from a background tab
        return;
      }
      loaded = true;
      try {
        const res = await fetch(`${base}/api/machines`, {
          cache: "no-store",
          headers: token ? { Authorization: `Bearer ${token}` } : {},
        });
        if (cancelled) return;
        if (res.status === 401) {
          storeToken("");
          setToken("");
          setData(null);
          setLocked(true);
          return;
        }
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const json = await res.json();
        if (cancelled) return;
        setData(json);
        setUpdated(new Date());
        setUnreachable(false);
      } catch (e) {
        if (!cancelled) setUnreachable(true);
      }
      if (!cancelled) timer = setTimeout(tick, pollMs);
    };
    tick();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [base, token, locked, pollMs]);

  const login = useCallback(
    async (password, remember) => {
      setBusy(true);
      setLoginError("");
      try {
        const res = await fetch(`${base}/api/login`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ password }),
        });
        const body = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(body.error || "Login failed.");
        storeToken(body.token || "", remember);
        setToken(body.token || "");
        setLocked(false);
      } catch (e) {
        setLoginError(
          e instanceof TypeError
            ? "Can't reach the monitor. It only works from devices on the private network."
            : e.message
        );
      } finally {
        setBusy(false);
      }
    },
    [base]
  );

  const lock = useCallback(() => {
    if (token) {
      fetch(`${base}/api/logout`, { method: "POST", headers: { Authorization: `Bearer ${token}` } }).catch(() => {});
    }
    storeToken("");
    setToken("");
    setData(null);
    setLocked(true);
  }, [base, token]);

  const machines = (data && data.machines) || [];
  const counts = { green: 0, yellow: 0, red: 0 };
  machines.forEach((m) => counts[machineStatus(m).cls]++);

  return (
    <div className="gm-root" data-theme={theme}>
      <div className="gm-header">
        <h2 className="gm-title">{title}</h2>
        {!locked && (
          <div className="gm-header-right">
            <div className="gm-summary">
              {[["green", "online"], ["yellow", "delayed"], ["red", "offline"]]
                .filter(([c]) => counts[c])
                .map(([c, t]) => (
                  <span key={c}>
                    <Dot cls={c} />
                    {counts[c]} {t}
                  </span>
                ))}
            </div>
            {token && (
              <button type="button" className="gm-lock-btn" onClick={lock}>
                Lock
              </button>
            )}
          </div>
        )}
      </div>

      {locked ? (
        <LoginForm onLogin={login} error={loginError} busy={busy} />
      ) : (
        <>
          {unreachable && (
            <div className="gm-banner" role="status">
              Can't reach the monitor. Check that this device is connected to Tailscale.
            </div>
          )}
          <div className="gm-grid">
            {data === null && !unreachable && <div className="gm-empty">Loading…</div>}
            {data !== null && machines.length === 0 && (
              <div className="gm-empty">No machines have reported yet.</div>
            )}
            {machines.map((m) => (
              <MachineCard key={m.name} m={m} />
            ))}
          </div>
          {updated && (
            <div className="gm-footer">
              Updated {updated.toLocaleTimeString()} · refreshes every {pollMs / 1000}s
            </div>
          )}
        </>
      )}
    </div>
  );
}
