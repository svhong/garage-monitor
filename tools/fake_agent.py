#!/usr/bin/env python3
"""Send made-up reports to a hub so the dashboard can be tried on any computer.

    GM_TOKEN=dev GM_BIND=127.0.0.1 python3 hub/hub.py
    GM_TOKEN=dev python3 tools/fake_agent.py

Simulates three machines:
  hermes-box       online, Hermes running (cycles through restarting/stopped
                   every minute so all the dot colours can be seen)
  living-room-pc   online, no Hermes
  old-desktop      reports once, then goes quiet (yellow, then red after 60 s)
"""
import json
import math
import os
import random
import time
import urllib.request

HUB = os.environ.get("GM_HUB_URL", "http://127.0.0.1:8787").rstrip("/")
TOKEN = os.environ.get("GM_TOKEN", "dev")
GB = 1024 ** 3


def post(report):
    req = urllib.request.Request(HUB + "/api/report", data=json.dumps(report).encode(),
                                 headers={"Content-Type": "application/json", "X-GM-Token": TOKEN},
                                 method="POST")
    urllib.request.urlopen(req, timeout=5).read()


def machine(name, t, hermes_state=None, model="13th Gen Intel(R) Core(TM) i7-1355U", hybrid=True):
    wave = (math.sin(t / 20) + 1) / 2
    per_core = [round(max(0, min(100, 4 + 30 * wave + random.uniform(-4, 12))), 1) for _ in range(12)]
    total = round(sum(per_core) / len(per_core), 1)
    cpu = {"percent": total, "per_core": per_core, "count": 12, "model": model,
           "freq_mhz": int(1200 + 2400 * wave), "load1": round(0.3 + 2 * wave, 2),
           "temp": round(46 + 30 * wave + random.uniform(-1, 1), 1)}
    if hybrid:
        cpu.update({"p_threads": [0, 1, 2, 3], "e_threads": list(range(4, 12)),
                    "p_percent": round(sum(per_core[:4]) / 4, 1), "e_percent": round(sum(per_core[4:]) / 8, 1)})
    report = {
        "name": name, "agent_version": "fake", "interval": 2, "os": "Ubuntu 26.04 LTS",
        "uptime_s": int(273_600 + t), "cpu": cpu,
        "gpu": {"busy": round(8 * wave, 1), "render": 0.0, "video": 0.0, "freq_mhz": 0 if wave < .5 else 600,
                "rc6": 100 if wave < .5 else 70, "gpu_w": 0.0, "pkg_w": round(3.2 + 9 * wave, 2)},
        "gpu_error": None,
        "mem": {"used": int((5 + 3 * wave) * GB), "total": 16 * GB, "percent": round((5 + 3 * wave) / 16 * 100, 1),
                "temp": 28.0},
        "disk": {"used": int(180 * GB), "total": int(476 * GB), "percent": 37.8, "temp": 25.0},
        "fan_rpm": 0 if wave < .6 else int(2400 * wave),
        "net": {"rx_bps": random.uniform(2_000, 40_000), "tx_bps": random.uniform(500, 8_000)},
        "power": {"battery": 57, "plugged": True, "charge_limit": 60, "charger_w": 65},
        "hermes": None,
    }
    if hermes_state:
        report["hermes"] = {"state": hermes_state, "supervisor": True, "processes": 6,
                            "gateway_uptime_s": {"running": 22_320 + int(t), "restarting": 12}.get(hermes_state),
                            "cpu_percent": round(0.4 + 6 * wave, 1), "rss_bytes": int(210 * 1024 ** 2),
                            "restarts": 0 if hermes_state == "running" else 1}
    return report


def main():
    start = time.time()
    post(machine("old-desktop", 0, model="Intel(R) Core(TM) i5-4590 CPU @ 3.30GHz", hybrid=False))
    print("sending fake reports to %s (Ctrl+C to stop)" % HUB)
    while True:
        t = time.time() - start
        # 45 s running, 15 s restarting, 15 s stopped, repeat
        state = ["running", "running", "running", "restarting", "stopped"][int(t // 15) % 5]
        post(machine("hermes-box", t, hermes_state=state))
        p = machine("living-room-pc", t, model="AMD Ryzen 5 5600G with Radeon Graphics", hybrid=False)
        p["gpu"], p["gpu_error"] = None, "no Intel GPU found"
        p["power"] = {"battery": None, "plugged": None, "charge_limit": None, "charger_w": None}
        p["mem"]["temp"] = None
        post(p)
        time.sleep(2)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
