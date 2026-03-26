#!/usr/bin/env bash
# primer/lib/evolve.sh — Evolution proposal handling for Primer
# Manages the propose -> validate -> apply -> log -> regenerate lifecycle.

# ---------------------------------------------------------------------------
# Process evolution proposals
# ---------------------------------------------------------------------------

primer_evolve() {
  local auto=0
  [[ "${1:-}" == "--auto" ]] && auto=1

  local ai_dir=""
  if [[ ${#Primer_SOURCES[@]:-0} -eq 0 ]]; then
    primer_info "No .ai/ sources found. Nothing to evolve."
    return 0
  fi
  for src in "${Primer_SOURCES[@]}"; do
    if [[ -d "$src/evolution/proposals" ]]; then
      ai_dir="$src"
      break
    fi
  done

  if [[ -z "$ai_dir" ]]; then
    primer_info "No proposals directory found. Nothing to evolve."
    return 0
  fi

  local proposals_dir="$ai_dir/evolution/proposals"
  local proposals=()
  for p in "$proposals_dir"/*.json "$proposals_dir"/*.yaml; do
    [[ -f "$p" ]] && proposals+=("$p")
  done

  if [[ ${#proposals[@]} -eq 0 ]]; then
    primer_info "No pending proposals."
    return 0
  fi

  primer_info "Found ${#proposals[@]} proposal(s)"

  # Run pre-evolve hooks
  local context
  context=$(jq -n --arg count "${#proposals[@]}" '{proposal_count: ($count | tonumber)}' 2>/dev/null || echo '{}')
  primer_run_hooks "pre-evolve" "$context" >/dev/null || return 1

  local applied=0
  local skipped=0

  for pfile in "${proposals[@]}"; do
    local pname
    pname="$(basename "$pfile")"
    primer_info "Processing: $pname"

    # Validate proposal has required fields
    if command -v jq &>/dev/null && [[ "$pfile" == *.json ]]; then
      local ptype pagent
      ptype=$(jq -r '.type // empty' "$pfile" 2>/dev/null) || true
      pagent=$(jq -r '.agent // empty' "$pfile" 2>/dev/null) || true

      if [[ -z "$ptype" ]]; then
        primer_warn "Skipping $pname: missing 'type' field"
        skipped=$((skipped + 1))
        continue
      fi
    elif [[ "$pfile" == *.yaml || "$pfile" == *.yml ]]; then
      # Basic YAML validation: check the file has a 'type:' field
      if ! grep -qE '^type:' "$pfile" 2>/dev/null; then
        if command -v yq &>/dev/null; then
          local ptype_yaml
          ptype_yaml=$(yq eval '.type // ""' "$pfile" 2>/dev/null) || true
          if [[ -z "$ptype_yaml" ]]; then
            primer_warn "Skipping $pname: missing 'type' field"
            skipped=$((skipped + 1))
            continue
          fi
        else
          primer_warn "Skipping $pname: missing 'type' field (no yq for full YAML validation)"
          skipped=$((skipped + 1))
          continue
        fi
      fi
    fi

    # In non-auto mode, prompt for confirmation
    if [[ $auto -eq 0 ]]; then
      echo -n "  Apply $pname? [y/N] "
      read -r answer
      if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        primer_info "Skipped: $pname"
        skipped=$((skipped + 1))
        continue
      fi
    fi

    # Apply the proposal: interpret type and execute the change
    local change
    change=$(cat "$pfile")

    # Extract proposal fields for YAML files (using grep/sed fallback)
    local ptype="" pagent="" change_id="" change_summary="" change_applies="" change_severity=""
    if [[ "$pfile" == *.yaml || "$pfile" == *.yml ]]; then
      ptype=$(grep -E '^type:' "$pfile" 2>/dev/null | head -1 | sed 's/^type:[[:space:]]*//' | tr -d '"' | sed 's/[[:space:]]*$//')
      pagent=$(grep -E '^agent:' "$pfile" 2>/dev/null | head -1 | sed 's/^agent:[[:space:]]*//' | tr -d '"' | sed 's/[[:space:]]*$//')
      change_id=$(grep -E '^\s+id:' "$pfile" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"' | sed 's/[[:space:]]*$//')
      change_summary=$(grep -E '^\s+summary:' "$pfile" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"' | sed 's/[[:space:]]*$//')
      change_applies=$(grep -E '^\s+applies_to:' "$pfile" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[]"' | sed 's/[[:space:]]*$//')
      change_severity=$(grep -E '^\s+severity:' "$pfile" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"' | sed 's/[[:space:]]*$//')
    elif command -v jq &>/dev/null && [[ "$pfile" == *.json ]]; then
      ptype=$(jq -r '.type // empty' "$pfile" 2>/dev/null) || true
      pagent=$(jq -r '.agent // empty' "$pfile" 2>/dev/null) || true
      change_id=$(jq -r '.change.id // empty' "$pfile" 2>/dev/null) || true
      change_summary=$(jq -r '.change.summary // empty' "$pfile" 2>/dev/null) || true
      change_applies=$(jq -r '.change.applies_to // "" | if type == "array" then join(",") else . end' "$pfile" 2>/dev/null) || true
      change_severity=$(jq -r '.change.severity // "medium"' "$pfile" 2>/dev/null) || true
    fi

    # Map proposal type to trust target section
    local trust_target=""
    case "$ptype" in
      add_gotcha)     trust_target="gotchas" ;;
      add_constraint) trust_target="constraints" ;;
      add_failure)    trust_target="knowledge" ;;
      add_decision)   trust_target="knowledge" ;;
      *)              trust_target="knowledge" ;;
    esac

    # Enforce trust policy if a trust-policy.yaml exists
    if [[ -n "$pagent" && -n "$trust_target" ]]; then
      local trust_result=""
      trust_result=$(_primer_evolve_trust_check "$pagent" "$trust_target") || true
      if [[ "$trust_result" == "denied" ]]; then
        primer_warn "Trust policy denied: agent '$pagent' cannot modify '$trust_target'"
        primer_warn "Skipping $pname (move to .ai/evolution/proposals/ and apply as 'human' to override)"
        skipped=$((skipped + 1))

        # Log the rejection
        local ts
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        primer_log_entry "$(jq -n \
          --arg ts "$ts" \
          --arg file "$pname" \
          --arg agent "${pagent:-unknown}" \
          --arg type "${ptype:-unknown}" \
          --arg action "denied" \
          --arg reason "trust_policy" \
          '{timestamp: $ts, file: $file, agent: $agent, type: $type, action: $action, reason: $reason}' 2>/dev/null \
        || echo "{\"timestamp\":\"$ts\",\"file\":\"$pname\",\"agent\":\"${pagent:-unknown}\",\"type\":\"${ptype:-unknown}\",\"action\":\"denied\",\"reason\":\"trust_policy\"}")"

        # Move denied proposal to rejected directory
        local rejected_dir="$ai_dir/evolution/rejected"
        mkdir -p "$rejected_dir"
        mv "$pfile" "$rejected_dir/$pname"
        continue
      fi
    fi

    # Execute the change based on type
    if [[ -n "$ptype" && -n "$change_id" && -n "$change_summary" ]]; then
      local ai_dir="${Primer_SOURCES[0]:-$PWD/.ai}"
      export Primer_KPL_DIR="$ai_dir/knowledge"
      local kpl_rc=0
      local kpl_type=""
      case "$ptype" in
        add_gotcha)     kpl_type="gotcha" ;;
        add_constraint) kpl_type="constraint" ;;
        add_failure)    kpl_type="failure" ;;
        add_decision)   kpl_type="decision" ;;
        *)
          primer_info "  Unknown proposal type '$ptype' — moved to applied without action"
          ;;
      esac

      if [[ -n "$kpl_type" && -f "$Primer_KPL_DIR/manifest.toml" ]]; then
        local kpl_output=""
        kpl_output=$(primer_kpl_add "$kpl_type" "$change_id" "$change_summary" "${change_applies:-**/*}" "${change_severity:-medium}" 2>&1) && kpl_rc=$? || kpl_rc=$?
        if [[ $kpl_rc -eq 2 ]]; then
          primer_warn "Conflict: entry '$change_id' already exists — skipping $pname"
          skipped=$((skipped + 1))

          # Log the conflict
          local ts
          ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
          primer_log_entry "$(jq -n \
            --arg ts "$ts" \
            --arg file "$pname" \
            --arg agent "${pagent:-unknown}" \
            --arg type "${ptype:-unknown}" \
            --arg action "conflict" \
            --arg reason "duplicate_id:$change_id" \
            '{timestamp: $ts, file: $file, agent: $agent, type: $type, action: $action, reason: $reason}' 2>/dev/null \
          || echo "{\"timestamp\":\"$ts\",\"file\":\"$pname\",\"agent\":\"${pagent:-unknown}\",\"type\":\"${ptype:-unknown}\",\"action\":\"conflict\",\"reason\":\"duplicate_id:$change_id\"}")"

          # Move conflicting proposal to rejected
          local rejected_dir="$ai_dir/evolution/rejected"
          mkdir -p "$rejected_dir"
          mv "$pfile" "$rejected_dir/$pname"
          continue
        elif [[ $kpl_rc -ne 0 ]]; then
          primer_warn "Failed to add $kpl_type: $kpl_output"
        else
          echo "$kpl_output"
        fi
      fi
    fi

    # Log the application
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    primer_log_entry "$(jq -n \
      --arg ts "$ts" \
      --arg file "$pname" \
      --arg agent "${pagent:-unknown}" \
      --arg type "${ptype:-unknown}" \
      --arg action "applied" \
      '{timestamp: $ts, file: $file, agent: $agent, type: $type, action: $action}' 2>/dev/null \
    || echo "{\"timestamp\":\"$ts\",\"file\":\"$pname\",\"agent\":\"${pagent:-unknown}\",\"type\":\"${ptype:-unknown}\",\"action\":\"applied\"}")"

    # Move proposal to applied
    local applied_dir="$ai_dir/evolution/applied"
    mkdir -p "$applied_dir"
    mv "$pfile" "$applied_dir/$pname"
    applied=$((applied + 1))
    primer_success "Applied: $pname"
  done

  # Run post-evolve hooks
  primer_run_hooks "post-evolve" '{}' >/dev/null

  primer_info "Evolution complete: $applied applied, $skipped skipped"
}

