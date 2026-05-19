#!/usr/bin/env bash
# =============================================================================
# PROPSIM Emulation Control Script
# Controls a PROPSIM channel emulator via ATE LAN interface (TCP/IP).
#
# Requires: bash, /dev/tcp (built-in), or netcat (nc) as fallback.
#
# Usage:
#   ./propsim_control.sh [--host <IP>] [--port <PORT>] <command>
#
# Commands:
#   start   Run the emulation (requires an emulation to already be loaded)
#   stop    Pause the emulation (keeps position, does not rewind)
#   reset   Stop the emulation, rewind to start, and close it
#   local   Deactivate remote mode and return the device to local GUI control
#
# Note on 'local':
#   The PROPSIM enters remote mode automatically when any ATE command is
#   received. There is no ATE command to switch back — the device returns to
#   local mode when the TCP connection is closed (per section 19.1 of the
#   manual). The 'local' command sends *CLS to clear pending status, waits for
#   *OPC?, then gracefully closes the connection, releasing the remote lock.
#
# Examples:
#   ./propsim_control.sh --host 192.168.0.1 start
#   ./propsim_control.sh --host 192.168.0.1 stop
#   ./propsim_control.sh --host 192.168.0.1 reset
#   ./propsim_control.sh --host 192.168.0.1 local
# =============================================================================

set -euo pipefail

# --- Defaults ----------------------------------------------------------------
HOST="172.31.19.38"
PORT=3334
TIMEOUT=10
COMMAND=""

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Colour

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        start|stop|reset|local) COMMAND="$1"; shift ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo -e "${RED}ERROR: Unknown argument: $1${NC}"; exit 1 ;;
    esac
done

if [[ -z "$COMMAND" ]]; then
    echo -e "${RED}ERROR: No command specified. Use: start | stop | reset | local${NC}"
    exit 1
fi

# --- Communication helpers ---------------------------------------------------
# We use a persistent TCP connection via /dev/tcp (bash built-in).
# A named pipe is used so we can read responses back.

FIFO=$(mktemp -u /tmp/propsim_fifo.XXXXXX)
mkfifo "$FIFO"

# Open connection: fd 3 = write (to PROPSIM), fd 4 = read (from PROPSIM)
exec 3<>"$FIFO" 4<>"$FIFO" 2>/dev/null || true

cleanup() {
    exec 3>&- 2>/dev/null || true
    exec 4>&- 2>/dev/null || true
    rm -f "$FIFO"
}
trap cleanup EXIT

# Open TCP socket via bash /dev/tcp
echo -e "${YELLOW}Connecting to PROPSIM at ${HOST}:${PORT}...${NC}"
exec 3<>"/dev/tcp/${HOST}/${PORT}" || {
    echo -e "${RED}ERROR: Cannot connect to ${HOST}:${PORT}${NC}"
    exit 1
}
exec 4<&3  # Use the same fd for reading

send_cmd() {
    # Send command followed by newline (ATE EOS)
    printf '%s\n' "$1" >&3
}

read_response() {
    # Read one line back with a timeout
    local response
    if read -r -t "$TIMEOUT" response <&3; then
        echo "${response}"
    else
        echo -e "${RED}ERROR: Timeout waiting for response.${NC}" >&2
        exit 1
    fi
}

query() {
    send_cmd "$1"
    read_response
}

check_error() {
    local resp
    resp=$(query "SYST:ERR?")
    if [[ "$resp" != 0* ]]; then
        echo -e "${RED}ERROR from PROPSIM: ${resp}${NC}" >&2
        exit 1
    fi
}

get_state() {
    query "DIAG:SIMU:STATE?"
}

# --- Identify device ---------------------------------------------------------
IDN=$(query "*IDN?")
echo -e "${GREEN}Connected: ${IDN}${NC}"
echo "Executing: ${COMMAND^^}"

# --- Commands ----------------------------------------------------------------

