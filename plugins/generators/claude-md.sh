#!/usr/bin/env bash
# primer/plugins/generators/claude-md.sh — Generate CLAUDE.md from .ai/ config
# Part of Primer (Portable AI Infrastructure Config)
#
# Plugin protocol:
#   --schema    JSON schema for this generator
#   --describe  Human-readable description
#   --exec      Read project config (JSON) from stdin, write CLAUDE.md to stdout

set -euo pipefail

case "${1:-}" in
  --schema)
    cat <<'SCHEMA'
{
  "name": "claude-md",
  "version": "1.0.0",
  "target_file": "CLAUDE.md",
  "description": "Generates CLAUDE.md from .ai/ canonical config",
  "accepts": "application/json",
  "produces": "text/markdown"
}
SCHEMA
    exit 0
    ;;
  --describe)
    echo "Generates CLAUDE.md from .ai/ canonical config"
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

# -- Tech stack (one line)
if [[ -n "$LANGUAGE" || -n "$FRAMEWORK" ]]; then
  local_stack=""
  [[ -n "$LANGUAGE" ]] && local_stack="$LANGUAGE"
  [[ -n "$FRAMEWORK" ]] && local_stack="${local_stack:+$local_stack / }$FRAMEWORK"
  _append "**Stack**: $local_stack"
  _append ""
fi

# -- Build commands
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

# -- Phase guidance
PHASE=$(_jq '.phase')
PHASE_GUIDANCE=$(_jq '.phase_guidance')
if [[ -n "$PHASE" ]]; then
  _append "## Current Phase"
  _append "Phase: **$PHASE**"
  [[ -n "$PHASE_GUIDANCE" ]] && _append "$PHASE_GUIDANCE"
  _append ""
fi

# -- Knowledge (injected by pre-generate hooks from KPL TOML files)
KNOWLEDGE_INJECTED=$(_jq '.knowledge_injected')
if [[ "$KNOWLEDGE_INJECTED" == "true" ]]; then
  KNOWLEDGE_ENTRIES=$(_jq_raw '(.knowledge_entries // [])[] | "- **\(.type // "note")/\(.id // "unknown")** [\(.severity // "medium")]: \(.text // .summary // "")"' 2>/dev/null)
  if [[ -n "$KNOWLEDGE_ENTRIES" ]]; then
    _append "## Knowledge"
    _append "$KNOWLEDGE_ENTRIES"
    _append ""
  fi
fi

# -- Context references (skills)
SKILLS=$(_jq_raw '(.skills // [])[] | "- When working on \(.scope // "related tasks"), read \`.ai/skills/\(.file // .name)\`"' 2>/dev/null)
if [[ -n "$SKILLS" ]]; then
  _append "## Context"
  _append "$SKILLS"
  _append ""
fi

# -- Evolution footer
_append "---"
_append "<!-- To propose improvements to this file, create .ai/evolution/proposals/<name>.yaml -->"
_append "<!-- with fields: section, current, proposed, rationale. Run \`primer evolve\` to review. -->"

# ---------------------------------------------------------------------------
# Compute hash and prepend header
# ---------------------------------------------------------------------------
HASH=$(echo -n "$OUTPUT" | shasum -a 256 | awk '{print $1}')
echo "<!-- primer:sha256:$HASH -->"
printf '%s' "$OUTPUT"
