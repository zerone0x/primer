#!/usr/bin/env bash
# primer/plugins/generators/agents-md.sh — Generate AGENTS.md from .ai/ config
# Part of Primer (Portable AI Infrastructure Config)
#
# Plugin protocol:
#   --schema    JSON schema for this generator
#   --describe  Human-readable description
#   --exec      Read project config (JSON) from stdin, write AGENTS.md to stdout

set -euo pipefail

case "${1:-}" in
  --schema)
    cat <<'SCHEMA'
{
  "name": "agents-md",
  "version": "1.0.0",
  "target_file": "AGENTS.md",
  "description": "Generates AGENTS.md from .ai/ canonical config (AAIF format)",
  "accepts": "application/json",
  "produces": "text/markdown"
}
SCHEMA
    exit 0
    ;;
  --describe)
    echo "Generates AGENTS.md from .ai/ canonical config (AAIF format)"
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

# -- Project overview
_append "# $PROJECT_NAME"
_append ""
_append "## Project Overview"
[[ -n "$PROJECT_DESC" ]] && _append "$PROJECT_DESC"
if [[ -n "$LANGUAGE" || -n "$FRAMEWORK" ]]; then
  local_stack=""
  [[ -n "$LANGUAGE" ]] && local_stack="$LANGUAGE"
  [[ -n "$FRAMEWORK" ]] && local_stack="${local_stack:+$local_stack / }$FRAMEWORK"
  _append ""
  _append "**Stack**: $local_stack"
fi
_append ""

# -- Build & test commands
BUILD=$(_jq '.build')
TEST=$(_jq '.test')
LINT=$(_jq '.lint')
DEV=$(_jq '.dev')

if [[ -n "$BUILD" || -n "$TEST" || -n "$LINT" || -n "$DEV" ]]; then
  _append "## Build & Test"
  _append '```bash'
  [[ -n "$BUILD" ]] && _append "# Build"  && _append "$BUILD" && _append ""
  [[ -n "$TEST" ]]  && _append "# Test"   && _append "$TEST"  && _append ""
  [[ -n "$LINT" ]]  && _append "# Lint"   && _append "$LINT"  && _append ""
  [[ -n "$DEV" ]]   && _append "# Dev"    && _append "$DEV"
  _append '```'
  _append ""
fi

# -- Code style / constraints
CONSTRAINTS=$(_jq_arr '.constraints')
if [[ -n "$CONSTRAINTS" ]]; then
  _append "## Code Style & Constraints"
  while IFS= read -r c; do
    [[ -n "$c" ]] && _append "- $c"
  done <<< "$CONSTRAINTS"
  _append ""
fi

# -- Agent roster
AGENTS=$(_jq_raw '(.agents // [])[] | "### \(.name)\n\(.role // "")\n\(.instructions // "")\n"' 2>/dev/null)
if [[ -n "$AGENTS" ]]; then
  _append "## Agent Roster"
  _append "$AGENTS"
fi

# -- Phase info
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
_append "<!-- AGENTS.md evolution: To propose changes, create .ai/evolution/proposals/<name>.yaml -->"
_append "<!-- Compatible with Codex and Copilot Workspace. Run \`primer evolve\` to review proposals. -->"

# ---------------------------------------------------------------------------
# Hash and output
# ---------------------------------------------------------------------------
HASH=$(echo -n "$OUTPUT" | shasum -a 256 | awk '{print $1}')
echo "<!-- primer:sha256:$HASH -->"
printf '%s' "$OUTPUT"
