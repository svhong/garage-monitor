#!/usr/bin/env python3
"""garage-monitor agent.

Samples this machine's health every few seconds and reports it to the hub
as JSON. Run with --once to print a single sample and exit (handy for
checking which sensors work on a new machine).

Settings come from environment variables (see /etc/garage-monitor/agent.env):
  GM_HUB_URL      where the hub listens, e.g. http://100.x.y.z:8787
  GM_TOKEN        shared secret the hub expects
  GM_INTERVAL     seconds between samples (default 2)
  GM_HERMES_USER  Linux user that runs Hermes; leave empty if this machine has none
  GM_NAME         display name (default: the hostname)
"""
import glob
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

import psutil

VERSION = "1.1.0"

HUB_URL = os.environ.get("GM_HUB_URL", "http://127.0.0.1:8787").rstrip("/")
TOKEN = os.environ.get("GM_TOKEN", "")
INTERVAL = max(1.0, float(os.environ.get("GM_INTERVAL", "2")))
HERMES_USER = os.environ.get("GM_HERMES_USER", "").strip()
MACHINE_NAME = os.environ.get("GM_NAME", "").strip() or socket.gethostname()

# Hermes counts as "just restarted" for this long after the gateway starts.
RESTART_GRACE_S = 60


def read_file(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def parse_cpulist(text):
    """Turn a kernel CPU list like '0-3,8,10-11' into [0, 1, 2, 3, 8, 10, 11]."""
    cpus = []
    for part in (text or "").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            cpus.extend(range(int(lo), int(hi) + 1))
        else:
            cpus.append(int(part))
    return cpus


def static_info():
    """Facts about the machine that don't change while the agent runs."""
    cpu_model = None
    for line in (read_file("/proc/cpuinfo", "") or "").splitlines():
        if line.startswith("model name"):
            cpu_model = line.split(":", 1)[1].strip()
            break
    if not cpu_model:
        cpu_model = platform.processor() or None

    os_name = None
    for line in (read_file("/etc/os-release", "") or "").splitlines():
        if line.startswith("PRETTY_NAME="):
            os_name = line.split("=", 1)[1].strip().strip('"')
    if not os_name:
        os_name = "%s %s" % (platform.system(), platform.release())

    # Intel hybrid CPUs (12th gen and newer) list performance and efficiency
    # cores separately.
    p_cpus = parse_cpulist(read_file("/sys/devices/cpu_core/cpus"))
    e_cpus = parse_cpulist(read_file("/sys/devices/cpu_atom/cpus"))
    hybrid = {"p": p_cpus, "e": e_cpus} if p_cpus and e_cpus else None

    return {"cpu_model": cpu_model, "os": os_name, "hybrid": hybrid}


class GpuReader:
    """Reads Intel GPU load and chip power from intel_gpu_top in the background.

    intel_gpu_top needs the CAP_PERFMON permission, which the systemd service
    grants. Without it, this reports an error and the GPU card says so.
    """

    def __init__(self):
        self.latest = None
        self.updated = 0.0
        self.error = None
        exe = shutil.which("intel_gpu_top")
        if not exe:
            self.error = "intel_gpu_top not installed"
            return
        vendors = {read_file(p) for p in glob.glob("/sys/class/drm/card*/device/vendor")}
        if "0x8086" not in vendors:  # 0x8086 = Intel
            self.error = "no Intel GPU found"
            return
        threading.Thread(target=self._run, args=(exe,), daemon=True).start()

    def _run(self, exe):
        cmd = [exe, "-J", "-s", str(int(INTERVAL * 1000))]
        stdbuf = shutil.which("stdbuf")
        if stdbuf:
            # Make intel_gpu_top flush each sample instead of buffering.
            cmd = [stdbuf, "-oL"] + cmd
        while True:
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        universal_newlines=True)
                self._parse(proc.stdout)
                err = (proc.stderr.read() or "").strip()
                proc.wait()
                self.error = err.splitlines()[-1] if err else "intel_gpu_top exited (%s)" % proc.returncode
            except Exception as exc:  # keep the agent alive whatever happens
                self.error = str(exc)
            self.latest = None
            time.sleep(30)

    def _parse(self, stream):
        # intel_gpu_top -J prints a never-ending JSON array of objects.
        # Collect one top-level object at a time by counting braces.
        buf, depth = "", 0
        for line in stream:
            if depth == 0:
                start = line.find("{")
                if start < 0:
                    continue
                line = line[start:]
            buf += line
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                try:
                    self._update(json.loads(buf[:buf.rfind("}") + 1]))
                except ValueError:
                    pass
                buf, depth = "", 0

    def _update(self, sample):
        engines = sample.get("engines") or {}

        def busy(prefix):
            vals = [e.get("busy", 0) for name, e in engines.items() if name.startswith(prefix)]
            return round(max(vals), 1) if vals else None

        all_busy = [e.get("busy", 0) for e in engines.values()]
        power = sample.get("power") or {}
        self.latest = {
            "busy": round(max(all_busy), 1) if all_busy else 0.0,
            "render": busy("Render"),
            "video": busy("Video"),
            "freq_mhz": round((sample.get("frequency") or {}).get("actual", 0)),
            "rc6": (sample.get("rc6") or {}).get("value"),
            "gpu_w": power.get("GPU"),
            "pkg_w": power.get("Package"),
        }
        self.updated = time.time()
        self.error = None

    def snapshot(self):
        if self.latest and time.time() - self.updated < INTERVAL * 3 + 5:
            return self.latest
        return None


