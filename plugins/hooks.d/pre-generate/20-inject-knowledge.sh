#!/usr/bin/env bash
# primer/plugins/hooks.d/pre-generate/20-inject-knowledge.sh
# Hook: Inject Tier 0+1 knowledge entries into config JSON.
#
# Reads config JSON from stdin. Looks up the Knowledge Persistence Layer
# entries from TOML files (gotchas.toml, constraints.toml, failures.toml)
# and injects them into the config under a "knowledge" key.
#
# Handles two TOML formats:
#   1. [[type]] with id/summary fields (template-shipped knowledge)
#   2. [entry-id] with summary field (KPL-added entries)
set -euo pipefail

# Read config JSON from stdin
CONFIG=$(cat)

# Bail early if jq is not available
if ! command -v jq &>/dev/null; then
  echo "$CONFIG"
  exit 0
fi

# Parse TOML knowledge files into JSON array entries.
# Handles both [[type]] array-of-tables and [id] table formats.
_parse_toml_to_json() {
  local file="$1" ftype="$2"
  [[ -f "$file" ]] || return 0

  local current_id="" summary="" severity="" in_array_table=0

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Array-of-tables: [[gotcha]], [[constraint]], [[failure]]
    if [[ "$line" =~ ^\[\[([a-zA-Z0-9_.-]+)\]\] ]]; then
      # Flush previous entry
      if [[ -n "$current_id" && -n "$summary" ]]; then
        jq -n --arg id "$current_id" --arg text "$summary" --arg sev "${severity:-medium}" --arg type "$ftype" \
          '{id: $id, text: $text, severity: $sev, type: $type}'
      fi
      current_id="" summary="" severity=""
      in_array_table=1
      continue
    fi

    # Single table: [entry-id]
    if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+)\] ]]; then
      # Flush previous entry
      if [[ -n "$current_id" && -n "$summary" ]]; then
        jq -n --arg id "$current_id" --arg text "$summary" --arg sev "${severity:-medium}" --arg type "$ftype" \
          '{id: $id, text: $text, severity: $sev, type: $type}'
      fi
      current_id="${BASH_REMATCH[1]}"
      summary="" severity=""
      in_array_table=0
      continue
    fi

    # Extract fields
    if [[ "$line" =~ ^id[[:space:]]*=[[:space:]]*\"(.*)\" ]]; then
      current_id="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^summary[[:space:]]*=[[:space:]]*\"(.*)\" ]]; then
      summary="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^severity[[:space:]]*=[[:space:]]*\"(.*)\" ]]; then
      severity="${BASH_REMATCH[1]}"
    fi
  done < "$file"

  # Flush last entry
  if [[ -n "$current_id" && -n "$summary" ]]; then
    jq -n --arg id "$current_id" --arg text "$summary" --arg sev "${severity:-medium}" --arg type "$ftype" \
      '{id: $id, text: $text, severity: $sev, type: $type}'
  fi
}

# Collect knowledge entries from .ai/ sources
KNOWLEDGE='[]'
dir="$PWD"
while true; do
  ai_knowledge="$dir/.ai/knowledge"
  if [[ -d "$ai_knowledge" ]]; then
    for ftype_file in gotchas:gotcha constraints:constraint failures:failure; do
      ftype="${ftype_file#*:}"
      fname="${ftype_file%:*}.toml"
      toml_path="$ai_knowledge/$fname"
      [[ -f "$toml_path" ]] || continue
      entries=$(_parse_toml_to_json "$toml_path" "$ftype" | jq -s '.' 2>/dev/null || echo '[]')
      KNOWLEDGE=$(jq -n --argjson a "$KNOWLEDGE" --argjson b "$entries" '$a + $b')
    done

    # Also check for legacy entries.json
    if [[ -f "$ai_knowledge/entries.json" ]]; then
      tier_entries=$(jq '[.[] | select(
        (.tier == null) or (.tier == 0) or (.tier == 1)
      )]' "$ai_knowledge/entries.json" 2>/dev/null || echo '[]')
      KNOWLEDGE=$(jq -n --argjson a "$KNOWLEDGE" --argjson b "$tier_entries" '$a + $b')
    fi
  fi
  [[ "$dir" == "$HOME" || "$dir" == "/" ]] && break
  dir="$(dirname "$dir")"
done

# If no knowledge entries found, pass through unchanged
entry_count=$(echo "$KNOWLEDGE" | jq 'length' 2>/dev/null || echo "0")
if [[ "$entry_count" == "0" ]]; then
  echo "$CONFIG"
  exit 0
fi

# Inject knowledge into config
KNOWLEDGE_TEXTS=$(echo "$KNOWLEDGE" | jq '[.[] | .text // .content // .entry // empty]' 2>/dev/null || echo '[]')

RESULT=$(echo "$CONFIG" | jq \
  --argjson entries "$KNOWLEDGE" \
  --argjson texts "$KNOWLEDGE_TEXTS" \
  '. + {
    knowledge: $texts,
    knowledge_entries: $entries,
    knowledge_count: ($entries | length),
    knowledge_injected: true
  }')

echo "$RESULT"
