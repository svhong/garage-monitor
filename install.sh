#!/usr/bin/env bash
# garage-monitor installer for Ubuntu/Debian.
#
#   sudo ./install.sh                         hub + agent (run this on hermes-box)
#   sudo ./install.sh --agent-only --hub URL --token TOKEN
#                                             agent only, reporting to an existing hub
#   sudo ./install.sh --uninstall             remove everything
#
# Options:
#   --port N            hub port (default 8787)
#   --hermes-user NAME  Linux user that runs Hermes (default: "hermes" if that user exists)
#   --no-hermes         don't look for Hermes on this machine
#   --name NAME         name shown on the dashboard (default: hostname)
#
# Hub options (for viewing on your website):
#   --set-password      ask for a (new) viewer password
#   --allow-origin URL  let this website read the data, e.g. https://example.com
#                       (repeat or comma-separate for several)
#   --https             serve the hub over HTTPS at https://<machine>.<tailnet>.ts.net
#                       via "tailscale serve" (needed for websites on https://)
#
# Re-running the script upgrades the installed files and keeps the existing
# token, password and allowed websites.
set -euo pipefail

APP=garage-monitor
SVC_USER=gmon
PREFIX=/opt/$APP
CONF=/etc/$APP
UNIT_DIR=/etc/systemd/system
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROLE=all
PORT=8787
HUB_URL=""
TOKEN=""
NAME=""
HERMES_USER=""
HERMES_SET=0
SET_PASSWORD=0
ORIGINS=""
HTTPS=0

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-only)  ROLE=agent ;;
    --uninstall)   ROLE=uninstall ;;
    --hub)         HUB_URL="${2:?--hub needs a URL}"; shift ;;
    --token)       TOKEN="${2:?--token needs a value}"; shift ;;
    --port)        PORT="${2:?--port needs a number}"; shift ;;
    --name)        NAME="${2:?--name needs a value}"; shift ;;
    --hermes-user) HERMES_USER="${2:?--hermes-user needs a name}"; HERMES_SET=1; shift ;;
    --no-hermes)   HERMES_USER=""; HERMES_SET=1 ;;
    --set-password) SET_PASSWORD=1 ;;
    --allow-origin) ORIGINS="${ORIGINS:+$ORIGINS,}${2:?--allow-origin needs a URL}"; shift ;;
    --https)       HTTPS=1 ;;
    -h|--help)     sed -n '2,25p' "$0"; exit 0 ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 $*"

if [[ $ROLE == uninstall ]]; then
  say "Stopping and removing services"
  systemctl disable --now $APP-agent.service $APP-hub.service 2>/dev/null || true
  if [[ -f $CONF/hub.env ]] && grep -q '^GM_HTTPS=1' "$CONF/hub.env"; then
    tailscale serve --https=443 off 2>/dev/null || true
  fi
  rm -f "$UNIT_DIR/$APP-agent.service" "$UNIT_DIR/$APP-hub.service"
  systemctl daemon-reload
  rm -rf "$PREFIX" "$CONF"
  id "$SVC_USER" &>/dev/null && userdel "$SVC_USER" || true
  say "Removed. (Packages python3-psutil and intel-gpu-tools were left installed.)"
  exit 0
fi

command -v apt-get >/dev/null || die "this installer supports Ubuntu/Debian only"
command -v tailscale >/dev/null || die "Tailscale is not installed"
command -v systemctl >/dev/null || die "systemd is required"

if [[ $ROLE == agent ]]; then
  [[ -n $HUB_URL && -n $TOKEN ]] || die "--agent-only needs --hub URL and --token TOKEN (the hub install prints both)"
fi

# --- packages --------------------------------------------------------------
PKGS=(python3 python3-psutil)
if grep -qs 0x8086 /sys/class/drm/card*/device/vendor; then
  PKGS+=(intel-gpu-tools)   # Intel GPU load and chip power
