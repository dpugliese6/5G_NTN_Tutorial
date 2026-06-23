#!/usr/bin/env bash
# =============================================================================
# Dome Attach-Only Test Script
#
# Brings up gNB and UE, waits for them to initialise, starts the PROPSIM
# channel emulation so the UE attaches, waits briefly, then tears everything
# down. Used as a sanity-check / quick attach test — no iperf3, no
# iterations.
#
# Timeline:
#   t=0s   : start gnb-cst and ue-cst (and begin streaming both logs)
#   t=45s  : start PROPSIM emulation (DIAG:SIMU:GO)
#   t=55s  : rewind PROPSIM emulation (DIAG:SIMU:GOS) and tear down
#
# Logs:
#   Both container logs are streamed to files in real time using
#   `docker logs -f`, started in the background as soon as each container
#   is up. The follower processes terminate naturally when the containers
#   are removed during teardown; we wait on them so files are flushed
#   before the script exits.
#
# Output files (in --output-dir, default '.'):
#   gnb-cst_<timestamp>.log
#   ue-cst_<timestamp>.log
#
# Usage:
#   ./attach_test.sh [options]
#
# Options:
#   --host <ip>           PROPSIM IP address    (default: 172.31.19.38)
#   --port <port>         PROPSIM ATE port      (default: 3334)
#   --startup-wait <sec>  Wait after containers up (default: 45)
#   --attach-wait <sec>   Wait after emulation start (default: 10)
#   --compose-file <f>    Docker Compose file   (default: docker-compose_ran.yaml)
#   --output-dir <dir>    Directory for log files (default: .)
#   -h | --help           Show this help message
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
PROPSIM_HOST="172.31.19.38"
PROPSIM_PORT=3334
STARTUP_WAIT=45
ATTACH_WAIT=10
COMPOSE_FILE="docker-compose_ran.yaml"
OUTPUT_DIR="."
PROPSIM_TIMEOUT=10

# -----------------------------------------------------------------------------
# Colours / logging
# -----------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()      { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔ $*${NC}"; }
log_warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $*${NC}"; }
log_err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✘ $*${NC}" >&2; }
log_step() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)          PROPSIM_HOST="$2";  shift 2 ;;
        --port)          PROPSIM_PORT="$2";  shift 2 ;;
        --startup-wait)  STARTUP_WAIT="$2";  shift 2 ;;
        --attach-wait)   ATTACH_WAIT="$2";   shift 2 ;;
        --compose-file)  COMPOSE_FILE="$2";  shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2";    shift 2 ;;
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) log_err "Unknown argument: $1"; exit 1 ;;
    esac
done

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
GNB_LOG="${OUTPUT_DIR}/gnb-cst_${TIMESTAMP}.log"
UE_LOG="${OUTPUT_DIR}/ue-cst_${TIMESTAMP}.log"

# =============================================================================
# PROPSIM ATE communication
# =============================================================================
PROPSIM_CONNECTED=0

propsim_connect() {
    log "Connecting to PROPSIM at ${PROPSIM_HOST}:${PROPSIM_PORT}..."
    exec 3<>"/dev/tcp/${PROPSIM_HOST}/${PROPSIM_PORT}" 2>/dev/null || {
        log_err "Cannot connect to PROPSIM at ${PROPSIM_HOST}:${PROPSIM_PORT}"
        return 1
    }
    PROPSIM_CONNECTED=1
    log_ok "PROPSIM connected."
}

propsim_disconnect() {
    if [[ "$PROPSIM_CONNECTED" -eq 1 ]]; then
        exec 3>&- 2>/dev/null || true
        PROPSIM_CONNECTED=0
        log "PROPSIM connection closed."
    fi
}

propsim_send()  { printf '%s\n' "$1" >&3; }
propsim_query() {
    local response
    printf '%s\n' "$1" >&3
    if read -r -t "$PROPSIM_TIMEOUT" response <&3; then
        echo "${response}"
    else
        log_err "Timeout waiting for PROPSIM response to: $1"
        return 1
    fi
}
propsim_get_state() { propsim_query "DIAG:SIMU:STATE?"; }

propsim_start_emulation() {
    local state
    state=$(propsim_get_state)
    log "  PROPSIM state: ${state}"
    if [[ "$state" == "RUNNING" ]]; then
        log_warn "  Emulation already running."; return 0
    fi
    if [[ "$state" == "CLOSED" ]]; then
        log_err "  No emulation loaded. Cannot start."; return 1
    fi
    propsim_send "DIAG:SIMU:GO"
    sleep 0.5
    state=$(propsim_get_state)
    if [[ "$state" == "RUNNING" ]]; then
        log_ok "  Emulation started (state: ${state})"
    else
        log_warn "  Expected RUNNING, got: ${state}"
    fi
}

propsim_rewind_emulation() {
    local state
    log "  Rewinding emulation timeline (DIAG:SIMU:GOS)..."
    propsim_send "DIAG:SIMU:GOS"
    sleep 1.0
    state=$(propsim_get_state)
    if [[ "$state" == "STOPPED" ]]; then
        log_ok "  Emulation rewound and stopped (state: ${state})"
    else
        log_warn "  Expected STOPPED after GOS, got: ${state}"
    fi
}

