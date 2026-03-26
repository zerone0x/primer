#!/usr/bin/env bash
# primer/lib/layer1.sh — Layer 1 (global/universal base) management
# Manages ~/.ai/ setup, stack detection, defaults loading, and trust policy.

set -euo pipefail

Primer_ROOT="${Primer_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
Primer_GLOBAL_DIR="${HOME}/.ai"
Primer_TEMPLATE_DIR="${Primer_ROOT}/templates/global-base/.ai"

# ---------------------------------------------------------------------------
# Logging (reuse from core.sh if loaded, otherwise define minimal versions)
# ---------------------------------------------------------------------------
if ! declare -f primer_log &>/dev/null; then
  primer_log()   { printf '\033[0;34m[primer]\033[0m %s\n' "$*" >&2; }
  primer_error() { printf '\033[0;31m[primer error]\033[0m %s\n' "$*" >&2; }
  primer_warn()  { printf '\033[0;33m[primer warn]\033[0m %s\n' "$*" >&2; }
fi

# ---------------------------------------------------------------------------
# primer_init_global — Initialize ~/.ai/ with global defaults
# ---------------------------------------------------------------------------
primer_init_global() {
  if [[ -d "$Primer_GLOBAL_DIR" ]]; then
    primer_log "~/.ai/ already exists, merging missing files only"
  else
    primer_log "Creating ~/.ai/ from global-base template"
    mkdir -p "$Primer_GLOBAL_DIR"
  fi

  # Copy template tree, never overwriting existing files
  local src
  while IFS= read -r src; do
    local rel="${src#"${Primer_TEMPLATE_DIR}/"}"
    local dest="${Primer_GLOBAL_DIR}/${rel}"
    local dest_dir
    dest_dir="$(dirname "$dest")"
    if [[ -d "$src" ]]; then
      mkdir -p "$dest"
    elif [[ -f "$src" ]]; then
      mkdir -p "$dest_dir"
      if [[ -f "$dest" ]]; then
        primer_log "  skip (exists): ${rel}"
      else
        cp "$src" "$dest"
        primer_log "  created: ${rel}"
      fi
    fi
  done < <(find "$Primer_TEMPLATE_DIR" -mindepth 1 | sort)

  primer_log "Global layer initialized at ${Primer_GLOBAL_DIR}"
}

# ---------------------------------------------------------------------------
# primer_detect_stack — Auto-detect project stack from lockfiles/manifests
# Returns: stack name (rust|node|python|go|unknown)
# ---------------------------------------------------------------------------
primer_detect_stack() {
  local dir="${1:-.}"

  # Check for stack indicators, ordered by specificity
  if [[ -f "${dir}/Cargo.toml" || -f "${dir}/Cargo.lock" ]]; then
    echo "rust"
  elif [[ -f "${dir}/go.mod" || -f "${dir}/go.sum" ]]; then
    echo "go"
  elif [[ -f "${dir}/pyproject.toml" || -f "${dir}/setup.py" || -f "${dir}/setup.cfg" || -f "${dir}/Pipfile" || -f "${dir}/requirements.txt" ]]; then
    echo "python"
  elif [[ -f "${dir}/package.json" || -f "${dir}/package-lock.json" || -f "${dir}/yarn.lock" || -f "${dir}/pnpm-lock.yaml" || -f "${dir}/bun.lockb" ]]; then
    echo "node"
  else
    echo "unknown"
  fi
}

# ---------------------------------------------------------------------------
# primer_load_defaults — Load build patterns for detected (or specified) stack
# Sets: Primer_BUILD_TEST, Primer_BUILD_LINT, Primer_BUILD_BUILD, Primer_BUILD_FMT
# ---------------------------------------------------------------------------
primer_load_defaults() {
  local stack="${1:-}"
  local dir="${2:-.}"

  if [[ -z "$stack" ]]; then
    stack="$(primer_detect_stack "$dir")"
  fi

  if [[ "$stack" == "unknown" ]]; then
    primer_warn "Could not detect stack in ${dir}, no build defaults loaded"
    return 1
  fi

  local patterns_file="${Primer_GLOBAL_DIR}/defaults/build-patterns.toml"
  if [[ ! -f "$patterns_file" ]]; then
    primer_error "Build patterns file not found: ${patterns_file}"
    primer_error "Run 'primer init' to create global defaults"
    return 1
  fi

  # Parse TOML: extract values for the detected stack section
  local in_section=0
  Primer_BUILD_TEST=""
  Primer_BUILD_LINT=""
  Primer_BUILD_BUILD=""
  Primer_BUILD_FMT=""

  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Section header
    if [[ "$line" =~ ^\[([a-z_-]+)\] ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$stack" ]]; then
        in_section=1
      else
        [[ $in_section -eq 1 ]] && break  # past our section
        in_section=0
      fi
      continue
    fi

    # Key-value pairs inside our section
    if [[ $in_section -eq 1 && "$line" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*\"(.*)\" ]]; then
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      case "$key" in
        test)  Primer_BUILD_TEST="$val" ;;
        lint)  Primer_BUILD_LINT="$val" ;;
        build) Primer_BUILD_BUILD="$val" ;;
        fmt)   Primer_BUILD_FMT="$val" ;;
      esac
    fi
  done < "$patterns_file"

  primer_log "Loaded ${stack} build defaults (test=${Primer_BUILD_TEST:-<none>})"
  export Primer_BUILD_TEST Primer_BUILD_LINT Primer_BUILD_BUILD Primer_BUILD_FMT
  return 0
}