# ---------------------------------------------------------------------------
# Create a proposal
# ---------------------------------------------------------------------------

# $1 = type (config, knowledge, constraint, ...)
# $2 = agent name
# $3 = change JSON
primer_propose() {
  local ptype="${1:?type required}"
  local agent="${2:?agent required}"
  local change_json="${3:?change_json required}"

  # Find or create proposals dir
  local ai_dir=""
  for src in "${Primer_SOURCES[@]}"; do
    ai_dir="$src"
    break
  done
  [[ -z "$ai_dir" ]] && ai_dir="$PWD/.ai"

  local proposals_dir="$ai_dir/evolution/proposals"
  mkdir -p "$proposals_dir"

  local ts
  ts=$(date -u +"%Y%m%d%H%M%S")
  local fname="${ts}-${agent}-${ptype}.json"

  local proposal
  proposal=$(jq -n \
    --arg type "$ptype" \
    --arg agent "$agent" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson change "$change_json" \
    '{type: $type, agent: $agent, timestamp: $ts, change: $change}' 2>/dev/null)

  if [[ -z "$proposal" ]]; then
    # Fallback without jq
    proposal="{\"type\":\"$ptype\",\"agent\":\"$agent\",\"change\":$change_json}"
  fi

  echo "$proposal" > "$proposals_dir/$fname"
  primer_success "Proposal created: $fname"
  echo "$proposals_dir/$fname"
}