# =============================================================================
# Docker Compose helpers
# =============================================================================
gnb_up()   { log "  Starting gnb-cst...";    docker compose -f "$COMPOSE_FILE" up -d gnb-cst; log_ok "  gnb-cst started."; }
gnb_down() {
    log "  Stopping gnb-cst..."
    docker compose -f "$COMPOSE_FILE" stop gnb-cst 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" rm -f gnb-cst 2>/dev/null || true
    log_ok "  gnb-cst stopped and removed."
}
ue_up()    { log "  Starting ue-cst...";     docker compose -f "$COMPOSE_FILE" up -d ue-cst;  log_ok "  ue-cst started."; }
ue_down() {
    log "  Stopping ue-cst..."
    docker compose -f "$COMPOSE_FILE" stop ue-cst 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" rm -f ue-cst 2>/dev/null || true
    log_ok "  ue-cst stopped and removed."
}

# =============================================================================
# Log streaming
#
# `docker logs -f <container>` follows the container's stdout/stderr until
# the container is removed. We start it backgrounded right after the
# container is up, capture its PID so we can `wait` on it during teardown
# (which guarantees the log file is fully flushed before the script exits).
#
# --since 0s ensures we don't replay everything that may have been emitted
# before the follower attached — important on slow systems where the
# container can produce a burst of output between `up -d` returning and us
# attaching the follower. (For a fresh `up -d`, this is effectively a no-op.)
# =============================================================================
GNB_LOG_PID=""
UE_LOG_PID=""

start_log_follower() {
    local container="$1"
    local outfile="$2"
    local pid_var="$3"

    log "  Streaming '${container}' logs to ${outfile}..."
    {
        echo "# === ${container} log — started $(date '+%Y-%m-%dT%H:%M:%S') ==="
    } > "$outfile"

    # Append the live stream. `docker logs -f` writes to BOTH stdout and
    # stderr depending on the source stream inside the container, so we
    # merge them with 2>&1.
    docker logs -f --since 0s "$container" >> "$outfile" 2>&1 &
    local pid=$!
    printf -v "$pid_var" '%s' "$pid"
    log_ok "  Follower for '${container}' running (pid ${pid})."
}

stop_log_followers() {
    # The followers should die on their own when the containers are
    # removed. Give them a moment, then kill any that are still around,
    # then `wait` to reap.
    if [[ -n "$GNB_LOG_PID" ]] && kill -0 "$GNB_LOG_PID" 2>/dev/null; then
        sleep 0.5
        kill "$GNB_LOG_PID" 2>/dev/null || true
    fi
    if [[ -n "$UE_LOG_PID" ]] && kill -0 "$UE_LOG_PID" 2>/dev/null; then
        sleep 0.5
        kill "$UE_LOG_PID" 2>/dev/null || true
    fi

    # Reap so output is fully flushed
    [[ -n "$GNB_LOG_PID" ]] && wait "$GNB_LOG_PID" 2>/dev/null || true
    [[ -n "$UE_LOG_PID"  ]] && wait "$UE_LOG_PID"  2>/dev/null || true

    GNB_LOG_PID=""
    UE_LOG_PID=""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    echo ""
    log_warn "Interrupt or exit — cleaning up..."
    if [[ "$PROPSIM_CONNECTED" -eq 1 ]]; then
        log "Rewinding PROPSIM emulation timeline..."
        propsim_send "DIAG:SIMU:GOS" || true
        sleep 0.5
        propsim_disconnect
    fi
    ue_down  || true
    gnb_down || true
    stop_log_followers
    log_warn "Cleanup complete."
}
# Note: only INT/TERM here. We do NOT trap EXIT because the script's
# normal teardown calls these functions explicitly — and trapping EXIT
# with `set -e` can cause double-teardown surprises.
trap cleanup INT TERM

# =============================================================================
# Pre-flight checks
# =============================================================================
log_step "Pre-flight checks"
command -v docker >/dev/null 2>&1 || { log_err "'docker' not found."; exit 1; }
[[ -f "$COMPOSE_FILE" ]] || { log_err "Docker Compose file not found: ${COMPOSE_FILE}"; exit 1; }
log_ok "All dependencies found."

propsim_connect
IDN=$(propsim_query "*IDN?")
log_ok "PROPSIM identified: ${IDN}"

# =============================================================================
# Configuration summary
# =============================================================================
log_step "Test Configuration (attach-only)"
echo -e "  Compose file     : ${BOLD}${COMPOSE_FILE}${NC}"
echo -e "  PROPSIM          : ${BOLD}${PROPSIM_HOST}:${PROPSIM_PORT}${NC}"
echo -e "  Startup wait     : ${BOLD}${STARTUP_WAIT}s${NC}"
echo -e "  Attach wait      : ${BOLD}${ATTACH_WAIT}s${NC}"
echo -e "  gNB log file     : ${BOLD}${GNB_LOG}${NC}"
echo -e "  UE  log file     : ${BOLD}${UE_LOG}${NC}"

# =============================================================================
# Run
# =============================================================================
log_step "Step 1: Start gnb-cst and ue-cst"
gnb_up
start_log_follower "gnb-cst" "$GNB_LOG" "GNB_LOG_PID"

ue_up
start_log_follower "ue-cst" "$UE_LOG" "UE_LOG_PID"

log_step "Step 2: Wait ${STARTUP_WAIT}s for containers to initialise"
sleep "$STARTUP_WAIT"
log_ok "Startup wait complete."

log_step "Step 3: Start PROPSIM emulation"
propsim_start_emulation

log_step "Step 4: Wait ${ATTACH_WAIT}s for UE to attach"
sleep "$ATTACH_WAIT"
log_ok "Attach wait complete."

log_step "Step 5: Tear down"
propsim_rewind_emulation
propsim_disconnect

ue_down
gnb_down

# Wait for the log followers to flush and exit. They should already be
# dead because the containers have been removed; this just reaps them.
stop_log_followers

log_step "Done"
log_ok "gNB log : ${GNB_LOG}"
log_ok "UE  log : ${UE_LOG}"
