#!/usr/bin/env bash
# =============================================================================
# Dome Throughput Test Automation Script — iperf2 UPLINK variant
#
# Uplink (UE → UPF) version of the iperf2 test. Like the downlink variant,
# this avoids iperf3's TCP control channel entirely: the iperf2 UDP test is
# pure data-plane, so a degraded radio link can't break the post-test
# results handshake (because there isn't one).
#
# Direction & topology:
#   * iperf2 SERVER runs inside the UPF container (the receiver)
#   * iperf2 CLIENT runs on the UE host, bound to ${IPERF_CLIENT}
#   * Traffic: UE host  ──UDP──>  UPF container   (uplink)
#
#   Authoritative per-interval stats (jitter, loss, throughput as seen by the
#   receiver) come from the SERVER side, captured by redirecting the host-
#   side stdout of `docker exec` into a CSV. The sender's view is logged
#   separately.
#
# Session setup (once):
#   * Start gnb-cst (kept up across all iterations)
#
# Per iteration:
#   1. Start ue-cst container
#   2. Wait 45s for the RAN to (re)attach
#   3. Start the PROPSIM emulation and wait 5s for UE attach
#   4. Ping the UPF from the UE address; if it fails, restart the iteration
#   5. Start iperf2 server inside the UPF container (host captures its stdout)
#   6. Run iperf2 client on the UE host pushing UDP uplink
#   7. Stop the iperf2 server, rewind PROPSIM, stop ue-cst
#
# Session teardown:
#   * Stop and remove gnb-cst
#   * Kill any leftover iperf2 server inside the UPF container
#
# Usage:
#   ./throughput_ul_udp_iperf2.sh --name <test_name> [options]
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
TEST_NAME=""
ITERATIONS=10
PROPSIM_HOST="172.31.19.38"
PROPSIM_PORT=3334
IPERF_SERVER="192.168.100.1"     # UPF-side address (iperf2 server bind addr)
IPERF_CLIENT="192.168.100.3"     # UE-side address (iperf2 client source)
IPERF_PORT=5202
IPERF_TIME=100
IPERF_BANDWIDTH="40M"
UPF_CONTAINER="upf"
COMPOSE_FILE="docker-compose_ran.yaml"
OUTPUT_DIR="."

RAN_INIT_WAIT=45
UE_ATTACH_WAIT=10
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
        --name)           TEST_NAME="$2";       shift 2 ;;
        --iterations)     ITERATIONS="$2";      shift 2 ;;
        --host)           PROPSIM_HOST="$2";    shift 2 ;;
        --port)           PROPSIM_PORT="$2";    shift 2 ;;
        --iperf-server)   IPERF_SERVER="$2";    shift 2 ;;
        --iperf-client)   IPERF_CLIENT="$2";    shift 2 ;;
        --iperf-port)     IPERF_PORT="$2";      shift 2 ;;
        --iperf-time)     IPERF_TIME="$2";      shift 2 ;;
        --iperf-bw)       IPERF_BANDWIDTH="$2"; shift 2 ;;
        --upf-container)  UPF_CONTAINER="$2";   shift 2 ;;
        --compose-file)   COMPOSE_FILE="$2";    shift 2 ;;
        --output-dir)     OUTPUT_DIR="$2";      shift 2 ;;
        -h|--help)
            sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) log_err "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -z "$TEST_NAME" ]] && { log_err "--name is required."; exit 1; }
mkdir -p "$OUTPUT_DIR"

# =============================================================================
# PROPSIM ATE communication (unchanged)
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
    log "  Stopping gnb-cst...";
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
# iperf2 server INSIDE the UPF container
#
# We start a fresh server per iteration to keep each CSV self-contained.
# `docker exec` is run WITHOUT -d so we can capture its stdout/stderr on
# the host directly into the CSV. The exec process is backgrounded by the
# shell (& at the end), and we also remember the in-container PID so we
# can send SIGINT to make iperf2 print its final summary cleanly.
# =============================================================================
DOCKER_EXEC_PID=""       # PID of the host-side `docker exec` wrapper
IPERF_SERVER_INSIDE_PID="" # PID of iperf inside the container

