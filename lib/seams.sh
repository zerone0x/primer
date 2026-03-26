#!/usr/bin/env bash
# primer/lib/seams.sh — Seam management for Primer
# Manages the sync between canonical .ai/ configs and tool-native formats.
# "Seams" are extension points where AI tools accept custom configuration:
#   - Claude Code: settings.json hooks, CLAUDE.md, .mcp.json
#   - Codex: AGENTS.md
#   - Cursor: .cursorrules, .cursor/ config
#   - Hermes: .hermes.md

# ---------------------------------------------------------------------------
# Tool detection registry (parallel arrays for bash 3.2 compat)
# ---------------------------------------------------------------------------

Primer_SEAM_TOOLS="claude codex cursor hermes harness"
Primer_SEAM_LABELS="Claude_Code Codex Cursor Hermes Harness"

# Detect which AI tools are installed on this system.
# Prints detected tool names, one per line.
primer_seams_detect() {
  local detected=()

  # Claude Code
  if command -v claude &>/dev/null; then
    detected+=("claude")
  fi

  # Codex (OpenAI)
  if command -v codex &>/dev/null; then
    detected+=("codex")
  fi

  # Cursor
  if [[ -d "$PWD/.cursor" ]] || [[ -d "${HOME}/.cursor" ]] || command -v cursor &>/dev/null; then
    detected+=("cursor")
  fi

  # Hermes
  if command -v hermes &>/dev/null || [[ -f "$PWD/.hermes.md" ]]; then
    detected+=("hermes")
  fi

  # Harness
  if [[ -d "$PWD/.harness" ]] || [[ -d "${HOME}/.harness" ]]; then
    detected+=("harness")
  fi

  if [[ ${#detected[@]} -eq 0 ]]; then
    primer_info "No AI tools detected"
    return 0
  fi

  for tool in "${detected[@]}"; do
    echo "$tool"
  done
}

# ---------------------------------------------------------------------------
# Hash tracking for drift detection
# ---------------------------------------------------------------------------

# Directory where we store hashes of last-synced shims
_primer_hash_dir() {
  local ai_dir="${Primer_SOURCES[0]:-$PWD/.ai}"
  echo "$ai_dir/.sync-hashes"
}

# Store hash of a generated shim file
_primer_hash_store() {
  local target="$1"
  local content="$2"
  local hash_dir
  hash_dir="$(_primer_hash_dir)"
  mkdir -p "$hash_dir"
  primer_hash "$content" > "$hash_dir/$target.sha256"
}

# Get stored hash for a target
_primer_hash_get() {
  local target="$1"
  local hash_dir
  hash_dir="$(_primer_hash_dir)"
  local hash_file="$hash_dir/$target.sha256"
  if [[ -f "$hash_file" ]]; then
    cat "$hash_file"
  fi
}

# ---------------------------------------------------------------------------
# Sync .ai/ configs to all tool-native formats
# ---------------------------------------------------------------------------

# Main sync entrypoint: detect tools, emit configs, update hashes.
primer_seams_sync() {
  local tools
  tools=$(primer_seams_detect)

  if [[ -z "$tools" ]]; then
    primer_warn "No AI tools detected. Nothing to sync."
    return 0
  fi

  primer_info "Detected tools: $(echo "$tools" | tr '\n' ' ')"

  # Load config once
  primer_load_config || {
    primer_error "No project.yaml found. Run 'primer init' first."
    return 1
  }

  local synced=0
  local failed=0

  while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    case "$tool" in
      claude)
        # Emit CLAUDE.md + sync hooks to settings.local.json + sync MCP
        primer_emit "claude-md" "$PWD" 2>/dev/null && synced=$((synced + 1)) || failed=$((failed + 1))
        # Run post-emit hooks (which include settings.json sync)
        primer_hooks_run "post-emit" '{"tool":"claude"}' >/dev/null 2>&1 || true
        # Sync MCP if available
        if type primer_mcp_sync &>/dev/null; then
          primer_mcp_sync 2>/dev/null || true
        fi
        ;;
      codex)
        primer_emit "agents-md" "$PWD" 2>/dev/null && synced=$((synced + 1)) || failed=$((failed + 1))
        ;;
      cursor)
        primer_emit "cursorrules" "$PWD" 2>/dev/null && synced=$((synced + 1)) || failed=$((failed + 1))
        ;;
      hermes)
        primer_emit "hermes-md" "$PWD" 2>/dev/null && synced=$((synced + 1)) || failed=$((failed + 1))
        ;;
      harness)
        primer_info "Harness detected but no generator configured (skipping)"
        ;;
    esac
  done <<< "$tools"

  if [[ $failed -gt 0 ]]; then
    primer_warn "Sync completed with errors: $synced synced, $failed failed"
    return 1
  fi
  primer_success "Synced $synced tool config(s)"
}

# ---------------------------------------------------------------------------
# Status: show which shims are stale via hash comparison
# ---------------------------------------------------------------------------

