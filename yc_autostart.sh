#!/usr/bin/env bash

# Скрипт watchdog для Yandex Cloud VM
#
# Логика:
# 1. Проверяем доступность TARGET_IP:PORT
# 2. Если доступен — ничего не делаем
# 3. Если недоступен 3 раза подряд:
#    - получаем IAM token через Python helper
#    - узнаём статус ВМ через Compute API
#    - если STOPPED -> start
#    - если RUNNING и разрешён restart -> restart
#
# Дополнительно:
# - есть lock от параллельных запусков
# - есть cooldown, чтобы не было бесконечных рестартов
# - все важные ответы API пишутся во временные файлы /tmp

set -u
set -o pipefail

# =========================
# НАСТРОЙКИ
# =========================

# ID виртуальной машины в Yandex Cloud
INSTANCE_ID="fv4ckchobr8nevv1tjir"

# IP, который проверяем
TARGET_IP="158.160.254.24"

# Порт, который должен отвечать
PORT=443

# Файл лога
LOG_FILE="/var/log/yc-watchdog.log"

# Lock-файл от параллельных запусков
LOCK_FILE="/run/yc-watchdog.lock"

# Файл времени последнего действия
COOLDOWN_FILE="/run/yc-watchdog_last_action"

# Базовый URL Compute API
COMPUTE_URL="https://compute.api.cloud.yandex.net/compute/v1"

# Сколько раз подряд проверять порт
CHECKS=3

# Пауза между проверками
DELAY_BETWEEN_CHECKS=5

# Таймаут TCP-проверки порта
TCP_TIMEOUT=2

# Cooldown между start/restart в секундах
# 900 = 15 минут
ACTION_COOLDOWN=900

# Делать ли restart, если ВМ RUNNING, но сервис на порту мёртв
ALLOW_RESTART_WHEN_RUNNING="true"

# Python helper, который получает IAM token
PYTHON_TOKEN_HELPER="/opt/yc-watchdog/get_iam_token.py"

# =========================
# ЛОГИРОВАНИЕ
# =========================

log() {
  local msg="$1"
  local line="[yc-watchdog] $(date '+%Y-%m-%d %H:%M:%S') $msg"
  echo "$line"
  echo "$line" >> "$LOG_FILE"
}

# =========================
# ЗАЩИТА ОТ ПАРАЛЛЕЛЬНЫХ ЗАПУСКОВ
# =========================

acquire_lock() {
  # Открываем lock-файл на fd 9
  exec 9>"$LOCK_FILE" || exit 1

  # Если другой экземпляр уже работает — выходим
  flock -n 9 || {
    log "Уже запущен другой экземпляр, выходим"
    exit 0
  }
}

# =========================
# ПРОВЕРКА ДОСТУПНОСТИ ПОРТА
# =========================

check_host() {
  # Проверка TCP-порта через netcat
  nc -z -w"$TCP_TIMEOUT" "$TARGET_IP" "$PORT" >/dev/null 2>&1
}

check_with_retries() {
  local i

  # CHECKS попыток подряд
  for i in $(seq 1 "$CHECKS"); do
    if check_host; then
      log "OK: $TARGET_IP:$PORT доступен (попытка $i)"
      return 0
    fi

    log "FAIL: попытка $i/$CHECKS"

    if [ "$i" -lt "$CHECKS" ]; then
      sleep "$DELAY_BETWEEN_CHECKS"
    fi
  done

  return 1
}

# =========================
# ПОЛУЧЕНИЕ IAM TOKEN
# =========================

get_iam_token() {
  # Запускаем Python helper
  # stderr пишем во временный файл, чтобы потом показать ошибку в логе
  python3 "$PYTHON_TOKEN_HELPER" 2>/tmp/yc_iam_error.log
}

# =========================
# РАБОТА С COMPUTE API
# =========================

api_get_instance() {
  local token="$1"

  # Получаем JSON с данными по ВМ
  curl -fsS \
    -H "Authorization: Bearer $token" \
    "$COMPUTE_URL/instances/$INSTANCE_ID"
}

