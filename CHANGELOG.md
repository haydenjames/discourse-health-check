# Changelog

All notable changes to this project will be documented in this file.

## [1.0.2] - 2026-06-04

### Added
- Offsite-backup proxy check: compares atime vs mtime on the latest backup to flag whether it appears to have been copied offsite. Skipped on `noatime` mounts. Suggested by [@ed_s on Discourse Meta](https://meta.discourse.org/u/ed_s).

## [1.0.1] - 2026-06-03

### Fixed
- Web server check now looks for Unicorn (Discourse's actual web server) instead of Puma. The previous loose `pgrep -f puma` was producing false positives.

## [1.0.0] - 2026-06-03

### Added
- Initial release.
- System checks: uptime, load, RAM, swap, disk, inodes.
- Network checks: TCP connection counts, local HTTP response.
- Docker engine checks: version, container status, restart count, resource usage.
- Discourse service checks (inside container): PostgreSQL, Redis, Nginx, Puma, Sidekiq.
- Reports Discourse version and uploads directory size.
- Backup freshness check with 7-day warning / 14-day critical thresholds.
- Live TLS check via `openssl s_client` against `hostname:443`.
- On-disk certificate inspection with stale-file detection when live TLS is fine.
- Security checks: pending OS updates, failed SSH attempts (24h), firewall, fail2ban.
- Pass / warning / critical summary scorecard.
- Exit codes (0 / 1 / 2) for use in cron and alerting.
- `--container`, `--no-ssl-check`, `--no-color`, `--help` options.
