#!/usr/bin/env bash
# ------------------------------
# Usage:
#   ./update_params.sh config.conf params1.json [params2.json ...] [output.json]
# ------------------------------
set -e

if [ $# -lt 2 ]; then
  echo "Usage: $0 <config.conf> <params1.json> [params2.json ...] [output.json]"
  exit 1
fi

CFG=$1
shift

# verifica file config
if [ ! -f "$CFG" ]; then
  echo "Error: config file not found: $CFG"
  exit 1
fi

# ultimo argomento è output.json se finisce con .json ed esiste già almeno un json prima
ARGS=("$@")
LAST_ARG="${ARGS[-1]}"
if [[ "$LAST_ARG" == *.json && ! -f "$LAST_ARG" ]]; then
  JSON_OUT="$LAST_ARG"
  unset 'ARGS[-1]'
else
  JSON_OUT=""
fi

JSON_FILES=("${ARGS[@]}")

# verifica JSON
for j in "${JSON_FILES[@]}"; do
  if [ ! -f "$j" ]; then
    echo "Error: JSON file not found: $j"
    exit 1
  fi
done

# escape regex per sed (chiavi)
escape_regex() {
  printf '%s\n' "$1" | sed 's/[][(){}.*+?^$|\\/]/\\&/g'
}

# aggiorna una singola chiave sostituendo l'intera riga (solo se NON commentata)
set_param() {
  local key="$1"
  local value="$2"
  local esc_key
  esc_key=$(escape_regex "$key")
  
  # Escape del valore per sed
  value=$(printf '%s\n' "$value" | sed 's/[&/\\]/\\&/g')
  
  # Pattern che:
  # - Cattura l'indentazione iniziale
  # - NON matcha se c'è un # (commentato)
  # - Trova la chiave con =
  # - Sostituisce tutta la riga
  # Il pattern ^([[:space:]]*) cattura spazi, ma NON deve essere seguito da #
  sed -i "s|^\([[:space:]]*\)\([^#]*\)$esc_key[[:space:]]*=.*|\1$key = $value;|" "$CFG"
}

# Funzione per parsare JSON senza jq (fallback)
parse_json_simple() {
  local json_file="$1"
  grep -o '"[^"]*"[[:space:]]*:[[:space:]]*[^,}]*' "$json_file" | while read -r line; do
    key=$(echo "$line" | sed 's/^"\([^"]*\)"[[:space:]]*:.*/\1/')
    val=$(echo "$line" | sed 's/^"[^"]*"[[:space:]]*:[[:space:]]*//' | sed 's/[[:space:]]*$//')
    echo "$key=$val"
  done
}

# applica tutti i JSON in ordine
for JSON_IN in "${JSON_FILES[@]}"; do
  echo "Applying $JSON_IN"
  
  if command -v jq &> /dev/null; then
    jq -r '
      to_entries[]
      | "\(.key)=\(
          if (.value|type) == "string"
          then "\"\(.value)\""
          else (.value|tostring)
          end
        )"
    ' "$JSON_IN" |
    while IFS='=' read -r key val; do
      set_param "$key" "$val"
    done
  else
    parse_json_simple "$JSON_IN" |
    while IFS='=' read -r key val; do
      set_param "$key" "$val"
    done
  fi
done

echo "Configuration updated from JSON files"

# merge finale JSON (se richiesto)
if [ -n "$JSON_OUT" ]; then
  if command -v jq &> /dev/null; then
    jq -s 'reduce .[] as $item ({}; . * $item)' "${JSON_FILES[@]}" > "$JSON_OUT"
    echo "Merged JSON saved to $JSON_OUT"
  fi
fi