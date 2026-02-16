#!/bin/bash

# Script to configure ue_template.conf with values from JSON files
# Version for nested structures (one level deep)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# File to store last configuration
LAST_CONFIG_FILE=".ue_last_config"

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
    echo -e "${CYAN}    UE Configuration Tool - Dynamic Mode${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo ""
}

# Function to save last configuration
save_last_config() {
    local ru_file="$1"
    local ntn_file="$2"
    local cells_file="$3"
    local additional_file="$4"
    
    cat > "$LAST_CONFIG_FILE" << EOF
RU_FILE=$ru_file
NTN_FILE=$ntn_file
CELLS_FILE=$cells_file
ADDITIONAL_FILE=$additional_file
EOF
    echo -e "${GREEN}Configuration saved for next time.${NC}"
}

# Function to load last configuration
load_last_config() {
    if [ -f "$LAST_CONFIG_FILE" ]; then
        source "$LAST_CONFIG_FILE"
        
        # Verify mandatory files still exist
        if [ -f "$RU_FILE" ] && [ -f "$NTN_FILE" ] && [ -f "$CELLS_FILE" ]; then
            return 0
        else
            echo -e "${YELLOW}Last configuration files no longer exist.${NC}"
            return 1
        fi
    else
        return 1
    fi
}

# Function to show last configuration option
show_last_config_menu() {
    echo -e "${BLUE}Last used configuration:${NC}"
    echo -e "  ${CYAN}RU:${NC}    $(basename "$RU_FILE")"
    echo -e "  ${CYAN}NTN:${NC}   $(basename "$NTN_FILE")"
    echo -e "  ${CYAN}Cells:${NC} $(basename "$CELLS_FILE")"
    
    # Show additional options file if it was set
    if [ -n "$ADDITIONAL_FILE" ] && [ "$ADDITIONAL_FILE" != "none" ]; then
        echo -e "  ${CYAN}Extra:${NC} $(basename "$ADDITIONAL_FILE")"
    else
        echo -e "  ${CYAN}Extra:${NC} (none)"
    fi
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo -e "  ${GREEN}1)${NC} Use last configuration"
    echo -e "  ${GREEN}2)${NC} Select new files"
    echo ""
    
    read -p "Choose option [1]: " choice
    choice="${choice:-1}"
    
    if [ "$choice" == "1" ]; then
        return 0
    else
        return 1
    fi
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

# Function to optionally select an additional options JSON file
# Returns the selected path, or "none" if the user skips
select_additional_options_file() {
    local dir="$1"
    local files=()

    echo -e "${BLUE}Step: Select Additional Options file (optional)${NC}" >&2
    echo "" >&2
    echo -e "${YELLOW}An additional options JSON file can supply extra key-value pairs" >&2
    echo -e "that will be exported as the USE_ADDITIONAL_OPTIONS environment variable.${NC}" >&2
    echo "" >&2
    echo -e "  ${GREEN}0)${NC} Skip (no additional options)" >&2

    # Check if directory exists; if not, offer skip only
    if [ ! -d "$dir" ]; then
        echo -e "${YELLOW}  (Directory '$dir' not found — skip only)${NC}" >&2
        echo "" >&2
        read -p "Press Enter to skip, or type the full path to a JSON file: " manual_path >&2
        if [ -z "$manual_path" ]; then
            echo "none"
            return 0
        elif [ -f "$manual_path" ]; then
            echo "$manual_path"
            return 0
        else
            echo -e "${RED}File not found: $manual_path — skipping.${NC}" >&2
            echo "none"
            return 0
        fi
    fi

    # Collect JSON files
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$dir" -maxdepth 2 -name "*.json" | sort)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${YELLOW}  No JSON files found in $dir — skip only.${NC}" >&2
        echo "" >&2
        read -p "Press Enter to skip, or type the full path to a JSON file: " manual_path >&2
        if [ -z "$manual_path" ]; then
            echo "none"
            return 0
        elif [ -f "$manual_path" ]; then
            echo "$manual_path"
            return 0
        else
            echo -e "${RED}File not found: $manual_path — skipping.${NC}" >&2
            echo "none"
            return 0
        fi
    fi

    # Display numbered list
    for i in "${!files[@]}"; do
        local filename=$(basename "${files[$i]}")
        printf "  ${GREEN}%2d)${NC} %s\n" $((i+1)) "$filename" >&2
    done
    echo "" >&2

    # Get user selection (0 = skip)
    local selection=""
    while true; do
        read -p "Enter number (0 to skip, 1-${#files[@]} to select): " selection >&2
        if [ "$selection" == "0" ] || [ -z "$selection" ]; then
            echo "none"
            return 0
        elif [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#files[@]} ]; then
            echo "${files[$((selection-1))]}"
            return 0
        else
            echo -e "${RED}Invalid selection. Enter 0 to skip or a number between 1 and ${#files[@]}.${NC}" >&2
        fi
    done
}

# Function to load additional options from a JSON file and export USE_ADDITIONAL_OPTIONS
load_additional_options() {
    local file="$1"

    # If no file was selected, clear the variable and return
    if [ -z "$file" ] || [ "$file" == "none" ]; then
        export USE_ADDITIONAL_OPTIONS=""
        echo "USE_ADDITIONAL_OPTIONS=" > .env.ue
        echo -e "${YELLOW}No additional options file selected — USE_ADDITIONAL_OPTIONS is empty.${NC}"
        return 0
    fi

    if [ ! -f "$file" ]; then
        echo -e "${RED}Error: Additional options file not found: $file${NC}"
        export USE_ADDITIONAL_OPTIONS=""
        return 1
    fi

    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}Loading additional options from: $(basename "$file")${NC}"
    echo -e "${CYAN}================================================${NC}"

    # Strip single-line and block comments before parsing
    local clean_json
    clean_json=$(grep -v '^\s*//' "$file" | sed 's|//.*||' | sed 's|/\*.*\*/||')

    if [ -z "$clean_json" ]; then
        echo -e "${RED}Error: Additional options file is empty after cleaning.${NC}"
        export USE_ADDITIONAL_OPTIONS=""
        return 1
    fi

    # Validate JSON
    if ! echo "$clean_json" | jq empty 2>/dev/null; then
        echo -e "${RED}Error: Additional options file contains invalid JSON.${NC}"
        export USE_ADDITIONAL_OPTIONS=""
        return 1
    fi

    # Validate that all keys start with -- or -
    local invalid_keys
    invalid_keys=$(echo "$clean_json" | jq -r 'keys[] | select(startswith("-") | not)')
    if [ -n "$invalid_keys" ]; then
        echo -e "${RED}Error: All keys must start with '--' (long flag) or '-' (short flag).${NC}"
        echo -e "${RED}Invalid keys found:${NC}"
        while IFS= read -r bad_key; do
            echo -e "  ${RED}• $bad_key${NC}"
        done <<< "$invalid_keys"
        export USE_ADDITIONAL_OPTIONS=""
        return 1
    fi

    # Compact the JSON (single line) and keep for reference
    local compact_json
    compact_json=$(echo "$clean_json" | jq -c '.')

    # Convert JSON to CLI flags string:
    #   string/number  ->  --flag value
    #   true/null      ->  --flag         (switch, no value)
    #   false          ->  (ignored)
    local flags_str=""
    local keys_list
    keys_list=$(echo "$clean_json" | jq -r 'keys[]')

    while IFS= read -r k; do
        [ -z "$k" ] && continue
        local vtype vraw
        vtype=$(echo "$clean_json" | jq -r ".[\"$k\"] | type")
        vraw=$(echo "$clean_json" | jq -r ".[\"$k\"]")
        case "$vtype" in
            "boolean")
                [ "$vraw" == "true" ] && flags_str="${flags_str} ${k}"
                ;;
            "null")
                flags_str="${flags_str} ${k}"
                ;;
            "string"|"number")
                flags_str="${flags_str} ${k} ${vraw}"
                ;;
        esac
    done <<< "$keys_list"

    # Trim leading space
    flags_str="${flags_str# }"

    export USE_ADDITIONAL_OPTIONS="$flags_str"

    # Write .env.ue for docker-compose
    echo "USE_ADDITIONAL_OPTIONS=${flags_str}" > .env.ue
    echo -e "${GREEN}Written:${NC} .env.ue  →  ${CYAN}${flags_str}${NC}"

    # Pretty-print summary table
    local keys
    keys=$(echo "$clean_json" | jq -r 'keys[]')
    local count=0
    local count_long=0
    local count_short=0
    local count_bool=0
    local count_ignored=0

    echo ""
    echo -e "${GREEN}Options loaded and exported to USE_ADDITIONAL_OPTIONS:${NC}"
    echo ""
    printf "  ${BLUE}%-38s  %-8s  %s${NC}\n" "Flag" "Type" "Value"
    printf "  ${BLUE}%-38s  %-8s  %s${NC}\n" "----" "----" "-----"

    while IFS= read -r key; do
        [ -z "$key" ] && continue
        count=$((count + 1))

        # Determine flag type: -- (long) or - (short)
        local flag_type
        if [[ "$key" == --* ]]; then
            flag_type="long (--)"
            count_long=$((count_long + 1))
        else
            flag_type="short (-)"
            count_short=$((count_short + 1))
        fi

        # Determine value type: boolean/null (switch) or string/number (with value)
        local raw_type
        raw_type=$(echo "$clean_json" | jq -r ".[\"$key\"] | type")
        local raw_value
        raw_value=$(echo "$clean_json" | jq -r ".[\"$key\"]")

        local display_value
        local display_type

        case "$raw_type" in
            "boolean")
                if [ "$raw_value" == "true" ]; then
                    display_value="${GREEN}(switch ON — no value)${NC}"
                    display_type="switch"
                    count_bool=$((count_bool + 1))
                else
                    # false → flag is disabled, will be ignored
                    display_value="${YELLOW}(switch OFF — ignored)${NC}"
                    display_type="ignored"
                    count_ignored=$((count_ignored + 1))
                fi
                ;;
            "null")
                # null → treated as a valueless switch (enabled)
                display_value="${GREEN}(switch ON — no value)${NC}"
                display_type="switch"
                count_bool=$((count_bool + 1))
                ;;
            "string"|"number")
                display_value="${CYAN}$raw_value${NC}"
                display_type="value"
                ;;
            *)
                display_value="${YELLOW}(complex type — kept as-is in JSON)${NC}"
                display_type="complex"
                ;;
        esac

        printf "  ${GREEN}%-38s${NC}  %-8s  " "$key" "$flag_type"
        echo -e "$display_value"

    done <<< "$keys"

    echo ""
    echo -e "${BLUE}Summary:${NC}"
    echo -e "  Total flags   : ${GREEN}$count${NC}"
    echo -e "  Long  (--xx)  : ${CYAN}$count_long${NC}"
    echo -e "  Short (-x)    : ${CYAN}$count_short${NC}"
    echo -e "  Switches (ON) : ${CYAN}$count_bool${NC}"
    echo -e "  Ignored (OFF) : ${YELLOW}$count_ignored${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo ""

    return 0
}