class AmdGpuReader:
    """Reads AMD GPU load, temperature, power and VRAM straight from sysfs.

    The amdgpu driver publishes all of this as small world-readable files, so
    there is no helper program, no extra package and no extra permission.
    With several AMD GPUs (e.g. a graphics card plus the CPU's integrated
    graphics) it watches the one with the most VRAM, i.e. the graphics card.
    """

    def __init__(self):
        self.error = None
        self.dev = None
        self.hwmon = None
        best_vram = -1
        for card in sorted(glob.glob("/sys/class/drm/card[0-9]*")):
            dev = card + "/device"
            if read_file(dev + "/vendor") != "0x1002" or not os.path.exists(dev + "/gpu_busy_percent"):
                continue
            vram = self._int(dev + "/mem_info_vram_total") or 0
            if vram > best_vram:
                best_vram, self.dev = vram, dev
        if not self.dev:
            self.error = "no AMD GPU found"
            return
        for hw in glob.glob(self.dev + "/hwmon/hwmon*"):
            if read_file(hw + "/name") == "amdgpu":
                self.hwmon = hw
                break

    @staticmethod
    def _int(path):
        val = read_file(path)
        try:
            return int(val)
        except (TypeError, ValueError):
            return None

    def _temps(self):
        """amdgpu labels its sensors: edge (the usual "GPU temp"),
        junction (hotspot) and mem (VRAM). Values are in millidegrees."""
        out = {}
        for label_path in glob.glob(self.hwmon + "/temp*_label"):
            val = self._int(label_path[:-len("_label")] + "_input")
            if val is not None:
                out[read_file(label_path)] = val / 1000
        return out

    def _freq(self):
        # pp_dpm_sclk lists the clock steps; the current one ends with "*".
        for line in (read_file(self.dev + "/pp_dpm_sclk", "") or "").splitlines():
            if line.rstrip().endswith("*"):
                digits = "".join(ch for ch in line.split(":", 1)[-1] if ch.isdigit())
                return int(digits) if digits else None
        return None

    def snapshot(self):
        if not self.dev:
            return None
        busy = self._int(self.dev + "/gpu_busy_percent")
        if busy is None:
            # A powered-down GPU refuses the read rather than waking up.
            if read_file(self.dev + "/power/runtime_status") == "suspended":
                return {"vendor": "amd", "busy": 0.0, "asleep": True}
            self.error = "can't read gpu_busy_percent"
            return None
        self.error = None
        out = {"vendor": "amd", "busy": float(busy), "asleep": False,
               "freq_mhz": self._freq(),
               "vram_used": self._int(self.dev + "/mem_info_vram_used"),
               "vram_total": self._int(self.dev + "/mem_info_vram_total")}
        if self.hwmon:
            temps = self._temps()
            out["temp"] = temps.get("edge")
            out["hotspot"] = temps.get("junction")
            out["mem_temp"] = temps.get("mem")
            # Newer GPUs report a 1-second average; older ones only the instant value.
            uw = self._int(self.hwmon + "/power1_average")
            if uw is None:
                uw = self._int(self.hwmon + "/power1_input")
            out["gpu_w"] = round(uw / 1_000_000, 1) if uw is not None else None
            out["fan_rpm"] = self._int(self.hwmon + "/fan1_input")
        return out