iperf_server_start_in_upf() {
    local out_log="$1"

    # Kill any stale iperf2 server inside the container on this port
    docker exec "${UPF_CONTAINER}" sh -c "pkill -f 'iperf -s.*-p ${IPERF_PORT}' || true" 2>/dev/null || true
    sleep 0.3

    log "  Starting iperf2 server inside '${UPF_CONTAINER}' (bind ${IPERF_SERVER}:${IPERF_PORT}, UDP)..."
    # Run docker exec in the foreground (of a background subshell) so its
    # stdout flows back through the host pipeline into our CSV file.
    docker exec "${UPF_CONTAINER}" \
        iperf -s -u -B "${IPERF_SERVER}" -p "${IPERF_PORT}" -i 1 -f m -e \
        >> "$out_log" 2>&1 &
    DOCKER_EXEC_PID=$!
    sleep 0.8

    # Confirm the docker exec wrapper is alive AND the iperf process is
    # actually listening inside the container.
    if ! kill -0 "$DOCKER_EXEC_PID" 2>/dev/null; then
        log_err "  'docker exec iperf -s' wrapper died immediately. See ${out_log}:"
        tail -n 10 "$out_log" | sed 's/^/    /' >&2 || true
        return 1
    fi

    IPERF_SERVER_INSIDE_PID=$(docker exec "${UPF_CONTAINER}" \
        sh -c "pgrep -n -f 'iperf -s.*-p ${IPERF_PORT}' || true" 2>/dev/null)

    if [[ -z "$IPERF_SERVER_INSIDE_PID" ]]; then
        log_err "  iperf2 server is not running inside '${UPF_CONTAINER}'. See ${out_log}:"
        tail -n 10 "$out_log" | sed 's/^/    /' >&2 || true
        return 1
    fi

    log_ok "  iperf2 server running inside container (in-container pid ${IPERF_SERVER_INSIDE_PID}). Output → ${out_log}"
}

iperf_server_stop_in_upf() {
    # Send SIGINT to the in-container iperf so it flushes its summary line
    if [[ -n "$IPERF_SERVER_INSIDE_PID" ]] && \
       docker ps --format '{{.Names}}' | grep -qx "${UPF_CONTAINER}"; then
        log "  Sending SIGINT to in-container iperf2 server (pid ${IPERF_SERVER_INSIDE_PID})..."
        docker exec "${UPF_CONTAINER}" sh -c "kill -INT ${IPERF_SERVER_INSIDE_PID} 2>/dev/null || true" || true
        # Allow time for the summary line to be written
        for _ in 1 2 3 4 5; do
            docker exec "${UPF_CONTAINER}" sh -c "kill -0 ${IPERF_SERVER_INSIDE_PID} 2>/dev/null" || break
            sleep 0.3
        done
        # Belt-and-braces: kill anything still bound to that port inside
        docker exec "${UPF_CONTAINER}" sh -c "pkill -f 'iperf -s.*-p ${IPERF_PORT}' || true" 2>/dev/null || true
    fi

    # Reap the host-side docker exec wrapper
    if [[ -n "$DOCKER_EXEC_PID" ]] && kill -0 "$DOCKER_EXEC_PID" 2>/dev/null; then
        wait "$DOCKER_EXEC_PID" 2>/dev/null || true
    fi
    DOCKER_EXEC_PID=""
    IPERF_SERVER_INSIDE_PID=""
    log_ok "  iperf2 server stopped."
}

# =============================================================================
# Cleanup
# =============================================================================
CURRENT_ITER=0

cleanup() {
    echo ""
    log_warn "Interrupt received — cleaning up (iteration ${CURRENT_ITER})..."
    if [[ "$PROPSIM_CONNECTED" -eq 1 ]]; then
        log "Rewinding PROPSIM emulation timeline..."
        propsim_send "DIAG:SIMU:GOS" || true
        sleep 0.5
        log_ok "PROPSIM timeline reset to start."
        propsim_disconnect
    fi
    iperf_server_stop_in_upf || true
    log "Stopping ue-cst...";  ue_down  || true
    log "Stopping gnb-cst..."; gnb_down || true
    log_warn "Cleanup complete. Exiting."
    exit 1
}
trap cleanup INT TERM

# =============================================================================
# Pre-flight checks
# =============================================================================
log_step "Pre-flight checks"
command -v docker >/dev/null 2>&1 || { log_err "'docker' not found.";  exit 1; }
command -v iperf  >/dev/null 2>&1 || { log_err "'iperf' (iperf2) not found on UE host. Install with: apt install iperf"; exit 1; }
command -v ping   >/dev/null 2>&1 || { log_err "'ping' not found.";    exit 1; }

