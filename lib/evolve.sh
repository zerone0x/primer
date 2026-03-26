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
      ptype=$(jq -r '.type // empty' "$pfile" 2>/dev/null)
      pagent=$(jq -r '.agent // empty' "$pfile" 2>/dev/null)

      if [[ -z "$ptype" ]]; then
        primer_warn "Skipping $pname: missing 'type' field"
        ((skipped++))
        continue
      fi
    fi

    # In non-auto mode, prompt for confirmation
    if [[ $auto -eq 0 ]]; then
      echo -n "  Apply $pname? [y/N] "
      read -r answer
      if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        primer_info "Skipped: $pname"
        ((skipped++))
        continue
      fi
    fi

    # Apply the proposal
    local change
    change=$(cat "$pfile")

    # Log the application
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    primer_log_entry "$(jq -n \
      --arg ts "$ts" \
      --arg file "$pname" \
      --arg action "applied" \
      '{timestamp: $ts, file: $file, action: $action}' 2>/dev/null \
    || echo "{\"timestamp\":\"$ts\",\"file\":\"$pname\",\"action\":\"applied\"}")"

    # Move proposal to applied
    local applied_dir="$ai_dir/evolution/applied"
    mkdir -p "$applied_dir"
    mv "$pfile" "$applied_dir/$pname"
    ((applied++))
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

  for src in "${Primer_SOURCES[@]}"; do
    local logfile="$src/evolution/log.jsonl"
    [[ -f "$logfile" ]] || continue

    if command -v jq &>/dev/null; then
      local filter="."
      [[ -n "$agent" ]] && filter="select(.agent == \"$agent\" or .file // \"\" | contains(\"$agent\"))"
      [[ -n "$since" ]] && filter="$filter | select(.timestamp >= \"$since\")"
      jq -c "$filter" "$logfile" 2>/dev/null
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
