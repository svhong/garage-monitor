# Garage Monitor

A small, self-hosted dashboard for keeping an eye on home machines. The first
one is **hermes-box**, the garage laptop that runs the Hermes agent.

It shows CPU load and temperature (including performance and efficiency
cores), Intel GPU load, chip power, RAM, disk, SSD temperature, fan speed,
network, charger and battery. On machines that run Hermes, it also shows
Hermes health. It works on desktop and phone, and it's only reachable over
Tailscale.

```
 hermes-box                       other machines (later)
┌───────────────────────┐        ┌───────────────────┐
│ agent ──► hub ──► web │ ◄───── │ agent             │
└───────────────────────┘        └───────────────────┘
            ▲  Tailscale only
   phone / desktop browser
```

- **agent** (`agent/agent.py`): reads this machine's sensors every 2 seconds
  and sends them to the hub. One per machine.
- **hub** (`hub/hub.py`): receives reports and serves the dashboard. Uses only
  the Python standard library, and keeps data in memory.
- **dashboard** (`hub/static/index.html`): one page that refreshes every 2 seconds.

## Status dots

| | Machine | Hermes |
|---|---|---|
| 🟢 | **Online**: reported in the last 10 s | **Running**: gateway up for over a minute |
| 🟡 | **Delayed**: no report for 10–60 s | **Restarting**: gateway just restarted, or the supervisor is up without a gateway |
| 🔴 | **Offline**: no report for over 60 s | **Stopped**: no gateway and no supervisor |

## Install on hermes-box (hub + agent)

The repo is private, so the laptop needs GitHub access to clone it
(`gh auth login`). Alternatively, clone it on another machine and copy it over.

```bash
git clone https://github.com/svhong/garage-monitor.git
cd garage-monitor
sudo ./install.sh
```

The installer will:

1. Detect the distro and install `python3-psutil`, plus the Intel GPU tools on
   Intel machines (`intel-gpu-tools` with apt, `igt-gpu-tools` with dnf).
   AMD GPUs need nothing extra: load, temperature, power, VRAM and the card's
   fan are read straight from the driver.
2. Create a locked-down system user `gmon` (no login, no home folder).
3. Copy the program to `/opt/garage-monitor` and its settings to `/etc/garage-monitor`.
4. Set up two systemd services that start on boot:
   - `garage-monitor-hub` listens **only on the Tailscale IP** (port 8787).
   - `garage-monitor-agent` gets exactly one extra permission, `CAP_PERFMON`,
     so it can read GPU load and chip power. It never runs as root.
5. Print the dashboard address, e.g. `http://hermes-box:8787`.

To update after a `git pull`, run `sudo ./install.sh` again. The access token is kept.

## Viewer password, HTTPS and your website

The first install asks for a **viewer password**, which is needed to open the
dashboard. The hub checks it; it never lives in any web page. Change it any
time with `sudo ./install.sh --set-password`.

To show the dashboard on your own website, use the React component in
[`web/`](web/README.md). It needs the hub on HTTPS (`--https`) and your site's
address allowed (`--allow-origin https://your-site.com`).

## Desktop widget (KDE Plasma)

To watch your machines on the desktop without a browser, install the Plasma 6 widget
on your desktop computer:

```bash
./plasmoid/install.sh
```

Then add **Garage Monitor** from **Add Widgets…** and set the hub address in its
settings. See [`plasmoid/README.md`](plasmoid/README.md).

## Add another machine later

On the new machine (Ubuntu/Debian or Fedora/RHEL, signed in to Tailscale):

```bash
sudo ./install.sh --agent-only --hub http://HUB-IP:8787 --token TOKEN
```

The hub install prints this exact command, with the right IP and token.
To read the token again: `sudo cat /etc/garage-monitor/hub.env`.

Before putting this on a **work laptop**, check with IT. Many companies don't
allow monitoring tools or Tailscale on company machines.

## Troubleshooting

| What | Command |
|---|---|
| Service status | `systemctl status garage-monitor-hub garage-monitor-agent` |
| Live logs | `journalctl -u garage-monitor-agent -f` |
| See exactly what the agent reads | `sudo -u gmon env $(sudo cat /etc/garage-monitor/agent.env \| xargs) python3 /opt/garage-monitor/agent/agent.py --once` |
| Remove everything | `sudo ./install.sh --uninstall` |

If the GPU row says something like "Permission denied" when run through the
service, the `CAP_PERFMON` permission isn't reaching `intel_gpu_top`. The
`--once` command above (run as `gmon` without the service) is *expected* to
show that error, since only the service grants the permission.

## Try the dashboard on any computer

```bash
GM_TOKEN=dev GM_BIND=127.0.0.1 python3 hub/hub.py
GM_TOKEN=dev python3 tools/fake_agent.py     # in a second terminal
```

Then open http://127.0.0.1:8787. The fake agent simulates three machines and
cycles Hermes through every status so all the dot colors can be seen.

## Roadmap

- [ ] A week of history (SQLite) with 24-hour and 7-day graphs
- [ ] Telegram alerts (high temperature, Hermes stopped, on battery, disk full)
