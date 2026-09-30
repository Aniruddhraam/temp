#!/usr/bin/env bash
# Safe one-shot migration: systemd-resolved -> dnscrypt-proxy (ODoH).
#
#   sudo ./odoh-migrate.sh            migrate
#   sudo odoh-migrate rollback        undo (also armed automatically as a dead-man switch)
#
# Phases:
#   1 PREFLIGHT  no system changes; abort on any problem
#   2 STAGE      dnscrypt-proxy runs on 127.0.0.1:53 NEXT TO systemd-resolved
#                (resolved only binds 127.0.0.53/.54) and must resolve real names over ODoH
#   3 COMMIT     dead-man rollback armed, then resolv.conf / resolved / nsswitch / tailscale switched
#   4 VERIFY     name resolution must work through the normal libc path, otherwise auto-rollback
#
# If STAGE fails nothing about system DNS has been touched.
set -Eeuo pipefail
trap '' HUP PIPE   # a closed terminal must not kill us half way

ROOT="${ODOH_ROOT:-}"            # test hook: fake filesystem root (never set in real use)
PORT="${ODOH_TEST_PORT:-53}"     # test hook
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="${TARBALL:-$HERE/dnscrypt-odoh-backup.tar.gz}"
STATE_DIR="$ROOT/var/lib/odoh-migration"
LOG="$ROOT/var/log/odoh-migration.log"
STAGE_TIMEOUT="${STAGE_TIMEOUT:-90}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-45}"
DEADMAN_MIN="${DEADMAN_MIN:-10}"
TEST_NAMES=(example.com cloudflare.com github.com)
RESOLVED_UNITS=(systemd-resolved.service systemd-resolved-varlink.socket systemd-resolved-monitor.socket)

