#!/usr/bin/env bash
# primer/plugins/generators/hermes-md.sh — Generate .hermes.md from .ai/ config
# Part of Primer (Portable AI Infrastructure Config)
#
# Plugin protocol:
#   --schema    JSON schema for this generator
#   --describe  Human-readable description
#   --exec      Read project config (JSON) from stdin, write .hermes.md to stdout

set -euo pipefail

case "${1:-}" in
  --schema)
    cat <<'SCHEMA'
{
  "name": "hermes-md",
  "version": "1.0.0",
  "target_file": ".hermes.md",
  "description": "Generates .hermes.md from .ai/ canonical config",
  "accepts": "application/json",
  "produces": "text/markdown"
}
SCHEMA
    exit 0
    ;;
  --describe)
    echo "Generates .hermes.md from .ai/ canonical config"
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
_jq_raw() { echo "$CONFIG" | jq -r "$1" 2>/dev/null || true; }

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

# -- Project header
_append "# ${PROJECT_NAME:-Project}"
[[ -n "$PROJECT_DESC" ]] && _append "$PROJECT_DESC"
_append ""

# -- Tech stack
if [[ -n "$LANGUAGE" || -n "$FRAMEWORK" ]]; then
  local_stack=""
  [[ -n "$LANGUAGE" ]] && local_stack="$LANGUAGE"
  [[ -n "$FRAMEWORK" ]] && local_stack="${local_stack:+$local_stack / }$FRAMEWORK"
  _append "**Stack**: $local_stack"
  _append ""
fi

# -- Commands
BUILD=$(_jq '.build')
TEST=$(_jq '.test')
LINT=$(_jq '.lint')
DEV=$(_jq '.dev')

if [[ -n "$BUILD" || -n "$TEST" || -n "$LINT" || -n "$DEV" ]]; then
  _append "## Commands"
  [[ -n "$BUILD" ]] && _append "- Build: \`$BUILD\`"
  [[ -n "$TEST" ]]  && _append "- Test: \`$TEST\`"
  [[ -n "$LINT" ]]  && _append "- Lint: \`$LINT\`"
  [[ -n "$DEV" ]]   && _append "- Dev: \`$DEV\`"
  _append ""
fi

# -- Constraints
CONSTRAINTS=$(_jq_arr '.constraints')
if [[ -n "$CONSTRAINTS" ]]; then
  _append "## Constraints"
  while IFS= read -r c; do
    [[ -n "$c" ]] && _append "- $c"
  done <<< "$CONSTRAINTS"
  _append ""
fi

# -- Skills (Hermes-specific: explicit skill references)
SKILLS=$(_jq_raw '(.skills // [])[] | "### \(.name // .file)\n\(.description // "")\nSource: `.ai/skills/\(.file // .name)`\nScope: \(.scope // "general")\n"' 2>/dev/null)
if [[ -n "$SKILLS" ]]; then
  _append "## Skills"
  _append "$SKILLS"
fi

# -- Memory guidance (Hermes-specific)
_append "## Memory"
_append "Use \`.ai/memory/\` for persistent context across sessions."
MEMORY_GUIDANCE=$(_jq '.memory_guidance')
if [[ -n "$MEMORY_GUIDANCE" ]]; then
  _append "$MEMORY_GUIDANCE"
fi
_append ""

# -- Phase
PHASE=$(_jq '.phase')
PHASE_GUIDANCE=$(_jq '.phase_guidance')
if [[ -n "$PHASE" ]]; then
  _append "## Current Phase"
  _append "Phase: **$PHASE**"
  [[ -n "$PHASE_GUIDANCE" ]] && _append "$PHASE_GUIDANCE"
  _append ""
fi

# -- Evolution footer
_append "---"
_append "<!-- To propose improvements, create .ai/evolution/proposals/<name>.yaml -->"
_append "<!-- Run \`primer evolve\` to review. Hermes will pick up changes on next load. -->"

# ---------------------------------------------------------------------------
# Hash and output
# ---------------------------------------------------------------------------
HASH=$(echo -n "$OUTPUT" | shasum -a 256 | awk '{print $1}')
echo "<!-- primer:sha256:$HASH -->"
printf '%s' "$OUTPUT"
