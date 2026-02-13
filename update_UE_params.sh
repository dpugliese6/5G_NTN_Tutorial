#!/bin/bash

# Se non passi un file usa default
JSON_FILE=${1:-ue_params.json}

if [ ! -f "$JSON_FILE" ]; then
  echo "File $JSON_FILE non trovato!"
  return 1
fi

export USE_ADDITIONAL_OPTIONS=$(python3 -c "
import json, io

with io.open('$JSON_FILE', encoding='utf-8') as f:
    params = json.load(f)

parts = []

for k, v in params.items():
    if isinstance(v, bool):
        if v:
            parts.append(f'--{k}')
    elif isinstance(v, list):
        for item in v:
            if len(k) == 1:
                parts.append(f'-{k} {item}')
            else:
                parts.append(f'--{k} {item}')
    else:
        if len(k) == 1:
            parts.append(f'-{k} {v}')
        else:
            parts.append(f'--{k} {v}')

print(' '.join(parts))
")

echo "----------------------------------"
echo "JSON file: $JSON_FILE"
echo "USE_ADDITIONAL_OPTIONS:"
echo "$USE_ADDITIONAL_OPTIONS"
echo "----------------------------------"