get_status() {
  local response status

  # Получаем JSON по ВМ
  response=$(api_get_instance "$IAM_TOKEN") || {
    log "Ошибка запроса статуса Compute API"
    return 1
  }

  # Для диагностики сохраняем сырой ответ
  echo "$response" > /tmp/yc_instance_response.json

  # Достаём статус
  status=$(echo "$response" | jq -r '.status // empty')

  if [ -z "$status" ]; then
    log "Ошибка получения статуса. Ответ API: $response"
    return 1
  fi

  echo "$status"
}

start_instance() {
  local response op_id

  # Отправляем команду запуска ВМ
  response=$(
    curl -fsS -X POST \
      -H "Authorization: Bearer $IAM_TOKEN" \
      "$COMPUTE_URL/instances/$INSTANCE_ID:start"
  ) || {
    log "Ошибка вызова start"
    return 1
  }

  # Сохраняем сырой ответ для диагностики
  echo "$response" > /tmp/yc_start_response.json

  # В ответе ожидается operation id
  op_id=$(echo "$response" | jq -r '.id // empty')

  if [ -z "$op_id" ]; then
    log "Ошибка start. Ответ API: $response"
    return 1
  fi

  log "Команда start отправлена, operation id: $op_id"
  return 0
}

restart_instance() {
  local response op_id

  # Отправляем команду рестарта ВМ
  response=$(
    curl -fsS -X POST \
      -H "Authorization: Bearer $IAM_TOKEN" \
      "$COMPUTE_URL/instances/$INSTANCE_ID:restart"
  ) || {
    log "Ошибка вызова restart"
    return 1
  }

  # Сохраняем сырой ответ для диагностики
  echo "$response" > /tmp/yc_restart_response.json

  # В ответе ожидается operation id
  op_id=$(echo "$response" | jq -r '.id // empty')

  if [ -z "$op_id" ]; then
    log "Ошибка restart. Ответ API: $response"
    return 1
  fi

  log "Команда restart отправлена, operation id: $op_id"
  return 0
}

# =========================
# COOLDOWN
# =========================

cooldown_active() {
  # Если файла нет — cooldown не активен
  [[ -f "$COOLDOWN_FILE" ]] || return 1

  local last now
  last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)

  # Если прошло меньше ACTION_COOLDOWN секунд — cooldown активен
  [[ $((now - last)) -lt $ACTION_COOLDOWN ]]
}

touch_cooldown() {
  # Сохраняем текущее время как время последнего действия
  date +%s > "$COOLDOWN_FILE"
}

# =========================
# ОСНОВНАЯ ЛОГИКА
# =========================

main() {
  # Готовим /run
  mkdir -p /run

  # Берём lock
  acquire_lock

  # Проверяем сервис
  if check_with_retries; then
    exit 0
  fi

  log "Сервер недоступен после $CHECKS проверок"

  # Если cooldown активен — не делаем start/restart
  if cooldown_active; then
    log "Cooldown активен, действие пропускаем"
    exit 0
  fi

  # Получаем IAM token
  IAM_TOKEN=$(get_iam_token)

  if [ -z "${IAM_TOKEN:-}" ]; then
    log "Не удалось получить IAM token"

    if [ -f /tmp/yc_iam_error.log ]; then
      log "IAM stderr: $(cat /tmp/yc_iam_error.log)"
    fi

    exit 1
  fi

  # Получаем статус ВМ
  STATUS=$(get_status) || exit 1
  log "Статус: $STATUS"

  # Если ВМ остановлена — запускаем
  if [ "$STATUS" = "STOPPED" ]; then
    log "Запуск ВМ"
    start_instance && touch_cooldown
    exit $?
  fi

  # Если ВМ работает, но сервис мёртв — рестартуем
  if [ "$STATUS" = "RUNNING" ] && [ "$ALLOW_RESTART_WHEN_RUNNING" = "true" ]; then
    log "Рестарт ВМ"
    restart_instance && touch_cooldown
    exit $?
  fi

  # Иные статусы: STARTING, STOPPING, RESTARTING и т.д.
  log "Ничего не делаем"
}

main