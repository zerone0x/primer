#!/usr/bin/env bash
# primer/lib/hooks.sh — Hook management for Primer
# Manages hooks in .ai/plugins/hooks.d/ and the built-in hooks.d/ directory.
# Hooks are organized by lifecycle stage and chained via stdin/stdout pipeline.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Known lifecycle stages (Claude Code mapping in comments)
Primer_HOOK_STAGES=(
  pre-generate       # Before config generation begins
  post-generate      # After config generation completes
  pre-emit           # Before emitting to tool-native format
  post-emit          # After emitting (sync to tool settings)
  pre-evolve         # Before processing evolution proposals
  post-evolve        # After processing evolution proposals
  on-knowledge-update # When knowledge entries change
  on-phase-change    # When project phase changes
  on-skill-create    # When a new skill is created
  on-error           # When a hook or generator fails
)

# ---------------------------------------------------------------------------
# Hook discovery
# ---------------------------------------------------------------------------

# Collect all hook scripts for a given stage, sorted by numeric prefix.
# Searches both built-in hooks.d/ and per-project .ai/plugins/hooks/.
# Returns paths, one per line, in execution order.
_primer_hooks_collect() {
  local stage="${1:?stage required}"
  local hooks=()

  # Built-in hooks shipped with Primer
  local primer_root
  primer_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local builtin_dir="$primer_root/plugins/hooks.d/$stage"
  if [[ -d "$builtin_dir" ]]; then
    for h in "$builtin_dir"/*; do
      [[ -f "$h" && -x "$h" ]] && hooks+=("$h")
    done
  fi

  # Per-project hooks from .ai/ sources (if Primer_SOURCES is populated)
  if [[ ${#Primer_SOURCES[@]:-0} -gt 0 ]]; then
    for src in "${Primer_SOURCES[@]}"; do
      local hdir="$src/plugins/hooks/$stage"
      [[ -d "$hdir" ]] || continue
      for h in "$hdir"/*; do
        [[ -f "$h" && -x "$h" ]] && hooks+=("$h")
      done
    done
  fi

  # Sort by basename (numeric prefix ordering: 10-foo before 20-bar)
  if [[ ${#hooks[@]} -gt 0 ]]; then
    printf '%s\n' "${hooks[@]}" | while read -r p; do
      echo "$(basename "$p") $p"
    done | sort -t- -k1,1n | awk '{print $2}'
  fi
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# List all hooks across all stages and sources.
# Output: stage<TAB>priority<TAB>path
primer_hooks_list() {
  local primer_root
  primer_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local stage
  for stage in "${Primer_HOOK_STAGES[@]}"; do
    local hooks
    hooks=$(_primer_hooks_collect "$stage")
    [[ -z "$hooks" ]] && continue

    while IFS= read -r hpath; do
      [[ -z "$hpath" ]] && continue
      local bname
      bname="$(basename "$hpath")"
      local priority="${bname%%-*}"
      printf '%s\t%s\t%s\n' "$stage" "$priority" "$hpath"
    done <<< "$hooks"
  done
}

# Chain hooks for a lifecycle stage via stdin/stdout pipeline.
# $1 = stage name
# $2 = initial input (piped to first hook; defaults to '{}')
# Each hook receives the previous hook's stdout on its stdin.
# If any hook exits nonzero, the chain stops and we return failure.
primer_hooks_run() {
  local stage="${1:?stage required}"
  local input="${2:-{\}}"

  local hooks
  hooks=$(_primer_hooks_collect "$stage")

  if [[ -z "$hooks" ]]; then
    echo "$input"
    return 0
  fi

  local result="$input"
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    local next
    next=$(echo "$result" | "$h" 2>/dev/null) || {
      primer_error "Hook failed: $h (stage: $stage)"
      return 1
    }
    result="$next"
  done <<< "$hooks"

  echo "$result"
}

# Install a hook from a URL or local path.
# $1 = URL or local file path
# $2 = target stage (e.g., pre-emit)
# $3 = optional priority prefix (default: 50)
primer_hooks_install() {
  local source="${1:?source URL or path required}"
  local stage="${2:?stage required}"
  local priority="${3:-50}"

  # Validate stage
  local valid=0
  for s in "${Primer_HOOK_STAGES[@]}"; do
    [[ "$s" == "$stage" ]] && { valid=1; break; }
  done
  if [[ $valid -eq 0 ]]; then
    primer_error "Unknown hook stage: $stage"
    primer_error "Valid stages: ${Primer_HOOK_STAGES[*]}"
    return 1
  fi

  # Determine install directory (first .ai/ source, or PWD/.ai/)
  local ai_dir="${Primer_SOURCES[0]:-$PWD/.ai}"
  local hook_dir="$ai_dir/plugins/hooks/$stage"
  mkdir -p "$hook_dir"

  local filename
  if [[ "$source" =~ ^https?:// ]]; then
    filename="$(basename "$source")"
    # Prefix with priority if not already prefixed
    if ! [[ "$filename" =~ ^[0-9]+-  ]]; then
      filename="${priority}-${filename}"
    fi
    if command -v curl &>/dev/null; then
      curl -fsSL "$source" -o "$hook_dir/$filename" || {
        primer_error "Failed to download hook from $source"
        return 1
      }
    elif command -v wget &>/dev/null; then
      wget -q "$source" -O "$hook_dir/$filename" || {
        primer_error "Failed to download hook from $source"
        return 1
      }
    else
      primer_error "Neither curl nor wget found"
      return 1
    fi
  elif [[ -f "$source" ]]; then
    filename="$(basename "$source")"
    if ! [[ "$filename" =~ ^[0-9]+- ]]; then
      filename="${priority}-${filename}"
    fi
    cp "$source" "$hook_dir/$filename"
  else
    primer_error "Source not found: $source"
    return 1
  fi

  chmod +x "$hook_dir/$filename"
  primer_success "Installed hook: $hook_dir/$filename"
}

# Dry-run hooks for a stage with sample input.
# $1 = stage name
# $2 = optional sample input (defaults to a test JSON object)
primer_hooks_test() {
  local stage="${1:?stage required}"
  local sample="${2:-{\"_primer_test\": true, \"stage\": \"$stage\"}}"

  local hooks
  hooks=$(_primer_hooks_collect "$stage")

  if [[ -z "$hooks" ]]; then
    primer_info "No hooks found for stage: $stage"
    return 0
  fi

  primer_info "Testing hooks for stage: $stage"
  primer_info "Input: $sample"
  echo

  local result="$sample"
  local i=0
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    i=$((i + 1))
    local bname
    bname="$(basename "$h")"
    primer_info "  [$i] Running: $bname"

    local next
    next=$(echo "$result" | "$h" 2>&1) && {
      primer_success "    Passed (output: ${#next} bytes)"
      result="$next"
    } || {
      primer_error "    Failed (exit code: $?)"
      primer_error "    Output: $next"
      return 1
    }
  done <<< "$hooks"

  echo
  primer_success "All hooks passed for stage: $stage"
  primer_info "Final output: $result"
}
