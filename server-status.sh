#!/bin/bash
# =============================================================================
# MediCertWizard - 서버 상태 수집 → JSON 생성
# =============================================================================
# Cron: * * * * * /bin/bash /data/projects/landing/server-status.sh
# Output: /data/projects/landing/status.json (nginx가 서빙)
# =============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

OUTPUT="/data/projects/landing/status.json"
TMP="${OUTPUT}.tmp"

# CPU usage (from /proc/stat, instant snapshot)
read -r cpu user nice system idle iowait irq softirq _ < /proc/stat
TOTAL1=$((user + nice + system + idle + iowait + irq + softirq))
IDLE1=$idle
sleep 1
read -r cpu user nice system idle iowait irq softirq _ < /proc/stat
TOTAL2=$((user + nice + system + idle + iowait + irq + softirq))
IDLE2=$idle
DIFF_TOTAL=$((TOTAL2 - TOTAL1))
DIFF_IDLE=$((IDLE2 - IDLE1))
if [ "$DIFF_TOTAL" -gt 0 ]; then
  CPU_USED=$(( (DIFF_TOTAL - DIFF_IDLE) * 100 / DIFF_TOTAL ))
else
  CPU_USED=0
fi

# Memory (from /proc/meminfo — works in cron)
MEM_TOTAL=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
MEM_AVAILABLE=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)
MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))
SWAP_TOTAL=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
SWAP_FREE=$(awk '/^SwapFree:/ {printf "%d", $2/1024}' /proc/meminfo)
SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))

# Disk - root (/)
DISK_TOTAL=$(df -BG / | awk 'NR==2 {gsub("G",""); print $2}')
DISK_USED=$(df -BG / | awk 'NR==2 {gsub("G",""); print $3}')
DISK_AVAIL=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
DISK_PERCENT=$(df / | awk 'NR==2 {gsub("%",""); print $5}')

# Disk - data (/data)
DATA_TOTAL=$(df -BG /data | awk 'NR==2 {gsub("G",""); print $2}')
DATA_USED=$(df -BG /data | awk 'NR==2 {gsub("G",""); print $3}')
DATA_AVAIL=$(df -BG /data | awk 'NR==2 {gsub("G",""); print $4}')
DATA_PERCENT=$(df /data | awk 'NR==2 {gsub("%",""); print $5}')

# Uptime
UPTIME_SECONDS=$(cut -d. -f1 /proc/uptime)
UPTIME_DAYS=$((UPTIME_SECONDS / 86400))
UPTIME_HOURS=$(( (UPTIME_SECONDS % 86400) / 3600 ))
LOAD_1=$(awk '{print $1}' /proc/loadavg)
LOAD_5=$(awk '{print $2}' /proc/loadavg)
LOAD_15=$(awk '{print $3}' /proc/loadavg)

# Network speed (enp2s0 — 1초 샘플링)
NET_IFACE=$(cat /proc/net/dev | grep -v 'lo\|docker\|br-\|veth\|Inter\|face' | awk -F: '{print $1}' | xargs | awk '{print $1}')
if [ -n "$NET_IFACE" ]; then
  NET1=$(grep "${NET_IFACE}:" /proc/net/dev | awk '{print $2, $10}')
  sleep 1
  NET2=$(grep "${NET_IFACE}:" /proc/net/dev | awk '{print $2, $10}')
  RX1=$(echo $NET1 | awk '{print $1}')
  TX1=$(echo $NET1 | awk '{print $2}')
  RX2=$(echo $NET2 | awk '{print $1}')
  TX2=$(echo $NET2 | awk '{print $2}')
  RX_BPS=$(( (RX2 - RX1) ))
  TX_BPS=$(( (TX2 - TX1) ))
  NET_SPEED_JSON="{\"iface\":\"$NET_IFACE\",\"rx_bps\":$RX_BPS,\"tx_bps\":$TX_BPS}"
else
  NET_SPEED_JSON="null"
fi