# ---------------------------------------------------------------------------
# Evolution log
# ---------------------------------------------------------------------------

# Append an entry to the evolution log.
# $1 = entry JSON string
primer_log_entry() {
  local entry="${1:?entry required}"

  local ai_dir=""
  for src in "${Primer_SOURCES[@]}"; do
    ai_dir="$src"
    break
  done
  [[ -z "$ai_dir" ]] && ai_dir="$PWD/.ai"

  local logfile="$ai_dir/evolution/log.jsonl"
  mkdir -p "$(dirname "$logfile")"
  echo "$entry" >> "$logfile"
}

# Query the evolution log.
# Options: --agent NAME, --since DATE
primer_log_query() {
  local agent="" since=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) agent="$2"; shift 2 ;;
      --since) since="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [[ ${#Primer_SOURCES[@]:-0} -eq 0 ]] && return 0
  for src in "${Primer_SOURCES[@]}"; do
    local logfile="$src/evolution/log.jsonl"
    [[ -f "$logfile" ]] || continue

    if command -v jq &>/dev/null; then
      local jq_args=()
      local filter="."
      if [[ -n "$agent" ]]; then
        jq_args+=(--arg agent "$agent")
        filter='select(.agent == $agent or (.file // "" | contains($agent)))'
      fi
      if [[ -n "$since" ]]; then
        jq_args+=(--arg since "$since")
        filter="$filter | select(.timestamp >= \$since)"
      fi
      jq -c "${jq_args[@]+"${jq_args[@]}"}" "$filter" "$logfile" 2>/dev/null
    else
      if [[ -n "$agent" ]]; then
        grep "$agent" "$logfile"
      elif [[ -n "$since" ]]; then
        cat "$logfile"
      else
        cat "$logfile"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Trust policy enforcement for evolution
