#!/usr/bin/env bash
# =============================================================================
# Dome RTT Test Automation Script — ping from UE
#
# Runs a series of RTT (ping) tests from the UE host toward the UPF, cycling
# only the OAI RAN UE container (ue-cst) and the PROPSIM channel emulation
# for each iteration. The gNB container (gnb-cst) is kept running for the
# whole session.
#
# Unlike the throughput tests, there is no server-side process to manage —
# ICMP echo is handled by the kernel of whatever is at ${IPERF_SERVER}
# (typically the UPF container). All measurement happens on the UE host
# side, where ping prints per-packet RTT lines and a final summary block.
#
# Session setup (once):
#   * Start gnb-cst (kept up across all iterations)
#
# Per iteration:
#   1. Start ue-cst container
#   2. Wait 45s for the RAN to (re)attach
#   3. Start the PROPSIM emulation and wait 5s for UE attach
#   4. Reachability check (a few slow pings); if it fails, recycle UE
#   5. Run the actual RTT measurement: ping -c N -i INTERVAL from
#      ${IPERF_CLIENT} to ${IPERF_SERVER}, full output → <name>_<i>.csv
#   6. Append a parsed summary block (min/avg/max/mdev + loss%) to the CSV
#   7. Rewind the PROPSIM emulation timeline
#   8. Stop and remove ue-cst
#
# Session teardown:
#   * Stop and remove gnb-cst
#
# Usage:
#   ./rtt_ping.sh --name <test_name> [options]
#
# Options:
#   --name <name>            Base name for output CSV files (required)
#   --iterations <n>         Number of test iterations         (default: 10)
#   --host <ip>              PROPSIM IP address                (default: 172.31.19.38)
#   --port <port>            PROPSIM ATE port                  (default: 3334)
#   --iperf-server <ip>      Ping target (UPF side)            (default: 192.168.100.1)
#   --iperf-client <ip>      Ping source bind addr (UE side)   (default: 192.168.100.3)
#   --ping-count <n>         Packets per iteration             (default: 500)
#   --ping-interval <sec>    Inter-packet interval (seconds)   (default: 0.2)
#   --ping-timeout <sec>     Per-packet wait timeout (-W)      (default: 2)
#   --compose-file <f>       Docker Compose file               (default: docker-compose_ran.yaml)
#   --output-dir <dir>       Directory for CSV output files    (default: .)
#   --max-retries <n>        Max ping attempts per iteration   (default: 5)
#   -h | --help              Show this help message
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
TEST_NAME=""
ITERATIONS=10
PROPSIM_HOST="172.31.19.38"
PROPSIM_PORT=3334
IPERF_SERVER="192.168.100.1"   # ping target
IPERF_CLIENT="192.168.100.3"   # ping source bind address
PING_COUNT=5000
PING_INTERVAL="0.02"
PING_TIMEOUT=2
COMPOSE_FILE="docker-compose_ran.yaml"
OUTPUT_DIR="."

RAN_INIT_WAIT=45        # seconds to wait for RAN to come up
UE_ATTACH_WAIT=5        # seconds to wait after starting emulation
PROPSIM_TIMEOUT=10      # TCP read timeout for PROPSIM ATE queries
MAX_PING_RETRIES=5      # max ping attempts per iteration before giving up

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
        --name)            TEST_NAME="$2";       shift 2 ;;
        --iterations)      ITERATIONS="$2";      shift 2 ;;
        --host)            PROPSIM_HOST="$2";    shift 2 ;;
        --port)            PROPSIM_PORT="$2";    shift 2 ;;
        --iperf-server)    IPERF_SERVER="$2";    shift 2 ;;
        --iperf-client)    IPERF_CLIENT="$2";    shift 2 ;;
        --ping-count)      PING_COUNT="$2";      shift 2 ;;
        --ping-interval)   PING_INTERVAL="$2";   shift 2 ;;
        --ping-timeout)    PING_TIMEOUT="$2";    shift 2 ;;
        --compose-file)    COMPOSE_FILE="$2";    shift 2 ;;
        --output-dir)      OUTPUT_DIR="$2";      shift 2 ;;
        --max-retries)     MAX_PING_RETRIES="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) log_err "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -z "$TEST_NAME" ]] && { log_err "--name is required."; exit 1; }
mkdir -p "$OUTPUT_DIR"

# Sanity-check ping interval: Linux ping requires root for intervals < 0.2s.
# At exactly 0.2s, regular users are usually fine, but we warn rather than
# silently fall back to ping's own minimum.
ping_interval_too_fast() {
    # awk handles floating-point comparison portably
    awk -v i="$PING_INTERVAL" 'BEGIN { exit !(i < 0.2) }'
}
if ping_interval_too_fast && [[ "$(id -u)" -ne 0 ]]; then
    log_warn "ping interval ${PING_INTERVAL}s < 0.2s usually requires root on Linux."
    log_warn "You may see 'ping: cannot flood; minimal interval allowed for user is 200ms'."
    log_warn "Re-run with sudo if you need a faster interval."
