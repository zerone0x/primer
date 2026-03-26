#!/usr/bin/env bash
# primer/lib/core.sh — Plugin discovery, directory walk, hook dispatch, config loading
# Part of Primer (Portable AI Infrastructure Config)

# ---------------------------------------------------------------------------
# Plugin / source discovery
# ---------------------------------------------------------------------------

# Walk from CWD up to $HOME collecting directories that contain .ai/
# Results stored in Primer_SOURCES array (deepest first).
primer_discover_sources() {
  Primer_SOURCES=()
  local dir="$PWD"
  while true; do
    if [[ -d "$dir/.ai" ]]; then
      Primer_SOURCES+=("$dir/.ai")
    fi
    # Stop when we reach HOME or root
    [[ "$dir" == "$HOME" || "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
  # Also check HOME if we haven't already
  if [[ -d "$HOME/.ai" ]]; then
    local already=0
    for s in "${Primer_SOURCES[@]}"; do
      [[ "$s" == "$HOME/.ai" ]] && already=1
    done
    [[ $already -eq 0 ]] && Primer_SOURCES+=("$HOME/.ai")
  fi
}

# Find plugins of a given type across all sources.
# Types: commands, generators, hooks, validators
# Prints plugin paths, one per line.
primer_discover_plugins() {
  local ptype="${1:?plugin type required}"
  [[ ${#Primer_SOURCES[@]} -eq 0 ]] && return 0
  for src in "${Primer_SOURCES[@]}"; do
    local pdir="$src/plugins/$ptype"
    [[ -d "$pdir" ]] || continue
    for f in "$pdir"/*; do
      [[ -f "$f" && -x "$f" ]] && echo "$f" || true
    done
  done
  return 0
}

# ---------------------------------------------------------------------------
# Hook dispatch
# ---------------------------------------------------------------------------

# Run hooks for a lifecycle stage. Hooks are chained via stdin/stdout.
# Hooks are sorted by numeric prefix (e.g., 10-validate.sh runs before 20-lint.sh).
# $1 = stage name (pre-emit, post-emit, pre-evolve, post-evolve, ...)
# $2 = initial input (JSON string, piped to first hook)
primer_run_hooks() {
  local stage="${1:?stage required}"
  local input="${2:-{\}}"
  local hooks=()
  local h

  [[ ${#Primer_SOURCES[@]} -eq 0 ]] && { echo "$input"; return 0; }
  for src in "${Primer_SOURCES[@]}"; do
    local hdir="$src/plugins/hooks/$stage"
    [[ -d "$hdir" ]] || continue
    for h in "$hdir"/*; do
      [[ -f "$h" && -x "$h" ]] && hooks+=("$h")
    done
  done

  # Sort hooks by basename (numeric prefix ordering)
  if [[ ${#hooks[@]} -gt 0 ]]; then
    local sorted
    sorted=$(printf '%s\n' "${hooks[@]}" | while read -r p; do
      echo "$(basename "$p") $p"
    done | sort -t- -k1,1n | awk '{print $2}')

    local result="$input"
    while IFS= read -r h; do
      [[ -z "$h" ]] && continue
      result=$(echo "$result" | "$h") || {
        primer_error "Hook failed: $h"
        return 1
      }
    done <<< "$sorted"
    echo "$result"
  else
    echo "$input"
  fi
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

# Load project.yaml from the nearest .ai/ source.
# Sets Primer_CONFIG as the raw YAML content and Primer_CONFIG_FILE as the path.
primer_load_config() {
  Primer_CONFIG=""
  Primer_CONFIG_FILE=""
  [[ ${#Primer_SOURCES[@]} -eq 0 ]] && return 1
  for src in "${Primer_SOURCES[@]}"; do
    if [[ -f "$src/project.yaml" ]]; then
      Primer_CONFIG_FILE="$src/project.yaml"
      Primer_CONFIG="$(cat "$Primer_CONFIG_FILE")"
      return 0
    fi
  done
  return 1
}

# Read a value from project.yaml. Uses yq if available, falls back to grep/sed.
# $1 = dotpath key (e.g., "project.name" or "budget.max_tokens")
primer_config_get() {
  local key="${1:?key required}"
  if [[ -z "${Primer_CONFIG_FILE:-}" ]]; then
    primer_load_config || return 1
  fi
  if command -v yq &>/dev/null; then
    yq eval ".$key" "$Primer_CONFIG_FILE" 2>/dev/null
  else
    # Simple fallback: handle single-level and two-level keys
    local leaf="${key##*.}"
    grep -E "^\s*${leaf}:" "$Primer_CONFIG_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/\s*$//'
  fi
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

# SHA256 hash for drift detection
primer_hash() {
  local content="${1:?content required}"
  if command -v sha256sum &>/dev/null; then
    echo -n "$content" | sha256sum | awk '{print $1}'
  else
    echo -n "$content" | shasum -a 256 | awk '{print $1}'
  fi
}
