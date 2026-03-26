#!/usr/bin/env bash
# primer/plugins/generators/cursorrules.sh — Generate .cursorrules from .ai/ config
# Part of Primer (Portable AI Infrastructure Config)
#
# Plugin protocol:
#   --schema    JSON schema for this generator
#   --describe  Human-readable description
#   --exec      Read project config (JSON) from stdin, write .cursorrules to stdout

set -euo pipefail

case "${1:-}" in
  --schema)
    cat <<'SCHEMA'
{
  "name": "cursorrules",
  "version": "1.0.0",
  "target_file": ".cursorrules",
  "description": "Generates .cursorrules from .ai/ canonical config",
  "accepts": "application/json",
  "produces": "text/plain"
}
SCHEMA
    exit 0
    ;;
  --describe)
    echo "Generates .cursorrules from .ai/ canonical config"
    exit 0
    ;;
  --exec)
    ;;
  *)
    echo "Usage: $0 {--schema|--describe|--exec}" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Read project config JSON from stdin
# ---------------------------------------------------------------------------
CONFIG=$(cat)

_jq() { echo "$CONFIG" | jq -r "$1 // empty" 2>/dev/null || true; }
_jq_arr() { echo "$CONFIG" | jq -r "($1 // [])[]" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Extract fields
# ---------------------------------------------------------------------------
PROJECT_NAME=$(_jq '.name')
PROJECT_DESC=$(_jq '.description')
LANGUAGE=$(_jq '.language')
FRAMEWORK=$(_jq '.framework')

# ---------------------------------------------------------------------------
# Build output
# ---------------------------------------------------------------------------
OUTPUT=""

_append() { OUTPUT+="$1"$'\n'; }

# -- Project context
_append "# Project: ${PROJECT_NAME:-Project}"
[[ -n "$PROJECT_DESC" ]] && _append "# $PROJECT_DESC"
_append ""

if [[ -n "$LANGUAGE" || -n "$FRAMEWORK" ]]; then
  local_stack=""
  [[ -n "$LANGUAGE" ]] && local_stack="$LANGUAGE"
  [[ -n "$FRAMEWORK" ]] && local_stack="${local_stack:+$local_stack / }$FRAMEWORK"
  _append "You are working on a $local_stack project."
  _append ""
fi

# -- Rules (constraints)
CONSTRAINTS=$(_jq_arr '.constraints')
if [[ -n "$CONSTRAINTS" ]]; then
  _append "## Rules"
  _append ""
  idx=1
  while IFS= read -r c; do
    if [[ -n "$c" ]]; then
      _append "$idx. $c"
      idx=$((idx + 1))
    fi
  done <<< "$CONSTRAINTS"
  _append ""
fi

# -- Build commands
BUILD=$(_jq '.build')
TEST=$(_jq '.test')
LINT=$(_jq '.lint')
DEV=$(_jq '.dev')

if [[ -n "$BUILD" || -n "$TEST" || -n "$LINT" || -n "$DEV" ]]; then
  _append "## Build Commands"
  _append ""
  [[ -n "$BUILD" ]] && _append "- Build: \`$BUILD\`"
  [[ -n "$TEST" ]]  && _append "- Test: \`$TEST\`"
  [[ -n "$LINT" ]]  && _append "- Lint: \`$LINT\`"
  [[ -n "$DEV" ]]   && _append "- Dev: \`$DEV\`"
  _append ""
fi

# -- Phase
PHASE=$(_jq '.phase')
PHASE_GUIDANCE=$(_jq '.phase_guidance')
if [[ -n "$PHASE" ]]; then
  _append "## Current Phase: $PHASE"
  [[ -n "$PHASE_GUIDANCE" ]] && _append "$PHASE_GUIDANCE"
  _append ""
fi

# No evolution footer for Cursor (limited file-write support)

# ---------------------------------------------------------------------------
# Hash and output
# ---------------------------------------------------------------------------
HASH=$(echo -n "$OUTPUT" | shasum -a 256 | awk '{print $1}')
echo "# primer:sha256:$HASH"
printf '%s' "$OUTPUT"