# ---------------------------------------------------------------------------
# primer_trust_check — Validate agent trust level for a proposed change
# $1 = agent name (claude-code|codex|cursor|...)
# $2 = target section (gotchas|skills|knowledge|constraints|trust-policy|build)
# $3 = confidence (0.0-1.0)
# Returns: 0 if allowed, 1 if denied
# Prints: "allowed", "review_required", or "denied"
# ---------------------------------------------------------------------------
primer_trust_check() {
  local agent="${1:?agent name required}"
  local target="${2:?target section required}"
  local confidence="${3:?confidence required}"

  local policy_file="${Primer_GLOBAL_DIR}/trust-policy.yaml"
  if [[ ! -f "$policy_file" ]]; then
    primer_error "Trust policy not found: ${policy_file}"
    echo "denied"
    return 1
  fi

  # Use yq if available for proper YAML parsing
  if command -v yq &>/dev/null; then
    _primer_trust_check_yq "$agent" "$target" "$confidence" "$policy_file"
    return $?
  fi

  # Fallback: simple grep-based parsing
  _primer_trust_check_grep "$agent" "$target" "$confidence" "$policy_file"
}

_primer_trust_check_yq() {
  local agent="$1" target="$2" confidence="$3" policy_file="$4"

  # Check if agent exists in policy, fall back to default
  local agent_key="$agent"
  local exists
  exists="$(yq eval ".trust_levels.\"${agent}\"" "$policy_file" 2>/dev/null)"
  if [[ "$exists" == "null" || -z "$exists" ]]; then
    agent_key="default"
  fi

  # Human can do anything
  if [[ "$agent_key" == "human" ]]; then
    echo "allowed"
    return 0
  fi

  # Check cannot_modify list
  local denied
  denied="$(yq eval ".trust_levels.\"${agent_key}\".cannot_modify[]" "$policy_file" 2>/dev/null)"
  while IFS= read -r item; do
    if [[ "$item" == "$target" ]]; then
      primer_log "Trust denied: ${agent} cannot modify ${target}"
      echo "denied"
      return 1
    fi
  done <<< "$denied"

  # Check can_modify list
  local allowed
  allowed="$(yq eval ".trust_levels.\"${agent_key}\".can_modify[]" "$policy_file" 2>/dev/null)"
  local in_allowed=0
  while IFS= read -r item; do
    if [[ "$item" == "$target" || "$item" == "all" ]]; then
      in_allowed=1
      break
    fi
  done <<< "$allowed"

  if [[ $in_allowed -eq 0 ]]; then
    primer_log "Trust denied: ${target} not in ${agent}'s can_modify list"
    echo "denied"
    return 1
  fi

  # Check confidence threshold
  local max_conf
  max_conf="$(yq eval ".trust_levels.\"${agent_key}\".max_confidence_auto_apply" "$policy_file" 2>/dev/null)"
  if [[ -n "$max_conf" && "$max_conf" != "null" ]]; then
    if awk "BEGIN {exit !($confidence <= $max_conf)}"; then
      echo "allowed"
      return 0
    else
      primer_log "Confidence ${confidence} exceeds auto-apply threshold ${max_conf} for ${agent}"
      echo "review_required"
      return 0
    fi
  fi

  echo "allowed"
  return 0
}

_primer_trust_check_grep() {
  local agent="$1" target="$2" confidence="$3" policy_file="$4"

  # Simple fallback: check if target appears in cannot_modify for this agent
  local in_agent_block=0
  local in_cannot=0
  local found_agent=0

  while IFS= read -r line; do
    # Detect agent block (handle both plain and quoted keys)
    if [[ "$line" =~ ^[[:space:]]{2}([a-z-]+): ]] || [[ "$line" =~ ^[[:space:]]{2}\"([a-z-]+)\": ]]; then
      local block_name="${BASH_REMATCH[1]}"
      if [[ "$block_name" == "$agent" ]]; then
        in_agent_block=1
        found_agent=1
      elif [[ $in_agent_block -eq 1 ]]; then
        break  # left our agent's block
      fi
    fi

    if [[ $in_agent_block -eq 1 ]]; then
      # Check cannot_modify
      if [[ "$line" =~ cannot_modify:.*\[(.+)\] ]]; then
        local items="${BASH_REMATCH[1]}"
        if echo "$items" | tr ',' '\n' | sed 's/[][ ]//g' | grep -qx "$target"; then
          echo "denied"
          return 1
        fi
      fi
      # Check can_modify
      if [[ "$line" =~ can_modify:.*\[(.+)\] ]]; then
        local items="${BASH_REMATCH[1]}"
        if echo "$items" | tr ',' '\n' | sed 's/[][ ]//g' | grep -qxE "(${target}|all)"; then
          echo "allowed"
          return 0
        fi
      fi
    fi
  done < "$policy_file"

  # If agent not found, use default trust (deny for safety)
  if [[ $found_agent -eq 0 ]]; then
    primer_warn "Agent '${agent}' not in trust policy, applying default (deny)"
    echo "denied"
    return 1
  fi

  echo "denied"
  return 1
}
