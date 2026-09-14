#!/usr/bin/env bash
#
# fanya_hanwen_socket_watchdog.sh
#
# Keeps www.fanyahanwen-corpus.cn serving.

set -Eeuo pipefail

SERVICE="${FANYA_WEB_SERVICE:-fanya-hanwen-web.service}"
ENV_FILE="${FANYA_ENV_FILE:-${HOME}/.config/fanya-hanwen.env}"
UNIT_DIR="${HOME}/.config/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/fanya-hanwen-watchdog"
STATE_FILE="${STATE_DIR}/restarts"
NAME="fanya-hanwen-socket-check"

# Puma eager-loads this app for the better part of a minute before it binds.
# Never intervene inside this window, or the watchdog restarts a server that is
# merely booting - and then does it again a minute later, forever.
GRACE_SECONDS="${FANYA_GRACE_SECONDS:-180}"

# If the socket breaks this often in an hour, a restart is not the answer.
# Stop trying and leave the reason in the journal where it can be found.
MAX_RESTARTS_PER_HOUR="${FANYA_MAX_RESTARTS:-4}"

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

log() { printf '[watchdog] %s\n' "$*"; }

# The socket path is read from PUMA_BIND rather than hardcoded, so this cannot
# drift out of step with config/puma.rb. The file is parsed, never sourced -
# sourcing it would execute whatever it contains.
socket_path() {
  [[ -r "${ENV_FILE}" ]] || return 0
  sed -n 's|^PUMA_BIND=unix://||p' "${ENV_FILE}" | head -n 1
}

# Seconds since the unit last entered the active state, via systemd's monotonic
# clock (microseconds since boot), compared against /proc/uptime.
active_for_seconds() {
  local entered now
  entered="$(systemctl --user show -p ActiveEnterTimestampMonotonic --value "${SERVICE}" 2>/dev/null || echo 0)"
  [[ "${entered}" =~ ^[0-9]+$ ]] && [[ "${entered}" != "0" ]] || { echo 0; return 0; }
  now="$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)"
  echo $(( (now - entered) / 1000000 ))
}

# Two separate questions: is the socket file there, and does anything answer on
# it. The first is what caught 2026-09-14; the second catches a wedged puma.
socket_ok() {
  local sock="$1"
  [[ -S "${sock}" ]] || return 1
  curl -s --max-time 10 --unix-socket "${sock}" http://localhost/up -o /dev/null 2>/dev/null
}

recent_restarts() {
  local cutoff
  cutoff=$(( $(date +%s) - 3600 ))
  [[ -f "${STATE_FILE}" ]] || { echo 0; return 0; }
  awk -v c="${cutoff}" '$1 >= c' "${STATE_FILE}" | wc -l
}

record_restart() {
  mkdir -p "${STATE_DIR}"
  date +%s >> "${STATE_FILE}"
  tail -n 200 "${STATE_FILE}" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "${STATE_FILE}"
}

do_check() {
  local sock active_for recent
  sock="$(socket_path)"
  if [[ -z "${sock}" ]]; then
    log "no PUMA_BIND in ${ENV_FILE}; nothing to watch"
    return 0
  fi

  # Stopped on purpose. Leave it stopped.
  systemctl --user is-active --quiet "${SERVICE}" || return 0

  active_for="$(active_for_seconds)"
  if [[ "${active_for}" -lt "${GRACE_SECONDS}" ]]; then
    return 0
  fi

  socket_ok "${sock}" && return 0

  recent="$(recent_restarts)"
  if [[ "${recent}" -ge "${MAX_RESTARTS_PER_HOUR}" ]]; then
    log "socket ${sock} still unusable after ${recent} restarts this hour - NOT restarting again, this needs a human"
    return 1
  fi

  log "socket ${sock} unusable after ${active_for}s active - restarting ${SERVICE} (${recent} prior restarts this hour)"
  record_restart
  systemctl --user restart "${SERVICE}"
}

do_status() {
  local sock
  sock="$(socket_path)"
  printf 'service        %s (%s)\n' "${SERVICE}" "$(systemctl --user is-active "${SERVICE}" 2>/dev/null || echo inactive)"
  printf 'active for     %ss\n' "$(active_for_seconds)"
  printf 'socket path    %s\n' "${sock:-<none in ${ENV_FILE}>}"
  if [[ -n "${sock}" && -S "${sock}" ]]; then
    printf 'socket file    present\n'
  else
    printf 'socket file    MISSING\n'
  fi
  if [[ -n "${sock}" ]] && socket_ok "${sock}"; then
    printf 'socket answers yes\n'
  else
    printf 'socket answers no\n'
  fi
  printf 'restarts/hour  %s of %s\n' "$(recent_restarts)" "${MAX_RESTARTS_PER_HOUR}"
  systemctl --user list-timers "${NAME}.timer" --no-pager 2>/dev/null || true
}

do_install() {
  mkdir -p "${UNIT_DIR}"
  cat > "${UNIT_DIR}/${NAME}.service" <<UNIT
[Unit]
Description=Restart ${SERVICE} if its proxy socket has gone
After=${SERVICE}

[Service]
Type=oneshot
ExecStart=${SELF} --check
UNIT
  cat > "${UNIT_DIR}/${NAME}.timer" <<UNIT
[Unit]
Description=Check the Fanya Hanwen proxy socket every minute

[Timer]
OnBootSec=3min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT
  chmod +x "${SELF}"
  systemctl --user daemon-reload
  systemctl --user enable --now "${NAME}.timer"
  log "installed, watching $(socket_path)"
  systemctl --user list-timers "${NAME}.timer" --no-pager
}

do_uninstall() {
  systemctl --user disable --now "${NAME}.timer" 2>/dev/null || true
  rm -f "${UNIT_DIR}/${NAME}.timer" "${UNIT_DIR}/${NAME}.service"
  systemctl --user daemon-reload
  log "removed"
}

case "${1:---check}" in
  --check)     do_check ;;
  --install)   do_install ;;
  --status)    do_status ;;
  --uninstall) do_uninstall ;;
  *) echo "usage: $(basename "$0") [--check|--install|--status|--uninstall]" >&2; exit 2 ;;
esac
