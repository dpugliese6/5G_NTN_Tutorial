#!/usr/bin/env bash
# =============================================================================
# Dome Throughput Test Automation Script — iperf3 variant
#
# Topology:
#   * iperf3 server runs inside the UPF container (persistent across iterations)
#   * iperf3 client runs on the UE host, using -R to reverse direction so the
#     UPF sends and the UE receives — i.e. downlink.
#
# Caveat (carried over from the iperf2 port's docstring): iperf3 maintains a
# TCP control channel between client and server even for UDP tests. Over a
# degraded radio link emulated by PROPSIM, this control channel can drop at
# the end of the test ("unable to receive results"). We handle that the same
# way the iperf2 script handled iperf client failures: retry the iteration
# after recycling the UE. If you see these retries dominate, switch back to
# the iperf2 variant.
#
# Session setup (once):
#   * Start oai-gnb (kept up across all iterations)
#   * Start the iperf3 server inside the UPF container (kept up across all
#     iterations — the server bind address ${IPERF_SERVER} lives in the UPF
#     and is independent of UE lifecycle)
#
# Per iteration:
#   1. Start oai-nr-ue container
#   2. Wait 45s for the RAN to (re)attach
#   3. Start the PROPSIM emulation and wait for UE attach
#   4. Ping the UPF from the UE address; if it fails, restart the iteration
#   5. Run iperf3 client on the UE host with -R (downlink) → JSON output
#   6. Rewind PROPSIM, stop oai-nr-ue
#
# Session teardown:
#   * Stop the iperf3 server in the UPF container
#   * Stop and remove oai-gnb
#
# Usage:
#   ./throughput_dl_udp_iperf3.sh --name <test_name> [options]
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
TEST_NAME=""
ITERATIONS=10
PROPSIM_HOST="172.31.19.38"
PROPSIM_PORT=3334
IPERF_SERVER="192.168.100.1"     # UPF-side address (iperf3 server bind addr)
IPERF_CLIENT="192.168.100.3"     # UE-side address (iperf3 client source)
IPERF_PORT=5202
IPERF_TIME=100
IPERF_BANDWIDTH="50M"
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
gnb_up()   { log "  Starting oai-gnb...";    docker compose -f "$COMPOSE_FILE" up -d oai-gnb; log_ok "  oai-gnb started."; }
gnb_down() {
    log "  Stopping oai-gnb...";
    docker compose -f "$COMPOSE_FILE" stop oai-gnb 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" rm -f oai-gnb 2>/dev/null || true
    log_ok "  oai-gnb stopped and removed."
}
ue_up()    { log "  Starting oai-nr-ue...";     docker compose -f "$COMPOSE_FILE" up -d oai-nr-ue;  log_ok "  oai-nr-ue started."; }
ue_down() {
    log "  Stopping oai-nr-ue..."
    docker compose -f "$COMPOSE_FILE" stop oai-nr-ue 2>/dev/null || true
    docker compose -f "$COMPOSE_FILE" rm -f oai-nr-ue 2>/dev/null || true
    log_ok "  oai-nr-ue stopped and removed."
}

# =============================================================================
# iperf3 server inside the UPF container
#
# We run a single long-lived server for the whole session. The bind address
# ${IPERF_SERVER} lives in the UPF container's network namespace and is
# unaffected by UE bring-up/tear-down, so there's no need to restart it per
# iteration.
# =============================================================================
IPERF_SERVER_CONTAINER_PID=""

iperf_server_start_upf() {
    # Kill any stale server inside the container on this port
    docker exec "${UPF_CONTAINER}" sh -c "pkill -f 'iperf3 -s.*-p ${IPERF_PORT}' 2>/dev/null || true" || true
    sleep 0.3

    log "  Starting iperf3 server inside '${UPF_CONTAINER}' (bind ${IPERF_SERVER}:${IPERF_PORT})..."
    # -s server, -B bind, -p port, -D daemonise so docker exec returns
    docker exec -d "${UPF_CONTAINER}" iperf3 -s -B "${IPERF_SERVER}" -p "${IPERF_PORT}"
    sleep 0.5

    if docker exec "${UPF_CONTAINER}" sh -c "pgrep -f 'iperf3 -s.*-p ${IPERF_PORT}' >/dev/null 2>&1"; then
        log_ok "  iperf3 server running inside '${UPF_CONTAINER}'."
    else
        log_err "  iperf3 server failed to start inside '${UPF_CONTAINER}'."
        return 1
    fi
}

