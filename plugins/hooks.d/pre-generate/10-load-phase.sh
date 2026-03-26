#!/usr/bin/env bash
# primer/plugins/hooks.d/pre-generate/10-load-phase.sh
# Hook: Load current phase overlay and merge into config JSON.
#
# Reads the project phase from the config JSON on stdin.
# If a phase overlay file exists at .ai/phases/<phase>.yaml,
# merges its contents into the config JSON and emits the result.
set -euo pipefail

# Read config JSON from stdin
CONFIG=$(cat)

# Extract current phase
PHASE=$(echo "$CONFIG" | jq -r '.phase // empty' 2>/dev/null || true)

if [[ -z "$PHASE" ]]; then
  # No phase set — pass through unchanged
  echo "$CONFIG"
  exit 0
fi

# Search for phase overlay file in .ai/ sources
# Walk from CWD upward looking for .ai/phases/<phase>.yaml
PHASE_FILE=""
dir="$PWD"
while true; do
  candidate="$dir/.ai/phases/${PHASE}.yaml"
  if [[ -f "$candidate" ]]; then
    PHASE_FILE="$candidate"
    break
  fi
  [[ "$dir" == "$HOME" || "$dir" == "/" ]] && break
  dir="$(dirname "$dir")"
done

if [[ -z "$PHASE_FILE" ]]; then
  # No overlay for this phase — pass through unchanged
  echo "$CONFIG"
  exit 0
fi

# Convert phase overlay to JSON and merge
if command -v yq &>/dev/null && command -v jq &>/dev/null; then
  PHASE_JSON=$(yq eval -o=json "$PHASE_FILE" 2>/dev/null)
  # Deep merge: phase overlay values override base config
  MERGED=$(jq -n \
    --argjson base "$CONFIG" \
    --argjson overlay "$PHASE_JSON" \
    '$base * $overlay + {phase_overlay_applied: true, phase_overlay_file: "'"$PHASE_FILE"'"}')
  echo "$MERGED"
elif command -v jq &>/dev/null; then
  # No yq — try to extract simple key-value pairs from YAML
  OVERLAY='{}'
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_-]*):[[:space:]]*(.*) ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val#\"}" ; val="${val%\"}"
      val="${val#\'}" ; val="${val%\'}"
      OVERLAY=$(echo "$OVERLAY" | jq --arg k "$key" --arg v "$val" '.[$k] = $v')
    fi
  done < "$PHASE_FILE"
  MERGED=$(jq -n \
    --argjson base "$CONFIG" \
    --argjson overlay "$OVERLAY" \
    '$base * $overlay + {phase_overlay_applied: true}')
  echo "$MERGED"
else
  # No jq at all — pass through unchanged
  echo "$CONFIG"
fi
