#!/usr/bin/env bash
# primer/lib/kpl.sh — Knowledge Persistence Layer
# Stores NON-INFERABLE info: decisions, gotchas, constraints, failure history.
# Uses TOML for structured data, Markdown for ADRs.

Primer_KPL_DIR="${Primer_KPL_DIR:-.ai/knowledge}"
Primer_KPL_TEMPLATE_DIR="${Primer_KPL_TEMPLATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates/knowledge/.ai/knowledge" 2>/dev/null && pwd)}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Approximate token count: words * 1.3
_kpl_token_count() {
  local text="$1"
  local words
  words=$(echo "$text" | wc -w | tr -d ' ')
  echo $(( (words * 13 + 9) / 10 ))
}

# Read a top-level key from a TOML section. Minimal parser, no nested tables.
# $1=file $2=section $3=key
_kpl_toml_get() {
  local file="$1" section="$2" key="$3"
  local in_section=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+)\] ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
        in_section=1
      else
        [[ $in_section -eq 1 ]] && return 0
        in_section=0
      fi
      continue
    fi
    # Match key literally (compare extracted key name)
    if [[ $in_section -eq 1 && "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.*) ]]; then
      local line_key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      if [[ "$line_key" == "$key" ]]; then
        # Strip surrounding quotes
        val="${val#\"}"
        val="${val%\"}"
        # Unescape TOML escaped characters
        val="${val//\\\"/\"}"
        val="${val//\\\\/\\}"
        echo "$val"
        return 0
      fi
    fi
  done < "$file"
}

# Set a key in a TOML section. Appends section if missing.
# $1=file $2=section $3=key $4=value
_kpl_toml_set() {
  local file="$1" section="$2" key="$3" value="$4"
  local tmpfile="${file}.tmp.$$"
  local in_section=0 key_written=0 section_found=0

  # Escape double quotes and backslashes in value for valid TOML
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"

  while IFS= read -r line; do
    if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+)\] ]]; then
      if [[ $in_section -eq 1 && $key_written -eq 0 ]]; then
        echo "${key} = \"${value}\""
        key_written=1
      fi
      if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
        in_section=1
        section_found=1
      else
        in_section=0
      fi
    fi
    if [[ $in_section -eq 1 && "$line" =~ ^([a-zA-Z0-9_-]+)[[:space:]]*= ]]; then
      local line_key="${BASH_REMATCH[1]}"
      if [[ "$line_key" == "$key" ]]; then
        echo "${key} = \"${value}\""
        key_written=1
        continue
      fi
    fi
    echo "$line"
  done < "$file" > "$tmpfile"

  if [[ $in_section -eq 1 && $key_written -eq 0 ]]; then
    echo "${key} = \"${value}\"" >> "$tmpfile"
    key_written=1
  fi

  if [[ $section_found -eq 0 ]]; then
    echo "" >> "$tmpfile"
    echo "[$section]" >> "$tmpfile"
    echo "${key} = \"${value}\"" >> "$tmpfile"
  fi

  mv "$tmpfile" "$file"
}

# Check if a path matches a glob pattern (fnmatch-style).
# $1=pattern $2=path
_kpl_glob_match() {
  local pattern="$1" path="$2"
  # Convert glob to regex. Use placeholders to avoid double-substitution.
  local ph1=$'\x01' ph2=$'\x02'
  local re="$pattern"
  re="${re//./\\.}"
  # **/ should match zero or more directory segments (including empty)
  re="${re//\*\*\//$ph1}"
  # standalone ** matches everything
  re="${re//\*\*/$ph2}"
  # single * matches anything except /
  re="${re//\*/[^/]*}"
  # Now replace placeholders with actual regex
  re="${re//$ph1/(.+/)?}"
  re="${re//$ph2/.*}"
  re="^${re}$"
  [[ "$path" =~ $re ]]
}

# Field separator for entry parsing (ASCII Unit Separator, safe for arbitrary text)
_KPL_FS=$'\x1f'

