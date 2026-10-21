#!/usr/bin/env bash
set -euo pipefail

state_file="${STATE_FILE:-watchdog-state/state}"
attempts="${CHECK_ATTEMPTS:-3}"
pause="${CHECK_PAUSE_SECONDS:-20}"
now="$(date +%s)"

for name in PROD_HEALTH_URL WATCHDOG_BOT_TOKEN WATCHDOG_CHAT_ID; do
  if [[ -z "${!name:-}" && "${DRY_RUN:-}" != "1" ]]; then
    echo "::error::Не задан секрет $name"
    exit 1
  fi
done

moscow() { TZ=Europe/Moscow date -d "@$1" '+%d.%m %H:%M'; }
minutes() { echo $(( ($1 + 59) / 60 )); }

check_once() {
  if [[ "${SIMULATE_DOWN:-}" == "1" ]]; then
    reason="пробный сбой, запущен вручную"
    return 1
  fi
  local response code body
  response="$(curl -sS -m 20 -w '\n%{http_code}' "$PROD_HEALTH_URL" 2>/dev/null)" || response=$'\n000'
  code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$code" == "000" ]]; then
    reason="не подключиться либо нет ответа за 20 секунд"
  elif [[ "$code" != "200" ]]; then
    reason="ответ $code"
  elif [[ "$body" != *'"status":"ok"'* ]]; then
    reason="ответ 200, но без \"status\":\"ok\""
  elif [[ "$body" == *'"environment":'* && "$body" != *'"environment":"production"'* ]]; then
    reason="адрес проверки ведёт не на прод (environment не production), поправить секрет PROD_HEALTH_URL"
  else
    return 0
  fi
  return 1
}

up=0
for attempt in $(seq 1 "$attempts"); do
  if check_once; then
    up=1
    break
  fi
  echo "Проверка $attempt из $attempts: $reason"
  if (( attempt < attempts )); then sleep "$pause"; fi
done

status="up"; since="$now"; last_alert=0
if [[ -f "$state_file" ]]; then
  value() { sed -n "s/^$1=\([a-z0-9]*\)$/\1/p" "$state_file" | head -n 1; }
  status="$(value status)"; since="$(value since)"; last_alert="$(value last_alert)"
  [[ "$status" == "down" && "$since" =~ ^[0-9]+$ && "$last_alert" =~ ^[0-9]+$ ]] || { status="up"; since="$now"; last_alert=0; }
fi

send() {
  if [[ "${DRY_RUN:-}" == "1" ]]; then
    echo "Сообщение: $1"
    return
  fi
  local response
  response="$(curl -sS -m 20 "https://api.telegram.org/bot${WATCHDOG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${WATCHDOG_CHAT_ID}" --data-urlencode "text=$1" 2>&1)" || true
  if [[ "$response" != *'"ok":true'* ]]; then
    echo "::error::Telegram не принял сообщение: ${response//${WATCHDOG_BOT_TOKEN}/***}"
    return 1
  fi
}

save() {
  mkdir -p "$(dirname "$state_file")"
  printf 'status=%s\nsince=%s\nlast_alert=%s\n' "$1" "$2" "$3" > "$state_file"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "changed=true" >> "$GITHUB_OUTPUT"; fi
}

if (( up )); then
  if [[ "$status" == "down" ]]; then
    send "Прод снова работает ($(moscow "$now") МСК). Не отвечал с $(moscow "$since"), около $(minutes $((now - since))) мин."
    save up "$now" 0
  fi
  echo "Прод отвечает"
elif [[ "$status" != "down" ]]; then
  send "Прод не отвечает ($(moscow "$now") МСК): $reason. Неудачных проверок подряд: $attempts. Пока не поднимется, напомню раз в час."
  save down "$now" "$now"
elif (( now - last_alert >= 3600 )); then
  send "Прод всё ещё не отвечает: $reason. Лежит с $(moscow "$since") МСК, около $(minutes $((now - since))) мин."
  save down "$since" "$now"
else
  echo "Прод лежит с $(moscow "$since") МСК, напоминание уже было в последний час"
fi