def make_gpu_reader():
    """AMD if the machine has one, otherwise Intel."""
    vendors = {read_file(p) for p in glob.glob("/sys/class/drm/card*/device/vendor")}
    if "0x1002" in vendors:  # 0x1002 = AMD
        return AmdGpuReader()
    return GpuReader()


class HermesWatcher:
    """Finds the Hermes processes and works out whether Hermes is healthy."""

    def __init__(self, user):
        self.user = user
        self.gateway_pid = None
        self.restarts = 0
        self.cpu_count = psutil.cpu_count() or 1

    @staticmethod
    def _is_gateway(args):
        return any(args[i] == "gateway" and args[i + 1] == "run" for i in range(len(args) - 1))

    def sample(self):
        gateway = None
        supervisor = False
        cpu = 0.0
        rss = 0
        count = 0
        # process_iter reuses Process objects between calls, so cpu_percent()
        # measures usage since the previous sample.
        for p in psutil.process_iter(["username", "cmdline", "create_time"]):
            if p.info["username"] != self.user:
                continue
            count += 1
            args = p.info["cmdline"] or []
            if self._is_gateway(args):
                gateway = p
            elif any(a.endswith("process_supervisor.sh") for a in args):
                supervisor = True
            try:
                cpu += p.cpu_percent(None)
                rss += p.memory_info().rss
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass

        uptime = None
        if gateway is not None:
            if self.gateway_pid is not None and gateway.pid != self.gateway_pid:
                self.restarts += 1
            self.gateway_pid = gateway.pid
            uptime = max(0, int(time.time() - gateway.info["create_time"]))

        if gateway is not None and uptime >= RESTART_GRACE_S:
            state = "running"
        elif gateway is not None or supervisor:
            state = "restarting"
        else:
            state = "stopped"

        return {
            "state": state,
            "gateway_uptime_s": uptime,
            "supervisor": supervisor,
            "processes": count,
            # Share of the whole machine (all cores), like the CPU card.
            "cpu_percent": round(cpu / self.cpu_count, 1),
            "rss_bytes": rss,
            "restarts": self.restarts,
        }


def read_temps():
    out = {"cpu": None, "nvme": None, "ram": None}
    try:
        temps = psutil.sensors_temperatures()
    except Exception:
        return out

    for e in temps.get("coretemp", []):
        if e.label.startswith("Package"):
            out["cpu"] = e.current
            break
    if out["cpu"] is None:
        for name in ("k10temp", "zenpower", "cpu_thermal", "acpitz"):
            if temps.get(name):
                out["cpu"] = temps[name][0].current
                break

    for e in temps.get("nvme", []):
        if e.label in ("Composite", ""):
            out["nvme"] = e.current
            break

    for entries in temps.values():
        for e in entries:
            if "DIMM" in (e.label or "").upper():
                out["ram"] = e.current
    return out


def read_fan():
    try:
        fans = psutil.sensors_fans()
    except Exception:
        return None
    # The AMD graphics card's own fan is shown on the GPU row instead.
    for name in ["dell_smm"] + sorted(n for n in fans if n != "amdgpu"):
        for f in fans.get(name, []):
            return f.current
    return None


def read_power():
    out = {"battery": None, "plugged": None, "charge_limit": None, "charger_w": None}
    try:
        bat = psutil.sensors_battery()
    except Exception:
        bat = None
    if bat:
        out["battery"] = round(bat.percent)
        out["plugged"] = bat.power_plugged

    for path in glob.glob("/sys/class/power_supply/BAT*/charge_control_end_threshold"):
        val = read_file(path)
        if val and val.isdigit():
            out["charge_limit"] = int(val)

    # USB-C chargers show up as ucsi_source_psy hwmon devices with the
    # negotiated voltage (mV) and current (mA).
    best = None
    for hw in glob.glob("/sys/class/hwmon/hwmon*"):
        if not (read_file(hw + "/name") or "").startswith("ucsi_source_psy"):
            continue
        if read_file(hw + "/device/online", "1") != "1":
            continue
        mv, ma = read_file(hw + "/in0_input"), read_file(hw + "/curr1_input")
        if mv and ma and mv.isdigit() and ma.isdigit():
            watts = round(int(mv) * int(ma) / 1_000_000)
            if watts > 0 and (best is None or watts > best):
                best = watts
    out["charger_w"] = best
    if out["plugged"] is None and best:
        out["plugged"] = True
    return out