iperf_server_stop_upf() {
    log "  Stopping iperf3 server inside '${UPF_CONTAINER}'..."
    docker exec "${UPF_CONTAINER}" sh -c "pkill -f 'iperf3 -s.*-p ${IPERF_PORT}' 2>/dev/null || true" || true
    log_ok "  iperf3 server stopped."
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
    iperf_server_stop_upf || true
    log "Stopping oai-nr-ue...";  ue_down  || true
    log "Stopping oai-gnb..."; gnb_down || true
    log_warn "Cleanup complete. Exiting."
    exit 1
}
trap cleanup INT TERM

# =============================================================================
# Pre-flight checks
# =============================================================================
log_step "Pre-flight checks"
command -v docker >/dev/null 2>&1 || { log_err "'docker' not found.";  exit 1; }
command -v iperf3 >/dev/null 2>&1 || { log_err "'iperf3' not found. Install with: apt install iperf3"; exit 1; }
command -v ping   >/dev/null 2>&1 || { log_err "'ping' not found.";    exit 1; }
command -v jq     >/dev/null 2>&1 || log_warn "'jq' not found — JSON outputs will still be written, but the post-run quick-summary will be skipped."

[[ -f "$COMPOSE_FILE" ]] || { log_err "Docker Compose file not found: ${COMPOSE_FILE}"; exit 1; }

# Verify the UPF container will have iperf3 available. We don't try to install
# it; we just fail fast if it's missing. The UPF needs to be up to check, so
# we'll re-check after gnb_up brings the stack up; for now warn if it's down.
log "Checking that container '${UPF_CONTAINER}' has 'iperf3' available..."
if docker ps --format '{{.Names}}' | grep -qx "${UPF_CONTAINER}"; then
    if ! docker exec "${UPF_CONTAINER}" sh -c 'command -v iperf3 >/dev/null 2>&1'; then
        log_err "'iperf3' not found inside '${UPF_CONTAINER}'."
        log_err "Install it in the container image, e.g. add 'iperf3' to its Dockerfile apt-get line."
        exit 1
    fi
    log_ok "'iperf3' found inside '${UPF_CONTAINER}'."
else
    log_warn "Container '${UPF_CONTAINER}' is not running yet — will check again after session setup."
fi

log_ok "All host dependencies found."

propsim_connect
IDN=$(propsim_query "*IDN?")
log_ok "PROPSIM identified: ${IDN}"

# =============================================================================
# Configuration summary
# =============================================================================
log_step "Test Configuration"
echo -e "  Test name        : ${BOLD}${TEST_NAME}${NC}"
echo -e "  Iterations       : ${BOLD}${ITERATIONS}${NC}"
echo -e "  Compose file     : ${BOLD}${COMPOSE_FILE}${NC}"
echo -e "  PROPSIM          : ${BOLD}${PROPSIM_HOST}:${PROPSIM_PORT}${NC}"
echo -e "  UPF container    : ${BOLD}${UPF_CONTAINER}${NC} (iperf3 SERVER)"
echo -e "  iperf3 server    : ${BOLD}${IPERF_SERVER}:${IPERF_PORT}${NC} (inside UPF)"
echo -e "  iperf3 client    : ${BOLD}${IPERF_CLIENT}${NC} (UE host, downlink via -R)"
echo -e "  Duration / BW    : ${BOLD}${IPERF_TIME}s${NC} @ ${BOLD}${IPERF_BANDWIDTH}${NC}"
echo -e "  Output directory : ${BOLD}${OUTPUT_DIR}${NC}"

# =============================================================================
# Session setup
# =============================================================================
log_step "Session setup"
log "Starting oai-gnb (persistent across all iterations)..."
gnb_up
log "Waiting ${RAN_INIT_WAIT}s for gNB to initialise..."
sleep "$RAN_INIT_WAIT"
log_ok "gNB initialisation wait complete."

# Re-check iperf3 in the UPF container now that the stack is up. If the UPF
# wasn't running at the pre-flight stage, this is the authoritative check.
if ! docker ps --format '{{.Names}}' | grep -qx "${UPF_CONTAINER}"; then
    log_err "Container '${UPF_CONTAINER}' is not running after session setup. Aborting."
    exit 1
fi
if ! docker exec "${UPF_CONTAINER}" sh -c 'command -v iperf3 >/dev/null 2>&1'; then
    log_err "'iperf3' not found inside '${UPF_CONTAINER}'. Aborting."
    exit 1
fi

log "Starting iperf3 server inside UPF (persistent across all iterations)..."
iperf_server_start_upf

# =============================================================================
# Main loop
# =============================================================================
log_step "Starting test loop"