fi

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
# Helper: parse ping output into a CSV summary block
#
# Standard `ping` output ends with:
#   --- <host> ping statistics ---
#   N packets transmitted, M received, X% packet loss, time TTTms
#   rtt min/avg/max/mdev = a/b/c/d ms
#
# This helper extracts those fields and writes a normalized
# comma-separated line, plus a comment header. It also extracts each
# per-packet "time=X ms" line into a one-RTT-per-line block so the CSV
# is trivial to load into pandas / Excel.
# =============================================================================
append_ping_summary() {
    local raw_file="$1"      # file containing the raw ping output
    local out_file="$2"      # CSV to append to
    local iteration="$3"

    # Extract per-packet RTTs (icmp_seq, ttl, time_ms)
    {
        echo ""
        echo "# --- per-packet RTTs (iteration ${iteration}) ---"
        echo "icmp_seq,ttl,rtt_ms"
        # Lines look like:
        #   64 bytes from 192.168.100.1: icmp_seq=1 ttl=64 time=12.3 ms
        grep -E 'icmp_seq=' "$raw_file" \
            | sed -E 's/.*icmp_seq=([0-9]+).*ttl=([0-9]+).*time=([0-9.]+).*/\1,\2,\3/' \
            || true
    } >> "$out_file"

    # Extract the summary line(s)
    local stats_line rtt_line
    stats_line=$(grep -E 'packets transmitted' "$raw_file" || true)
    rtt_line=$(grep -E 'rtt min/avg/max' "$raw_file" || true)

    local sent recv loss_pct min avg max mdev
    if [[ -n "$stats_line" ]]; then
        # "N packets transmitted, M received, X% packet loss, time Tms"
        sent=$(echo "$stats_line"  | sed -E 's/^([0-9]+) packets transmitted.*/\1/')
        recv=$(echo "$stats_line"  | sed -E 's/.*, ([0-9]+) received.*/\1/')
        loss_pct=$(echo "$stats_line" | sed -E 's/.*, ([0-9.]+)% packet loss.*/\1/')
    else
        sent=""; recv=""; loss_pct=""
    fi

    if [[ -n "$rtt_line" ]]; then
        # "rtt min/avg/max/mdev = a/b/c/d ms"
        local values
        values=$(echo "$rtt_line" | sed -E 's|.*= ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+).*|\1,\2,\3,\4|')
        min=$(echo  "$values" | cut -d, -f1)
        avg=$(echo  "$values" | cut -d, -f2)
        max=$(echo  "$values" | cut -d, -f3)
        mdev=$(echo "$values" | cut -d, -f4)
    else
        min=""; avg=""; max=""; mdev=""
    fi

    {
        echo ""
        echo "# --- summary (iteration ${iteration}) ---"
        echo "iteration,sent,received,loss_pct,rtt_min_ms,rtt_avg_ms,rtt_max_ms,rtt_mdev_ms"
        echo "${iteration},${sent},${recv},${loss_pct},${min},${avg},${max},${mdev}"
    } >> "$out_file"
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
    log_warn "Cleanup complete. Exiting."
    exit 1
}
trap cleanup INT TERM

# =============================================================================
# Pre-flight checks
# =============================================================================
log_step "Pre-flight checks"

command -v docker >/dev/null 2>&1 || { log_err "'docker' not found.";  exit 1; }
command -v ping   >/dev/null 2>&1 || { log_err "'ping' not found.";    exit 1; }
[[ -f "$COMPOSE_FILE" ]] || { log_err "Docker Compose file not found: ${COMPOSE_FILE}"; exit 1; }

log_ok "All dependencies found."

propsim_connect
IDN=$(propsim_query "*IDN?")
log_ok "PROPSIM identified: ${IDN}"

