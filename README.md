# discourse-health-check

A single-script, one-shot health overview for a Discourse forum server.

Run it from the host's command line and get a clean, color-coded report covering
system resources, Docker, every Discourse service, backups, TLS, and security
basics — with a pass / warning / critical summary at the bottom.

No agents, no daemons, no dependencies beyond what's already on a typical
Discourse host.

```
╔══════════════════════════════════════════════════════════╗
║  Discourse Server Health Check                           ║
╚══════════════════════════════════════════════════════════╝
  Host: forum.example.com    Date: 2026-06-03 14:32:09 UTC
  Discourse path: /var/discourse    Container: app

━━━ SYSTEM UPTIME & LOAD
  · Uptime: up 3 weeks, 2 days
  · Load average: 0.05 / 0.07 / 0.07  (6 CPU cores)
  ✔ CPU load: 1% of capacity

━━━ MEMORY
  · RAM: 3188MB used / 5927MB total / 1716MB available
  ✔ Memory utilization: 53%
  ✔ Swap: 57MB / 1023MB (5%)

  ... (sections for Disk, Network, Docker, Discourse Services,
       Backups, SSL/TLS, Security) ...

════════════════════════════════════════════════════════════

  Summary    19 passed   1 warnings   0 critical   (20 checks)

  ▸ Warnings found — review items marked ⚠ above

════════════════════════════════════════════════════════════
```

## What it checks

**System**
- Uptime and load average vs CPU core count
- RAM and swap usage
- Disk space and inode usage per real mount (snap/tmpfs excluded)
- TCP connection counts, local HTTP response

**Docker**
- Engine version, container running status, restart count, CPU/memory usage
- Docker storage footprint

**Discourse services (inside the container)**
- PostgreSQL — readiness, database size, connection pool usage
- Redis — ping, memory, key count
- Nginx, Puma (worker count), Sidekiq (queue / retry / scheduled)
- Discourse version, uploads directory size

**Backups**
- Newest backup file, age, size, total backup count
- Warns at 7 days, critical at 14 days

**SSL / TLS**
- Live cert served on `:443` (what visitors actually see)
- On-disk cert files (flags stale/expired files when live TLS is fine)
- `--no-ssl-check` to skip the live check when behind Cloudflare or another CDN

**Security**
- Pending OS package updates (highlights security patches)
- Failed SSH attempts in the last 24 hours
- Firewall status (UFW / firewalld / iptables)
- Fail2ban status and active jails

## Requirements

- Linux host running a standard Discourse Docker install
- `bash`, `docker`, `curl`, `openssl`, `awk`, `grep`, `find` (all standard)
- Optional: `ufw` / `firewall-cmd` / `iptables`, `fail2ban-client`, `journalctl`

Tested on Ubuntu 22.04 and 24.04. Should work on any modern Debian/RHEL-family
distro with a standalone Discourse container.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/haydenjames/discourse-health-check/main/discourse-health-check.sh \
  -o /usr/local/bin/discourse-health-check
sudo chmod +x /usr/local/bin/discourse-health-check
```

Or clone the repo:

```bash
git clone https://github.com/haydenjames/discourse-health-check.git
cd discourse-health-check
chmod +x discourse-health-check.sh
```

## Usage

```bash
sudo ./discourse-health-check.sh
```

### Options

```
--container NAME    Discourse container name (default: app)
--no-ssl-check      Skip the live TLS check (useful behind Cloudflare / CDN)
--no-color          Disable ANSI colors (good for piping to a file)
-h, --help          Show help
```

### Examples

Save a plain-text report:

```bash
sudo ./discourse-health-check.sh --no-color > health-$(date +%F).txt
```

Run against a non-default container name:

```bash
sudo ./discourse-health-check.sh --container forum
```

Use behind Cloudflare (skip live TLS check):

```bash
sudo ./discourse-health-check.sh --no-ssl-check
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0`  | All checks passed |
| `1`  | One or more warnings |
| `2`  | One or more critical issues |

Useful in cron — pipe the output to a log and alert only on non-zero exit:

```cron
0 7 * * * /usr/local/bin/discourse-health-check --no-color > /var/log/discourse-health.log 2>&1 || mail -s "Discourse health: issues" admin@example.com < /var/log/discourse-health.log
```

## Contributing

Issues and pull requests welcome. If a check is wrong or missing for your
distro / setup, please open an issue with the relevant output so it can be
fixed for everyone.

## License

MIT — see [LICENSE](LICENSE).
