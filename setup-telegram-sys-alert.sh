#!/usr/bin/env bash
# setup-telegram-sys-alert.sh
# Installs a lightweight CPU/Mem usage checker that alerts to Telegram via systemd timer.

set -euo pipefail

SERVICE_NAME="check-sys.service"
TIMER_NAME="check-sys.timer"
ENV_FILE="/etc/telegram-sys-alert.env"
BIN_PATH="/usr/local/bin/check_sys.sh"
UNIT_DIR="/etc/systemd/system"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_deps() {
  local miss=()
  for c in curl awk grep sed date hostname; do
    has_cmd "$c" || miss+=("$c")
  done
  if (( ${#miss[@]} )); then
    echo "Installing missing deps: ${miss[*]}"
    if has_cmd apt-get; then
      apt-get update -y && apt-get install -y "${miss[@]}"
    elif has_cmd dnf; then
      dnf install -y "${miss[@]}"
    elif has_cmd yum; then
      yum install -y "${miss[@]}"
    elif has_cmd apk; then
      apk add --no-cache "${miss[@]}"
    else
      echo "Please install: ${miss[*]} and re-run." >&2
      exit 1
    fi
  fi
}

write_bin() {
  install -d -m 0755 "$(dirname "$BIN_PATH")"
  cat > "$BIN_PATH" <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

# Read env file if provided by systemd service
if [[ -f "/etc/telegram-sys-alert.env" ]]; then
  # shellcheck disable=SC1091
  source /etc/telegram-sys-alert.env
fi

# === CONFIG (env-first with fallbacks) ===
BOT_TOKEN="${BOT_TOKEN:-YOUR_TELEGRAM_BOT_TOKEN}"
CHAT_ID="${CHAT_ID:-YOUR_CHAT_ID}"
THRESHOLD="${THRESHOLD:-86}"
HOSTNAME="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S %z')"

if [[ "$BOT_TOKEN" == "YOUR_TELEGRAM_BOT_TOKEN" || "$CHAT_ID" == "YOUR_CHAT_ID" ]]; then
  echo "BOT_TOKEN/CHAT_ID not set. Set in /etc/telegram-sys-alert.env" >&2
  exit 2
fi

send_tg () {
  local msg="$1"
  curl -sS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d parse_mode="Markdown" \
    --data-urlencode text="$msg" >/dev/null
}

# === CPU (1s window) ===
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

# === De-duplicate spam: cooldown ===
STATE_FILE="/tmp/.check_sys_last_alert"
COOLDOWN_SEC="${COOLDOWN_SEC:-900}" # default 15 minutes
now_epoch=$(date +%s)
last=0; [[ -f "$STATE_FILE" ]] && last=$(cat "$STATE_FILE" || echo 0)

msg="*ALERT:* High usage on \`${HOSTNAME}\`\n*Time:* ${NOW}\n"
alert=false

if (( cpu_usage >= THRESHOLD )); then
  msg+="- *CPU:* ${cpu_usage}% (>= ${THRESHOLD}%)\n"
  alert=true
fi
if (( mem_used_pct >= THRESHOLD )); then
  used_gb=$(awk -v t="$mem_total_kb" -v a="$mem_avail_kb" 'BEGIN{printf "%.2f",(t-a)/1024/1024)')
  total_gb=$(awk -v t="$mem_total_kb" 'BEGIN{printf "%.2f",t/1024/1024)')
  msg+="- *Mem:* ${mem_used_pct}% (${used_gb}/${total_gb} GB)\n"
  alert=true
fi

if [[ "$alert" == true ]]; then
  if (( now_epoch - last >= COOLDOWN_SEC )); then
    send_tg "$msg"
    echo "$now_epoch" > "$STATE_FILE"
  fi
fi
EOF
  chmod 0755 "$BIN_PATH"
  echo "Installed script: $BIN_PATH"
}

write_env() {
  if [[ -f "$ENV_FILE" ]]; then
    echo "Env file exists: $ENV_FILE (unchanged)"
    return
  fi
  echo "Creating $ENV_FILE"
  read -rp "Enter TELEGRAM BOT_TOKEN (from @BotFather): " BOT
  read -rp "Enter TELEGRAM CHAT_ID: " CHAT
  : "${BOT:=YOUR_TELEGRAM_BOT_TOKEN}"
  : "${CHAT:=YOUR_CHAT_ID}"
  cat > "$ENV_FILE" <<EOF
# /etc/telegram-sys-alert.env
BOT_TOKEN=$BOT
CHAT_ID=$CHAT
THRESHOLD=86        # Default threshold (%) for CPU/Mem
#COOLDOWN_SEC=900   # Optional: suppress repeated alerts for N seconds
EOF
  chmod 0640 "$ENV_FILE"
  echo "Wrote $ENV_FILE"
}

write_units() {
  cat > "${UNIT_DIR}/${SERVICE_NAME}" <<EOF
[Unit]
Description=Check CPU/Mem and notify Telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN_PATH}
Nice=10
IOSchedulingClass=best-effort
EOF

  cat > "${UNIT_DIR}/${TIMER_NAME}" <<EOF
[Unit]
Description=Run ${SERVICE_NAME} every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s
Unit=${SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "${UNIT_DIR}/${SERVICE_NAME}" "${UNIT_DIR}/${TIMER_NAME}"
  systemctl daemon-reload
  echo "Wrote unit files: ${SERVICE_NAME}, ${TIMER_NAME}"
}

enable_start() {
  systemctl enable --now "${TIMER_NAME}"
  echo "Enabled & started timer: ${TIMER_NAME}"
}

status() {
  systemctl status --no-pager "${TIMER_NAME}" || true
  echo "---- Last runs ----"
  journalctl -u "${SERVICE_NAME}" -n 10 --no-pager || true
}

test_run() {
  echo "Running one-off test (does NOT change timer)…"
  # For a guaranteed test alert, temporarily set THRESHOLD=0 for this run only:
  THRESHOLD=0 "${BIN_PATH}" || true
  echo "If BOT_TOKEN/CHAT_ID valid, you should receive a Telegram message."
}

uninstall_all() {
  echo "Stopping and disabling timer…"
  systemctl disable --now "${TIMER_NAME}" || true
  echo "Removing unit files…"
  rm -f "${UNIT_DIR}/${SERVICE_NAME}" "${UNIT_DIR}/${TIMER_NAME}"
  systemctl daemon-reload || true
  echo "Removing binary…"
  rm -f "${BIN_PATH}"
  echo "Keeping env file at ${ENV_FILE} (contains secrets). Remove manually if desired."
  echo "Uninstall complete."
}

usage() {
  cat <<USAGE
Usage: sudo $0 [--install|--status|--test|--uninstall]

  --install   Install script, env, systemd units; enable timer.
  --status    Show timer/service status and recent logs.
  --test      Run one-off test (sends alert with THRESHOLD=0).
  --uninstall Stop timer, remove units & binary (keep env file).
USAGE
}

main() {
  case "${1:-}" in
    --install)
      need_root
      ensure_deps
      write_bin
      write_env
      write_units
      enable_start
      echo "Done. Use '$0 --status' to verify."
      ;;
    --status)
      status
      ;;
    --test)
      test_run
      ;;
    --uninstall)
      need_root
      uninstall_all
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
