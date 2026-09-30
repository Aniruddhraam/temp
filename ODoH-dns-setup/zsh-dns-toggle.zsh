# Source from ~/.zshrc:  source /path/to/zsh-dns-toggle.zsh
# Requires: nmcli, dig, sudo, dnscrypt-proxy installed via odoh-migrate.sh
# ==============================================================================
# DNS mode switching: dnscrypt-proxy (ODoH) <-> the network's own plain DNS
# ------------------------------------------------------------------------------
# Normal state: /etc/resolv.conf -> 127.0.0.1 (dnscrypt-proxy, ODoH, cached).
# Captive networks (e.g. university Wi-Fi login) block ODoH/relay traffic until you
# authenticate, so nothing resolves and the login portal can't load. Workflow:
#   dnsplain   -> point resolv.conf at the DHCP-provided DNS, then open http://neverssl.com
#   dnsodoh    -> after logging in, go back to encrypted ODoH DNS
#   dnsstatus  -> show which mode is active and test a lookup
# dnscrypt-proxy keeps running in both modes; only /etc/resolv.conf changes.
# Full undo of the migration is a different command: sudo odoh-migrate rollback
# ==============================================================================

# Print the interface carrying the default route (falls back to the first connected NIC).
_dns_iface() {
  local dev
  dev=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  [[ -z $dev ]] && dev=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | awk -F: '$2=="connected" && $1!~/^(lo|tailscale)/{print $1; exit}')
  print -r -- "$dev"
}

# Switch to plain DNS using the first nameserver from the current network's DHCP lease.
dnsplain() {
  local dev dns
  dev=$(_dns_iface)
  dns=$(nmcli -g IP4.DNS device show "$dev" 2>/dev/null | head -1)
  if [[ -z $dns ]]; then
    echo "dnsplain: no DHCP DNS found on '${dev:-?}' (are you connected to the Wi-Fi?)" >&2
    return 1
  fi
  # tee (not >) so the redirect itself runs as root; keeps the file's SELinux context
  printf 'nameserver %s\n' "$dns" | sudo tee /etc/resolv.conf >/dev/null || return 1
  echo "==> PLAIN DNS via $dns on $dev (unencrypted; the network can see lookups)."
  echo "    Log in at http://neverssl.com, then run: dnsodoh"
}

# Switch back to the local dnscrypt-proxy (ODoH) resolver and check that it works.
dnsodoh() {
  systemctl is-active --quiet dnscrypt-proxy || sudo systemctl start dnscrypt-proxy || return 1
  printf 'nameserver 127.0.0.1\noptions edns0\n' | sudo tee /etc/resolv.conf >/dev/null || return 1
  # dig prints errors to stdout, so only a real IPv4 address counts as success
  if dig +short +time=6 +tries=1 example.com @127.0.0.1 2>/dev/null | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
    echo "==> ODoH DNS active (dnscrypt-proxy on 127.0.0.1) and resolving."
  else
    echo "==> resolv.conf now points at dnscrypt-proxy but it isn't resolving yet." >&2
    echo "    Not logged in to the network? Run dnsplain, log in, then dnsodoh again." >&2
    return 1
  fi
}

# Show the active mode and time a lookup.
dnsstatus() {
  local ns
  ns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
  if [[ $ns == 127.0.0.1 ]]; then echo "mode: ODoH (dnscrypt-proxy, $(systemctl is-active dnscrypt-proxy))"
  else echo "mode: PLAIN via ${ns:-none}"; fi
  dig +noall +answer +stats example.com | awk '/IN/{print "  " $0} /Query time/{print "  " $0}'
}