# GPU (nvidia-smi)
GPU_JSON="null"
if command -v nvidia-smi &>/dev/null; then
  GPU_RAW=$(nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,power.limit --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [ -n "$GPU_RAW" ]; then
    IFS=',' read -r GPU_NAME GPU_TEMP GPU_UTIL GPU_MEM_USED GPU_MEM_TOTAL GPU_POWER GPU_POWER_LIMIT <<< "$GPU_RAW"
    GPU_NAME=$(echo "$GPU_NAME" | xargs)
    GPU_TEMP=$(echo "$GPU_TEMP" | xargs)
    GPU_UTIL=$(echo "$GPU_UTIL" | xargs)
    GPU_MEM_USED=$(echo "$GPU_MEM_USED" | xargs)
    GPU_MEM_TOTAL=$(echo "$GPU_MEM_TOTAL" | xargs)
    GPU_POWER=$(printf "%.0f" "$(echo "$GPU_POWER" | xargs)" 2>/dev/null || echo "0")
    GPU_POWER_LIMIT=$(printf "%.0f" "$(echo "$GPU_POWER_LIMIT" | xargs)" 2>/dev/null || echo "0")
    GPU_JSON="{\"name\":\"$GPU_NAME\",\"temp\":$GPU_TEMP,\"util\":$GPU_UTIL,\"mem_used\":$GPU_MEM_USED,\"mem_total\":$GPU_MEM_TOTAL,\"power\":$GPU_POWER,\"power_limit\":$GPU_POWER_LIMIT}"
  fi
fi

# Docker containers
RUNNING=$(docker ps -q 2>/dev/null | wc -l)
STOPPED=$(docker ps -aq --filter 'status=exited' 2>/dev/null | wc -l)
TOTAL=$((RUNNING + STOPPED))

# Per-service status (batch docker stats for speed)
declare -A STATS_MEM STATS_CPU
while IFS=$'\t' read -r name cpu mem; do
  STATS_CPU["$name"]="$cpu"
  STATS_MEM["$name"]="$mem"
done < <(docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | sed 's/%//g' | awk -F'\t' '{split($3,a," / "); print $1"\t"$2"\t"a[1]}')

SERVICES=(
  "medicertwizard-nginx-1"
  "medicertwizard-api-1"
  "medicertwizard-frontend-1"
  "medicertwizard-postgres-1"
  "medicertwizard-redis-1"
  "medicertwizard-worker-1"
  "medicertwizard-minio-1"
  "medicertwizard-libreoffice-1"
  "howol-frontend"
  "howol-backend"
  "howol-postgres"
  "howol-redis"
  "howol-celery"
  "kimes-web"
  "kimes-api"
  "kimes-db"
  "rehab-app-1"
  "rehab-db-1"
  "rehab2"
  "mediedu-simple"
  "mediedu_simple-db-1"
  "edu2"
  "ai-practice"
  "tidewave"
  "intranet"
  "intranet-db"
  "books-hub"
  "landing"
  "cloudflared"
  "nginx-proxy-manager"
  "portainer"
  "mediconsol-frontend"
  "mediconsol-backend"
  "mediconsol-db"
  "supabase-kong"
  "supabase-db"
  "ollama"
  "code-server"
)

SERVICES_JSON=""
for i in "${!SERVICES[@]}"; do
  name="${SERVICES[$i]}"
  status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)
  status=$(echo "$status" | tr -d '\n')
  [ -z "$status" ] && status="not_found"
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)
  health=$(echo "$health" | tr -d '\n')
  [ -z "$health" ] && health="none"
  mem="${STATS_MEM[$name]:-0B}"
  cpu="${STATS_CPU[$name]:-0.00}"

  [ $i -gt 0 ] && SERVICES_JSON="$SERVICES_JSON,"
  SERVICES_JSON="$SERVICES_JSON{\"name\":\"$name\",\"status\":\"$status\",\"health\":\"$health\",\"mem\":\"$mem\",\"cpu\":\"$cpu\"}"
done

# Network checks
check_endpoint() {
  local url="$1"
  local start end ms code
  start=$(date +%s%N)
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$url" 2>/dev/null)
  code=${code:-0}
  # Ensure code is a valid integer
  code=$(echo "$code" | grep -oE '^[0-9]+' | head -1)
  code=${code:-0}
  code=$((code))
  end=$(date +%s%N)
  ms=$(( (end - start) / 1000000 ))
  echo "{\"url\":\"$url\",\"code\":$code,\"ms\":$ms}"
}

NET_MCW=$(check_endpoint "http://127.0.0.1:8180/api/v1/health")
NET_LANDING=$(check_endpoint "http://127.0.0.1:80/")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$TMP" << ENDJSON
{
  "timestamp": "$TIMESTAMP",
  "cpu": {
    "used": $CPU_USED,
    "cores": $(nproc)
  },
  "memory": {
    "total_mb": $MEM_TOTAL,
    "used_mb": $MEM_USED,
    "available_mb": $MEM_AVAILABLE
  },
  "swap": {
    "total_mb": $SWAP_TOTAL,
    "used_mb": $SWAP_USED
  },
  "disk": {
    "total_gb": $DISK_TOTAL,
    "used_gb": $DISK_USED,
    "avail_gb": $DISK_AVAIL,
    "percent": $DISK_PERCENT
  },
  "data_disk": {
    "total_gb": $DATA_TOTAL,
    "used_gb": $DATA_USED,
    "avail_gb": $DATA_AVAIL,
    "percent": $DATA_PERCENT
  },
  "uptime": {
    "days": $UPTIME_DAYS,
    "hours": $UPTIME_HOURS,
    "load": [$LOAD_1, $LOAD_5, $LOAD_15]
  },
  "docker": {
    "running": $RUNNING,
    "stopped": $STOPPED,
    "total": $TOTAL
  },
  "services": [$SERVICES_JSON],
  "gpu": $GPU_JSON,
  "net_speed": $NET_SPEED_JSON,
  "network": [$NET_MCW, $NET_LANDING]
}
ENDJSON

# Atomic write
cp "$TMP" "$OUTPUT" && rm -f "$TMP"