# Parse all entries from a TOML file (gotchas, constraints, failures).
# Outputs: id<FS>summary<FS>applies_to<FS>severity<FS>date per entry
# where <FS> is ASCII Unit Separator (0x1F) to avoid conflicts with | in summaries.
_kpl_parse_entries() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local current_id="" summary="" applies_to="" severity="" date=""

  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\] ]]; then
      # Flush previous entry
      if [[ -n "$current_id" && -n "$summary" ]]; then
        printf '%s\n' "${current_id}${_KPL_FS}${summary}${_KPL_FS}${applies_to}${_KPL_FS}${severity}${_KPL_FS}${date}"
      fi
      summary="" applies_to="" severity="" date=""
      current_id="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^summary[[:space:]]*=[[:space:]]*\"(.*)\" ]]; then
      summary="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^applies_to[[:space:]]*=[[:space:]]*\[(.*)\] ]]; then
      applies_to="${BASH_REMATCH[1]}"
      # Clean up quotes and spaces
      applies_to="${applies_to//\"/}"
      applies_to="${applies_to// /}"
    elif [[ "$line" =~ ^severity[[:space:]]*=[[:space:]]*\"(.*)\" ]]; then
      severity="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^date[[:space:]]*=[[:space:]]*\"(.*)\" ]]; then
      date="${BASH_REMATCH[1]}"
    fi
  done < "$file"
  # Flush last entry
  if [[ -n "$current_id" && -n "$summary" ]]; then
    printf '%s\n' "${current_id}${_KPL_FS}${summary}${_KPL_FS}${applies_to}${_KPL_FS}${severity}${_KPL_FS}${date}"
  fi
}

# Severity to sort key (lower = higher priority)
_kpl_severity_rank() {
  case "$1" in
    high) echo 0 ;;
    medium) echo 1 ;;
    low) echo 2 ;;
    *) echo 3 ;;
  esac
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Initialize .ai/knowledge/ with manifest and template files
primer_kpl_init() {
  local target="${1:-$Primer_KPL_DIR}"
  if [[ -f "$target/manifest.toml" ]]; then
    echo "KPL already initialized at $target"
    return 0
  fi

  mkdir -p "$target/decisions"

  if [[ -n "${Primer_KPL_TEMPLATE_DIR:-}" && -d "$Primer_KPL_TEMPLATE_DIR" ]]; then
    # Only copy files that don't already exist (preserve template-provided knowledge)
    [[ ! -f "$target/manifest.toml" ]] && cp "$Primer_KPL_TEMPLATE_DIR/manifest.toml" "$target/manifest.toml"
    [[ ! -f "$target/gotchas.toml" ]] && cp "$Primer_KPL_TEMPLATE_DIR/gotchas.toml" "$target/gotchas.toml"
    [[ ! -f "$target/constraints.toml" ]] && cp "$Primer_KPL_TEMPLATE_DIR/constraints.toml" "$target/constraints.toml"
    [[ ! -f "$target/failures.toml" ]] && cp "$Primer_KPL_TEMPLATE_DIR/failures.toml" "$target/failures.toml"
    [[ ! -f "$target/decisions/TEMPLATE.md" ]] && cp "$Primer_KPL_TEMPLATE_DIR/decisions/TEMPLATE.md" "$target/decisions/TEMPLATE.md"
  else
    # Inline minimal templates
    cat > "$target/manifest.toml" <<'TOML'
[meta]
version = "1.0"
project = ""
created = ""
last_pruned = ""

[budget]
tier0_max_tokens = 200
tier1_max_tokens = 1500
tier2_max_tokens = 5000
TOML
    [[ ! -f "$target/gotchas.toml" ]] && touch "$target/gotchas.toml"
    [[ ! -f "$target/constraints.toml" ]] && touch "$target/constraints.toml"
    [[ ! -f "$target/failures.toml" ]] && touch "$target/failures.toml"
    cat > "$target/decisions/TEMPLATE.md" <<'MD'
# ADR-XXXX: Title

## Status
Proposed | Accepted | Deprecated | Superseded

## Context
Why this decision was needed.

## Decision
What we decided.

## Consequences
What happens as a result.

## Alternatives Considered
What we didn't choose, and why.
MD
  fi

  # Stamp creation date
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _kpl_toml_set "$target/manifest.toml" "meta" "created" "$now"

  echo "KPL initialized at $target"
}