for (( i=1; i<=ITERATIONS; i++ )); do
    CURRENT_ITER=$i
    JSON_FILE="${OUTPUT_DIR}/${TEST_NAME}_${i}.json"
    CLIENT_LOG="${OUTPUT_DIR}/${TEST_NAME}_${i}_client.log"

    echo ""
    log_step "Iteration ${i} / ${ITERATIONS}"
    log "Client JSON output  → ${JSON_FILE}"
    log "Client stderr/log   → ${CLIENT_LOG}"

    # ----- 1. UE up ------------------------------------------------------
    log "Step 1: Starting oai-nr-ue..."
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
        log_warn "UE not connected. Recycling oai-nr-ue for iteration ${i}..."
        propsim_send "DIAG:SIMU:GOS" || true
        sleep 1.0
        ue_down || true
        ue_up
        sleep "$RAN_INIT_WAIT"
        propsim_start_emulation
        sleep "$UE_ATTACH_WAIT"
    done
    log_ok "UE is connected."

    # ----- 4. Run the iperf3 client from the UE host --------------------
    # -R reverses direction: the UPF-side server sends, the UE-side client
    # receives — i.e. this is downlink. -J emits a single JSON object with
    # both per-interval and summary stats. --get-server-output appends the
    # receiver-side view (which on -R is the UPF side, i.e. sender stats).
    log "Step 4: Running iperf3 client on UE host (UDP, ${IPERF_BANDWIDTH}, ${IPERF_TIME}s, downlink via -R)..."
    echo "# === Iteration ${i} — client side — $(date '+%Y-%m-%dT%H:%M:%S') ===" > "$CLIENT_LOG"
    echo "# Client: iperf3 -c ${IPERF_SERVER} -B ${IPERF_CLIENT} -u -b ${IPERF_BANDWIDTH} -p ${IPERF_PORT} -t ${IPERF_TIME} -i 1 -R -J --get-server-output" >> "$CLIENT_LOG"

    iperf3_ok=0
    while [[ "$iperf3_ok" -eq 0 ]]; do
        if iperf3 \
                -c "${IPERF_SERVER}" \
                -B "${IPERF_CLIENT}" \
                -u \
                -b "${IPERF_BANDWIDTH}" \
                -p "${IPERF_PORT}" \
                -t "${IPERF_TIME}" \
                -i 1 \
                -R \
                -J \
                --get-server-output \
                > "$JSON_FILE" 2>> "$CLIENT_LOG"; then
            log_ok "iperf3 client finished. JSON → ${JSON_FILE}"
            iperf3_ok=1
        else
            log_err "iperf3 client failed. Last lines of ${CLIENT_LOG}:"
            tail -n 10 "$CLIENT_LOG" | sed 's/^/    /' >&2

            log_warn "Recycling oai-nr-ue for iteration ${i} due to iperf3 client failure..."
            propsim_send "DIAG:SIMU:GOS" || true
            sleep 1.0
            ue_down || true
            ue_up
            sleep "$RAN_INIT_WAIT"
            propsim_start_emulation
            sleep "$UE_ATTACH_WAIT"

            log "  Re-checking UE connectivity before retrying iperf3..."
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
            log_ok "  UE reconnected. Retrying iperf3 client."

            # Make sure the server inside the UPF didn't die (it shouldn't,
            # but be defensive — control-channel teardown can leave it in
            # an odd state in rare cases).
            if ! docker exec "${UPF_CONTAINER}" sh -c "pgrep -f 'iperf3 -s.*-p ${IPERF_PORT}' >/dev/null 2>&1"; then
                log_warn "  iperf3 server in UPF is no longer running — restarting it."
                iperf_server_start_upf
            fi
        fi
    done

    # ----- 5. Rewind PROPSIM --------------------------------------------
    log "Step 5: Rewinding emulation timeline..."
    propsim_rewind_emulation

    # ----- 6. UE down ---------------------------------------------------
    log "Step 6: Stopping oai-nr-ue..."
    ue_down

    # Optional quick-summary line if jq is present
    if command -v jq >/dev/null 2>&1; then
        if mbps=$(jq -r '.end.sum.bits_per_second / 1e6 | floor' "$JSON_FILE" 2>/dev/null) \
           && lost=$(jq -r '.end.sum.lost_percent // 0' "$JSON_FILE" 2>/dev/null); then
            log_ok "Iteration ${i} complete — ${mbps} Mbps, ${lost}% lost."
        else
            log_ok "Iteration ${i} complete."
        fi
    else
        log_ok "Iteration ${i} complete."
    fi
done

# =============================================================================
# Teardown
# =============================================================================
log_step "Session teardown"
log "Stopping iperf3 server in UPF..."; iperf_server_stop_upf
log "Stopping oai-gnb...";              gnb_down
log "Disconnecting from PROPSIM...";    propsim_disconnect

log_step "All iterations complete"
log_ok "Test '${TEST_NAME}' finished. ${ITERATIONS} iterations run."
log_ok "JSON results : ${OUTPUT_DIR}/${TEST_NAME}_*.json"
log_ok "Client logs  : ${OUTPUT_DIR}/${TEST_NAME}_*_client.log"