mkdir -p "$(dirname "$LOG")" "$STATE_DIR"
log()  { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$LOG" >&2; }
die()  { log "ABORT: $*"; exit 1; }
sc()   { systemctl "$@"; }

# ---------------------------------------------------------------- helpers
dns_ok() {   # >=2 of 3 names resolve through the local proxy
  local n out ok=0
  for n in "${TEST_NAMES[@]}"; do
    # dig prints "communications error" to STDOUT on failure, so only a real IPv4 address counts as an answer
    out="$(dig +short +time=4 +tries=1 "$n" A @127.0.0.1 -p "$PORT" 2>/dev/null || true)"
    grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<<"$out" && ok=$((ok+1))
  done
  [ "$ok" -ge 2 ]
}

wait_for() {  # wait_for <seconds> <cmd...>
  local t=$1 i=0; shift
  while [ "$i" -lt "$t" ]; do "$@" && return 0; sleep 2; i=$((i+2)); done
  return 1
}

libc_ok() {   # the real path every application uses: nsswitch -> resolv.conf -> 127.0.0.1
  [ -n "$ROOT" ] && return 0                     # not testable in the fake root
  getent ahostsv4 example.org >/dev/null 2>&1 && getent ahostsv4 github.com >/dev/null 2>&1
}

odoh_ok() {   # dnscrypt-proxy reports a live ODoH server
  [ -n "$ROOT" ] && return 0
  journalctl -u dnscrypt-proxy --since "-10min" --no-pager 2>/dev/null | grep -q 'OK (ODoH)'
}

default_dev() { ip route show default 2>/dev/null | awk '/default/{print $5; exit}'; }

tailnet_suffix() {
  command -v tailscale >/dev/null 2>&1 || return 0
  tailscale status --json 2>/dev/null | sed -n 's/.*"MagicDNSSuffix": *"\([^"]*\)".*/\1/p' | head -1
}

write_dispatcher() {   # improved 99-captive-dns: same rules as your original + tailnet MagicDNS
  local tn="$1" f="$ROOT/etc/NetworkManager/dispatcher.d/99-captive-dns"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<EOF
#!/bin/bash
# Managed by odoh-migrate.sh. Regenerates dnscrypt-proxy forwarding rules on every connection.
ACTION=\$2
RULES=/etc/dnscrypt-proxy/forwarding-rules.txt
TAILNET="$tn"
if [ "\$ACTION" = "up" ]; then
    LOCAL_DNS=\$(echo "\$IP4_NAMESERVERS" | awk '{print \$1}')
    [ -z "\$LOCAL_DNS" ] && LOCAL_DNS=\$(echo "\$DHCP4_DOMAIN_NAME_SERVERS" | awk '{print \$1}')
    SEARCH_DOMAIN=\$(echo "\$IP4_DOMAINS" | awk '{print \$1}')
    if [ -n "\$LOCAL_DNS" ]; then
        {
          echo "# Captive portal bypasses"
          for d in fedoraproject.org '*.fedoraproject.org' networkcheck.kde.org nmcheck.gnome.org; do echo "\$d \$LOCAL_DNS"; done
          echo "# Standard local network routing"
          for d in local '*.local' lan '*.lan' home.arpa '*.home.arpa' router.local; do echo "\$d \$LOCAL_DNS"; done
          if [ -n "\$SEARCH_DOMAIN" ] && [ "\$SEARCH_DOMAIN" != "~" ]; then
              echo "\$SEARCH_DOMAIN \$LOCAL_DNS"; echo "*.\$SEARCH_DOMAIN \$LOCAL_DNS"
          fi
          [ -n "\$TAILNET" ] && echo "\$TAILNET 100.100.100.100"
        } > "\$RULES.tmp" && mv -f "\$RULES.tmp" "\$RULES"
    fi
fi
EOF
  chmod 755 "$f"
}

seed_rules() {   # dnscrypt-proxy 2.1.14 is FATAL if the rules file is missing -> always create it now
  local dev dns dom tn; tn="$(tailnet_suffix || true)"
  dev="$(default_dev || true)"
  dns="$(nmcli -g IP4.DNS device show "$dev" 2>/dev/null | head -1 || true)"
  dom="$(nmcli -g IP4.DOMAIN device show "$dev" 2>/dev/null | head -1 || true)"
  IP4_NAMESERVERS="$dns" IP4_DOMAINS="$dom" bash "$ROOT/etc/NetworkManager/dispatcher.d/99-captive-dns" "$dev" up || true
  [ -f "$ROOT/etc/dnscrypt-proxy/forwarding-rules.txt" ] || {
    { echo "# seeded empty by odoh-migrate.sh"; [ -n "$tn" ] && echo "$tn 100.100.100.100"; } > "$ROOT/etc/dnscrypt-proxy/forwarding-rules.txt"; }
}

# ---------------------------------------------------------------- rollback
do_rollback() {
  local bk="${1:-$STATE_DIR/latest}"
  [ -d "$bk" ] || die "no backup dir at $bk"
  bk="$(readlink -f "$bk")"
  log "ROLLBACK using $bk"
  # 1. bring resolved back first so DNS recovers as early as possible
  for u in "${RESOLVED_UNITS[@]}"; do sc enable --now "$u" 2>/dev/null || sc start "$u" 2>/dev/null || true; done
  # 2. resolv.conf -> original symlink/file
  if [ -f "$bk/resolv.link" ]; then ln -sfn "$(cat "$bk/resolv.link")" "$ROOT/etc/resolv.conf"
  elif [ -f "$bk/resolv.conf" ]; then cp -f "$bk/resolv.conf" "$ROOT/etc/resolv.conf"; fi
  # 3. nsswitch (content of the real file, keeps the authselect symlink)
  if [ -f "$bk/nsswitch.orig" ]; then cat "$bk/nsswitch.orig" > "$(readlink -f "$ROOT/etc/nsswitch.conf")"; fi
  # 4. NetworkManager config + dispatcher
  [ -f "$bk/NetworkManager.conf" ] && cp -f "$bk/NetworkManager.conf" "$ROOT/etc/NetworkManager/NetworkManager.conf"
  [ -f "$bk/dispatcher.absent" ] && rm -f "$ROOT/etc/NetworkManager/dispatcher.d/99-captive-dns"
  [ -f "$bk/dispatcher.orig" ] && cp -f "$bk/dispatcher.orig" "$ROOT/etc/NetworkManager/dispatcher.d/99-captive-dns"
  # 5. tailscale
  if [ -f "$bk/tailscale.corpdns" ] && [ "$(cat "$bk/tailscale.corpdns")" = "true" ] && command -v tailscale >/dev/null 2>&1; then
    tailscale set --accept-dns=true || true
  fi
  # 6. stop dnscrypt, drop the drop-in, reload
  sc disable --now dnscrypt-proxy.service 2>/dev/null || true
  rm -rf "$ROOT/etc/systemd/system/dnscrypt-proxy.service.d"
  sc daemon-reload || true
  sc restart NetworkManager || true
  sc stop odoh-deadman.timer 2>/dev/null || true
  if [ -z "$ROOT" ]; then
    wait_for 30 getent ahostsv4 example.org >/dev/null 2>&1 && log "rollback OK: DNS works again" || log "WARNING: DNS still failing after rollback"
  else
    log "rollback done"
  fi
}

if [ "${1:-}" = "rollback" ]; then do_rollback "${2:-}"; exit 0; fi

# ---------------------------------------------------------------- 1. PREFLIGHT
[ -n "$ROOT" ] || [ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$TARBALL" ] || die "tarball not found: $TARBALL"
if tar -tzf "$TARBALL" | grep -qE '^/|(^|/)\.\.(/|$)'; then die "tarball has absolute or .. paths"; fi
tar -tzf "$TARBALL" | grep -q 'etc/dnscrypt-proxy/dnscrypt-proxy.toml' || die "tarball lacks dnscrypt-proxy.toml"
for c in dig tar ip; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c (dnf install bind-utils)"; done
if ! command -v dnscrypt-proxy >/dev/null 2>&1; then
  log "installing dnscrypt-proxy"
  if command -v dnf >/dev/null 2>&1; then dnf install -y dnscrypt-proxy
  elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y dnscrypt-proxy
  else die "no supported package manager"; fi
fi
command -v dnscrypt-proxy >/dev/null 2>&1 || die "dnscrypt-proxy still not installed"
if [ -z "$ROOT" ] && ss -lunH 2>/dev/null | awk '{print $5}' | grep -qE '^127\.0\.0\.1:53$'; then
  die "something already listens on 127.0.0.1:53"
fi
if [ -z "$ROOT" ]; then
  wait_for 6 getent ahostsv4 example.org >/dev/null 2>&1 || die "system DNS is not working before migration; fix that first"
fi
log "preflight OK"

# ---------------------------------------------------------------- backup (state needed for rollback)
TS="$(date +%Y%m%d-%H%M%S)"; BK="$STATE_DIR/$TS"; mkdir -p "$BK"
ln -sfn "$BK" "$STATE_DIR/latest"
[ -L "$ROOT/etc/resolv.conf" ] && readlink "$ROOT/etc/resolv.conf" > "$BK/resolv.link" || cp -a "$ROOT/etc/resolv.conf" "$BK/resolv.conf" 2>/dev/null || true
cat "$ROOT/etc/nsswitch.conf" > "$BK/nsswitch.orig"
cp -a "$ROOT/etc/NetworkManager/NetworkManager.conf" "$BK/NetworkManager.conf"
if [ -f "$ROOT/etc/NetworkManager/dispatcher.d/99-captive-dns" ]; then cp -a "$ROOT/etc/NetworkManager/dispatcher.d/99-captive-dns" "$BK/dispatcher.orig"; else : > "$BK/dispatcher.absent"; fi
[ -d "$ROOT/etc/dnscrypt-proxy" ] && cp -a "$ROOT/etc/dnscrypt-proxy" "$BK/dnscrypt-proxy.dir"
if command -v tailscale >/dev/null 2>&1; then tailscale debug prefs 2>/dev/null | sed -n 's/.*"CorpDNS": *\(true\|false\).*/\1/p' > "$BK/tailscale.corpdns" || true; fi
install -m 755 "${BASH_SOURCE[0]}" "$ROOT/usr/local/sbin/odoh-migrate" 2>/dev/null || { mkdir -p "$ROOT/usr/local/sbin"; install -m 755 "${BASH_SOURCE[0]}" "$ROOT/usr/local/sbin/odoh-migrate"; }
log "backup in $BK (undo any time: sudo odoh-migrate rollback)"

# ---------------------------------------------------------------- 2. STAGE
stage_fail() { log "STAGE FAILED: $1 -- system DNS untouched, restoring config"; sc disable --now dnscrypt-proxy.service 2>/dev/null || true
               [ -d "$BK/dnscrypt-proxy.dir" ] && { rm -rf "$ROOT/etc/dnscrypt-proxy"; cp -a "$BK/dnscrypt-proxy.dir" "$ROOT/etc/dnscrypt-proxy"; }
               [ -f "$BK/NetworkManager.conf" ] && cp -f "$BK/NetworkManager.conf" "$ROOT/etc/NetworkManager/NetworkManager.conf"
               [ -f "$BK/dispatcher.absent" ] && rm -f "$ROOT/etc/NetworkManager/dispatcher.d/99-captive-dns"
               rm -rf "$ROOT/etc/systemd/system/dnscrypt-proxy.service.d"; sc daemon-reload || true
               exit 1; }

log "extracting config"
mkdir -p "$ROOT/etc" "$ROOT/var/cache/dnscrypt-proxy"
tar -xzf "$TARBALL" -C "${ROOT:-/}"
TN="$(tailnet_suffix || true)"
write_dispatcher "$TN"
seed_rules
if [ -n "$ROOT" ]; then   # test shim: unprivileged port + fake-root paths
  sed -i "s#127.0.0.1:53'#127.0.0.1:$PORT'#; s#/var/cache/dnscrypt-proxy/#$ROOT/var/cache/dnscrypt-proxy/#g; s#/etc/dnscrypt-proxy/forwarding-rules.txt#$ROOT/etc/dnscrypt-proxy/forwarding-rules.txt#" "$ROOT/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
  sed -i "s#^RULES=/etc/#RULES=$ROOT/etc/#" "$ROOT/etc/NetworkManager/dispatcher.d/99-captive-dns"
  seed_rules
fi
[ -z "$ROOT" ] && command -v restorecon >/dev/null 2>&1 && restorecon -R /etc/dnscrypt-proxy /etc/NetworkManager /var/cache/dnscrypt-proxy 2>/dev/null || true

# make crashes recover in seconds, not the packaged 120 s (with resolved gone that would be 2 min of no DNS)
mkdir -p "$ROOT/etc/systemd/system/dnscrypt-proxy.service.d"
cat > "$ROOT/etc/systemd/system/dnscrypt-proxy.service.d/override.conf" <<'EOF'
[Unit]
StartLimitIntervalSec=0
[Service]
Restart=always
RestartSec=3
EOF
sc daemon-reload

dnscrypt-proxy -config "$ROOT/etc/dnscrypt-proxy/dnscrypt-proxy.toml" -check >"$BK/check.log" 2>&1 || { tail -5 "$BK/check.log" >&2; stage_fail "config check failed"; }
log "config check OK"

log "starting dnscrypt-proxy next to systemd-resolved and testing (up to ${STAGE_TIMEOUT}s)"
sc enable --now dnscrypt-proxy.service || stage_fail "could not start dnscrypt-proxy"
wait_for "$STAGE_TIMEOUT" dns_ok || stage_fail "no resolution via ODoH on 127.0.0.1 (network may block ODoH/relays/bootstrap)"
odoh_ok || stage_fail "resolving, but no ODoH server is live"
log "STAGE OK: ODoH resolution works on 127.0.0.1:$PORT"

# ---------------------------------------------------------------- 3. COMMIT
COMMITTED=0
on_err() { local rc=$?; if [ "$COMMITTED" = 1 ]; then log "ERROR (rc=$rc) after commit -> rolling back"; do_rollback "$BK"; fi; exit "$rc"; }
trap on_err ERR

log "arming dead-man rollback in ${DEADMAN_MIN} min"
if [ -z "$ROOT" ]; then
  systemd-run --quiet --unit=odoh-deadman --on-active="${DEADMAN_MIN}min" /usr/local/sbin/odoh-migrate rollback "$BK"
fi
COMMITTED=1
log "COMMIT: switching system DNS"
printf 'nameserver 127.0.0.1\noptions edns0\n' > "$ROOT/etc/resolv.conf.new"
chmod 644 "$ROOT/etc/resolv.conf.new"
mv -fT "$ROOT/etc/resolv.conf.new" "$ROOT/etc/resolv.conf"           # atomic, replaces the symlink
[ -z "$ROOT" ] && command -v restorecon >/dev/null 2>&1 && restorecon /etc/resolv.conf 2>/dev/null || true
sed -i --follow-symlinks 's/resolve \[!UNAVAIL=return\] //g; s/resolve //g' "$ROOT/etc/nsswitch.conf"   # keeps the authselect symlink
for u in "${RESOLVED_UNITS[@]}"; do sc disable --now "$u" 2>/dev/null || true; done   # sockets too, or resolved re-activates
if command -v tailscale >/dev/null 2>&1; then tailscale set --accept-dns=false || true; fi
sc restart NetworkManager

# ---------------------------------------------------------------- 4. VERIFY
log "verifying (up to ${VERIFY_TIMEOUT}s)"
wait_for "$VERIFY_TIMEOUT" libc_ok || false
dns_ok || false
if [ -n "$TN" ] && [ -z "$ROOT" ]; then
  peer="$(tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/\1/p' | sed -n 2p)"
  [ -n "$peer" ] && { getent hosts "$peer" >/dev/null 2>&1 && log "tailnet name OK ($peer)" || log "note: tailnet name $peer did not resolve (peer offline?)"; }
fi
trap - ERR
sc stop odoh-deadman.timer 2>/dev/null || true
log "SUCCESS. Resolver: dnscrypt-proxy (ODoH) on 127.0.0.1. Undo: sudo odoh-migrate rollback"
[ -z "$ROOT" ] && dig amazon.com @127.0.0.1 | grep 'Query time' || true