[[ -f "$COMPOSE_FILE" ]] || { log_err "Docker Compose file not found: ${COMPOSE_FILE}"; exit 1; }

log "Checking that container '${UPF_CONTAINER}' has 'iperf' available..."
if docker ps --format '{{.Names}}' | grep -qx "${UPF_CONTAINER}"; then
    if ! docker exec "${UPF_CONTAINER}" sh -c 'command -v iperf >/dev/null 2>&1'; then
        log_err "'iperf' (iperf2) not found inside '${UPF_CONTAINER}'."
        log_err "Install it in the container image, e.g. add 'iperf' to its Dockerfile apt-get line."
        exit 1
    fi
    log_ok "'iperf' found inside '${UPF_CONTAINER}'."
else
    log_warn "Container '${UPF_CONTAINER}' is not running yet — will check again before the first iteration."
fi

log_ok "All host dependencies found."

propsim_connect
IDN=$(propsim_query "*IDN?")
log_ok "PROPSIM identified: ${IDN}"

# =============================================================================
# Configuration summary
# =============================================================================
log_step "Test Configuration (UPLINK)"
echo -e "  Test name        : ${BOLD}${TEST_NAME}${NC}"
echo -e "  Iterations       : ${BOLD}${ITERATIONS}${NC}"
echo -e "  Compose file     : ${BOLD}${COMPOSE_FILE}${NC}"
echo -e "  PROPSIM          : ${BOLD}${PROPSIM_HOST}:${PROPSIM_PORT}${NC}"
echo -e "  Direction        : ${BOLD}UE → UPF (uplink)${NC}"
echo -e "  iperf2 server    : ${BOLD}${IPERF_SERVER}:${IPERF_PORT}${NC} (inside ${UPF_CONTAINER})"
echo -e "  iperf2 client    : ${BOLD}${IPERF_CLIENT}${NC} (UE host, sending uplink)"
echo -e "  Duration / BW    : ${BOLD}${IPERF_TIME}s${NC} @ ${BOLD}${IPERF_BANDWIDTH}${NC}"
echo -e "  Output directory : ${BOLD}${OUTPUT_DIR}${NC}"

# =============================================================================
# Session setup
# =============================================================================
log_step "Session setup"
log "Starting gnb-cst (persistent across all iterations)..."
gnb_up
log "Waiting ${RAN_INIT_WAIT}s for gNB to initialise..."
sleep "$RAN_INIT_WAIT"
log_ok "gNB initialisation wait complete."

# =============================================================================
# Main loop
# =============================================================================
log_step "Starting test loop"

