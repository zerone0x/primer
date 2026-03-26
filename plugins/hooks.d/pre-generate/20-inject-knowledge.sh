#!/usr/bin/env bash
# primer/plugins/hooks.d/pre-generate/20-inject-knowledge.sh
# Hook: Inject Tier 0+1 knowledge entries into config JSON.
#
# Reads config JSON from stdin. Looks up the Knowledge Persistence Layer
# entries (Tier 0 = critical/always, Tier 1 = project-specific) and
# injects them into the config under a "knowledge" key.
set -euo pipefail

# Read config JSON from stdin
CONFIG=$(cat)

# Bail early if jq is not available
if ! command -v jq &>/dev/null; then
  echo "$CONFIG"
  exit 0
fi

# Collect knowledge entries from .ai/ sources
# Walk from CWD upward to find .ai/knowledge/entries.json files
KNOWLEDGE='[]'
dir="$PWD"
while true; do
  kfile="$dir/.ai/knowledge/entries.json"
  if [[ -f "$kfile" ]]; then
    # Filter for tier 0 and tier 1 entries
    # If entries have a "tier" field, select 0 and 1; otherwise include all
    tier_entries=$(jq '[.[] | select(
      (.tier == null) or (.tier == 0) or (.tier == 1)
    )]' "$kfile" 2>/dev/null || echo '[]')

    # Merge into collected knowledge (deeper sources = lower priority)
    KNOWLEDGE=$(jq -n --argjson a "$KNOWLEDGE" --argjson b "$tier_entries" '$a + $b')
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
# Extract just the text of each entry for the "knowledge" array,
# and keep full entries in "knowledge_entries" for generators that need metadata
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