# Add a knowledge entry
# $1=type (gotcha|constraint|failure|decision)
# $2=id (slug, e.g. "no-orm-caching")
# $3=summary (one-line description)
# $4=applies_to (comma-separated globs, e.g. "src/db/**,lib/cache.ts")
# $5=severity (high|medium|low)
primer_kpl_add() {
  local type="${1:?type required: gotcha|constraint|failure|decision}"
  local id="${2:?id required}"
  local summary="${3:?summary required}"
  local applies_to="${4:?applies_to globs required}"
  local severity="${5:-medium}"
  local target="${Primer_KPL_DIR}"

  [[ -f "$target/manifest.toml" ]] || { echo "KPL not initialized. Run primer_kpl_init first." >&2; return 1; }

  # Validate ID: must be a valid TOML bare key (alphanumeric, hyphens, underscores only)
  if [[ ! "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid id: '$id'. Use only alphanumeric characters, hyphens, and underscores (no spaces or dots)." >&2
    return 1
  fi

  if [[ "$type" == "decision" ]]; then
    local adr_file="$target/decisions/${id}.md"
    if [[ -f "$adr_file" ]]; then
      echo "Decision $id already exists at $adr_file" >&2
      return 1
    fi
    local safe_id safe_summary
    safe_id=$(printf '%s' "$id" | sed 's/[&/\]/\\&/g')
    safe_summary=$(printf '%s' "$summary" | sed 's/[&/\]/\\&/g')
    sed "s/ADR-XXXX: Title/ADR-${safe_id}: ${safe_summary}/" "$target/decisions/TEMPLATE.md" > "$adr_file"
    echo "Decision added: $adr_file"
    # Record in manifest
    _kpl_toml_set "$target/manifest.toml" "entry.${id}" "type" "decision"
    _kpl_toml_set "$target/manifest.toml" "entry.${id}" "summary" "$summary"
    _kpl_toml_set "$target/manifest.toml" "entry.${id}" "applies_to" "$applies_to"
    _kpl_toml_set "$target/manifest.toml" "entry.${id}" "severity" "$severity"
    _kpl_toml_set "$target/manifest.toml" "entry.${id}" "added" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    return 0
  fi

  # For gotcha, constraint, failure: append to the corresponding TOML file
  local toml_file
  case "$type" in
    gotcha)     toml_file="$target/gotchas.toml" ;;
    constraint) toml_file="$target/constraints.toml" ;;
    failure)    toml_file="$target/failures.toml" ;;
    *) echo "Unknown type: $type. Use gotcha|constraint|failure|decision." >&2; return 1 ;;
  esac

  # Check for duplicate entry ID in the target TOML file
  if [[ -f "$toml_file" ]] && grep -qE "^\[${id}\]" "$toml_file" 2>/dev/null; then
    echo "Conflict: $type '$id' already exists in $(basename "$toml_file"). Skipping duplicate." >&2
    return 2
  fi

  # Build applies_to array string
  local applies_arr=""
  IFS=',' read -ra globs <<< "$applies_to"
  for g in "${globs[@]}"; do
    [[ -n "$applies_arr" ]] && applies_arr="${applies_arr}, "
    applies_arr="${applies_arr}\"${g}\""
  done

  # Escape double quotes and backslashes in summary for valid TOML
  local escaped_summary="${summary//\\/\\\\}"
  escaped_summary="${escaped_summary//\"/\\\"}"

  {
    echo ""
    echo "[$id]"
    echo "summary = \"$escaped_summary\""
    echo "applies_to = [${applies_arr}]"
    echo "severity = \"$severity\""
    [[ "$type" == "failure" ]] && echo "date = \"$(date -u +%Y-%m-%d)\""
  } >> "$toml_file"

  # Record in manifest
  _kpl_toml_set "$target/manifest.toml" "entry.${id}" "type" "$type"
  _kpl_toml_set "$target/manifest.toml" "entry.${id}" "summary" "$summary"
  _kpl_toml_set "$target/manifest.toml" "entry.${id}" "applies_to" "$applies_to"
  _kpl_toml_set "$target/manifest.toml" "entry.${id}" "severity" "$severity"
  _kpl_toml_set "$target/manifest.toml" "entry.${id}" "added" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  echo "Added $type: $id"
}