# Function to confirm selection
confirm_selection() {
    echo ""
    echo -e "${YELLOW}Selected configurations:${NC}"
    echo -e "  ${CYAN}RU:${NC}    $(basename "$1")"
    echo -e "  ${CYAN}NTN:${NC}   $(basename "$2")"
    echo -e "  ${CYAN}Cells:${NC} $(basename "$3")"
    if [ -n "$4" ] && [ "$4" != "none" ]; then
        echo -e "  ${CYAN}Extra:${NC} $(basename "$4")"
    else
        echo -e "  ${CYAN}Extra:${NC} (none)"
    fi
    echo ""
    
    read -p "Proceed with these files? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to replace a value in nested structure
replace_value_nested() {
    local pattern="$1"
    local new_value="$2"
    
    # Use word boundaries to match exact parameter names only
    # This prevents "x" from matching "att_tx", "nb_rx", etc.
    if grep -E "[[:space:]]${pattern}[[:space:]]*=" "$OUTPUT_FILE" >/dev/null 2>&1; then
        # Replace the value, preserving indentation
        # Use word boundary in sed as well
        sed -i.bak "s|\([[:space:]]${pattern}[[:space:]]*=[[:space:]]*\).*|\1${new_value};|" "$OUTPUT_FILE"
        return 0
    else
        return 1
    fi
}

# Function to read JSON with comment support
read_json_clean() {
    local file="$1"
    # Strip // comments and /* */ comments
    grep -v '^\s*//' "$file" | sed 's|//.*||' | sed 's|/\*.*\*/||'
}

# Function to extract all key-value pairs from a JSON file
extract_json_params() {
    local file="$1"
    local category="$2"
    
    echo -e "${CYAN}?????????????????????????????????????????????${NC}"
    echo -e "${CYAN}Reading all parameters from $category...${NC}"
    echo -e "${CYAN}File: $(basename "$file")${NC}"
    echo -e "${CYAN}?????????????????????????????????????????????${NC}"
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo -e "${RED}ERROR: File does not exist!${NC}"
        echo ""
        return 1
    fi
    
    # Get clean JSON and extract all key-value pairs
    local clean_json=$(read_json_clean "$file")
    
    if [ -z "$clean_json" ]; then
        echo -e "${RED}ERROR: Empty JSON after cleaning${NC}"
        echo ""
        return 1
    fi
    
    # Get all keys at root level
    local keys=$(echo "$clean_json" | jq -r 'keys[]' 2>&1)
    local jq_exit=$?
    
    if [ $jq_exit -ne 0 ]; then
        echo -e "${RED}ERROR: jq failed to parse JSON${NC}"
        echo -e "${RED}Error: $keys${NC}"
        echo ""
        return 1
    fi
    
    if [ -z "$keys" ]; then
        echo -e "${RED}ERROR: No keys found in JSON${NC}"
        echo ""
        return 1
    fi
    
    local count=0
    local applied=0
    
    # Arrays to store results for summary
    local applied_params=()
    local applied_values=()
    local skipped_params=()
    local skipped_values=()
    
    # Process each key
    while IFS= read -r key; do
        if [ -z "$key" ]; then continue; fi
        
        count=$((count + 1))
        
        # Get the value for this key
        local value=$(echo "$clean_json" | jq -r ".[\"$key\"]" 2>/dev/null)
        
        if [ "$value" = "null" ] || [ -z "$value" ]; then
            continue
        fi
        
        # Handle string values (need quotes in config)
        if echo "$clean_json" | jq -e ".[\"$key\"] | type == \"string\"" >/dev/null 2>&1; then
            # Add quotes for string values
            if replace_value_nested "$key" "\"$value\""; then
                applied=$((applied + 1))
                applied_params+=("$key")
                applied_values+=("\"$value\"")
            else
                skipped_params+=("$key")
                skipped_values+=("\"$value\"")
            fi
        else
            # Numeric or boolean values
            if replace_value_nested "$key" "$value"; then
                applied=$((applied + 1))
                applied_params+=("$key")
                applied_values+=("$value")
            else
                skipped_params+=("$key")
                skipped_values+=("$value")
            fi
        fi
        
    done <<< "$keys"
    
    # Print summary - ALL parameters read from JSON
    echo ""
    echo -e "${CYAN}?? ALL PARAMETERS READ FROM JSON ($count total):${NC}"
    echo ""
    
    # Show applied parameters in green
    if [ ${#applied_params[@]} -gt 0 ]; then
        echo -e "${GREEN}? APPLIED (found in template - $applied parameters):${NC}"
        for i in "${!applied_params[@]}"; do
            printf "  ${GREEN}? %-38s${NC} = ${CYAN}%s${NC}\n" "${applied_params[$i]}" "${applied_values[$i]}"
        done
        echo ""
    fi
    
    # Show skipped parameters in yellow
    if [ ${#skipped_params[@]} -gt 0 ]; then
        echo -e "${YELLOW}? NOT APPLIED (not found in template - ${#skipped_params[@]} parameters):${NC}"
        for i in "${!skipped_params[@]}"; do
            printf "  ${YELLOW}? %-38s${NC} = ${CYAN}%s${NC}\n" "${skipped_params[$i]}" "${skipped_values[$i]}"
        done
        echo ""
    fi
    
    echo -e "${BLUE}?????????????????????????????????????????????${NC}"
    echo -e "${BLUE}Summary for $category: Applied ${GREEN}$applied${BLUE}/${count} parameters${NC}"
    echo -e "${BLUE}?????????????????????????????????????????????${NC}"
    echo ""
    
    return 0
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
    local template="ue_template.conf"
    
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
    echo -e "${RED}Error: Template file 'ue_template.conf' not found.${NC}"
    echo "Searched in: current directory, confs directory, and parent directory"
    exit 1
fi

echo -e "${GREEN}Found template file:${NC} $TEMPLATE_FILE"
echo ""

# Check if last configuration exists and offer to use it
USE_LAST_CONFIG=false
if load_last_config; then
    if show_last_config_menu; then
        USE_LAST_CONFIG=true
    fi
fi

# If not using last config, select files interactively
if [ "$USE_LAST_CONFIG" = false ]; then
    echo -e "${GREEN}Step 1: Select configuration files${NC}"
    echo ""

    # Select RU file (shared with gNB)
    RU_FILE=$(select_file "${CONF_DIR}/RUs" "RU configuration")
    if [ $? -ne 0 ]; then exit 1; fi
    echo ""

    # Select NTN file (UE specific)
    NTN_FILE=$(select_file "${CONF_DIR}/UE/NTN" "NTN configuration")
    if [ $? -ne 0 ]; then exit 1; fi
    echo ""

    # Select Cells file (UE specific)
    CELLS_FILE=$(select_file "${CONF_DIR}/UE/Cells" "Cells configuration")
    if [ $? -ne 0 ]; then exit 1; fi
    echo ""

    # Select Additional Options file (optional)
    ADDITIONAL_FILE=$(select_additional_options_file "${CONF_DIR}/UE/UE_additional_flags")
    echo ""

    # Confirm selection
    if ! confirm_selection "$RU_FILE" "$NTN_FILE" "$CELLS_FILE" "$ADDITIONAL_FILE"; then
        echo -e "${YELLOW}Configuration cancelled.${NC}"
        exit 0
    fi
    
    # Save this configuration for next time
    save_last_config "$RU_FILE" "$NTN_FILE" "$CELLS_FILE" "$ADDITIONAL_FILE"
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
    # Create backup of template first
    BACKUP_FILE="${TEMPLATE_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$TEMPLATE_FILE" "$BACKUP_FILE"
    echo -e "${GREEN}Created backup:${NC} $BACKUP_FILE"
    OUTPUT_FILE="$TEMPLATE_FILE"
else
    read -p "Enter output filename [ue_configured.conf]: " OUTPUT_FILE
    OUTPUT_FILE="${OUTPUT_FILE:-ue_configured.conf}"
fi

echo ""
echo -e "${GREEN}Step 2: Processing configuration...${NC}"
echo ""

# Copy template to output (only if different files)
if [ "$TEMPLATE_FILE" != "$OUTPUT_FILE" ]; then
    cp "$TEMPLATE_FILE" "$OUTPUT_FILE"
else
    echo -e "${BLUE}Working directly on template file (backup already created)${NC}"
    echo ""
fi

# Process each JSON file dynamically
extract_json_params "$RU_FILE" "RU"
extract_json_params "$NTN_FILE" "NTN"
extract_json_params "$CELLS_FILE" "Cells"

# Load additional options and export USE_ADDITIONAL_OPTIONS
load_additional_options "$ADDITIONAL_FILE"

# Clean up backup files
rm -f "${OUTPUT_FILE}.bak"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}? Configuration complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${CYAN}Output file:${NC} $OUTPUT_FILE"

# Show USE_ADDITIONAL_OPTIONS status
if [ -n "$USE_ADDITIONAL_OPTIONS" ]; then
    echo -e "${CYAN}USE_ADDITIONAL_OPTIONS:${NC} set (${#USE_ADDITIONAL_OPTIONS} chars)"
else
    echo -e "${CYAN}USE_ADDITIONAL_OPTIONS:${NC} (empty — no additional options selected)"
fi
echo ""