primer_seams_status() {
  # Map targets to output files
  local targets=("claude-md" "agents-md" "cursorrules" "hermes-md")
  local files=("CLAUDE.md" "AGENTS.md" ".cursorrules" ".hermes.md")

  local stale=0
  local current=0
  local missing=0

  local i=0
  for target in "${targets[@]}"; do
    local outfile="${files[$i]}"
    local outpath="$PWD/$outfile"
    i=$((i + 1))

    if [[ ! -f "$outpath" ]]; then
      continue
    fi

    local current_hash
    current_hash=$(primer_hash "$(cat "$outpath")")
    local stored_hash
    stored_hash=$(_primer_hash_get "$target")

    if [[ -z "$stored_hash" ]]; then
      printf '  %-20s %s  (no sync record)\n' "$target" "$outfile"
      missing=$((missing + 1))
    elif [[ "$current_hash" == "$stored_hash" ]]; then
      printf '  %-20s %s  [current]\n' "$target" "$outfile"
      current=$((current + 1))
    else
      printf '  %-20s %s  [STALE]\n' "$target" "$outfile"
      stale=$((stale + 1))
    fi
  done

  # Also check Claude Code settings sync
  local settings_local="$PWD/.claude/settings.local.json"
  if [[ -f "$settings_local" ]]; then
    local s_hash
    s_hash=$(primer_hash "$(cat "$settings_local")")
    local s_stored
    s_stored=$(_primer_hash_get "claude-settings-local")
    if [[ -z "$s_stored" ]]; then
      printf '  %-20s %s  (no sync record)\n' "claude-hooks" ".claude/settings.local.json"
      missing=$((missing + 1))
    elif [[ "$s_hash" == "$s_stored" ]]; then
      printf '  %-20s %s  [current]\n' "claude-hooks" ".claude/settings.local.json"
      current=$((current + 1))
    else
      printf '  %-20s %s  [STALE]\n' "claude-hooks" ".claude/settings.local.json"
      stale=$((stale + 1))
    fi
  fi

  # MCP config
  if [[ -f "$PWD/.mcp.json" ]]; then
    local m_hash
    m_hash=$(primer_hash "$(cat "$PWD/.mcp.json")")
    local m_stored
    m_stored=$(_primer_hash_get "mcp-json")
    if [[ -z "$m_stored" ]]; then
      printf '  %-20s %s  (no sync record)\n' "mcp-servers" ".mcp.json"
      missing=$((missing + 1))
    elif [[ "$m_hash" == "$m_stored" ]]; then
      printf '  %-20s %s  [current]\n' "mcp-servers" ".mcp.json"
      current=$((current + 1))
    else
      printf '  %-20s %s  [STALE]\n' "mcp-servers" ".mcp.json"
      stale=$((stale + 1))
    fi
  fi

  echo
  primer_info "Status: $current current, $stale stale, $missing untracked"
  [[ $stale -gt 0 ]] && primer_warn "Run 'primer seams sync' to update stale configs"
  return 0
}

# ---------------------------------------------------------------------------
# Diff between canonical .ai/ and a generated shim
# ---------------------------------------------------------------------------

# $1 = target name (claude-md, agents-md, cursorrules, hermes-md)
primer_seams_diff() {
  local target="${1:?target required}"

  # We need to regenerate to a temp file and diff against the existing shim
  local outfile
  outfile=$(_primer_target_file "$target")
  local outpath="$PWD/$outfile"

  if [[ ! -f "$outpath" ]]; then
    primer_error "Shim file not found: $outpath"
    primer_error "Run 'primer emit $target' first."
    return 1
  fi

  # Load config
  primer_load_config || {
    primer_error "No project.yaml found"
    return 1
  }

  # Generate fresh output to a temp file
  local tmpfile
  tmpfile=$(mktemp "${TMPDIR:-/tmp}/primer-diff-XXXXXX")
  trap "rm -f '$tmpfile'" RETURN

  local config_json="{}"
  if [[ -n "${Primer_CONFIG_FILE:-}" ]]; then
    config_json=$(primer_config_to_json "$Primer_CONFIG_FILE")
  fi

  # Find and run the generator
  local generator=""
  local primer_root
  primer_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # Check project generators first, then built-in
  for src in "${Primer_SOURCES[@]}"; do
    local g="$src/plugins/generators/${target}.sh"
    [[ -f "$g" && -x "$g" ]] && { generator="$g"; break; }
  done
  [[ -z "$generator" ]] && generator="$primer_root/plugins/generators/${target}.sh"

  if [[ ! -f "$generator" || ! -x "$generator" ]]; then
    primer_error "No generator found for target: $target"
    return 1
  fi

  echo "$config_json" | "$generator" --exec > "$tmpfile" 2>/dev/null || {
    primer_error "Generator failed for target: $target"
    return 1
  }

  # Show diff
  if diff -u "$outpath" "$tmpfile" 2>/dev/null; then
    primer_success "$target: shim is up to date"
  else
    primer_warn "$target: shim differs from canonical config"
    return 1
  fi
}
