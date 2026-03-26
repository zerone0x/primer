#!/usr/bin/env bash
# primer/plugins/hooks.d/on-knowledge-update/10-regenerate-shims.sh
# Hook: Auto-regenerate all tool-native configs when knowledge changes.
#
# This hook is triggered when knowledge entries are added, modified, or pruned.
# It re-runs the full emit pipeline for all detected tools so that knowledge
# changes are reflected in CLAUDE.md, AGENTS.md, .cursorrules, etc.
set -euo pipefail

# Pass through stdin
INPUT=$(cat)

# Locate the Primer root (where bin/primer lives)
Primer_ROOT=""
# Try relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
candidate="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd)"
if [[ -f "$candidate/bin/primer" ]]; then
  Primer_ROOT="$candidate"
fi

# Fallback: look for primer in PATH
if [[ -z "$Primer_ROOT" ]] && command -v primer &>/dev/null; then
  Primer_BIN="$(command -v primer)"
  Primer_ROOT="$(cd "$(dirname "$Primer_BIN")/.." && pwd)"
fi

if [[ -z "$Primer_ROOT" ]]; then
  echo "$INPUT"
  exit 0
fi

# Source the libraries we need
source "$Primer_ROOT/lib/core.sh" 2>/dev/null || true
source "$Primer_ROOT/lib/emit.sh" 2>/dev/null || true

# Discover sources
if type primer_discover_sources &>/dev/null; then
  primer_discover_sources
fi

# Only regenerate if we have sources
if [[ ${#Primer_SOURCES[@]:-0} -eq 0 ]]; then
  echo "$INPUT"
  exit 0
fi

# Load config
if type primer_load_config &>/dev/null; then
  primer_load_config 2>/dev/null || true
fi

# Regenerate all targets that have generators available
if type primer_emit_all &>/dev/null; then
  # Capture output but do not let it contaminate our pipeline stdout
  primer_emit_all "$PWD" >/dev/null 2>&1 || {
    # Log failure but do not break the hook chain
    echo "Warning: shim regeneration had errors" >&2
  }
fi

# Also re-sync MCP if the function exists
if type primer_mcp_sync &>/dev/null; then
  primer_mcp_sync >/dev/null 2>&1 || true
fi

# Also re-sync Claude hooks if the function exists
if type primer_hooks_run &>/dev/null; then
  primer_hooks_run "post-emit" '{"trigger":"knowledge-update"}' >/dev/null 2>&1 || true
fi

# Pass through input unchanged
echo "$INPUT"
