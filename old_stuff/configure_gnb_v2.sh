#!/bin/bash

# Script to configure gnb_template.conf with values from JSON files
# Interactive menu to select configuration files

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "  Ubuntu/Debian: sudo apt-get install jq"
    echo "  macOS: brew install jq"
    exit 1
fi

# Function to display header
display_header() {
    clear
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}    gNB Configuration Tool - Interactive Menu${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo ""
}

# Function to list files in a directory and let user select
select_file() {
    local dir="$1"
    local description="$2"
    local files=()
    
    # Check if directory exists
    if [ ! -d "$dir" ]; then
        echo -e "${RED}Error: Directory not found: $dir${NC}" >&2
        return 1
    fi
    
    # Get list of JSON files
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$dir" -maxdepth 2 -name "*.json" | sort)
    
    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}Error: No JSON files found in $dir${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}Select $description:${NC}" >&2
    echo "" >&2
    
    # Display numbered list
    for i in "${!files[@]}"; do
        local filename=$(basename "${files[$i]}")
        printf "  ${GREEN}%2d)${NC} %s\n" $((i+1)) "$filename" >&2
    done
    echo "" >&2
    
    # Get user selection
    local selection=""
    while true; do
        read -p "Enter number (1-${#files[@]}): " selection >&2
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#files[@]} ]; then
            echo "${files[$((selection-1))]}"
            return 0
        else
            echo -e "${RED}Invalid selection. Please enter a number between 1 and ${#files[@]}${NC}" >&2
        fi
    done
}