# Query entries matching given file paths
# $@ = file paths to check against applies_to globs
primer_kpl_query() {
  local target="${Primer_KPL_DIR}"
  [[ -f "$target/manifest.toml" ]] || { echo "KPL not initialized." >&2; return 1; }

  local -a query_paths=("$@")
  [[ ${#query_paths[@]} -eq 0 ]] && { echo "Usage: primer_kpl_query <path> [path...]" >&2; return 1; }

  local -a results=()

  # Scan all entry files
  local toml_file
  for toml_file in "$target/gotchas.toml" "$target/constraints.toml" "$target/failures.toml"; do
    [[ -f "$toml_file" ]] || continue
    while IFS="$_KPL_FS" read -r eid esummary eapplies eseverity edate; do
      [[ -z "$eid" ]] && continue
      # Check each query path against each applies_to glob
      local -a globs
      IFS=',' read -ra globs <<< "$eapplies"
      local matched=0
      for glob in "${globs[@]}"; do
        for qpath in "${query_paths[@]}"; do
          if _kpl_glob_match "$glob" "$qpath"; then
            matched=1
            break 2
          fi
        done
      done
      if [[ $matched -eq 1 ]]; then
        local rank
        rank=$(_kpl_severity_rank "$eseverity")
        results+=("${rank}${_KPL_FS}${eid}${_KPL_FS}${esummary}${_KPL_FS}${eseverity}${_KPL_FS}${edate}")
      fi
    done < <(_kpl_parse_entries "$toml_file")
  done

  # Also check decision entries in manifest
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[entry\.([a-zA-Z0-9_-]+)\] ]]; then
      local eid="${BASH_REMATCH[1]}"
      local etype esummary eapplies eseverity
      etype=$(_kpl_toml_get "$target/manifest.toml" "entry.${eid}" "type")
      [[ "$etype" != "decision" ]] && continue
      esummary=$(_kpl_toml_get "$target/manifest.toml" "entry.${eid}" "summary")
      eapplies=$(_kpl_toml_get "$target/manifest.toml" "entry.${eid}" "applies_to")
      eseverity=$(_kpl_toml_get "$target/manifest.toml" "entry.${eid}" "severity")
      IFS=',' read -ra globs <<< "$eapplies"
      local matched=0
      for glob in "${globs[@]}"; do
        for qpath in "${query_paths[@]}"; do
          if _kpl_glob_match "$glob" "$qpath"; then
            matched=1
            break 2
          fi
        done
      done
      if [[ $matched -eq 1 ]]; then
        local rank
        rank=$(_kpl_severity_rank "$eseverity")
        results+=("${rank}${_KPL_FS}${eid}${_KPL_FS}${esummary}${_KPL_FS}${eseverity}${_KPL_FS}decision")
      fi
    fi
  done < "$target/manifest.toml"

  if [[ ${#results[@]} -eq 0 ]]; then
    echo "No matching entries."
    return 0
  fi

  # Sort by severity rank
  printf '%s\n' "${results[@]}" | sort -t"$_KPL_FS" -k1,1n | while IFS="$_KPL_FS" read -r _ eid esummary eseverity eextra; do
    printf "[%s] %-8s %s" "$eseverity" "$eid" "$esummary"
    [[ -n "$eextra" ]] && printf " (%s)" "$eextra"
    printf "\n"
  done
}

# Show token budget usage by tier
primer_kpl_budget() {
  local target="${Primer_KPL_DIR}"
  [[ -f "$target/manifest.toml" ]] || { echo "KPL not initialized." >&2; return 1; }

  local tier0_max tier1_max tier2_max
  tier0_max=$(_kpl_toml_get "$target/manifest.toml" "budget" "tier0_max_tokens")
  tier1_max=$(_kpl_toml_get "$target/manifest.toml" "budget" "tier1_max_tokens")
  tier2_max=$(_kpl_toml_get "$target/manifest.toml" "budget" "tier2_max_tokens")
  tier0_max="${tier0_max:-200}"
  tier1_max="${tier1_max:-1500}"
  tier2_max="${tier2_max:-5000}"

  # Count content in each file
  local t0_content t1_content t2_content
  t0_content=$(head -20 "$target/manifest.toml" 2>/dev/null || echo "")
  local t0_tokens
  t0_tokens=$(_kpl_token_count "$t0_content")

  local t1_content=""
  for f in "$target/gotchas.toml" "$target/constraints.toml" "$target/failures.toml"; do
    [[ -f "$f" ]] && t1_content="${t1_content}$(cat "$f")"
  done
  local t1_tokens
  t1_tokens=$(_kpl_token_count "$t1_content")

  local t2_content=""
  for f in "$target/decisions"/*.md; do
    [[ -f "$f" && "$(basename "$f")" != "TEMPLATE.md" ]] && t2_content="${t2_content}$(cat "$f")"
  done
  local t2_tokens
  t2_tokens=$(_kpl_token_count "$t2_content")

  echo "KPL Token Budget"
  echo "================"
  printf "Tier 0 (always):       %4d / %4d tokens\n" "$t0_tokens" "$tier0_max"
  printf "Tier 1 (scope-match):  %4d / %4d tokens\n" "$t1_tokens" "$tier1_max"
  printf "Tier 2 (on-demand):    %4d / %4d tokens\n" "$t2_tokens" "$tier2_max"
  echo ""
  local total=$(( t0_tokens + t1_tokens + t2_tokens ))
  local total_max=$(( tier0_max + tier1_max + tier2_max ))
  printf "Total:                 %4d / %4d tokens\n" "$total" "$total_max"
}

# List deprecated/stale entries for pruning
primer_kpl_prune() {
  local target="${Primer_KPL_DIR}"
  local dry_run="${1:---dry-run}"
  [[ -f "$target/manifest.toml" ]] || { echo "KPL not initialized." >&2; return 1; }

  echo "Scanning for deprecated entries..."
  local found=0

  # Check decisions for "Deprecated" or "Superseded" status
  for f in "$target/decisions"/*.md; do
    [[ -f "$f" && "$(basename "$f")" != "TEMPLATE.md" ]] || continue
    if grep -qE '^\s*(Deprecated|Superseded)\s*$' "$f" 2>/dev/null; then
      local basename_f
      basename_f=$(basename "$f" .md)
      echo "  STALE: decision/$basename_f (status: deprecated/superseded)"
      found=1
      if [[ "$dry_run" == "--apply" ]]; then
        rm "$f"
        echo "    -> removed"
      fi
    fi
  done

  if [[ $found -eq 0 ]]; then
    echo "No stale entries found."
  elif [[ "$dry_run" != "--apply" ]]; then
    echo ""
    echo "Run with --apply to remove stale entries."
  else
    _kpl_toml_set "$target/manifest.toml" "meta" "last_pruned" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
}

# Generate context injection for given paths
# $1 = comma-separated file paths
# $2 = format: claude-md | agents-md | raw (default: claude-md)
primer_kpl_inject() {
  local paths_csv="${1:?paths required}"
  local format="${2:-claude-md}"
  local target="${Primer_KPL_DIR}"
  [[ -f "$target/manifest.toml" ]] || { echo "KPL not initialized." >&2; return 1; }

  local tier0_max tier1_max
  tier0_max=$(_kpl_toml_get "$target/manifest.toml" "budget" "tier0_max_tokens")
  tier1_max=$(_kpl_toml_get "$target/manifest.toml" "budget" "tier1_max_tokens")
  tier0_max="${tier0_max:-200}"
  tier1_max="${tier1_max:-1500}"

  # Split paths
  local -a query_paths=()
  IFS=',' read -ra query_paths <<< "$paths_csv"

  # --- Tier 0: manifest summary + entry count ---
  local project version
  project=$(_kpl_toml_get "$target/manifest.toml" "meta" "project")
  version=$(_kpl_toml_get "$target/manifest.toml" "meta" "version")

  local entry_count=0
  while IFS= read -r line; do
    [[ "$line" =~ ^\[entry\. ]] && (( entry_count++ ))
  done < "$target/manifest.toml"

  local tier0_out=""
  case "$format" in
    claude-md|agents-md)
      tier0_out="# Knowledge (${project:-project} v${version:-1.0}, ${entry_count} entries)"
      ;;
    raw)
      tier0_out="KPL: ${project:-project} v${version:-1.0}, ${entry_count} entries"
      ;;
  esac

  local tier0_tokens
  tier0_tokens=$(_kpl_token_count "$tier0_out")
  if (( tier0_tokens > tier0_max )); then
    tier0_out="${tier0_out:0:150}..."
  fi

  # --- Tier 1: scope-matched summaries ---
  local -a matched_entries=()

  for toml_file in "$target/gotchas.toml" "$target/constraints.toml" "$target/failures.toml"; do
    [[ -f "$toml_file" ]] || continue
    local ftype
    case "$(basename "$toml_file" .toml)" in
      gotchas) ftype="gotcha" ;;
      constraints) ftype="constraint" ;;
      failures) ftype="failure" ;;
    esac
    while IFS="$_KPL_FS" read -r eid esummary eapplies eseverity edate; do
      [[ -z "$eid" ]] && continue
      IFS=',' read -ra globs <<< "$eapplies"
      local matched=0
      for glob in "${globs[@]}"; do
        for qpath in "${query_paths[@]}"; do
          if _kpl_glob_match "$glob" "$qpath"; then
            matched=1
            break 2
          fi
        done
      done
      if [[ $matched -eq 1 ]]; then
        local rank
        rank=$(_kpl_severity_rank "$eseverity")
        matched_entries+=("${rank}${_KPL_FS}${ftype}${_KPL_FS}${eid}${_KPL_FS}${esummary}${_KPL_FS}${eseverity}")
      fi
    done < <(_kpl_parse_entries "$toml_file")
  done

  # Also check decision entries in manifest (same logic as primer_kpl_query)
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[entry\.([a-zA-Z0-9_-]+)\] ]]; then
      local eid="${BASH_REMATCH[1]}"
      local etype esummary eapplies eseverity
      etype=$(_kpl_toml_get "$target/manifest.toml" "entry.${eid}" "type")
      [[ "$etype" != "decision" ]] && continue
      esummary=$(_kpl_toml_get "$target/manifest.toml" "entry.${eid}" "summary")
      eapplies=$(_kpl_toml_get "$target/manifest.toml" "entry.${eid}" "applies_to")
      eseverity=$(_kpl_toml_get "$target/manifest.toml" "entry.${eid}" "severity")
      IFS=',' read -ra globs <<< "$eapplies"
      local matched=0
      for glob in "${globs[@]}"; do
        for qpath in "${query_paths[@]}"; do
          if _kpl_glob_match "$glob" "$qpath"; then
            matched=1
            break 2
          fi
        done
      done
      if [[ $matched -eq 1 ]]; then
        local rank
        rank=$(_kpl_severity_rank "$eseverity")
        matched_entries+=("${rank}${_KPL_FS}decision${_KPL_FS}${eid}${_KPL_FS}${esummary}${_KPL_FS}${eseverity}")
      fi
    fi
  done < "$target/manifest.toml"

  # Sort by severity
  local -a sorted_entries=()
  if [[ ${#matched_entries[@]} -gt 0 ]]; then
    while IFS= read -r line; do
      sorted_entries+=("$line")
    done < <(printf '%s\n' "${matched_entries[@]}" | sort -t"$_KPL_FS" -k1,1n)
  fi

  # Build tier1 output within budget
  local tier1_out=""
  local tier1_tokens=0

  for entry in ${sorted_entries[@]+"${sorted_entries[@]}"}; do
    IFS="$_KPL_FS" read -r _ etype eid esummary eseverity <<< "$entry"
    local line_out=""
    case "$format" in
      claude-md)
        line_out="- **${etype}/${eid}** [${eseverity}]: ${esummary}"
        ;;
      agents-md)
        line_out="- [${eseverity}] ${etype}/${eid}: ${esummary}"
        ;;
      raw)
        line_out="${etype}/${eid} (${eseverity}): ${esummary}"
        ;;
    esac

    local line_tokens
    line_tokens=$(_kpl_token_count "$line_out")
    if (( tier1_tokens + line_tokens > tier1_max )); then
      tier1_out="${tier1_out}
(... more entries available via primer_kpl_query)"
      break
    fi
    tier1_out="${tier1_out}
${line_out}"
    (( tier1_tokens += line_tokens ))
  done

  # --- Combine output ---
  echo "$tier0_out"
  if [[ -n "$tier1_out" ]]; then
    echo "$tier1_out"
  fi
}