# =============================================================================
# Configuration summary
# =============================================================================
log_step "Test Configuration (RTT / ping)"
echo -e "  Test name        : ${BOLD}${TEST_NAME}${NC}"
echo -e "  Iterations       : ${BOLD}${ITERATIONS}${NC}"
echo -e "  Compose file     : ${BOLD}${COMPOSE_FILE}${NC}"
echo -e "  PROPSIM          : ${BOLD}${PROPSIM_HOST}:${PROPSIM_PORT}${NC}"
echo -e "  Direction        : ${BOLD}UE → UPF (ICMP echo)${NC}"
echo -e "  Source / bind    : ${BOLD}${IPERF_CLIENT}${NC}"
echo -e "  Target           : ${BOLD}${IPERF_SERVER}${NC}"
echo -e "  Packets / iter   : ${BOLD}${PING_COUNT}${NC} @ ${BOLD}${PING_INTERVAL}s${NC} interval"
echo -e "  Est. duration    : ${BOLD}~$(awk -v c="$PING_COUNT" -v i="$PING_INTERVAL" 'BEGIN { printf "%.1f", c*i }')s${NC} per iteration"
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

    # ----- 3. Start emulation, wait for UE attach, reachability check ---
    log "Step 3: Starting PROPSIM emulation..."
    propsim_start_emulation

    log "Waiting ${UE_ATTACH_WAIT}s for UE to attach..."
    sleep "$UE_ATTACH_WAIT"

    log "Step 3b: Reachability check (slow ping ${IPERF_CLIENT} → ${IPERF_SERVER})..."
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
    log_ok "UE is reachable. Proceeding with RTT measurement."

    # ----- 4. Run the actual ping measurement ---------------------------
    # Retry on failure (e.g. transient unreachability mid-test), bounded
    # by MAX_PING_RETRIES. ping's exit code is 0 only if at least one
    # reply was received and (for -c N) it ran to completion. A non-zero
    # exit means we should reset and try again.
    ping_ok=0
    ping_attempt=0
    ping_failed=0
    while [[ "$ping_ok" -eq 0 ]]; do
        ping_attempt=$((ping_attempt + 1))
        if [[ "$ping_attempt" -gt "$MAX_PING_RETRIES" ]]; then
            log_err "ping failed ${MAX_PING_RETRIES} times in a row on iteration ${i}. Giving up on this iteration."
            ping_failed=1
            break
        fi

        log "Step 4: Running ping (attempt ${ping_attempt}/${MAX_PING_RETRIES}, ${PING_COUNT} packets @ ${PING_INTERVAL}s)..."
        echo "# === Iteration ${i} — attempt ${ping_attempt} — $(date '+%Y-%m-%dT%H:%M:%S') ===" >> "$CSV_FILE"
        echo "# Command: ping -c ${PING_COUNT} -i ${PING_INTERVAL} -W ${PING_TIMEOUT} -I ${IPERF_CLIENT} ${IPERF_SERVER}" >> "$CSV_FILE"

        ping_raw=$(mktemp)
        set +e
        ping -c "$PING_COUNT" \
             -i "$PING_INTERVAL" \
             -W "$PING_TIMEOUT" \
             -I "$IPERF_CLIENT" \
             "$IPERF_SERVER" \
             > "$ping_raw" 2>&1
        ping_rc=$?
        set -e

        # Always preserve the raw ping output in the CSV for inspection.
        echo "# --- raw ping output ---" >> "$CSV_FILE"
        cat "$ping_raw" >> "$CSV_FILE"

        if [[ "$ping_rc" -eq 0 ]]; then
            log_ok "ping completed (rc=0)."
            append_ping_summary "$ping_raw" "$CSV_FILE" "$i"
            rm -f "$ping_raw"
            ping_ok=1
        else
            log_err "ping failed (rc=${ping_rc}). Tail of output:"
            tail -n 5 "$ping_raw" | sed 's/^/    /' >&2
            # Still append a summary block; if some packets did get through
            # it will reflect partial measurement, otherwise the fields
            # will be empty.
            append_ping_summary "$ping_raw" "$CSV_FILE" "$i"
            rm -f "$ping_raw"

            log_warn "Recycling ue-cst for iteration ${i} due to ping failure..."
            propsim_send "DIAG:SIMU:GOS" || true
            sleep 1.0
            ue_down || true
            ue_up
            sleep "$RAN_INIT_WAIT"
            propsim_start_emulation
            sleep "$UE_ATTACH_WAIT"

            log "  Re-checking UE reachability before retrying ping..."
            until ping -c 3 -W 2 -I "$IPERF_CLIENT" "$IPERF_SERVER" >/dev/null 2>&1; do
                log_warn "  UE still not reachable, recycling again..."
                propsim_send "DIAG:SIMU:GOS" || true
                sleep 1.0
                ue_down || true
                ue_up
                sleep "$RAN_INIT_WAIT"
                propsim_start_emulation
                sleep "$UE_ATTACH_WAIT"
            done
            log_ok "  UE is reachable. Retrying ping."
        fi
    done

    if [[ "$ping_failed" -eq 1 ]]; then
        echo "# !!! Iteration ${i} ABANDONED after ${MAX_PING_RETRIES} failed attempts !!!" >> "$CSV_FILE"
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

log "Disconnecting from PROPSIM..."
propsim_disconnect

log_step "All iterations complete"
log_ok "Test '${TEST_NAME}' finished. ${ITERATIONS} iterations run."
log_ok "Results saved to: ${OUTPUT_DIR}/${TEST_NAME}_*.csv"