#!/usr/bin/env bash
# =============================================================================
# Dome Throughput Test Automation Script — iperf3 DOWNLINK TCP
#
# Runs a series of downlink TCP throughput tests via iperf3, cycling only the
# OAI RAN UE container (ue-cst) and a PROPSIM channel emulation (controlled
# remotely via its ATE LAN interface) for each iteration. The gNB container
# (gnb-cst) is kept running for the whole session, and the iperf3 server is
# started once inside the upf container at the beginning.
#
# Direction & topology:
#   * iperf3 SERVER runs inside the UPF container (started once at session start)
#   * iperf3 CLIENT runs on the UE host, bound to ${IPERF_CLIENT}, with -R
#     to reverse the data direction (server → client = downlink)
#   * Protocol: TCP (iperf3's default). No -u, no -b.
#
#   The client (UE side) is the receiver under -R, so the client-side stdout
#   contains the authoritative downlink throughput numbers and is written to
#   the CSV.
#
# Note on iperf3's TCP control channel:
#   iperf3 keeps a TCP control connection open between client and server even
#   for UDP tests, and uses it to exchange final results. Over a degraded
#   PROPSIM link this can occasionally drop at the end with
#   "unable to receive results". For TCP tests the client is the receiver
#   under -R, so its own per-second stats are already in the CSV by the time
#   the control channel might fail. We treat that specific stderr message as
#   success and only retry on real errors.
#
# Session setup (once):
#   * Start gnb-cst (kept up across all iterations)
#   * Start the iperf3 server in the upf container:
#       docker exec -d upf iperf3 -s -p <iperf-port>
#
# Per iteration:
#   1. Start ue-cst container
#   2. Wait 45s for the RAN to (re)attach
#   3. Start the PROPSIM emulation and wait 5s for UE attach
#   4. Ping the iperf3 server from the UE address; if it fails, restart
#      the iteration (rewind emulation, recycle ue-cst, retry)
#   5. Run iperf3 (TCP, downlink via -R) and append output to
#      <name>_<iteration>.csv
#   6. Rewind the PROPSIM emulation timeline to the start (DIAG:SIMU:GOS)
#   7. Stop and remove the ue-cst container
#
# Session teardown:
#   * Stop and remove gnb-cst
#   * Kill the iperf3 server inside upf
#
# Usage:
#   ./throughput_dl_tcp_iperf3.sh --name <test_name> [options]
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
TEST_NAME=""
ITERATIONS=4
PROPSIM_HOST="172.31.19.38"
PROPSIM_PORT=3334
IPERF_SERVER="192.168.100.1"
IPERF_CLIENT="192.168.100.3"
IPERF_PORT=5202
IPERF_TIME=100
UPF_CONTAINER="upf"
COMPOSE_FILE="docker-compose_ran.yaml"
OUTPUT_DIR="."

RAN_INIT_WAIT=45        # seconds to wait for RAN to come up
UE_ATTACH_WAIT=10        # seconds to wait after starting emulation
PROPSIM_TIMEOUT=10      # TCP read timeout for PROPSIM ATE queries
MAX_IPERF_RETRIES=5     # max iperf3 attempts per iteration before giving up
IPERF_TIMEOUT_GRACE=30  # extra seconds on top of IPERF_TIME before the iperf3 client is hard-killed

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
        --upf-container)  UPF_CONTAINER="$2";   shift 2 ;;
        --compose-file)   COMPOSE_FILE="$2";    shift 2 ;;
        --output-dir)     OUTPUT_DIR="$2";      shift 2 ;;
        --max-retries)    MAX_IPERF_RETRIES="$2"; shift 2 ;;
        --timeout-grace)  IPERF_TIMEOUT_GRACE="$2"; shift 2 ;;
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
# iperf3 server on UPF
# Start once at the beginning (detached inside the upf container), kill at
# session teardown / interrupt.
# =============================================================================
iperf_server_start() {
    log "  Checking that container '${UPF_CONTAINER}' is running..."
    if ! docker ps --format '{{.Names}}' | grep -qx "${UPF_CONTAINER}"; then
        log_err "  Container '${UPF_CONTAINER}' is not running."
        log_err "  Bring the core network up first (it must expose '${UPF_CONTAINER}')."
        return 1
    fi

    log "  Killing any stale iperf3 server inside '${UPF_CONTAINER}'..."
    docker exec "${UPF_CONTAINER}" sh -c "pkill -f 'iperf3 -s' || true" 2>/dev/null || true
    sleep 0.5

    log "  Starting iperf3 server inside '${UPF_CONTAINER}' on port ${IPERF_PORT}..."
    docker exec -d "${UPF_CONTAINER}" iperf3 -s -p "${IPERF_PORT}"
    sleep 1

    if docker exec "${UPF_CONTAINER}" sh -c "pgrep -f 'iperf3 -s -p ${IPERF_PORT}' >/dev/null"; then
        log_ok "  iperf3 server is running inside '${UPF_CONTAINER}' on port ${IPERF_PORT}."
    else
        log_err "  iperf3 server failed to start inside '${UPF_CONTAINER}'."
        return 1
    fi
}

