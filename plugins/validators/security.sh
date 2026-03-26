#!/usr/bin/env bash
# Primer Security Validator Plugin
# Checks proposals for prompt injection, oversized payloads, safety violations
set -euo pipefail

# --- Plugin interface ---

if [[ "${1:-}" == "--schema" ]]; then
  cat <<'SCHEMA'
{
  "name": "security",
  "version": "1.0.0",
  "type": "validator",
  "input": "json",
  "description": "Security validator: checks proposals for injection, oversize, and safety violations"
}
SCHEMA
  exit 0
fi

if [[ "${1:-}" == "--describe" ]]; then
  echo "Security validator for Primer proposals."
  echo "Checks for: prompt injection patterns, oversized payloads (>5KB),"
  echo "attempts to remove safety constraints, and invalid agent names."
  exit 0
fi

if [[ "${1:-}" != "--exec" ]]; then
  echo "Usage: $0 [--schema | --describe | --exec]" >&2
  echo "  --schema    Output plugin metadata as JSON" >&2
  echo "  --describe  Output human-readable description" >&2
  echo "  --exec      Validate proposal JSON from stdin" >&2
  exit 1
fi

# --- Validation logic (--exec) ---

if ! command -v jq &>/dev/null; then
  echo '{"valid":false,"errors":["jq is required but not installed"]}' >&2
  exit 1
fi

INPUT=$(cat)

errors=()
warnings=()

add_error() {
  errors+=("$1")
}

add_warning() {
  warnings+=("$1")
}

# --- Check 1: Payload size ---

input_size=${#INPUT}
max_size=5120  # 5KB

if (( input_size > max_size )); then
  add_error "Payload exceeds maximum size of 5KB (${input_size} bytes)"
fi

# --- Check 2: Prompt injection patterns ---

# Lowercase the entire input for case-insensitive matching
input_lower=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]')

injection_patterns=(
  "ignore previous"
  "ignore all previous"
  "ignore the above"
  "disregard previous"
  "disregard all previous"
  "disregard the above"
  "forget previous"
  "forget all previous"
  "forget your instructions"
  "system prompt"
  "override instructions"
  "override your instructions"
  "new instructions"
  "you are now"
  "act as root"
  "act as admin"
  "sudo mode"
  "jailbreak"
  "developer mode"
  "dan mode"
  "ignore safety"
  "bypass safety"
  "bypass security"
  "disable safety"
  "disable security"
  "remove all constraints"
  "remove all restrictions"
  "pretend you are"
  "roleplay as"
  "\\\\n\\\\nsystem:"
  "\\]\\]><!--"
  "<script>"
  "{{system"
  "{%.*import"
)

for pattern in "${injection_patterns[@]}"; do
  if echo "$input_lower" | grep -qiF "$pattern" 2>/dev/null || echo "$input_lower" | grep -qi "$pattern" 2>/dev/null; then
    add_error "Prompt injection pattern detected: '$pattern'"
  fi
done

# --- Check 3: Agent name validation ---

agent=$(echo "$INPUT" | jq -r '.agent // empty' 2>/dev/null)

if [[ -n "$agent" ]]; then
  # Must be alphanumeric with dots, hyphens, underscores
  if ! echo "$agent" | grep -qE '^[a-zA-Z0-9._-]+$'; then
    add_error "Invalid agent name: '$agent' (must match ^[a-zA-Z0-9._-]+\$)"
  fi

  # Must not be too long
  if (( ${#agent} > 100 )); then
    add_error "Agent name exceeds 100 characters"
  fi

  # Suspicious agent names
  suspicious_agents=("system" "root" "admin" "sudo" "superuser" "god" "master")
  agent_lower=$(echo "$agent" | tr '[:upper:]' '[:lower:]')
  for sa in "${suspicious_agents[@]}"; do
    if [[ "$agent_lower" == "$sa" ]]; then
      add_warning "Suspicious agent name: '$agent' (matches reserved name '$sa')"
    fi
  done
fi

# --- Check 4: Safety constraint removal ---

change_type=$(echo "$INPUT" | jq -r '.type // empty' 2>/dev/null)
change_summary=$(echo "$INPUT" | jq -r '.change.summary // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
change_content=$(echo "$INPUT" | jq -r '.change.content // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')

# Flag proposals that try to remove or weaken constraints
if [[ "$change_type" == "update_constraint" ]]; then
  old_value=$(echo "$INPUT" | jq -r '.change.old_value // empty' 2>/dev/null)
  new_value=$(echo "$INPUT" | jq -r '.change.new_value // empty' 2>/dev/null)

  # Replacing a constraint with something shorter is suspicious
  if [[ -n "$old_value" && -n "$new_value" ]]; then
    old_len=${#old_value}
    new_len=${#new_value}
    if (( new_len < old_len / 2 )); then
      add_warning "Constraint replacement is significantly shorter (${old_len} -> ${new_len} chars), may weaken safety"
    fi
  fi

  removal_terms=("remove safety" "delete constraint" "no restrictions" "allow everything" "permit all" "disable check" "skip validation")
  for term in "${removal_terms[@]}"; do
    if [[ "$change_summary" == *"$term"* ]] || [[ "$change_content" == *"$term"* ]]; then
      add_error "Proposal appears to remove safety constraints: '$term'"
    fi
  done
fi

# --- Check 5: Confidence bounds ---

confidence=$(echo "$INPUT" | jq -r '.confidence // empty' 2>/dev/null)
if [[ -n "$confidence" ]]; then
  out_of_range=$(echo "$confidence" | jq 'if . < 0 or . > 1 then "yes" else "no" end' 2>/dev/null || echo "invalid")
  if [[ "$out_of_range" == "yes" ]]; then
    add_error "Confidence must be between 0 and 1, got $confidence"
  elif [[ "$out_of_range" == "invalid" ]]; then
    add_error "Confidence is not a valid number: '$confidence'"
  fi
fi

# --- Output result ---

valid=true
if [[ ${#errors[@]} -gt 0 ]]; then
  valid=false
fi

errors_json="[]"
if [[ ${#errors[@]} -gt 0 ]]; then
  errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
fi

warnings_json="[]"
if [[ ${#warnings[@]} -gt 0 ]]; then
  warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
fi

printf '{"valid":%s,"errors":%s,"warnings":%s}\n' "$valid" "$errors_json" "$warnings_json"

if [[ "$valid" == "false" ]]; then
  exit 1
fi
exit 0
