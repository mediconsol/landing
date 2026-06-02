#!/bin/bash
# Collect server status and write to status.json
# Run via cron: * * * * * /Users/mcs/deploy/landing/collect-status.sh

# cron's default PATH lacks /usr/sbin (where sysctl lives) — force a full PATH
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin

OUT="/Users/mcs/deploy/landing/status.json"

# CPU - abort if sysctl unavailable rather than emit bogus defaults
cpu_cores=$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null)
if [ -z "$cpu_cores" ] || [ "$cpu_cores" -lt 1 ] 2>/dev/null; then
  echo "[$(date)] collect-status: sysctl hw.logicalcpu unavailable, aborting" >&2
  exit 1
fi
cpu_used=$(ps -A -o %cpu 2>/dev/null | tail -n +2 | awk -v cores="$cpu_cores" '{s+=$1} END {printf "%.0f", s/cores}')
cpu_used=${cpu_used:-0}

# Memory - abort on failure rather than writing 0 (causes Infinity% in UI)
total_mem_bytes=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null)
if [ -z "$total_mem_bytes" ] || [ "$total_mem_bytes" -lt 1 ] 2>/dev/null; then
  echo "[$(date)] collect-status: sysctl hw.memsize unavailable, aborting" >&2
  exit 1
fi
total_mem_mb=$(awk -v b="$total_mem_bytes" 'BEGIN{printf "%d", b/1024/1024}')
page_size=$(/usr/bin/vm_stat | head -1 | grep -o '[0-9]*')
page_size=${page_size:-4096}
pages_active=$(/usr/bin/vm_stat | awk '/Pages active/ {gsub(/\./,"",$3); print $3+0}')
pages_wired=$(/usr/bin/vm_stat | awk '/Pages wired/ {gsub(/\./,"",$4); print $4+0}')
pages_compressed=$(/usr/bin/vm_stat | awk '/Pages occupied by compressor/ {gsub(/\./,"",$5); print $5+0}')
used_mem_mb=$(( (pages_active + pages_wired + pages_compressed) * page_size / 1024 / 1024 ))

# Disk — / is the read-only OS partition (always near-empty on APFS).
# /System/Volumes/Data is the real user-data partition that fills up.
read_disk() {
  local mount=$1
  /bin/df -g "$mount" | tail -1 | awk '{gsub(/%/,"",$5); print $2, $3, $5}'
}
read os_total os_used os_pct <<<"$(read_disk /)"
read data_total data_used data_pct <<<"$(read_disk /System/Volumes/Data)"
disk_total=${os_total:-0}
disk_used=${os_used:-0}
disk_pct=${os_pct:-0}
data_disk_total=${data_total:-0}
data_disk_used=${data_used:-0}
data_disk_pct=${data_pct:-0}

# Uptime & Load - parse from uptime command (works in all environments)
uptime_out=$(uptime)
if echo "$uptime_out" | grep -q 'days'; then
  up_days=$(echo "$uptime_out" | sed 's/.*up \([0-9]*\) days.*/\1/')
  up_hours=$(echo "$uptime_out" | awk -F'days,' '{print $2}' | awk -F':' '{printf "%d", $1+0}')
else
  up_days=0
  up_hours=$(echo "$uptime_out" | awk -F'up ' '{print $2}' | awk -F':' '{printf "%d", $1+0}')
fi
up_days=${up_days:-0}
up_hours=${up_hours:-0}
load1=$(echo "$uptime_out" | awk -F'load averages: ' '{print $2}' | awk '{print $1}'); load1=${load1:-0}
load5=$(echo "$uptime_out" | awk -F'load averages: ' '{print $2}' | awk '{print $2}'); load5=${load5:-0}
load15=$(echo "$uptime_out" | awk -F'load averages: ' '{print $2}' | awk '{print $3}'); load15=${load15:-0}

# Docker
DOCKER=/usr/local/bin/docker
docker_running=$($DOCKER ps -q 2>/dev/null | wc -l | tr -d ' '); docker_running=${docker_running:-0}
docker_stopped=$($DOCKER ps -q -f status=exited 2>/dev/null | wc -l | tr -d ' '); docker_stopped=${docker_stopped:-0}
docker_total=$((docker_running + docker_stopped))

# Services
services="["
first=true
while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  status=$(echo "$line" | awk '{print $2}')
  mem=$(echo "$line" | awk '{print $3}')
  if [ "$first" = true ]; then first=false; else services+=","; fi
  services+="{\"name\":\"$name\",\"status\":\"$status\",\"mem\":\"$mem\"}"
done < <($DOCKER ps -a --format "{{.Names}} {{.State}} {{.Size}}" 2>/dev/null | head -30)
services+="]"

# Network checks
check_url() {
  local url=$1
  local start=$(python3 -c "import time; print(int(time.time()*1000))")
  local code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
  local end=$(python3 -c "import time; print(int(time.time()*1000))")
  local ms=$((end - start))
  code=$((10#$code))
  echo "{\"url\":\"$url\",\"code\":$code,\"ms\":$ms}"
}

net_80=$(check_url "http://localhost:80")
net_5510=$(check_url "http://localhost:5510/api/v1/health")
net_5511=$(check_url "http://localhost:5511")
net_5520=$(check_url "http://localhost:5520")

timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$OUT" << ENDJSON
{
  "timestamp": "$timestamp",
  "cpu": {"used": $cpu_used, "cores": $cpu_cores},
  "memory": {"total_mb": $total_mem_mb, "used_mb": $used_mem_mb},
  "disk": {"total_gb": $disk_total, "used_gb": $disk_used, "percent": $disk_pct},
  "data_disk": {"total_gb": $data_disk_total, "used_gb": $data_disk_used, "percent": $data_disk_pct},
  "swap": {"total_mb": 0, "used_mb": 0},
  "uptime": {"days": $up_days, "hours": $up_hours, "load": [$load1, $load5, $load15]},
  "docker": {"running": $docker_running, "stopped": $docker_stopped, "total": $docker_total},
  "network": [$net_80, $net_5510, $net_5511, $net_5520],
  "services": $services
}
ENDJSON