fi
say "Installing packages: ${PKGS[*]}"
apt-get update -qq >/dev/null
apt-get install -y -qq "${PKGS[@]}" >/dev/null

# --- service user ------------------------------------------------------------
if ! id "$SVC_USER" &>/dev/null; then
  say "Creating system user $SVC_USER"
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$SVC_USER"
fi
GROUPS_OK=()
for g in video render; do
  getent group "$g" >/dev/null && GROUPS_OK+=("$g")
done

# --- files -------------------------------------------------------------------
say "Copying program files to $PREFIX"
mkdir -p "$PREFIX"
rm -rf "$PREFIX/agent" "$PREFIX/hub"
cp -r "$SRC/agent" "$SRC/hub" "$PREFIX/"
find "$PREFIX" -name __pycache__ -prune -exec rm -rf {} +
chown -R root:root "$PREFIX"
chmod -R u=rwX,go=rX "$PREFIX"

install -d -m 750 -o root -g "$SVC_USER" "$CONF"

# --- settings ----------------------------------------------------------------
if [[ $HERMES_SET -eq 0 ]] && id hermes &>/dev/null; then
  HERMES_USER=hermes
fi

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
TS_NAME="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)"

if [[ $ROLE == all ]]; then
  [[ -n $TS_IP ]] || die "couldn't get this machine's Tailscale IP; is Tailscale connected? (tailscale status)"
  # Keep the existing token on upgrade so other agents don't need re-installing.
  if [[ -f $CONF/hub.env ]]; then
    TOKEN="$(sed -n 's/^GM_TOKEN=//p' "$CONF/hub.env")"
  fi
  [[ -n $TOKEN ]] || TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
  # The local agent talks to the hub over loopback.
  HUB_URL="http://127.0.0.1:$PORT"

  # Keep the password, allowed websites and HTTPS choice from a previous install.
  PW_HASH=""; OLD_ORIGINS=""
  if [[ -f $CONF/hub.env ]]; then
    PW_HASH="$(sed -n 's/^GM_VIEW_PASSWORD_HASH=//p' "$CONF/hub.env")"
    OLD_ORIGINS="$(sed -n 's/^GM_ALLOW_ORIGINS=//p' "$CONF/hub.env")"
    grep -q '^GM_HTTPS=1' "$CONF/hub.env" && HTTPS=1
  fi

  if [[ $SET_PASSWORD -eq 1 || ( -z $PW_HASH && -t 0 ) ]]; then
    echo
    echo "Choose a viewer password for the dashboard (at least 8 characters)."
    [[ -z $PW_HASH ]] && echo "Press Enter without typing to skip (anyone on your Tailscale could then view it)."
    while true; do
      read -rsp "Password: " PW1; echo
      if [[ -z $PW1 && $SET_PASSWORD -eq 0 ]]; then
        echo "Skipped. Set one later with: sudo ./install.sh --set-password"; break
      fi
      read -rsp "Again:    " PW2; echo
      if [[ $PW1 != "$PW2" ]]; then echo "They don't match, try again."; continue; fi
      if [[ ${#PW1} -lt 8 ]]; then echo "Too short, try again."; continue; fi
      PW_HASH="$(printf '%s\n' "$PW1" | python3 "$PREFIX/hub/hub.py" --hash-password)"
      unset PW1 PW2
      say "Password set"
      break
    done
  fi

  # Merge allowed websites, dropping trailing slashes and duplicates.
  ALL_ORIGINS="$(printf '%s' "$OLD_ORIGINS,$ORIGINS" | tr ',' '\n' | sed 's:/*$::' | grep -v '^$' | sort -u | paste -sd, - || true)"

  say "Writing $CONF/hub.env"
  umask 027
  cat > "$CONF/hub.env" <<EOF
GM_BIND=$TS_IP,127.0.0.1
GM_PORT=$PORT
GM_TOKEN=$TOKEN
GM_VIEW_PASSWORD_HASH=$PW_HASH
GM_ALLOW_ORIGINS=$ALL_ORIGINS
GM_HTTPS=$HTTPS
EOF
  chgrp "$SVC_USER" "$CONF/hub.env"
  umask 022
fi

say "Writing $CONF/agent.env"
umask 027
cat > "$CONF/agent.env" <<EOF
GM_HUB_URL=$HUB_URL
GM_TOKEN=$TOKEN
GM_INTERVAL=2
GM_HERMES_USER=$HERMES_USER
GM_NAME=$NAME
EOF
chgrp "$SVC_USER" "$CONF/agent.env"
umask 022

# --- systemd units -------------------------------------------------------------
say "Installing systemd services"
if [[ $ROLE == all ]]; then
  cat > "$UNIT_DIR/$APP-hub.service" <<EOF
[Unit]
Description=Garage Monitor hub (dashboard)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=$CONF/hub.env
ExecStart=/usr/bin/python3 $PREFIX/hub/hub.py
Restart=always
RestartSec=5
# The hub needs no special permissions at all.
CapabilityBoundingSet=
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true

[Install]
WantedBy=multi-user.target
EOF
fi

cat > "$UNIT_DIR/$APP-agent.service" <<EOF
[Unit]
Description=Garage Monitor agent (collects this machine's stats)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
${GROUPS_OK:+SupplementaryGroups=${GROUPS_OK[*]}}
EnvironmentFile=$CONF/agent.env
ExecStart=/usr/bin/python3 $PREFIX/agent/agent.py
Restart=always
RestartSec=5
# Option B: the only extra permission is reading performance counters
# (Intel GPU load and chip power). Nothing else.
AmbientCapabilities=CAP_PERFMON
CapabilityBoundingSet=CAP_PERFMON
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
if [[ $ROLE == all ]]; then
  systemctl enable --quiet $APP-hub.service
  systemctl restart $APP-hub.service
fi
systemctl enable --quiet $APP-agent.service
systemctl restart $APP-agent.service

sleep 3
FAILED=0
for svc in $( [[ $ROLE == all ]] && echo hub ) agent; do
  if systemctl is-active --quiet $APP-$svc.service; then
    say "$APP-$svc is running"
  else
    echo "!! $APP-$svc failed to start. See: journalctl -u $APP-$svc -n 30" >&2
    FAILED=1
  fi
done

HTTPS_OK=0
if [[ $ROLE == all && $HTTPS -eq 1 ]]; then
  say "Setting up HTTPS with tailscale serve"
  if tailscale serve --bg --https=443 "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
    HTTPS_OK=1
  else
    echo "!! tailscale serve failed. Turn on 'HTTPS Certificates' (and MagicDNS) in the" >&2
    echo "   Tailscale admin console under DNS, then run: sudo ./install.sh" >&2
  fi
fi

echo
if [[ $ROLE == all ]]; then
  echo "Dashboard:"
  [[ $HTTPS_OK -eq 1 && -n $TS_NAME ]] && echo "  https://$TS_NAME          <- use this one in your website component"
  [[ -n $TS_NAME ]] && echo "  http://$TS_NAME:$PORT"
  echo "  http://$TS_IP:$PORT"
  echo "  (works from any device signed in to your Tailscale)"
  [[ -n $ALL_ORIGINS ]] && echo "Websites allowed to show it: $ALL_ORIGINS"
  [[ -z $PW_HASH ]] && echo "No viewer password is set. Add one with: sudo ./install.sh --set-password"
  echo
  echo "To add another machine later, clone the repo there and run:"
  echo "  sudo ./install.sh --agent-only --hub http://$TS_IP:$PORT --token $TOKEN"
else
  echo "Agent installed; it should appear on the dashboard within a few seconds."
fi
[[ -n $HERMES_USER ]] && echo && echo "Watching Hermes processes owned by user: $HERMES_USER"
exit $FAILED
