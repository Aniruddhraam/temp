#!/usr/bin/env bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo."
  exit 1
fi

echo "[+] Installing dnscrypt-proxy if not present..."
if command -v dnf &> /dev/null; then
  dnf install -y dnscrypt-proxy
elif command -v apt &> /dev/null; then
  apt-get update && apt-get install -y dnscrypt-proxy
fi

echo "[+] Creating cache directory and setting permissions..."
mkdir -p /var/cache/dnscrypt-proxy
chown dnscrypt-proxy:dnscrypt-proxy /var/cache/dnscrypt-proxy 2>/dev/null || chown _dnscrypt-proxy:_dnscrypt-proxy /var/cache/dnscrypt-proxy 2>/dev/null || true

echo "[+] Restoring configuration backup..."
if [ -f "dnscrypt-odoh-backup.tar.gz" ]; then
  tar -xzvf dnscrypt-odoh-backup.tar.gz -C /
else
  echo "[!] Backup tarball not found! Ensure dnscrypt-odoh-backup.tar.gz is in the current directory."
  exit 1
fi

echo "[+] Stopping and disabling systemd-resolved..."
systemctl stop systemd-resolved || true
systemctl disable systemd-resolved || true

echo "[+] Rebuilding /etc/resolv.conf..."
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chown root:root /etc/resolv.conf
chmod 644 /etc/resolv.conf
restorecon -v /etc/resolv.conf 2>/dev/null || true

echo "[+] Patching /etc/nsswitch.conf to remove systemd-resolve..."
sed -i 's/resolve \[!UNAVAIL=return\] //g' /etc/nsswitch.conf
sed -i 's/resolve //g' /etc/nsswitch.conf

echo "[+] Setting executable permissions on NetworkManager dispatcher..."
chmod +x /etc/NetworkManager/dispatcher.d/99-captive-dns

echo "[+] Disabling Tailscale DNS hijacking (if installed)..."
if command -v tailscale &> /dev/null; then
  tailscale set --accept-dns=false || true
fi

echo "[+] Reloading and restarting services..."
systemctl daemon-reload
systemctl restart NetworkManager
systemctl enable --now dnscrypt-proxy
systemctl restart dnscrypt-proxy

echo "[✓] Deployment complete! Verification test:"
dig amazon.com @127.0.0.1 | grep "Query time"
