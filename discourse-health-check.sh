#!/usr/bin/env bash
#
# discourse-health-check.sh
#
# One-shot health overview for a Discourse forum server.
# Checks system resources, Docker, all Discourse services,
# backups, SSL/TLS, and security basics.
#
# Usage:  sudo ./discourse-health-check.sh [options]
#
# Options:
#   --container NAME    Discourse container name (default: app)
#   --no-ssl-check      Skip live TLS check (useful behind CDN/proxy)
#   --no-color          Disable ANSI colors
#   -h, --help          Show this help
#
# Project: https://github.com/haydenjames/discourse-health-check
# License: MIT
#

set -euo pipefail

# ── Defaults / options ───────────────────────────────────
USE_COLOR=true
CONTAINER_NAME="app"
SKIP_SSL_LIVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)    CONTAINER_NAME="${2:-app}"; shift 2 ;;
        --no-color)     USE_COLOR=false; shift ;;
        --no-ssl-check) SKIP_SSL_LIVE=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Colors & formatting ─────────────────────────────────
if $USE_COLOR && [[ -t 1 ]]; then
    R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' B='\033[0;34m'
    C='\033[0;36m' W='\033[1;37m' D='\033[0;90m' N='\033[0m'
    BLD='\033[1m'
else
    R='' G='' Y='' B='' C='' W='' D='' N='' BLD=''
fi

# ── Counters ─────────────────────────────────────────────
PASS=0; WARN=0; CRIT=0

section() { echo -e "\n${B}━━━ ${W}$1${N}"; }
ok()      { PASS=$((PASS + 1)); echo -e "  ${G}✔${N} $1"; }
warn()    { WARN=$((WARN + 1)); echo -e "  ${Y}⚠${N} $1"; }
crit()    { CRIT=$((CRIT + 1)); echo -e "  ${R}✖${N} $1"; }
info()    { echo -e "  ${C}·${N} $1"; }

# ── Root check ───────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${R}Error:${N} This script must be run as root (sudo)." >&2
    exit 1
fi

# ── Detect Discourse install path ────────────────────────
DISCOURSE_DIR=""
for d in /var/discourse /opt/discourse "$HOME/discourse" /srv/discourse; do
    [[ -f "$d/launcher" ]] && DISCOURSE_DIR="$d" && break
done

# ── Helpers ──────────────────────────────────────────────
in_container() {
    docker exec "$CONTAINER_NAME" bash -c "$1" 2>/dev/null
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "$CONTAINER_NAME"
}

# ═════════════════════════════════════════════════════════
#  HEADER
# ═════════════════════════════════════════════════════════
clear 2>/dev/null || true
echo ""
echo -e "${W}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${W}║${N}  ${BLD}Discourse Server Health Check${N}                           ${W}║${N}"
echo -e "${W}╚══════════════════════════════════════════════════════════╝${N}"
echo -e "  ${D}Host:${N} $(hostname)    ${D}Date:${N} $(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ -n "$DISCOURSE_DIR" ]]; then
    echo -e "  ${D}Discourse path:${N} ${DISCOURSE_DIR}    ${D}Container:${N} ${CONTAINER_NAME}"
else
    echo -e "  ${Y}Discourse install not found (checked /var/discourse, /opt/discourse, ~/discourse, /srv/discourse)${N}"
fi
echo ""

# ═════════════════════════════════════════════════════════
section "SYSTEM UPTIME & LOAD"
# ═════════════════════════════════════════════════════════
info "Uptime: $(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*load.*//')"

cores=$(nproc)
read -r load1 load5 load15 _ < /proc/loadavg
info "Load average: ${load1} / ${load5} / ${load15}  (${cores} CPU cores)"

load_pct=$(awk "BEGIN {printf \"%.0f\", (${load1}/${cores})*100}")
if   (( load_pct < 70 )); then ok   "CPU load: ${load_pct}% of capacity"
elif (( load_pct < 90 )); then warn "CPU load: ${load_pct}% of capacity"
else                            crit "CPU load: ${load_pct}% of capacity"
fi

# ═════════════════════════════════════════════════════════
section "MEMORY"
# ═════════════════════════════════════════════════════════
read -r total used avail <<< "$(free -m | awk '/^Mem:/ {print $2, $3, $7}')"
mem_pct=$(( used * 100 / total ))
info "RAM: ${used}MB used / ${total}MB total / ${avail}MB available"

if   (( mem_pct < 75 )); then ok   "Memory utilization: ${mem_pct}%"
elif (( mem_pct < 90 )); then warn "Memory utilization: ${mem_pct}%"
else                           crit "Memory utilization: ${mem_pct}%"
fi

swap_total=$(free -m | awk '/^Swap:/ {print $2}')
swap_used=$(free -m | awk '/^Swap:/ {print $3}')
if (( swap_total > 0 )); then
    swap_pct=$(( swap_used * 100 / swap_total ))
    if   (( swap_pct < 20 )); then ok   "Swap: ${swap_used}MB / ${swap_total}MB (${swap_pct}%)"
    elif (( swap_pct < 50 )); then warn "Swap: ${swap_used}MB / ${swap_total}MB (${swap_pct}%)"
    else                           crit "Swap: ${swap_used}MB / ${swap_total}MB (${swap_pct}%)"
    fi
else
    warn "No swap space configured"
fi

# ═════════════════════════════════════════════════════════
section "DISK"
# ═════════════════════════════════════════════════════════
while IFS= read -r line; do
    fs=$(awk '{print $1}' <<< "$line")
    size=$(awk '{print $2}' <<< "$line")
    used_d=$(awk '{print $3}' <<< "$line")
    avail_d=$(awk '{print $4}' <<< "$line")
    pct=$(awk '{print $5}' <<< "$line" | tr -d '%')
    mount=$(awk '{print $6}' <<< "$line")

    label="${mount}  ${used_d} / ${size}  (${avail_d} free)"
    if   (( pct < 75 )); then ok   "${label}  —  ${pct}%"
    elif (( pct < 90 )); then warn "${label}  —  ${pct}%"
    else                       crit "${label}  —  ${pct}%"
    fi
done < <(df -h --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | tail -n +2)

inode_issues=0
while IFS= read -r line; do
    pct=$(awk '{print $5}' <<< "$line" | tr -d '%')
    mount=$(awk '{print $6}' <<< "$line")
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    if (( pct > 80 )); then
        warn "Inode usage on ${mount}: ${pct}%"
        inode_issues=1
    fi
done < <(df -i --output=source,size,used,avail,pcent,target -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | tail -n +2)
(( inode_issues == 0 )) && ok "Inode usage healthy on all mounts"

# ═════════════════════════════════════════════════════════
section "NETWORK"
# ═════════════════════════════════════════════════════════
if command -v ss &>/dev/null; then
    estab=$(ss -t state established 2>/dev/null | tail -n +2 | wc -l)
    tw=$(ss -t state time-wait 2>/dev/null | wc -l)
    info "TCP connections — established: ${estab}  time-wait: ${tw}"
fi

http_status=""
for url in http://localhost https://localhost; do
    resp=$(curl -sI --max-time 5 -k "$url" 2>/dev/null | head -1 | tr -d '\r')
    if [[ -n "$resp" ]]; then
        http_status="$resp"
        break
    fi
done
if [[ -n "$http_status" ]]; then
    if [[ "$http_status" == *"200"* || "$http_status" == *"301"* || "$http_status" == *"302"* ]]; then
        ok "Local HTTP response: ${http_status}"
    else
        warn "Local HTTP response: ${http_status}"
    fi
else
    warn "No HTTP response on localhost"
fi

# ═════════════════════════════════════════════════════════
section "DOCKER ENGINE"
# ═════════════════════════════════════════════════════════
if ! command -v docker &>/dev/null; then
    crit "Docker is not installed"
else
    docker_ver=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    info "Docker version: ${docker_ver}"

    if container_running; then
        ok "Container '${CONTAINER_NAME}' is running"

        started=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null \
                  | cut -dT -f1,2 | tr T ' ' | cut -d. -f1)
        info "Container started: ${started}"

        restarts=$(docker inspect --format '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo "?")
        if [[ "$restarts" == "0" ]]; then ok "Zero container restarts"
        else                               warn "Container restart count: ${restarts}"
        fi

        read -r cpu mem <<< "$(docker stats "$CONTAINER_NAME" --no-stream --format '{{.CPUPerc}} {{.MemPerc}}' 2>/dev/null || echo '? ?')"
        info "Container resource usage — CPU: ${cpu}   Memory: ${mem}"
    else
        crit "Container '${CONTAINER_NAME}' is NOT running"
        docker ps -a --filter "name=${CONTAINER_NAME}" --format '  Status: {{.Status}}' 2>/dev/null
    fi

    docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
    docker_size=$(du -sh "$docker_root" 2>/dev/null | awk '{print $1}')
    info "Docker storage (${docker_root}): ${docker_size}"
fi

# ═════════════════════════════════════════════════════════
section "DISCOURSE SERVICES"
# ═════════════════════════════════════════════════════════
if container_running; then

    # ── PostgreSQL ───────────────────────────────────────
    if [[ "$(in_container 'pg_isready -q && echo ok')" == "ok" ]]; then
        ok "PostgreSQL is accepting connections"
        pg_size=$(in_container "sudo -u postgres psql -At -c \"SELECT pg_size_pretty(pg_database_size('discourse'));\"" || echo "?")
        pg_conns=$(in_container "sudo -u postgres psql -At -c \"SELECT count(*) FROM pg_stat_activity;\"" || echo "?")
        pg_max=$(in_container "sudo -u postgres psql -At -c \"SHOW max_connections;\"" || echo "?")
        info "Database size: ${pg_size}"
        info "Connections: ${pg_conns} active / ${pg_max} max"
        if [[ "$pg_conns" =~ ^[0-9]+$ ]] && [[ "$pg_max" =~ ^[0-9]+$ ]] && (( pg_conns * 100 / pg_max > 80 )); then
            warn "Connection pool above 80% — consider tuning max_connections"
        fi
    else
        crit "PostgreSQL is NOT responding"
    fi

    # ── Redis ────────────────────────────────────────────
    redis_ping=$(in_container "redis-cli ping" || echo "fail")
    if [[ "$redis_ping" == "PONG" ]]; then
        ok "Redis is responding"
        redis_mem=$(in_container "redis-cli info memory 2>/dev/null | grep used_memory_human | cut -d: -f2" | tr -d '\r\n ' || echo "?")
        redis_keys=$(in_container "redis-cli info keyspace 2>/dev/null | grep '^db0' | cut -d= -f2 | cut -d, -f1" | tr -d '\r\n ' || echo "?")
        [[ -z "$redis_keys" ]] && redis_keys="0"
        info "Redis memory: ${redis_mem}   keys: ${redis_keys}"
    else
        crit "Redis is NOT responding"
    fi

    # ── Nginx ────────────────────────────────────────────
    if [[ "$(in_container 'pgrep -x nginx >/dev/null && echo ok')" == "ok" ]]; then
        ok "Nginx is running"
    else
        crit "Nginx is NOT running"
    fi

    # ── Puma (web server) ────────────────────────────────
    if [[ "$(in_container 'pgrep -f puma >/dev/null && echo ok')" == "ok" ]]; then
        ok "Puma (web) is running"
        workers=$(in_container "pgrep -c -f 'puma.*cluster worker' || echo 0" | tr -d '\r')
        info "Puma workers: ${workers}"
    else
        crit "Puma (web) is NOT running"
    fi

    # ── Sidekiq (background jobs) ────────────────────────
    if [[ "$(in_container 'pgrep -f sidekiq >/dev/null && echo ok')" == "ok" ]]; then
        ok "Sidekiq is running"
        enqueued=$(in_container "redis-cli llen queue:default" | tr -d '\r' || echo "?")
        retries=$(in_container "redis-cli zcard retry" | tr -d '\r' || echo "?")
        scheduled=$(in_container "redis-cli zcard schedule" | tr -d '\r' || echo "?")
        info "Jobs — queued: ${enqueued}   retries: ${retries}   scheduled: ${scheduled}"
        if [[ "$retries" =~ ^[0-9]+$ ]] && (( retries > 100 )); then
            warn "Sidekiq retry queue has ${retries} jobs — check /sidekiq in admin"
        fi
    else
        crit "Sidekiq is NOT running"
    fi

    # ── Discourse version ────────────────────────────────
    disc_ver=$(in_container "grep -oP '\"\\K[0-9][^\"]+' /var/www/discourse/lib/version.rb 2>/dev/null || grep -oP \"'\\K[0-9][^']+\" /var/www/discourse/lib/version.rb 2>/dev/null" | tr -d '\r' | head -1)
    [[ -z "$disc_ver" ]] && disc_ver="?"
    info "Discourse version: ${disc_ver}"

    # ── Uploads ──────────────────────────────────────────
    uploads_size=$(in_container "du -sh /var/www/discourse/public/uploads/ 2>/dev/null" | awk '{print $1}' | tr -d '\r')
    [[ -z "$uploads_size" || "$uploads_size" == "0" ]] && uploads_size=$(in_container "du -sh /shared/uploads/ 2>/dev/null" | awk '{print $1}' | tr -d '\r')
    info "Uploads directory: ${uploads_size:-unknown}"

else
    warn "Container '${CONTAINER_NAME}' not running — skipping service checks"
fi

# ═════════════════════════════════════════════════════════
section "BACKUPS"
# ═════════════════════════════════════════════════════════
backup_found=false
for bdir in \
    /var/discourse/shared/standalone/backups/default \
    /var/discourse/shared/standalone/backups \
    /opt/discourse/shared/standalone/backups/default \
    /opt/discourse/shared/standalone/backups; do

    [[ -d "$bdir" ]] || continue
    latest=$(find "$bdir" -name "*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
    [[ -z "$latest" ]] && continue

    backup_found=true
    backup_date=$(stat -c %y "$latest" 2>/dev/null | cut -d' ' -f1)
    backup_size=$(du -sh "$latest" 2>/dev/null | awk '{print $1}')
    days_ago=$(( ($(date +%s) - $(stat -c %Y "$latest")) / 86400 ))
    backup_count=$(find "$bdir" -name "*.tar.gz" -type f 2>/dev/null | wc -l)

    if   (( days_ago <= 7 ));  then ok   "Latest backup: ${backup_date} (${days_ago}d ago, ${backup_size})"
    elif (( days_ago <= 14 )); then warn "Latest backup: ${backup_date} (${days_ago}d ago, ${backup_size})"
    else                            crit "Latest backup: ${backup_date} (${days_ago}d ago, ${backup_size})"
    fi
    info "Backup count: ${backup_count} files in ${bdir}"
    break
done
$backup_found || warn "No backup files found"

# ═════════════════════════════════════════════════════════
section "SSL / TLS CERTIFICATE"
# ═════════════════════════════════════════════════════════
live_cert_ok=false

if $SKIP_SSL_LIVE; then
    info "Live TLS check skipped (--no-ssl-check)"
else
    live_host=$(hostname -f 2>/dev/null || hostname)
    live_expiry=$(echo | openssl s_client -servername "$live_host" -connect "$live_host:443" 2>/dev/null \
                  | openssl x509 -noout -enddate -subject 2>/dev/null)
    if [[ -n "$live_expiry" ]]; then
        live_cn=$(echo "$live_expiry" | grep subject | sed 's/subject=.*CN *= *//')
        live_date=$(echo "$live_expiry" | grep notAfter | cut -d= -f2)
        live_epoch=$(date -d "$live_date" +%s 2>/dev/null)
        live_days=$(( (live_epoch - $(date +%s)) / 86400 ))
        info "Live cert served to visitors (${live_cn})"
        if   (( live_days > 30 )); then ok   "TLS valid for ${live_days} more days (expires ${live_date})"
                                        live_cert_ok=true
        elif (( live_days > 7 ));  then warn "TLS expires in ${live_days} days (${live_date})"
        elif (( live_days > 0 ));  then crit "TLS expires in ${live_days} days! (${live_date})"
        else                            crit "Live TLS certificate is EXPIRED"
        fi
    else
        info "Could not connect to ${live_host}:443 for live TLS check"
    fi
fi

# On-disk cert files
for cert_path in \
    /var/discourse/shared/standalone/letsencrypt/*/fullchain.pem \
    /var/discourse/shared/standalone/ssl/*.pem \
    /var/discourse/shared/standalone/ssl/*.crt \
    /var/discourse/shared/standalone/ssl/*.cer \
    /opt/discourse/shared/standalone/letsencrypt/*/fullchain.pem \
    /etc/letsencrypt/live/*/fullchain.pem; do

    # shellcheck disable=SC2086
    cert_file=$(ls -1t $cert_path 2>/dev/null | head -1) || continue
    [[ -z "$cert_file" ]] && continue

    expiry_raw=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    [[ -z "$expiry_raw" ]] && continue

    subject=$(openssl x509 -subject -noout -in "$cert_file" 2>/dev/null | sed 's/subject=//')
    expiry_epoch=$(date -d "$expiry_raw" +%s 2>/dev/null)
    days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))

    if $live_cert_ok; then
        if (( days_left <= 0 )); then
            warn "Stale cert on disk (${subject}) — expired, consider removing"
        fi
    else
        info "On-disk cert: ${subject}"
        if   (( days_left > 30 )); then ok   "On-disk cert expires: ${expiry_raw} (${days_left} days)"
        elif (( days_left > 7 ));  then warn "On-disk cert expires: ${expiry_raw} (${days_left} days)"
        elif (( days_left > 0 ));  then crit "On-disk cert expires: ${expiry_raw} (${days_left} days!)"
        else                            crit "On-disk cert EXPIRED ${expiry_raw}"
        fi
    fi
    break
done

# ═════════════════════════════════════════════════════════
section "SECURITY"
# ═════════════════════════════════════════════════════════

# OS updates
if command -v apt-get &>/dev/null; then
    upgradable=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
    security=$(apt list --upgradable 2>/dev/null | grep -c "\-security" || true)
    if (( upgradable == 0 )); then
        ok "All system packages up to date"
    elif (( security > 0 )); then
        warn "${upgradable} updates pending (${security} security)"
    else
        info "${upgradable} updates pending (0 security)"
    fi
elif command -v dnf &>/dev/null; then
    upgradable=$(dnf check-update --quiet 2>/dev/null | grep -c "^[a-zA-Z]" || true)
    info "${upgradable} package updates available"
fi

# Failed SSH (last 24h)
failed_ssh=0
ssh_src="last 24h"
if command -v journalctl &>/dev/null; then
    failed_ssh=$(journalctl --since "24 hours ago" --no-pager -q 2>/dev/null \
                 | grep -c "Failed password" || echo "0")
elif [[ -f /var/log/auth.log ]]; then
    cutoff=$(date -d "24 hours ago" '+%s')
    while IFS= read -r line; do
        ts=$(echo "$line" | awk '{print $1, $2, $3}')
        ts_epoch=$(date -d "$ts" '+%s' 2>/dev/null) || continue
        if (( ts_epoch >= cutoff )); then
            failed_ssh=$((failed_ssh + 1))
        fi
    done < <(grep "Failed password" /var/log/auth.log 2>/dev/null | tail -2000)
fi
if [[ "$failed_ssh" =~ ^[0-9]+$ ]]; then
    if   (( failed_ssh < 100 ));  then info "Failed SSH attempts (${ssh_src}): ${failed_ssh}"
    elif (( failed_ssh < 500 ));  then warn "Failed SSH attempts (${ssh_src}): ${failed_ssh}"
    else                                crit "Failed SSH attempts (${ssh_src}): ${failed_ssh}"
    fi
fi

# Firewall
fw_active=false
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ok "UFW firewall is active"
    fw_active=true
elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
    ok "firewalld is active"
    fw_active=true
elif iptables -L -n 2>/dev/null | grep -qE "DROP|REJECT"; then
    ok "iptables rules with DROP/REJECT detected"
    fw_active=true
fi
$fw_active || warn "No active firewall detected"

# Fail2ban
if command -v fail2ban-client &>/dev/null; then
    if fail2ban-client status &>/dev/null; then
        jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g' | xargs)
        ok "Fail2ban is running — jails: ${jails}"
    else
        warn "Fail2ban installed but not running"
    fi
fi

# ═════════════════════════════════════════════════════════
#  SUMMARY
# ═════════════════════════════════════════════════════════
total=$((PASS + WARN + CRIT))
echo ""
echo -e "${D}$(printf '═%.0s' {1..60})${N}"
echo ""
echo -e "  ${BLD}Summary${N}    ${G}${PASS} passed${N}   ${Y}${WARN} warnings${N}   ${R}${CRIT} critical${N}   (${total} checks)"
echo ""

if (( CRIT > 0 )); then
    echo -e "  ${R}▸ Critical issues found — review items marked ✖ above${N}"
    exit_code=2
elif (( WARN > 0 )); then
    echo -e "  ${Y}▸ Warnings found — review items marked ⚠ above${N}"
    exit_code=1
else
    echo -e "  ${G}▸ All checks passed — server looks healthy${N}"
    exit_code=0
fi

echo -e "\n${D}$(printf '═%.0s' {1..60})${N}\n"
exit $exit_code