# ---------------------------------------------------------------------------

# Find trust-policy.yaml: check project .ai/ first, then ~/.ai/
_primer_evolve_find_trust_policy() {
  for src in "${Primer_SOURCES[@]}"; do
    local f="$src/trust-policy.yaml"
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  local global="$HOME/.ai/trust-policy.yaml"
  [[ -f "$global" ]] && { echo "$global"; return 0; }
  return 1
}

# Check trust policy for an agent modifying a target section.
# $1 = agent name
# $2 = target section (gotchas, constraints, knowledge, skills, etc.)
# Prints: "allowed" or "denied"
_primer_evolve_trust_check() {
  local agent="${1:?agent required}"
  local target="${2:?target required}"

  local policy_file
  policy_file=$(_primer_evolve_find_trust_policy) || {
    # No trust policy found — allow by default
    echo "allowed"
    return 0
  }

  # Use yq if available
  if command -v yq &>/dev/null; then
    # Check if agent exists, fall back to default
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
    local denied_items
    denied_items="$(yq eval ".trust_levels.\"${agent_key}\".cannot_modify[]" "$policy_file" 2>/dev/null)" || true
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      if [[ "$item" == "$target" ]]; then
        echo "denied"
        return 0
      fi
    done <<< "$denied_items"

    # Check can_modify list
    local allowed_items
    allowed_items="$(yq eval ".trust_levels.\"${agent_key}\".can_modify[]" "$policy_file" 2>/dev/null)" || true
    local in_allowed=0
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      if [[ "$item" == "$target" || "$item" == "all" ]]; then
        in_allowed=1
        break
      fi
    done <<< "$allowed_items"

    if [[ $in_allowed -eq 0 ]]; then
      echo "denied"
      return 0
    fi

    echo "allowed"
    return 0
  fi

  # Fallback: grep-based trust policy parsing
  local in_agent_block=0 found_agent=0

  while IFS= read -r line; do
    # Detect agent block
    if [[ "$line" =~ ^[[:space:]]{2}([a-zA-Z0-9_-]+):[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]{2}\"([a-zA-Z0-9_-]+)\":[[:space:]]*$ ]]; then
      local block_name="${BASH_REMATCH[1]}"
      if [[ "$block_name" == "$agent" ]]; then
        in_agent_block=1
        found_agent=1
      elif [[ $in_agent_block -eq 1 ]]; then
        break
      else
        in_agent_block=0
      fi
    fi

    if [[ $in_agent_block -eq 1 ]]; then
      if [[ "$line" =~ cannot_modify:.*\[(.+)\] ]]; then
        local items="${BASH_REMATCH[1]}"
        if echo "$items" | tr ',' '\n' | sed 's/[][ ]//g' | grep -qx "$target"; then
          echo "denied"
          return 0
        fi
      fi
      if [[ "$line" =~ can_modify:.*\[(.+)\] ]]; then
        local items="${BASH_REMATCH[1]}"
        if echo "$items" | tr ',' '\n' | sed 's/[][ ]//g' | grep -qxE "(${target}|all)"; then
          echo "allowed"
          return 0
        fi
      fi
    fi
  done < "$policy_file"

  # If agent not found, try "default" block
  if [[ $found_agent -eq 0 ]]; then
    in_agent_block=0
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]{2}default:[[:space:]]*$ ]]; then
        in_agent_block=1
      elif [[ $in_agent_block -eq 1 && "$line" =~ ^[[:space:]]{2}[a-zA-Z] ]]; then
        break
      fi
      if [[ $in_agent_block -eq 1 ]]; then
        if [[ "$line" =~ cannot_modify:.*\[(.+)\] ]]; then
          local items="${BASH_REMATCH[1]}"
          if echo "$items" | tr ',' '\n' | sed 's/[][ ]//g' | grep -qx "$target"; then
            echo "denied"
            return 0
          fi
        fi
        if [[ "$line" =~ can_modify:.*\[(.+)\] ]]; then
          local items="${BASH_REMATCH[1]}"
          if echo "$items" | tr ',' '\n' | sed 's/[][ ]//g' | grep -qxE "(${target}|all)"; then
            echo "allowed"
            return 0
          fi
        fi
      fi
    done < "$policy_file"
  fi

  # Default: deny for safety
  echo "denied"
  return 0
}