iperf_server_stop() {
    if docker ps --format '{{.Names}}' | grep -qx "${UPF_CONTAINER}"; then
        log "  Killing iperf3 server inside '${UPF_CONTAINER}'..."
        docker exec "${UPF_CONTAINER}" sh -c "pkill -f 'iperf3 -s' || true" 2>/dev/null || true
        log_ok "  iperf3 server stopped."
    else
        log_warn "  Container '${UPF_CONTAINER}' no longer running — skipping iperf3 stop."
    fi
}

# Hard-restart the iperf3 server inside the UPF. Needed when the server gets
# stuck thinking a previous client is still running a test ("the server is
# busy running a test"), which happens when a control connection dies
# abnormally over a degraded link.
iperf_server_restart() {
    log "  Hard-restarting iperf3 server inside '${UPF_CONTAINER}'..."
    iperf_server_stop || true
    sleep 1
    iperf_server_start
}

# =============================================================================
# Cleanup on exit / interrupt
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
    log "Stopping ue-cst...";  ue_down  || true
    log "Stopping gnb-cst..."; gnb_down || true
    log "Stopping iperf3 server on upf..."
    iperf_server_stop || true
    log_warn "Cleanup complete. Exiting."
    exit 1
}
trap cleanup INT TERM

# =============================================================================
# Pre-flight checks
# =============================================================================
log_step "Pre-flight checks"

command -v docker  >/dev/null 2>&1 || { log_err "'docker' not found.";   exit 1; }
command -v iperf3  >/dev/null 2>&1 || { log_err "'iperf3' not found.";   exit 1; }
command -v ping    >/dev/null 2>&1 || { log_err "'ping' not found.";     exit 1; }
command -v timeout >/dev/null 2>&1 || { log_err "'timeout' not found (install coreutils)."; exit 1; }

[[ -f "$COMPOSE_FILE" ]] || { log_err "Docker Compose file not found: ${COMPOSE_FILE}"; exit 1; }

log_ok "All dependencies found."

propsim_connect
IDN=$(propsim_query "*IDN?")
log_ok "PROPSIM identified: ${IDN}"

# =============================================================================
# Configuration summary
# =============================================================================
log_step "Test Configuration (DOWNLINK TCP)"
echo -e "  Test name        : ${BOLD}${TEST_NAME}${NC}"
echo -e "  Iterations       : ${BOLD}${ITERATIONS}${NC}"
echo -e "  Compose file     : ${BOLD}${COMPOSE_FILE}${NC}"
echo -e "  PROPSIM          : ${BOLD}${PROPSIM_HOST}:${PROPSIM_PORT}${NC}"
echo -e "  Direction        : ${BOLD}UPF → UE (downlink, TCP, -R)${NC}"
echo -e "  UPF container    : ${BOLD}${UPF_CONTAINER}${NC}"
echo -e "  iperf3 server    : ${BOLD}${IPERF_SERVER}:${IPERF_PORT}${NC}"
echo -e "  iperf3 client    : ${BOLD}${IPERF_CLIENT}${NC}"
echo -e "  iperf3 duration  : ${BOLD}${IPERF_TIME}s${NC}"
echo -e "  Output directory : ${BOLD}${OUTPUT_DIR}${NC}"

# =============================================================================
# Session setup: start iperf3 server on UPF, then gnb-cst (persistent)
# =============================================================================
log_step "Session setup"

log "Starting iperf3 server on UPF..."
iperf_server_start

log "Starting gnb-cst (persistent across all iterations)..."
gnb_up

log "Waiting ${RAN_INIT_WAIT}s for gNB to initialise..."
sleep "$RAN_INIT_WAIT"
log_ok "gNB initialisation wait complete."

# =============================================================================
# Main test loop
# =============================================================================
log_step "Starting test loop"

