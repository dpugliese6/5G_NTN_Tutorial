#!/bin/bash
set -e  # Exit on error
set -o pipefail  # Exit on pipe failure

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration paths
CONF_DIR="confs"
CELLS_DIR="$CONF_DIR/Cells"
NTN_DIR="$CONF_DIR/NTN"
RUS_DIR="$CONF_DIR/RUs"
GNB_CONF="$CONF_DIR/gnb_template.conf"
BACKUP_DIR="backups"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed. Please install it first:${NC}"
    echo "  Ubuntu/Debian: sudo apt-get install jq"
    echo "  RHEL/CentOS: sudo yum install jq"
    exit 1
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Function to display menu and get selection
select_file() {
    local dir=$1
    local category=$2
    local files=()
    local i=1
    
    echo "" >&2
    echo -e "${BLUE}=== Select $category Configuration ===${NC}" >&2
    
    # Check if directory exists
    if [ ! -d "$dir" ]; then
        echo -e "${RED}Error: Directory $dir does not exist${NC}" >&2
        return 1
    fi
    
    # Read files into array - use explicit loop
    for file in "$dir"/*.json; do
        if [ -f "$file" ]; then
            files+=("$file")
            echo "  $i) $(basename "$file")" >&2
            ((i++))
        fi
    done
    
    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${RED}No JSON files found in $dir${NC}" >&2
        ls -la "$dir" >&2
        return 1
    fi
    
    # Get user selection
    while true; do
        echo -ne "${YELLOW}Enter selection (1-${#files[@]}): ${NC}" >&2
        read -r selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#files[@]} ]; then
            echo "${files[$((selection-1))]}"
            return 0
        else
            echo -e "${RED}Invalid selection. Please try again.${NC}" >&2
        fi
    done
}

# Function to extract value from JSON (handles comments)
get_json_value() {
    local file=$1
    local key=$2
    # Remove comments and extract value
    grep -v "^[[:space:]]*\/\/" "$file" | jq -r ".$key // empty" 2>/dev/null
}

# Function to update gnb_template.conf with new values
update_gnb_conf() {
    local temp_conf="${GNB_CONF}.tmp"
    cp "$GNB_CONF" "$temp_conf"
    
    echo -e "\n${GREEN}Updating gnb_template.conf...${NC}"
    
    # Update Cells parameters
    if [ -n "$CELLS_FILE" ]; then
        echo -e "${BLUE}  → Applying Cells configuration from $(basename "$CELLS_FILE")${NC}"
        
        # Extract values from JSON
        local abs_freq_ssb=$(get_json_value "$CELLS_FILE" "absoluteFrequencySSB")
        local dl_abs_freq=$(get_json_value "$CELLS_FILE" "dl_absoluteFrequencyPointA")
        local dl_freq_band=$(get_json_value "$CELLS_FILE" "dl_frequencyBand")
        local dl_scs=$(get_json_value "$CELLS_FILE" "dl_subcarrierSpacing")
        local dl_bw=$(get_json_value "$CELLS_FILE" "dl_carrierBandwidth")
        local dl_bwp_loc=$(get_json_value "$CELLS_FILE" "initialDLBWPlocationAndBandwidth")
        local ul_freq_band=$(get_json_value "$CELLS_FILE" "ul_frequencyBand")
        local ul_abs_freq=$(get_json_value "$CELLS_FILE" "ul_absoluteFrequencyPointA")
        local ul_scs=$(get_json_value "$CELLS_FILE" "ul_subcarrierSpacing")
        local ul_bw=$(get_json_value "$CELLS_FILE" "ul_carrierBandwidth")
        local ul_bwp_loc=$(get_json_value "$CELLS_FILE" "initialULBWPlocationAndBandwidth")
        
        # Update values in config file
        [ -n "$abs_freq_ssb" ] && sed -i "s/^\([[:space:]]*absoluteFrequencySSB[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$abs_freq_ssb;/" "$temp_conf"
        [ -n "$dl_abs_freq" ] && sed -i "s/^\([[:space:]]*dl_absoluteFrequencyPointA[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$dl_abs_freq;/" "$temp_conf"
        [ -n "$dl_freq_band" ] && sed -i "s/^\([[:space:]]*dl_frequencyBand[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$dl_freq_band;/" "$temp_conf"
        [ -n "$dl_scs" ] && sed -i "s/^\([[:space:]]*dl_subcarrierSpacing[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$dl_scs;/" "$temp_conf"
        [ -n "$dl_bw" ] && sed -i "s/^\([[:space:]]*dl_carrierBandwidth[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$dl_bw;/" "$temp_conf"
        [ -n "$dl_bwp_loc" ] && sed -i "s/^\([[:space:]]*initialDLBWPlocationAndBandwidth[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$dl_bwp_loc;/" "$temp_conf"
        [ -n "$ul_freq_band" ] && sed -i "s/^\([[:space:]]*ul_frequencyBand[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$ul_freq_band;/" "$temp_conf"
        [ -n "$ul_abs_freq" ] && sed -i "s/^\([[:space:]]*ul_absoluteFrequencyPointA[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$ul_abs_freq;/" "$temp_conf"
        [ -n "$ul_scs" ] && sed -i "s/^\([[:space:]]*ul_subcarrierSpacing[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$ul_scs;/" "$temp_conf"
        [ -n "$ul_bw" ] && sed -i "s/^\([[:space:]]*ul_carrierBandwidth[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$ul_bw;/" "$temp_conf"
        [ -n "$ul_bwp_loc" ] && sed -i "s/^\([[:space:]]*initialULBWPlocationAndBandwidth[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$ul_bwp_loc;/" "$temp_conf"
    fi
    
    # Update NTN parameters
    if [ -n "$NTN_FILE" ]; then
        echo -e "${BLUE}  → Applying NTN configuration from $(basename "$NTN_FILE")${NC}"
        
        # Extract HARQ value
        local disable_harq=$(grep -v "^[[:space:]]*\/\/" "$NTN_FILE" | jq -r '.harq.disable_harq // empty' 2>/dev/null)
        [ -n "$disable_harq" ] && sed -i "s/^\([[:space:]]*disable_harq[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$disable_harq;/" "$temp_conf"
        
        # Extract SIB19 values
        local cell_koffset=$(grep -v "^[[:space:]]*\/\/" "$NTN_FILE" | jq -r '.sib19.cellSpecificKoffset_r17 // empty' 2>/dev/null)
        local ta_common=$(grep -v "^[[:space:]]*\/\/" "$NTN_FILE" | jq -r '.sib19."ta-Common-r17" // empty' 2>/dev/null)
        local pos_x=$(grep -v "^[[:space:]]*\/\/" "$NTN_FILE" | jq -r '.sib19."positionX-r17" // empty' 2>/dev/null)
        local pos_y=$(grep -v "^[[:space:]]*\/\/" "$NTN_FILE" | jq -r '.sib19."positionY-r17" // empty' 2>/dev/null)
        local pos_z=$(grep -v "^[[:space:]]*\/\/" "$NTN_FILE" | jq -r '.sib19."positionZ-r17" // empty' 2>/dev/null)
        local vel_x=$(grep -v "^[[:space:]]*\/\/" "$NTN_FILE" | jq -r '.sib19."velocityVX-r17" // empty' 2>/dev/null)
        local vel_y=$(grep -v "^[[:space:]]*\/\/" "$NTN_FILE" | jq -r '.sib19."velocityVY-r17" // empty' 2>/dev/null)
        local vel_z=$(grep -v "^[[:space:]]*\/\/" "$NTN_FILE" | jq -r '.sib19."velocityVZ-r17" // empty' 2>/dev/null)
        
        # Update SIB19 values in ntn_Config_r17 section
        [ -n "$cell_koffset" ] && sed -i "s/^\([[:space:]]*cellSpecificKoffset_r17[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$cell_koffset;/" "$temp_conf"
        [ -n "$ta_common" ] && sed -i "s/^\([[:space:]]*ta-Common-r17[[:space:]]*=[[:space:]]*\)-\?[0-9]*;/\1$ta_common;/" "$temp_conf"
        [ -n "$pos_x" ] && sed -i "s/^\([[:space:]]*positionX-r17[[:space:]]*=[[:space:]]*\)-\?[0-9]*;/\1$pos_x;/" "$temp_conf"
        [ -n "$pos_y" ] && sed -i "s/^\([[:space:]]*positionY-r17[[:space:]]*=[[:space:]]*\)-\?[0-9]*;/\1$pos_y;/" "$temp_conf"
        [ -n "$pos_z" ] && sed -i "s/^\([[:space:]]*positionZ-r17[[:space:]]*=[[:space:]]*\)-\?[0-9]*;/\1$pos_z;/" "$temp_conf"
        [ -n "$vel_x" ] && sed -i "s/^\([[:space:]]*velocityVX-r17[[:space:]]*=[[:space:]]*\)-\?[0-9]*;/\1$vel_x;/" "$temp_conf"
        [ -n "$vel_y" ] && sed -i "s/^\([[:space:]]*velocityVY-r17[[:space:]]*=[[:space:]]*\)-\?[0-9]*;/\1$vel_y;/" "$temp_conf"
        [ -n "$vel_z" ] && sed -i "s/^\([[:space:]]*velocityVZ-r17[[:space:]]*=[[:space:]]*\)-\?[0-9]*;/\1$vel_z;/" "$temp_conf"
    fi
    
    # Update RUs parameters
    if [ -n "$RUS_FILE" ]; then
        echo -e "${BLUE}  → Applying RUs configuration from $(basename "$RUS_FILE")${NC}"
        
        local att_tx=$(get_json_value "$RUS_FILE" "att_tx")
        local att_rx=$(get_json_value "$RUS_FILE" "att_rx")
        local max_rxgain=$(get_json_value "$RUS_FILE" "max_rxgain")
        local sdr_addrs=$(get_json_value "$RUS_FILE" "sdr_addrs")
        
        # Update RUs section
        [ -n "$att_tx" ] && sed -i "/RUs = (/,/^)/ s/^\([[:space:]]*att_tx[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$att_tx;/" "$temp_conf"
        [ -n "$att_rx" ] && sed -i "/RUs = (/,/^)/ s/^\([[:space:]]*att_rx[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$att_rx;/" "$temp_conf"
        [ -n "$max_rxgain" ] && sed -i "/RUs = (/,/^)/ s/^\([[:space:]]*max_rxgain[[:space:]]*=[[:space:]]*\)[0-9]*;/\1$max_rxgain;/" "$temp_conf"
        [ -n "$sdr_addrs" ] && sed -i "/RUs = (/,/^)/ s/^\([[:space:]]*sdr_addrs[[:space:]]*=[[:space:]]*\)\"[^\"]*\";/\1\"$sdr_addrs\";/" "$temp_conf"
    fi
    
    # Move temp file to original
    mv "$temp_conf" "$GNB_CONF"
    echo -e "${GREEN}✓ Configuration updated successfully!${NC}"
}

# Main script
clear
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   gNB Configuration Tool                      ║${NC}"
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo ""

# Check if gnb_template.conf exists
if [ ! -f "$GNB_CONF" ]; then
    echo -e "${RED}Error: $GNB_CONF not found!${NC}"
    exit 1
fi

# Check if directories exist
for dir in "$CELLS_DIR" "$NTN_DIR" "$RUS_DIR"; do
    if [ ! -d "$dir" ]; then
        echo -e "${RED}Error: Directory $dir not found!${NC}"
        echo -e "${YELLOW}Current directory: $(pwd)${NC}"
        echo -e "${YELLOW}Expected structure:${NC}"
        echo -e "  $(pwd)/confs/Cells/"
        echo -e "  $(pwd)/confs/NTN/"
        echo -e "  $(pwd)/confs/RUs/"
        exit 1
    fi
done

# Create backup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/gnb_template.conf.backup.$TIMESTAMP"
cp "$GNB_CONF" "$BACKUP_FILE"
echo -e "${GREEN}✓ Backup created: $BACKUP_FILE${NC}"

# Select configurations
CELLS_FILE=$(select_file "$CELLS_DIR" "Cells")
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to select Cells configuration${NC}"
    exit 1
fi

NTN_FILE=$(select_file "$NTN_DIR" "NTN")
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to select NTN configuration${NC}"
    exit 1
fi

RUS_FILE=$(select_file "$RUS_DIR" "RUs")
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to select RUs configuration${NC}"
    exit 1
fi

# Display summary
echo -e "\n${YELLOW}═══════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Configuration Summary:${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
echo -e "  Cells: ${GREEN}$(basename "$CELLS_FILE")${NC}"
echo -e "  NTN:   ${GREEN}$(basename "$NTN_FILE")${NC}"
echo -e "  RUs:   ${GREEN}$(basename "$RUS_FILE")${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

# Confirm
echo -ne "\n${YELLOW}Apply these configurations? (y/n): ${NC}"
read confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    update_gnb_conf
    echo -e "\n${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Configuration completed successfully!         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
else
    echo -e "\n${YELLOW}Configuration cancelled. Removing backup...${NC}"
    rm "$BACKUP_FILE"
    echo -e "${YELLOW}No changes made.${NC}"
fi