# Function to confirm selection
confirm_selection() {
    echo ""
    echo -e "${YELLOW}Selected configurations:${NC}"
    echo -e "  ${CYAN}RU:${NC}    $(basename "$1")"
    echo -e "  ${CYAN}NTN:${NC}   $(basename "$2")"
    echo -e "  ${CYAN}Cells:${NC} $(basename "$3")"
    echo ""
    
    read -p "Proceed with these files? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to replace a value in the config file
replace_value() {
    local pattern="$1"
    local new_value="$2"
    
    sed -i.bak "s|^\([ ]*${pattern}[ ]*=[ ]*\).*|\1${new_value};|" "$OUTPUT_FILE"
}

# Function to find confs directory
find_confs_dir() {
    # Try current directory first
    if [ -d "./confs" ]; then
        echo "./confs"
        return 0
    fi
    
    # Try parent directory
    if [ -d "../confs" ]; then
        echo "../confs"
        return 0
    fi
    
    # Try looking in common locations
    for dir in "./" "../" "../../"; do
        if [ -d "${dir}confs" ]; then
            echo "${dir}confs"
            return 0
        fi
    done
    
    return 1
}

# Function to find template file
find_template() {
    local template="gnb_template.conf"
    
    # Try current directory
    if [ -f "./$template" ]; then
        echo "./$template"
        return 0
    fi
    
    # Try confs directory
    if [ -f "${CONF_DIR}/$template" ]; then
        echo "${CONF_DIR}/$template"
        return 0
    fi
    
    # Try parent directory
    if [ -f "../$template" ]; then
        echo "../$template"
        return 0
    fi
    
    return 1
}

# Main script starts here
display_header

# Find confs directory
CONF_DIR=$(find_confs_dir)
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: 'confs' directory not found.${NC}"
    echo "Please run this script from the project directory or its parent."
    exit 1
fi

echo -e "${GREEN}Found configuration directory:${NC} $CONF_DIR"
echo ""

# Find template file
TEMPLATE_FILE=$(find_template)
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Template file 'gnb_template.conf' not found.${NC}"
    echo "Searched in: current directory, confs directory, and parent directory"
    exit 1
fi

echo -e "${GREEN}Found template file:${NC} $TEMPLATE_FILE"
echo ""

# Interactive file selection
echo -e "${GREEN}Step 1: Select configuration files${NC}"
echo ""

# Select RU file
RU_FILE=$(select_file "${CONF_DIR}/RUs" "RU configuration")
if [ $? -ne 0 ]; then exit 1; fi
echo ""

# Select NTN file
NTN_FILE=$(select_file "${CONF_DIR}/NTN" "NTN configuration")
if [ $? -ne 0 ]; then exit 1; fi
echo ""

# Select Cells file
CELLS_FILE=$(select_file "${CONF_DIR}/Cells" "Cells configuration")
if [ $? -ne 0 ]; then exit 1; fi

# Confirm selection
if ! confirm_selection "$RU_FILE" "$NTN_FILE" "$CELLS_FILE"; then
    echo -e "${YELLOW}Configuration cancelled.${NC}"
    exit 0
fi

# Ask for output filename
echo ""
echo -e "${YELLOW}Output options:${NC}"
echo -e "  1) Create new file (default)"
echo -e "  2) Overwrite template (keep backup)"
echo ""
read -p "Choose option [1]: " output_option
output_option="${output_option:-1}"

if [ "$output_option" == "2" ]; then
    # Create backup of template
    BACKUP_FILE="${TEMPLATE_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$TEMPLATE_FILE" "$BACKUP_FILE"
    OUTPUT_FILE="$TEMPLATE_FILE"
    echo -e "${GREEN}Created backup:${NC} $BACKUP_FILE"
else
    read -p "Enter output filename [gnb_configured.conf]: " OUTPUT_FILE
    OUTPUT_FILE="${OUTPUT_FILE:-gnb_configured.conf}"
fi

echo ""
echo -e "${GREEN}Step 2: Processing configuration...${NC}"
echo ""

# Function to read JSON with comment support
read_json() {
    local file="$1"
    local key="$2"
    # Strip // comments and parse with jq
    grep -v '^\s*//' "$file" | sed 's|//.*||' | jq -r "$key"
}

# Read JSON values
echo "Reading JSON configurations..."

# RU values
ATT_TX=$(read_json "$RU_FILE" '.att_tx')
ATT_RX=$(read_json "$RU_FILE" '.att_rx')
MAX_RXGAIN=$(read_json "$RU_FILE" '.max_rxgain')
SDR_ADDRS=$(read_json "$RU_FILE" '.sdr_addrs')

# NTN values
DISABLE_HARQ=$(read_json "$NTN_FILE" '.disable_harq')
CELL_SPECIFIC_KOFFSET=$(read_json "$NTN_FILE" '.cellSpecificKoffset_r17')
TA_COMMON=$(read_json "$NTN_FILE" '."ta-Common-r17"')
POS_X=$(read_json "$NTN_FILE" '."positionX-r17"')
POS_Y=$(read_json "$NTN_FILE" '."positionY-r17"')
POS_Z=$(read_json "$NTN_FILE" '."positionZ-r17"')
VEL_VX=$(read_json "$NTN_FILE" '."velocityVX-r17"')
VEL_VY=$(read_json "$NTN_FILE" '."velocityVY-r17"')
VEL_VZ=$(read_json "$NTN_FILE" '."velocityVZ-r17"')
DL_MAX_MCS=$(read_json "$NTN_FILE" '.dl_max_mcs')
UL_MAX_MCS=$(read_json "$NTN_FILE" '.ul_max_mcs')

# Cells values
ABS_FREQ_SSB=$(read_json "$CELLS_FILE" '.absoluteFrequencySSB')
DL_ABS_FREQ_POINT_A=$(read_json "$CELLS_FILE" '.dl_absoluteFrequencyPointA')
DL_FREQ_BAND=$(read_json "$CELLS_FILE" '.dl_frequencyBand')
DL_SUBCARRIER_SPACING=$(read_json "$CELLS_FILE" '.dl_subcarrierSpacing')
DL_CARRIER_BANDWIDTH=$(read_json "$CELLS_FILE" '.dl_carrierBandwidth')
INITIAL_DL_BWP_LOC=$(read_json "$CELLS_FILE" '.initialDLBWPlocationAndBandwidth')
UL_FREQ_BAND=$(read_json "$CELLS_FILE" '.ul_frequencyBand')
UL_ABS_FREQ_POINT_A=$(read_json "$CELLS_FILE" '.ul_absoluteFrequencyPointA')
UL_SUBCARRIER_SPACING=$(read_json "$CELLS_FILE" '.ul_subcarrierSpacing')
UL_CARRIER_BANDWIDTH=$(read_json "$CELLS_FILE" '.ul_carrierBandwidth')
INITIAL_UL_BWP_LOC=$(read_json "$CELLS_FILE" '.initialULBWPlocationAndBandwidth')

echo "Applying configurations to template..."

# Copy template to output
cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

# Apply RU configurations
echo "  ✓ Applying RU configurations..."
replace_value "att_tx" "$ATT_TX"
replace_value "att_rx" "$ATT_RX"
replace_value "max_rxgain" "$MAX_RXGAIN"
replace_value "sdr_addrs" "\"$SDR_ADDRS\""

# Apply NTN configurations
echo "  ✓ Applying NTN configurations..."
replace_value "disable_harq" "$DISABLE_HARQ"
replace_value "cellSpecificKoffset_r17" "$CELL_SPECIFIC_KOFFSET"
replace_value "ta-Common-r17" "$TA_COMMON"
replace_value "positionX-r17" "$POS_X"
replace_value "positionY-r17" "$POS_Y"
replace_value "positionZ-r17" "$POS_Z"
replace_value "velocityVX-r17" "$VEL_VX"
replace_value "velocityVY-r17" "$VEL_VY"
replace_value "velocityVZ-r17" "$VEL_VZ"

# Apply MCS values (in MACRLCs section)
sed -i.bak "s|^\([ ]*dl_max_mcs[ ]*=[ ]*\).*|\1${DL_MAX_MCS};|" "$OUTPUT_FILE"
sed -i.bak "s|^\([ ]*ul_max_mcs[ ]*=[ ]*\).*|\1${UL_MAX_MCS};|" "$OUTPUT_FILE"

# Apply Cells configurations
echo "  ✓ Applying Cells configurations..."
replace_value "absoluteFrequencySSB" "$ABS_FREQ_SSB"
replace_value "dl_absoluteFrequencyPointA" "$DL_ABS_FREQ_POINT_A"
replace_value "dl_frequencyBand" "$DL_FREQ_BAND"
replace_value "dl_subcarrierSpacing" "$DL_SUBCARRIER_SPACING"
replace_value "dl_carrierBandwidth" "$DL_CARRIER_BANDWIDTH"
replace_value "initialDLBWPlocationAndBandwidth" "$INITIAL_DL_BWP_LOC"
replace_value "ul_frequencyBand" "$UL_FREQ_BAND"
replace_value "ul_absoluteFrequencyPointA" "$UL_ABS_FREQ_POINT_A"
replace_value "ul_subcarrierSpacing" "$UL_SUBCARRIER_SPACING"
replace_value "ul_carrierBandwidth" "$UL_CARRIER_BANDWIDTH"
replace_value "initialULBWPlocationAndBandwidth" "$INITIAL_UL_BWP_LOC"

# Clean up backup file
rm -f "${OUTPUT_FILE}.bak"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}✓ Configuration complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${CYAN}Output file:${NC} $OUTPUT_FILE"
echo ""
echo -e "${YELLOW}Summary of applied values:${NC}"
echo -e "  ${CYAN}RU:${NC}"
echo -e "    att_tx=$ATT_TX, att_rx=$ATT_RX, max_rxgain=$MAX_RXGAIN"
echo -e "    sdr_addrs=$SDR_ADDRS"
echo -e "  ${CYAN}NTN:${NC}"
echo -e "    Position=($POS_X, $POS_Y, $POS_Z)"
echo -e "    Velocity=($VEL_VX, $VEL_VY, $VEL_VZ)"
echo -e "    MCS: DL=$DL_MAX_MCS, UL=$UL_MAX_MCS"
echo -e "  ${CYAN}Cells:${NC}"
echo -e "    Bands: DL=$DL_FREQ_BAND, UL=$UL_FREQ_BAND"
echo -e "    Bandwidth=$DL_CARRIER_BANDWIDTH PRBs"
echo -e "    Subcarrier Spacing: DL=$DL_SUBCARRIER_SPACING, UL=$UL_SUBCARRIER_SPACING"
echo ""