#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/yc_autostart.sh"

run_case() {
  local case_name="$1"
  local nc_exit="$2"
  local status="$3"
  local allow_restart="$4"
  local cooldown_mode="$5"
  local expected_action="$6"

  local tmp
  tmp="$(mktemp -d)"
  local stubs="$tmp/stubs"
  mkdir -p "$stubs"

  cat > "$stubs/nc" <<'SH'
#!/usr/bin/env bash
exit "${NC_EXIT:-1}"
SH

  cat > "$stubs/python3" <<'SH'
#!/usr/bin/env bash
echo fake-iam-token
SH

  cat > "$stubs/curl" <<'SH'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *":start"* ]]; then
  : > "${TEST_TMP_DIR}/start_called"
  echo '{"id":"op-start"}'
  exit 0
fi
if [[ "$all" == *":restart"* ]]; then
  : > "${TEST_TMP_DIR}/restart_called"
  echo '{"id":"op-restart"}'
  exit 0
fi
echo "{\"status\":\"${INSTANCE_STATUS:-UNKNOWN}\"}"
SH

  cat > "$stubs/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  chmod +x "$stubs"/*

  local cooldown_file="$tmp/last_action"
  if [[ "$cooldown_mode" == "active" ]]; then
    date +%s > "$cooldown_file"
  fi

  env \
    PATH="$stubs:/usr/bin:/bin" \
    TEST_TMP_DIR="$tmp" \
    NC_EXIT="$nc_exit" \
    INSTANCE_STATUS="$status" \
    LOG_FILE="$tmp/watchdog.log" \
    LOCK_FILE="$tmp/watchdog.lock" \
    COOLDOWN_FILE="$cooldown_file" \
    CHECKS=1 \
    DELAY_BETWEEN_CHECKS=0 \
    ALLOW_RESTART_WHEN_RUNNING="$allow_restart" \
    ACTION_COOLDOWN=900 \
    PYTHON_TOKEN_HELPER="ignored.py" \
    "$SCRIPT"

  case "$expected_action" in
    none)
      [[ ! -f "$tmp/start_called" ]]
      [[ ! -f "$tmp/restart_called" ]]
      ;;
    start)
      [[ -f "$tmp/start_called" ]]
      [[ ! -f "$tmp/restart_called" ]]
      ;;
    restart)
      [[ ! -f "$tmp/start_called" ]]
      [[ -f "$tmp/restart_called" ]]
      ;;
    *)
      echo "Unknown expected action: $expected_action" >&2
      return 1
      ;;
  esac

  rm -rf "$tmp"
  echo "PASS: $case_name"
}

run_case "host is reachable" 0 "RUNNING" "true" "inactive" "none"
run_case "stopped vm triggers start" 1 "STOPPED" "true" "inactive" "start"
run_case "running vm triggers restart" 1 "RUNNING" "true" "inactive" "restart"
run_case "cooldown skips action" 1 "STOPPED" "true" "active" "none"

echo "All tests passed"
