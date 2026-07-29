# Changelog

All notable changes to this project will be documented in this file.

## [1.0.4] - 2026-07-29

### Fixed
- Web server check no longer matches its own `docker exec` wrapper. `pgrep -f unicorn` was run inside a shell whose command line contained the word "unicorn", so pgrep matched itself and the check passed whether or not the web server was actually running — the same root cause as the Puma false positive in 1.0.1, which was renamed rather than fixed. Patterns now bracket their first character (`[u]nicorn`) so only real processes match.
- Web server check now detects Pitchfork as well as Unicorn. Discourse made Pitchfork the default in 2026.2 and removed Unicorn entirely in 2026.4. Pitchfork is matched first, since `config/unicorn_launcher` was kept for the Docker images and can still match a bare "unicorn" pattern on a Pitchfork install.

### Added
- Web server worker count is now validated — a running master with zero workers is reported as critical instead of passing silently.
- PostgreSQL major version is reported, and flagged as critical below 15 (the minimum required from Discourse 2026.5 onwards).

## [1.0.3] - 2026-06-04

### Changed
- Network section now interprets the HTTP → HTTPS redirect instead of showing the raw `301 Moved Permanently` status line, which read as a problem. Now shows "HTTP → HTTPS redirect working" when port 80 redirects to an `https://` location, or warns if port 80 returns 200 (HTTPS not enforced).

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
