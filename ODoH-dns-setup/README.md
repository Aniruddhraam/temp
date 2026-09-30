# ODoH DNS setup (dnscrypt-proxy)

Replaces systemd-resolved with dnscrypt-proxy using Oblivious DoH (Cloudflare target via a relay),
with a 4096-entry cache and a 40 min minimum TTL.

```
sudo ./odoh-migrate.sh          # migrate (setup-ODoH.sh is a thin wrapper around this)
sudo odoh-migrate rollback      # undo
```

## How it stays safe
1. **Preflight** – no changes; aborts on a bad tarball or if 127.0.0.1:53 is taken.
2. **Stage** – dnscrypt-proxy starts next to systemd-resolved (resolved only binds 127.0.0.53/.54) and must
   resolve real names over ODoH. On failure the config is restored and system DNS was never touched.
3. **Commit** – a 10 min dead-man rollback timer is armed, then resolv.conf, resolved (service + varlink/monitor
   sockets), nsswitch and Tailscale DNS are switched.
4. **Verify** – lookups must work through the normal libc path, otherwise it rolls back automatically.

Backups live in `/var/lib/odoh-migration/<timestamp>`; log in `/var/log/odoh-migration.log`.

## Things the old script got wrong (fixed)
- dnscrypt-proxy 2.1.14 (Fedora) exits FATAL if `forwarding-rules.txt` is missing, and the unit waits 120 s to
  retry. The rules file is now seeded and a drop-in sets `RestartSec=3`.
- `systemd-resolved-varlink.socket` re-activates resolved on the first NSS lookup; the sockets are now disabled too.
- `sed -i` replaced the authselect `/etc/nsswitch.conf` symlink with a regular file; now `--follow-symlinks`.
- Tailscale MagicDNS broke with `--accept-dns=false`; the dispatcher now forwards the tailnet suffix to 100.100.100.100.

## Caveats
- Networks that block UDP/53 to the bootstrap resolvers (1.1.1.1 / 1.0.0.1) or HTTPS to the relay will fail the
  stage step (safely). `ignore_system_dns = true`, so there is no fallback to the network's DNS.
- Captive portals, `.lan`/`.local` and the network search domain are forwarded to the DHCP DNS by
  `/etc/NetworkManager/dispatcher.d/99-captive-dns`.

## One-word DNS switching for captive portals
Captive networks (e.g. a university Wi-Fi login) block ODoH/relay traffic until you authenticate. Add
`zsh-dns-toggle.zsh` to your shell (`source` it from `~/.zshrc`) to get:

| Command | Effect |
|---|---|
| `dnsplain` | Point `/etc/resolv.conf` at the DHCP-provided DNS, then open `http://neverssl.com` to log in |
| `dnsodoh` | Back to dnscrypt-proxy (ODoH); starts the service if needed and checks that lookups work |
| `dnsstatus` | Show the active mode and time a lookup |

dnscrypt-proxy keeps running in both modes; only `/etc/resolv.conf` changes. While in plain mode the network
can see your lookups, so switch back once logged in.
