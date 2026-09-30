#!/usr/bin/env bash
# Deprecated entry point. The old script disabled systemd-resolved before verifying that
# dnscrypt-proxy worked, which could leave the machine without DNS. It now delegates to
# odoh-migrate.sh, which stages and verifies first and rolls back automatically on failure.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/odoh-migrate.sh" "$@"