for (( i=1; i<=ITERATIONS; i++ )); do
    CURRENT_ITER=$i
    CSV_FILE="${OUTPUT_DIR}/${TEST_NAME}_${i}.csv"          # receiver (UPF) stats
    CLIENT_LOG="${OUTPUT_DIR}/${TEST_NAME}_${i}_client.log" # sender (UE) stats

    echo ""
    log_step "Iteration ${i} / ${ITERATIONS}"
    log "Receiver (server, in UPF) output → ${CSV_FILE}"
    log "Sender   (client, on UE)  output → ${CLIENT_LOG}"

    # ----- 1. UE up ------------------------------------------------------
    log "Step 1: Starting ue-cst..."
    ue_up

    # ----- 2. Settle -----------------------------------------------------
    log "Step 2: Waiting ${RAN_INIT_WAIT}s for UE to settle..."
    sleep "$RAN_INIT_WAIT"

    # ----- 3. PROPSIM + attach ------------------------------------------
    log "Step 3: Starting PROPSIM emulation..."
    propsim_start_emulation
    log "Waiting ${UE_ATTACH_WAIT}s for UE to attach..."
    sleep "$UE_ATTACH_WAIT"

    log "Step 3b: Checking UE connectivity (ping ${IPERF_CLIENT} → ${IPERF_SERVER})..."
    until ping -c 3 -W 2 -I "$IPERF_CLIENT" "$IPERF_SERVER" >/dev/null 2>&1; do
        log_warn "UE not connected. Recycling ue-cst for iteration ${i}..."
        propsim_send "DIAG:SIMU:GOS" || true
        sleep 1.0
        ue_down || true
        ue_up
        sleep "$RAN_INIT_WAIT"
        propsim_start_emulation
        sleep "$UE_ATTACH_WAIT"
    done
    log_ok "UE is connected."

    # ----- 4. Start the iperf2 server inside the UPF container ----------
    echo "# === Iteration ${i} — $(date '+%Y-%m-%dT%H:%M:%S') ===" >  "$CSV_FILE"
    echo "# Server (in ${UPF_CONTAINER}): iperf -s -u -B ${IPERF_SERVER} -p ${IPERF_PORT} -i 1 -f m -e" >> "$CSV_FILE"
    iperf_server_start_in_upf "$CSV_FILE"

    # ----- 5. Run the iperf2 client on the UE host ----------------------
    log "Step 5: Running iperf2 client on UE host (UDP uplink, ${IPERF_BANDWIDTH}, ${IPERF_TIME}s)..."
    echo "# === Iteration ${i} — client side — $(date '+%Y-%m-%dT%H:%M:%S') ===" > "$CLIENT_LOG"
    echo "# Client (on UE host): iperf -c ${IPERF_SERVER} -B ${IPERF_CLIENT} -u -b ${IPERF_BANDWIDTH} -p ${IPERF_PORT} -t ${IPERF_TIME} -i 1 -f m -e" >> "$CLIENT_LOG"

    iperf_ok=0
    while [[ "$iperf_ok" -eq 0 ]]; do
        if iperf \
                -c "${IPERF_SERVER}" \
                -B "${IPERF_CLIENT}" \
                -u \
                -b "${IPERF_BANDWIDTH}" \
                -p "${IPERF_PORT}" \
                -t "${IPERF_TIME}" \
                -i 1 \
                -f m \
                -e \
                >> "$CLIENT_LOG" 2>&1; then
            log_ok "iperf2 client finished. Sender stats → ${CLIENT_LOG}"
            iperf_ok=1
        else
            log_err "iperf2 client failed. Last lines of ${CLIENT_LOG}:"
            tail -n 10 "$CLIENT_LOG" | sed 's/^/    /' >&2

            log_warn "Recycling ue-cst for iteration ${i} due to iperf2 client failure..."
            iperf_server_stop_in_upf || true
            propsim_send "DIAG:SIMU:GOS" || true
            sleep 1.0
            ue_down || true
            ue_up
            sleep "$RAN_INIT_WAIT"
            propsim_start_emulation
            sleep "$UE_ATTACH_WAIT"

            log "  Re-checking UE connectivity before retrying iperf2..."
            until ping -c 3 -W 2 -I "$IPERF_CLIENT" "$IPERF_SERVER" >/dev/null 2>&1; do
                log_warn "  UE still not connected, recycling again..."
                propsim_send "DIAG:SIMU:GOS" || true
                sleep 1.0
                ue_down || true
                ue_up
                sleep "$RAN_INIT_WAIT"
                propsim_start_emulation
                sleep "$UE_ATTACH_WAIT"
            done
            log_ok "  UE reconnected. Restarting iperf2 server and retrying client."
            iperf_server_start_in_upf "$CSV_FILE"
        fi
    done

    # ----- 6. Stop the iperf2 server (flushes final summary) ------------
    log "Step 6: Stopping iperf2 server to capture summary line..."
    iperf_server_stop_in_upf

    # ----- 7. Rewind PROPSIM --------------------------------------------
    log "Step 7: Rewinding emulation timeline..."
    propsim_rewind_emulation

    # ----- 8. UE down ---------------------------------------------------
    log "Step 8: Stopping ue-cst..."
    ue_down

    log_ok "Iteration ${i} complete."
done

# =============================================================================
# Teardown
# =============================================================================
log_step "Session teardown"
log "Stopping gnb-cst..."; gnb_down
log "Disconnecting from PROPSIM..."; propsim_disconnect

log_step "All iterations complete"
log_ok "Test '${TEST_NAME}' finished. ${ITERATIONS} iterations run."
log_ok "Receiver CSVs : ${OUTPUT_DIR}/${TEST_NAME}_*.csv"
log_ok "Sender logs   : ${OUTPUT_DIR}/${TEST_NAME}_*_client.log"