do_start() {
    local state
    state=$(get_state)
    echo "  Current state: ${state}"

    if [[ "$state" == "RUNNING" ]]; then
        echo "  Emulation is already running. Nothing to do."
        return
    fi
    if [[ "$state" == "CLOSED" ]]; then
        echo -e "${RED}  ERROR: No emulation is loaded. Open an emulation first.${NC}"
        exit 1
    fi

    send_cmd "DIAG:SIMU:GO"
    check_error
    sleep 0.5

    state=$(get_state)
    echo "  New state: ${state}"
    if [[ "$state" == "RUNNING" ]]; then
        echo -e "${GREEN}  Emulation started successfully.${NC}"
    else
        echo -e "${YELLOW}  WARNING: Expected RUNNING but got ${state}${NC}"
    fi
}

do_stop() {
    local state
    state=$(get_state)
    echo "  Current state: ${state}"

    if [[ "$state" == "STOPPED" ]]; then
        echo "  Emulation is already stopped/paused. Nothing to do."
        return
    fi
    if [[ "$state" == "CLOSED" ]]; then
        echo -e "${RED}  ERROR: No emulation is loaded.${NC}"
        exit 1
    fi

    send_cmd "DIAG:SIMU:STOP"
    check_error
    sleep 0.5

    state=$(get_state)
    echo "  New state: ${state}"
    if [[ "$state" == "STOPPED" ]]; then
        echo -e "${GREEN}  Emulation paused successfully.${NC}"
    else
        echo -e "${YELLOW}  WARNING: Expected STOPPED but got ${state}${NC}"
    fi
}

do_reset() {
    local state
    state=$(get_state)
    echo "  Current state: ${state}"

    if [[ "$state" == "CLOSED" ]]; then
        echo "  No emulation loaded. Sending *RST to clear device state."
        send_cmd "*RST"
        sleep 1.0
        echo -e "${GREEN}  Device reset complete.${NC}"
        return
    fi

    # Step 1: rewind to start
    echo "  Step 1: Rewinding emulation to start..."
    send_cmd "DIAG:SIMU:GOS"
    check_error
    sleep 0.5
    state=$(get_state)
    echo "  State after rewind: ${state}"

    # Step 2: close the emulation
    echo "  Step 2: Closing emulation..."
    send_cmd "DIAG:SIMU:CLOSE"
    check_error
    sleep 0.5
    state=$(get_state)
    echo "  State after close: ${state}"

    # Step 3: full device reset
    echo "  Step 3: Sending device reset (*RST)..."
    send_cmd "*RST"
    # *RST disconnects local user and closes emulation; no response is expected
    sleep 1.0
    echo -e "${GREEN}  Reset complete.${NC}"
}

do_local() {
    # The PROPSIM returns to local mode when the remote TCP connection is closed.
    # There is no explicit ATE command for this (section 19.1). We cleanly
    # prepare the device before dropping the connection.

    # Step 1: clear status registers
    echo "  Step 1: Clearing status registers (*CLS)..."
    send_cmd "*CLS"
    # *CLS produces no response; a short pause is sufficient
    sleep 0.2

    # Step 2: wait for all pending operations
    echo "  Step 2: Waiting for pending operations to complete (*OPC?)..."
    local opc
    opc=$(query "*OPC?")
    if [[ "$opc" == "1" ]]; then
        echo "  All operations complete."
    else
        echo -e "${YELLOW}  WARNING: Unexpected *OPC? response: ${opc}${NC}"
    fi

    # Step 3: connection close (happens in cleanup trap) releases remote lock
    echo "  Step 3: Closing connection — device will return to local mode."
    echo -e "${GREEN}  Remote mode deactivated. The PROPSIM GUI is now in local control.${NC}"
}

# --- Dispatch ----------------------------------------------------------------
case "$COMMAND" in
    start) do_start ;;
    stop)  do_stop  ;;
    reset) do_reset ;;
    local) do_local ;;
esac

echo "Connection closed."