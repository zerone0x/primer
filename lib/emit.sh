#!/usr/bin/env bash
# primer/lib/emit.sh — Generator dispatch for Primer
# Generates tool-native config files from canonical .ai/ config.

# ---------------------------------------------------------------------------
# Target registry (parallel arrays for bash 3.2 compat)
# ---------------------------------------------------------------------------

Primer_REG_TARGETS="claude-md agents-md cursorrules hermes-md"
Primer_REG_FILES="CLAUDE.md AGENTS.md .cursorrules .hermes.md"
Primer_REG_DETECT="command_-v_claude true test_-d_.cursor||command_-v_cursor test_-f_.hermes.md||command_-v_hermes"

# Resolve output filename for a target
_primer_target_file() {
  local target="$1"
  local i=1
  local t
  for t in $Primer_REG_TARGETS; do
    if [[ "$t" == "$target" ]]; then
      echo "$Primer_REG_FILES" | cut -d' ' -f"$i"
      return 0
    fi
    i=$((i + 1))
  done
  echo "$target"
}

# Check if a target's tool is detected
_primer_target_detected() {
  local target="$1"
  local i=1
  local t detect
  for t in $Primer_REG_TARGETS; do
    if [[ "$t" == "$target" ]]; then
      detect=$(echo "$Primer_REG_DETECT" | cut -d' ' -f"$i" | tr '_' ' ')
      eval "$detect" >/dev/null 2>&1
      return $?
    fi
    i=$((i + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# Config to JSON conversion
# ---------------------------------------------------------------------------

# Convert project.yaml to JSON for generator consumption.
# Uses yq if available, otherwise a lightweight bash/jq parser.
# $1 = path to YAML file
primer_config_to_json() {
  local yaml_file="${1:?yaml file required}"

  if command -v yq >/dev/null 2>&1; then
    yq eval -o=json "$yaml_file"
    return
  fi

  _primer_yaml_to_json "$yaml_file"
}

# Minimal YAML-to-JSON for the subset project.yaml uses.
# Handles: scalar key-value, simple lists, one level of nesting.
_primer_yaml_to_json() {
  local file="$1"
  local json="{}"
  local current_key=""
  local in_list=0
  local list_items=""
  local in_complex_block=0
  local block_indent=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    local stripped="${line#"${line%%[![:space:]]*}"}"
    local indent=$(( ${#line} - ${#stripped} ))

    # If inside a complex block (list-of-objects), skip until we return to base indent
    if [[ $in_complex_block -eq 1 ]]; then
      if [[ $indent -eq 0 ]]; then
        in_complex_block=0
      else
        continue
      fi
    fi

    # List item (simple string values only)
    if [[ "$line" =~ ^([[:space:]]*)-[[:space:]]+(.*) ]]; then
      local val="${BASH_REMATCH[2]}"
      val="${val#\"}" ; val="${val%\"}"
      val="${val#\'}" ; val="${val%\'}"
      val="$(echo "$val" | sed 's/[[:space:]]*$//')"

      # Detect list-of-objects: item contains "key: value" pattern
      if [[ "$val" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]] ]]; then
        # This is a list of objects — beyond our simple parser
        # Store current_key as empty array and skip the rest of this block
        if [[ $in_list -eq 0 ]]; then
          json=$(echo "$json" | jq --arg k "$current_key" '.[$k] = []')
        fi
        in_list=0
        list_items=""
        in_complex_block=1
        continue
      fi

      if [[ $in_list -eq 0 ]]; then
        in_list=1
        list_items=""
      fi
      list_items+="$val"$'\n'
      continue
    fi

    # Key: value
    if [[ "$line" =~ ^([[:space:]]*)([a-zA-Z_][a-zA-Z0-9_-]*):[[:space:]]*(.*) ]]; then
      local key="${BASH_REMATCH[2]}"
      local val="${BASH_REMATCH[3]}"
      val="${val%%#*}"
      val="$(echo "$val" | sed 's/[[:space:]]*$//')"
      val="${val#\"}" ; val="${val%\"}"
      val="${val#\'}" ; val="${val%\'}"

      # Flush pending list
      if [[ $in_list -eq 1 && -n "$current_key" ]]; then
        local arr
        arr=$(printf '%s\n' "$list_items" | jq -R -s 'split("\n") | map(select(length > 0))')
        json=$(echo "$json" | jq --arg k "$current_key" --argjson v "$arr" '.[$k] = $v')
        in_list=0
        list_items=""
      fi

      if [[ $indent -eq 0 ]]; then
        if [[ -n "$val" ]]; then
          json=$(echo "$json" | jq --arg k "$key" --arg v "$val" '.[$k] = $v')
          current_key="$key"
        else
          # Key with no value — next lines are a list or nested block
          current_key="$key"
        fi
      fi
      # Skip indented keys (they belong to nested structures we handle via list detection)
      continue
    fi
  done < "$file"

  # Final flush
  if [[ $in_list -eq 1 && -n "$current_key" ]]; then
    local arr
    arr=$(printf '%s\n' "$list_items" | jq -R -s 'split("\n") | map(select(length > 0))')
    json=$(echo "$json" | jq --arg k "$current_key" --argjson v "$arr" '.[$k] = $v')
  fi

  echo "$json"
}

# ---------------------------------------------------------------------------
# Emit a single target
# ---------------------------------------------------------------------------

# $1 = target name (claude-md, agents-md, cursorrules, etc.)
# $2 = output directory (defaults to PWD)
primer_emit() {
  local target="${1:?target required}"
  local outdir="${2:-$PWD}"

  if [[ ${#Primer_SOURCES[@]} -eq 0 ]]; then
    primer_error "No .ai/ sources found. Run 'primer init' first."
    return 1
  fi

  # Find the generator plugin for this target
  local generator=""
  local src gdir g name
  for src in "${Primer_SOURCES[@]}"; do
    gdir="$src/plugins/generators"
    [[ -d "$gdir" ]] || continue
    for g in "$gdir"/*; do
      [[ -f "$g" && -x "$g" ]] || continue
      name="$(basename "$g" | sed 's/\.[^.]*$//')"
      if [[ "$name" == "$target" ]]; then
        generator="$g"
        break 2
      fi
    done
  done

  # Fall back to built-in generators shipped with Primer
  if [[ -z "$generator" ]]; then
    local primer_root
    primer_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local builtin="$primer_root/plugins/generators/${target}.sh"
    if [[ -f "$builtin" && -x "$builtin" ]]; then
      generator="$builtin"
    fi
  fi

  if [[ -z "$generator" ]]; then
    primer_error "No generator found for target: $target"
    primer_info "Available generators:"
    primer_emit_list
    return 1
  fi

  primer_info "Emitting: ${BOLD}$target${RESET}"

  # Load config if not already loaded
  if [[ -z "${Primer_CONFIG_FILE:-}" ]]; then
    primer_load_config || {
      primer_error "No project.yaml found"
      return 1
    }
  fi

  # Convert config to JSON for the generator
  local config_json="{}"
  if [[ -n "${Primer_CONFIG_FILE:-}" ]]; then
    config_json=$(primer_config_to_json "$Primer_CONFIG_FILE")
  fi

  # Run pre-emit hooks
  local hooked
  hooked=$(primer_run_hooks "pre-emit" "$config_json") || return 1

  # Execute generator with --exec (JSON on stdin, target content on stdout)
  local output
  output=$(echo "$hooked" | "$generator" --exec) || {
    primer_error "Generator failed: $generator"
    return 1
  }

  # Run post-emit hooks
  local final
  final=$(primer_run_hooks "post-emit" "$output") || return 1

  # Write output file
  local outfile
  outfile=$(_primer_target_file "$target")
  local outpath="$outdir/$outfile"
  echo "$final" > "$outpath"

  primer_success "Emitted $target -> $outpath"
}

# ---------------------------------------------------------------------------
# Emit all registered targets
# ---------------------------------------------------------------------------

primer_emit_all() {
  local outdir="${1:-$PWD}"
  local targets_list=""

  if [[ ${#Primer_SOURCES[@]} -eq 0 ]]; then
    primer_warn "No .ai/ sources found."
    return 0
  fi

  # Collect targets from registered list (auto-detect which tools are installed)
  local t
  for t in $Primer_REG_TARGETS; do
    if _primer_target_detected "$t"; then
      targets_list="${targets_list}${t}"$'\n'
    fi
  done

  # Also include any generators found in plugin dirs (even unregistered ones)
  local src gdir g name
  for src in "${Primer_SOURCES[@]}"; do
    gdir="$src/plugins/generators"
    [[ -d "$gdir" ]] || continue
    for g in "$gdir"/*; do
      [[ -f "$g" && -x "$g" ]] || continue
      name="$(basename "$g" | sed 's/\.[^.]*$//')"
      # Add if not already in list
      if ! echo "$targets_list" | grep -qx "$name"; then
        targets_list="${targets_list}${name}"$'\n'
      fi
    done
  done

  if [[ -z "$targets_list" ]]; then
    primer_warn "No generators found. Install generator plugins in .ai/plugins/generators/"
    return 0
  fi

  local emitted=0
  local failed=0
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    primer_emit "$t" "$outdir" && emitted=$((emitted + 1)) || failed=$((failed + 1))
  done <<< "$targets_list"

  if [[ $failed -gt 0 ]]; then
    primer_error "$failed generator(s) failed"
    return 1
  fi
  primer_success "All $emitted target(s) emitted"
}

# ---------------------------------------------------------------------------
# List available generators
# ---------------------------------------------------------------------------

primer_emit_list() {
  if [[ ${#Primer_SOURCES[@]} -eq 0 ]]; then
    return 0
  fi
  local src gdir g name
  for src in "${Primer_SOURCES[@]}"; do
    gdir="$src/plugins/generators"
    [[ -d "$gdir" ]] || continue
    for g in "$gdir"/*; do
      [[ -f "$g" && -x "$g" ]] || continue
      name="$(basename "$g" | sed 's/\.[^.]*$//')"
      local desc=""
      desc=$("$g" --describe 2>/dev/null || true)
      echo "  $name  ${desc:+— $desc}  ($g)"
    done
  done
}
