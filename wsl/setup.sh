#!/usr/bin/env bash
# Configures Docker Engine inside a WSL distro (Ubuntu/Debian). Run as root.
# Safe to run more than once: every step checks what is already there.
#
#   --fresh   the distro was just created by the installer (sets root as default user)

set -euo pipefail

FRESH=0
[ "${1:-}" = "--fresh" ] && FRESH=1

log()  { echo "  [wsl] $*"; }
fail() { echo "  [wsl] ERROR: $*" >&2; exit 1; }

# Network inside WSL can be flaky (DNS, VPNs): retry downloads a few times
retry() { # attempts command...
  local n="$1" i=1; shift
  until "$@"; do
    [ "$i" -ge "$n" ] && return 1
    log "Network problem, retrying ($i/$((n - 1)))..."
    i=$((i + 1)); sleep $((i * 3))
  done
}

[ "$(id -u)" -eq 0 ] || fail "must run as root"

. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *" ubuntu "*|*" debian "*) ;;
  *) fail "unsupported distro '${ID:-unknown}' (needs Ubuntu or Debian)";;
esac

WSL_CONF="${WSL_CONF:-/etc/wsl.conf}"

# ---- /etc/wsl.conf helpers (keep the user's other settings) -----------------

ini_get() { # section key
  [ -f "$WSL_CONF" ] || return 0
  awk -v s="$1" -v k="$2" '
    /^[[:space:]]*\[/ { gsub(/[][[:space:]]/, ""); insec = ($0 == s); next }
    insec {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (index(line, k) == 1) {
        rest = substr(line, length(k) + 1)
        if (rest ~ /^[[:space:]]*=/) { sub(/^[[:space:]]*=[[:space:]]*/, "", rest); print rest; exit }
      }
    }' "$WSL_CONF"
}

ini_set() { # section key value
  touch "$WSL_CONF"
  awk -v s="$1" -v k="$2" -v v="$3" '
    function emit() { print k " = " v; done = 1 }
    /^[[:space:]]*\[/ {
      if (insec && !done) emit()
      name = $0; gsub(/[][[:space:]]/, "", name)
      insec = (name == s); if (insec) seen = 1
      print; next
    }
    insec {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (index(line, k) == 1 && substr(line, length(k) + 1) ~ /^[[:space:]]*=/) {
        if (!done) emit()
        next
      }
    }
    { print }
    END {
      if (!done) {
        if (!seen) { print ""; print "[" s "]" }
        emit()
      }
    }' "$WSL_CONF" > "$WSL_CONF.tmp"
  cat "$WSL_CONF.tmp" > "$WSL_CONF" && rm -f "$WSL_CONF.tmp"
}

# ---- WSL settings ------------------------------------------------------------

log "Configuring /etc/wsl.conf"
if [ -f "$WSL_CONF" ] && [ ! -f "$WSL_CONF.before-wsl-docker-engine" ]; then
  cp "$WSL_CONF" "$WSL_CONF.before-wsl-docker-engine"
fi
conf_before="$(cat "$WSL_CONF" 2>/dev/null || true)"

# systemd starts Docker automatically when the distro boots
ini_set boot systemd true

# "metadata" lets Linux owners/permissions be stored on Windows drives
# (Postgres and others refuse data folders without proper permissions)
opts="$(ini_get automount options | tr -d '"')"
case ",$opts," in
  *,metadata,*) ;;
  *) ini_set automount options "\"${opts:+$opts,}metadata\"" ;;
esac

if [ "$FRESH" -eq 1 ]; then
  ini_set user default root
fi

# ---- Packages ----------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Acquire::Retries=5 -o Acquire::http::Timeout=30)
apt_updated=0
need_pkg() {
  if ! dpkg -s "$1" >/dev/null 2>&1; then
    if [ "$apt_updated" -eq 0 ]; then retry 4 apt-get "${APT_OPTS[@]}" update -qq; apt_updated=1; fi
    log "Installing $1"
    retry 4 apt-get "${APT_OPTS[@]}" install -y -qq "$1" >/dev/null
  fi
}
need_pkg ca-certificates
need_pkg curl
need_pkg socat

if command -v dockerd >/dev/null 2>&1; then
  log "Docker Engine already installed: $(dockerd --version)"
else
  log "Installing Docker Engine (official script from get.docker.com)"
  retry 4 curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 3 https://get.docker.com -o /tmp/get-docker.sh \
    || fail "Could not download https://get.docker.com (check your internet connection / DNS)"
  # The official script also downloads keys and packages: retry it as a whole
  retry 3 sh -c 'sh /tmp/get-docker.sh >/tmp/get-docker.log 2>&1' \
    || { tail -n 30 /tmp/get-docker.log; fail "Docker install failed"; }
  rm -f /tmp/get-docker.sh
  log "Installed: $(dockerd --version)"
fi

# Enable Docker at boot (works even before systemd is running)
systemctl enable docker.service docker.socket >/dev/null 2>&1 || true

# ---- Windows paths for docker compose ----------------------------------------
# With COMPOSE_CONVERT_WINDOWS_PATHS=1, compose turns C:\x into /c/x.
# This makes /c, /d, ... point to the WSL drive mounts.

AUTOMOUNT_ROOT="$(ini_get automount root | tr -d '"')"
AUTOMOUNT_ROOT="${AUTOMOUNT_ROOT:-/mnt/}"

cat > /usr/local/sbin/wsl-docker-drive-links <<EOF
#!/bin/sh
# Created by wsl-docker-engine: links /c -> ${AUTOMOUNT_ROOT%/}/c (and other drives)
for d in ${AUTOMOUNT_ROOT%/}/?; do
  [ -d "\$d" ] || continue
  l="/\$(basename "\$d")"
  [ -e "\$l" ] || [ -L "\$l" ] || ln -s "\$d" "\$l"
done
EOF
chmod 755 /usr/local/sbin/wsl-docker-drive-links

cat > /etc/systemd/system/wsl-docker-drive-links.service <<'EOF'
[Unit]
Description=Link Windows drives as /c, /d, ... (wsl-docker-engine)
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wsl-docker-drive-links

[Install]
WantedBy=multi-user.target
EOF
systemctl enable wsl-docker-drive-links.service >/dev/null 2>&1 || true
/usr/local/sbin/wsl-docker-drive-links

# ---- Automatic security updates for Docker Engine -----------------------------

if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ] && grep -rqs "download.docker.com" /etc/apt/sources.list.d/; then
  cat > /etc/apt/apt.conf.d/52wsl-docker-engine <<'EOF'
// Created by wsl-docker-engine: also auto-update Docker Engine from the official repo
Unattended-Upgrade::Origins-Pattern {
	"origin=Docker,archive=${distro_codename},label=Docker CE";
};
EOF
  chmod 644 /etc/apt/apt.conf.d/52wsl-docker-engine
  log "Automatic updates enabled for Docker Engine"
fi

touch /etc/wsl-docker-engine

# Tell the installer whether the distro must restart (new wsl.conf or no systemd yet)
if [ "$(cat "$WSL_CONF" 2>/dev/null || true)" != "$conf_before" ] || [ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]; then
  touch /run/wsl-docker-engine.restart
fi
log "Done"
