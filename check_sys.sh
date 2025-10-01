#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
BOT_TOKEN="${BOT_TOKEN:-YOUR_TELEGRAM_BOT_TOKEN}"
CHAT_ID="${CHAT_ID:-YOUR_CHAT_ID}"
THRESHOLD="${THRESHOLD:-86}"
HOSTNAME="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S %z')"

send_tg () {
  local msg="$1"
  curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d parse_mode="Markdown" \
    --data-urlencode text="$msg" >/dev/null
}

# === CPU ===
read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
total1=$((user+nice+system+idle+iowait+irq+softirq+steal))
idle1=$idle
sleep 1
read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
total2=$((user+nice+system+idle+iowait+irq+softirq+steal))
idle2=$idle
total_delta=$((total2-total1))
idle_delta=$((idle2-idle1))
cpu_usage=$(( (100*(total_delta-idle_delta)) / (total_delta==0?1:total_delta) ))

# === MEM ===
mem_total_kb=$(grep -i '^MemTotal:' /proc/meminfo | awk '{print $2}')
mem_avail_kb=$(grep -i '^MemAvailable:' /proc/meminfo | awk '{print $2}')
mem_used_pct=$(( 100 - (100*mem_avail_kb / (mem_total_kb==0?1:mem_total_kb)) ))

# === Alert ===
msg="*ALERT:* High usage on \`${HOSTNAME}\`\n*Time:* ${NOW}\n"
alert=false

if (( cpu_usage >= THRESHOLD )); then
  msg+="- *CPU:* ${cpu_usage}%\n"
  alert=true
fi
if (( mem_used_pct >= THRESHOLD )); then
  used_gb=$(awk -v t="$mem_total_kb" -v a="$mem_avail_kb" 'BEGIN{printf "%.2f",(t-a)/1024/1024}')
  total_gb=$(awk -v t="$mem_total_kb" 'BEGIN{printf "%.2f",t/1024/1024}')
  msg+="- *Mem:* ${mem_used_pct}% (${used_gb}/${total_gb} GB)\n"
  alert=true
fi

if [[ "$alert" == true ]]; then
  send_tg "$msg"
fi