class Collector:
    def __init__(self):
        self.info = static_info()
        self.gpu = make_gpu_reader()
        self.hermes = HermesWatcher(HERMES_USER) if HERMES_USER else None
        self.last_net = None
        psutil.cpu_percent(percpu=True)  # first call only sets a baseline

    def _net(self):
        now = time.time()
        rx = tx = 0
        for nic, c in psutil.net_io_counters(pernic=True).items():
            if nic == "lo":
                continue
            rx += c.bytes_recv
            tx += c.bytes_sent
        rates = {"rx_bps": None, "tx_bps": None}
        if self.last_net:
            t0, rx0, tx0 = self.last_net
            dt = max(now - t0, 0.001)
            rates = {"rx_bps": max(0, (rx - rx0) / dt), "tx_bps": max(0, (tx - tx0) / dt)}
        self.last_net = (now, rx, tx)
        return rates

    def sample(self):
        per_core = psutil.cpu_percent(percpu=True)
        total = round(sum(per_core) / max(len(per_core), 1), 1)
        cpu = {
            "percent": total,
            "per_core": per_core,
            "count": len(per_core),
            "model": self.info["cpu_model"],
        }
        hybrid = self.info["hybrid"]
        if hybrid:
            for kind in ("p", "e"):
                vals = [per_core[i] for i in hybrid[kind] if i < len(per_core)]
                cpu[kind + "_percent"] = round(sum(vals) / len(vals), 1) if vals else None
                cpu[kind + "_threads"] = hybrid[kind]
        try:
            freq = psutil.cpu_freq()
            cpu["freq_mhz"] = round(freq.current) if freq else None
        except Exception:
            cpu["freq_mhz"] = None
        try:
            cpu["load1"] = round(os.getloadavg()[0], 2)
        except OSError:
            cpu["load1"] = None

        temps = read_temps()
        cpu["temp"] = temps["cpu"]

        vm = psutil.virtual_memory()
        du = psutil.disk_usage("/")

        report = {
            "name": MACHINE_NAME,
            "agent_version": VERSION,
            "interval": INTERVAL,
            "os": self.info["os"],
            "uptime_s": int(time.time() - psutil.boot_time()),
            "cpu": cpu,
            "gpu": self.gpu.snapshot(),
            "gpu_error": self.gpu.error,
            "mem": {"used": vm.total - vm.available, "total": vm.total, "percent": vm.percent,
                    "temp": temps["ram"]},
            "disk": {"used": du.used, "total": du.total, "percent": du.percent, "temp": temps["nvme"]},
            "fan_rpm": read_fan(),
            "net": self._net(),
            "power": read_power(),
            "hermes": self.hermes.sample() if self.hermes else None,
        }
        return report


def send(report):
    req = urllib.request.Request(
        HUB_URL + "/api/report",
        data=json.dumps(report).encode(),
        headers={"Content-Type": "application/json", "X-GM-Token": TOKEN},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        resp.read()


def main():
    collector = Collector()

    if "--once" in sys.argv:
        time.sleep(1)  # give CPU and network counters something to compare against
        collector.sample()
        deadline = time.time() + INTERVAL * 2 + 2
        while collector.gpu.error is None and collector.gpu.snapshot() is None and time.time() < deadline:
            time.sleep(0.25)
        time.sleep(1)
        print(json.dumps(collector.sample(), indent=2))
        return

    print("garage-monitor agent %s reporting as %r to %s every %ss"
          % (VERSION, MACHINE_NAME, HUB_URL, INTERVAL), flush=True)
    last_error = None
    while True:
        started = time.time()
        try:
            send(collector.sample())
            if last_error:
                print("reconnected to hub", flush=True)
                last_error = None
        except (urllib.error.URLError, OSError, ValueError) as exc:
            msg = str(exc)
            if msg != last_error:  # don't flood the log with the same error
                print("could not reach hub: %s" % msg, file=sys.stderr, flush=True)
                last_error = msg
        time.sleep(max(0.1, INTERVAL - (time.time() - started)))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