for (( i=1; i<=ITERATIONS; i++ )); do
    CURRENT_ITER=$i
    CSV_FILE="${OUTPUT_DIR}/${TEST_NAME}_${i}.csv"

    echo ""
    log_step "Iteration ${i} / ${ITERATIONS}"
    log "Output file: ${CSV_FILE}"

    # ----- 1. Bring up the UE -------------------------------------------
    log "Step 1: Starting ue-cst..."
    ue_up

    # ----- 2. Wait for the UE / RAN to settle ---------------------------
    log "Step 2: Waiting ${RAN_INIT_WAIT}s for UE to settle..."
    sleep "$RAN_INIT_WAIT"
    log_ok "UE wait complete."

    # ----- 3. Start emulation, wait for UE attach, ping check -----------
    log "Step 3: Starting PROPSIM emulation..."
    propsim_start_emulation

    log "Waiting ${UE_ATTACH_WAIT}s for UE to attach..."
    sleep "$UE_ATTACH_WAIT"

    log "Step 3b: Checking UE connectivity (ping ${IPERF_CLIENT} → ${IPERF_SERVER})..."
    until ping -c 3 -W 2 -I "$IPERF_CLIENT" "$IPERF_SERVER" >/dev/null 2>&1; do
        log_warn "UE not connected. Recycling ue-cst for iteration ${i}..."
        propsim_send "DIAG:SIMU:GOS" || true
        sleep 1.0
        log "  Recycling ue-cst..."
        ue_down || true
        ue_up
        log "  Waiting ${RAN_INIT_WAIT}s for UE to settle..."
        sleep "$RAN_INIT_WAIT"
        log "  Restarting PROPSIM emulation..."
        propsim_start_emulation
        log "  Waiting ${UE_ATTACH_WAIT}s for UE to attach..."
        sleep "$UE_ATTACH_WAIT"
        log "  Retrying ping..."
    done
    log_ok "UE is connected. Proceeding with iperf3."

    # ----- 4. Run iperf3 (TCP, downlink via -R) -------------------------
    # The client (UE side) is the receiver under -R, so the per-second
    # lines and the final receiver-side summary printed by the client
    # are the authoritative downlink throughput.
    #
    # Retry policy (per user request):
    #   - On EVERY retry, kill and restart the iperf3 server inside UPF
    #     before reconnecting. The server has been observed to freeze in
    #     ways that don't always surface as a clean "server is busy"
    #     error, so we treat every failure as if the server might be
    #     stuck.
    #   - The iperf3 client itself is wrapped in `timeout` (IPERF_TIME +
    #     IPERF_TIMEOUT_GRACE seconds) so that a client-side freeze
    #     can't block the script indefinitely either.
    #   - "unable to receive results" / "interrupt" stderr is still
    #     treated as success — the per-second receiver data is already
    #     in the CSV at that point.
    #   - On a hard timeout from the wrapper (exit code 124), or any
    #     other non-success exit, we restart the server, recycle the UE,
    #     and try again.
    #
    # Bounded by MAX_IPERF_RETRIES so a persistently stuck setup can't
    # blow through the whole run silently.
    iperf3_ok=0
    iperf3_attempt=0
    iperf3_failed=0
    iperf3_hard_timeout=$(( IPERF_TIME + IPERF_TIMEOUT_GRACE ))

    while [[ "$iperf3_ok" -eq 0 ]]; do
        iperf3_attempt=$((iperf3_attempt + 1))
        if [[ "$iperf3_attempt" -gt "$MAX_IPERF_RETRIES" ]]; then
            log_err "iperf3 failed ${MAX_IPERF_RETRIES} times in a row on iteration ${i}. Giving up on this iteration."
            iperf3_failed=1
            break
        fi

        # --- Restart the iperf3 server before EVERY attempt -------------
        # This is the user-requested behaviour: kill any lingering server
        # state (busy/frozen/half-closed) and start fresh each time.
        log "Step 4 (attempt ${iperf3_attempt}/${MAX_IPERF_RETRIES}): Restarting iperf3 server before client run..."
        iperf_server_restart || {
            log_err "Failed to restart iperf3 server. Aborting iteration ${i}."
            iperf3_failed=1
            break
        }
        # Brief settle time so the server is fully listening before connect.
        sleep 1

        log "Step 4: Running iperf3 TCP downlink (duration: ${IPERF_TIME}s, hard timeout: ${iperf3_hard_timeout}s)..."
        echo "# === Iteration ${i} — attempt ${iperf3_attempt} — $(date '+%Y-%m-%dT%H:%M:%S') ===" >> "$CSV_FILE"
        echo "# Client: iperf3 -c ${IPERF_SERVER} -B ${IPERF_CLIENT} -p ${IPERF_PORT} -t ${IPERF_TIME} -i 1 -R" >> "$CSV_FILE"

        iperf3_err=$(mktemp)
        # `timeout --foreground` so SIGINT from our own trap still reaches
        # iperf3 if the user hits Ctrl+C while it's running. On expiry
        # (exit 124) it sends SIGTERM, then SIGKILL after a few seconds.
        set +e
        timeout --foreground --kill-after=5 "$iperf3_hard_timeout" \
            iperf3 \
                -c "$IPERF_SERVER" \
                -B "$IPERF_CLIENT" \
                -p "$IPERF_PORT"   \
                -t "$IPERF_TIME"   \
                -i 1               \
                -R                 \
                >> "$CSV_FILE" 2> "$iperf3_err"
        iperf3_rc=$?
        set -e

        iperf3_stderr_content=$(cat "$iperf3_err")
        cat "$iperf3_err" >> "$CSV_FILE"
        rm -f "$iperf3_err"

        if [[ "$iperf3_rc" -eq 0 ]]; then
            log_ok "iperf3 completed. Results appended to ${CSV_FILE}"
            iperf3_ok=1

        elif [[ "$iperf3_rc" -eq 124 ]]; then
            # Hard timeout: iperf3 client never returned within the grace
            # window. Definitely a frozen run — server WILL be restarted
            # at the top of the next loop iteration.
            log_err "iperf3 client did not finish within ${iperf3_hard_timeout}s — frozen run."
            echo "# !!! HARD TIMEOUT after ${iperf3_hard_timeout}s — run aborted by 'timeout' wrapper" >> "$CSV_FILE"
            log_warn "Will recycle UE and retry with a fresh iperf3 server on next attempt."
            # Recycle the UE too — a frozen iperf3 often coincides with
            # the radio link being in a bad state, so a clean UE attach
            # is the safest reset.
            propsim_send "DIAG:SIMU:GOS" || true
            sleep 1.0
            ue_down || true
            ue_up
            sleep "$RAN_INIT_WAIT"
            propsim_start_emulation
            sleep "$UE_ATTACH_WAIT"
            until ping -c 3 -W 2 -I "$IPERF_CLIENT" "$IPERF_SERVER" >/dev/null 2>&1; do
                log_warn "  UE not connected, recycling again..."
                propsim_send "DIAG:SIMU:GOS" || true
                sleep 1.0
                ue_down || true
                ue_up
                sleep "$RAN_INIT_WAIT"
                propsim_start_emulation
                sleep "$UE_ATTACH_WAIT"
            done

        elif echo "$iperf3_stderr_content" | grep -qE "unable to receive results|interrupt"; then
            # Control-channel drop at the end of the test — receiver-side
            # per-second data is already in the CSV.
            log_warn "iperf3 control channel dropped at end of test (receiver data already saved):"
            echo "$iperf3_stderr_content" | sed 's/^/    /' >&2
            log_ok "Treating as success — TCP receiver-side measurements are in ${CSV_FILE}"
            iperf3_ok=1

        else
            # Any other failure (server busy, connect refused, network
            # error, etc.). Server will be restarted at the top of the
            # next loop iteration. Recycle the UE as well, since we
            # can't tell from here whether it's a UE-side or a transport
            # problem — better to reset both.
            log_err "iperf3 failed (rc=${iperf3_rc}). Error output:"
            echo "$iperf3_stderr_content" | sed 's/^/    /' >&2

            log_warn "Recycling ue-cst for iteration ${i}..."
            propsim_send "DIAG:SIMU:GOS" || true
            sleep 1.0
            ue_down || true
            ue_up
            sleep "$RAN_INIT_WAIT"
            propsim_start_emulation
            sleep "$UE_ATTACH_WAIT"
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
            log_ok "  UE is connected. Will retry with a fresh iperf3 server on next attempt."
        fi
    done

    if [[ "$iperf3_failed" -eq 1 ]]; then
        echo "# !!! Iteration ${i} ABANDONED after ${MAX_IPERF_RETRIES} failed attempts !!!" >> "$CSV_FILE"
        log_warn "Iteration ${i} marked as failed. Continuing to next iteration."
    fi

    # ----- 5. Rewind emulation timeline ---------------------------------
    log "Step 5: Rewinding emulation timeline..."
    propsim_rewind_emulation

    # ----- 6. Stop & remove ue-cst (gnb-cst stays up) -------------------
    log "Step 6: Stopping ue-cst..."
    ue_down

    log_ok "Iteration ${i} complete."
done

# =============================================================================
# Session teardown
# =============================================================================
log_step "Session teardown"

log "Stopping gnb-cst..."
gnb_down

log "Stopping iperf3 server on UPF..."
iperf_server_stop

log "Disconnecting from PROPSIM..."
propsim_disconnect

log_step "All iterations complete"
log_ok "Test '${TEST_NAME}' finished. ${ITERATIONS} iterations run."
log_ok "Results saved to: ${OUTPUT_DIR}/${TEST_NAME}_*.csv"