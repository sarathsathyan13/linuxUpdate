#system update · SH
#!/usr/bin/env bash
#
# system-update.sh — Advanced Linux update/upgrade automation
#
# Features:
#   - Root/sudo check
#   - Network reachability check with retries
#   - apt lock detection (waits instead of failing)
#   - Non-interactive apt frontend (no dialogs hang the script)
#   - Full logging to timestamped logfile + console
#   - Error trapping with line-number reporting
#   - update -> upgrade -> dist-upgrade -> autoremove -> autoclean
#   - Reboot-required detection at the end
#   - Safe to re-run (idempotent)
#
# Usage:
#   sudo ./system-update.sh
#   sudo ./system-update.sh --no-reboot-check   # skip reboot check
#   sudo ./system-update.sh --ping-host 1.1.1.1 # custom network check host
#
set -Eeuo pipefail
 
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PING_HOST="8.8.8.8"
PING_COUNT=3
PING_RETRIES=3
PING_RETRY_DELAY=5
LOCK_WAIT_TIMEOUT=180          # seconds to wait for apt/dpkg lock
LOG_DIR="/var/log/system-update"
LOG_FILE="${LOG_DIR}/update_$(date +%Y%m%d_%H%M%S).log"
CHECK_REBOOT=true
 
export DEBIAN_FRONTEND=noninteractive
 
# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-reboot-check) CHECK_REBOOT=false; shift ;;
    --ping-host) PING_HOST="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done
 
# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
 
log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%-5s] %s\n' "$ts" "$level" "$*" | tee -a "$LOG_FILE"
}
 
info()  { log "INFO"  "$@"; }
warn()  { log "WARN"  "$@"; }
error() { log "ERROR" "$@"; }
step()  {
  echo | tee -a "$LOG_FILE"
  log "STEP" "$*"
  printf '%.0s#' {1..70} | tee -a "$LOG_FILE"
  echo | tee -a "$LOG_FILE"
}
 
on_error() {
  local exit_code=$?
  local line_no=$1
  error "Script failed at line ${line_no} (exit code ${exit_code}). See ${LOG_FILE}"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR
 
# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root. Try: sudo $0"
    exit 1
  fi
  info "Root privileges confirmed."
}
 
check_network() {
  info "Checking network connectivity to ${PING_HOST}..."
  local attempt=1
  while (( attempt <= PING_RETRIES )); do
    if ping -c "$PING_COUNT" -W 2 "$PING_HOST" >>"$LOG_FILE" 2>&1; then
      info "Network is reachable (attempt ${attempt}/${PING_RETRIES})."
      return 0
    fi
    warn "Network check failed (attempt ${attempt}/${PING_RETRIES}). Retrying in ${PING_RETRY_DELAY}s..."
    sleep "$PING_RETRY_DELAY"
    ((attempt++))
  done
  error "No network connectivity after ${PING_RETRIES} attempts. Aborting."
  exit 1
}
 
detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  else
    echo "unknown"
  fi
}
 
wait_for_apt_lock() {
  local waited=0
  local lock_files=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
                     /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
  while fuser "${lock_files[@]}" >/dev/null 2>&1; do
    if (( waited >= LOCK_WAIT_TIMEOUT )); then
      error "Timed out waiting ${LOCK_WAIT_TIMEOUT}s for apt/dpkg lock to release."
      exit 1
    fi
    warn "Another apt/dpkg process holds the lock. Waiting... (${waited}s/${LOCK_WAIT_TIMEOUT}s)"
    sleep 5
    ((waited+=5))
  done
}
 
# ---------------------------------------------------------------------------
# Update routines
# ---------------------------------------------------------------------------
run_apt_flow() {
  wait_for_apt_lock
  step "apt-get update"
  apt-get update -y 2>&1 | tee -a "$LOG_FILE"
 
  wait_for_apt_lock
  step "apt-get upgrade"
  apt-get upgrade -y --with-new-pkgs 2>&1 | tee -a "$LOG_FILE"
 
  wait_for_apt_lock
  step "apt-get dist-upgrade (handles dependency changes; supersedes full-upgrade)"
  apt-get dist-upgrade -y 2>&1 | tee -a "$LOG_FILE"
 
  wait_for_apt_lock
  step "apt-get autoremove --purge"
  apt-get autoremove -y --purge 2>&1 | tee -a "$LOG_FILE"
 
  wait_for_apt_lock
  step "apt-get autoclean"
  apt-get autoclean -y 2>&1 | tee -a "$LOG_FILE"
}
 
run_dnf_flow() {
  step "dnf upgrade"
  dnf upgrade --refresh -y 2>&1 | tee -a "$LOG_FILE"
  step "dnf autoremove"
  dnf autoremove -y 2>&1 | tee -a "$LOG_FILE"
}
 
run_yum_flow() {
  step "yum update"
  yum update -y 2>&1 | tee -a "$LOG_FILE"
}
 
run_pacman_flow() {
  step "pacman -Syu"
  pacman -Syu --noconfirm 2>&1 | tee -a "$LOG_FILE"
}
 
run_zypper_flow() {
  step "zypper refresh & update"
  zypper --non-interactive refresh 2>&1 | tee -a "$LOG_FILE"
  zypper --non-interactive update 2>&1 | tee -a "$LOG_FILE"
}
 
check_reboot_required() {
  $CHECK_REBOOT || return 0
  step "Checking whether a reboot is required"
  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is required to complete updates."
    if [[ -f /var/run/reboot-required.pkgs ]]; then
      info "Packages requiring reboot:"
      cat /var/run/reboot-required.pkgs | tee -a "$LOG_FILE"
    fi
  else
    info "No reboot required."
  fi
}
 
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local start_time
  start_time=$(date +%s)
 
  step "Starting system update automation"
  require_root
  check_network
 
  local pkg_mgr
  pkg_mgr=$(detect_pkg_manager)
  info "Detected package manager: ${pkg_mgr}"
 
  case "$pkg_mgr" in
    apt)     run_apt_flow ;;
    dnf)     run_dnf_flow ;;
    yum)     run_yum_flow ;;
    pacman)  run_pacman_flow ;;
    zypper)  run_zypper_flow ;;
    *)
      error "No supported package manager found. Aborting."
      exit 1
      ;;
  esac
 
  check_reboot_required
 
  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$(( end_time - start_time ))
  step "Update automation complete in ${elapsed}s. Log saved to ${LOG_FILE}"
}
 
main "$@"
 
