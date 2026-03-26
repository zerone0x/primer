#!/usr/bin/env bash
# primer/lib/mcp.sh — MCP (Model Context Protocol) server config management
# Manages MCP server definitions in .ai/ and syncs to tool-native formats.

# ---------------------------------------------------------------------------
# MCP config file discovery
# ---------------------------------------------------------------------------

# Find the canonical MCP config file across .ai/ sources.
# Returns the path to the first mcp-servers.yaml found.
_primer_mcp_config_file() {
  [[ ${#Primer_SOURCES[@]:-0} -eq 0 ]] && return 1
  for src in "${Primer_SOURCES[@]}"; do
    local f="$src/mcp-servers.yaml"
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# List MCP servers defined in .ai/mcp-servers.yaml.
primer_mcp_list() {
  local config_file
  config_file=$(_primer_mcp_config_file) || {
    primer_info "No mcp-servers.yaml found in any .ai/ source"
    return 0
  }

  primer_info "MCP servers (from $config_file):"

  if command -v yq &>/dev/null; then
    yq eval '.servers[] | "  " + .name + " — " + .command + " " + (.args | join(" "))' "$config_file" 2>/dev/null
  elif command -v jq &>/dev/null && command -v yq &>/dev/null; then
    yq eval -o=json "$config_file" | jq -r '.servers[] | "  \(.name) — \(.command) \(.args | join(" "))"' 2>/dev/null
  else
    # Fallback: simple grep-based listing
    local in_server=0
    local name="" cmd="" args=""
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*#  ]] && continue
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
        # Print previous server if we have one
        [[ -n "$name" ]] && echo "  $name — $cmd $args"
        name="${BASH_REMATCH[1]}"
        cmd="" ; args=""
      elif [[ "$line" =~ ^[[:space:]]*command:[[:space:]]*(.*) ]]; then
        cmd="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]*args:[[:space:]]*\[(.*)\] ]]; then
        args="${BASH_REMATCH[1]}"
        args="${args//\"/}"
        args="${args//,/ }"
      fi
    done < "$config_file"
    # Print last server
    [[ -n "$name" ]] && echo "  $name — $cmd $args"
  fi
}

# Sync MCP config from .ai/mcp-servers.yaml to .mcp.json (Claude Code format).
# The .mcp.json format is:
# {
#   "mcpServers": {
#     "server-name": {
#       "command": "...",
#       "args": [...],
#       "env": { ... }
#     }
#   }
# }
primer_mcp_sync() {
  local config_file
  config_file=$(_primer_mcp_config_file) || {
    primer_info "No mcp-servers.yaml found. Skipping MCP sync."
    return 0
  }

  local outpath="$PWD/.mcp.json"
  local mcp_json='{"mcpServers":{}}'

  if command -v yq &>/dev/null && command -v jq &>/dev/null; then
    # Parse YAML to JSON, then reshape for Claude Code format
    local raw_json
    raw_json=$(yq eval -o=json "$config_file" 2>/dev/null)

    mcp_json=$(echo "$raw_json" | jq '
      .servers // [] |
      reduce .[] as $srv ({};
        . + {
          ($srv.name): (
            { command: $srv.command, args: ($srv.args // []) }
            + if $srv.env then { env: $srv.env } else {} end
          )
        }
      ) | { mcpServers: . }
    ' 2>/dev/null) || {
      primer_error "Failed to parse MCP config"
      return 1
    }
  elif command -v jq &>/dev/null; then
    # No yq — parse YAML manually and build JSON
    local servers='[]'
    local name="" cmd="" in_args=0 in_env=0
    local args_arr='[]' env_obj='{}'

    _flush_server() {
      if [[ -n "$name" ]]; then
        servers=$(echo "$servers" | jq \
          --arg n "$name" --arg c "$cmd" \
          --argjson a "$args_arr" --argjson e "$env_obj" \
          '. += [{ name: $n, command: $c, args: $a, env: $e }]')
      fi
      name="" ; cmd="" ; args_arr='[]' ; env_obj='{}' ; in_args=0 ; in_env=0
    }

    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue

      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*) ]]; then
        _flush_server
        name="${BASH_REMATCH[1]}"
        name="${name#\"}" ; name="${name%\"}"
      elif [[ "$line" =~ ^[[:space:]]*command:[[:space:]]*(.*) ]]; then
        cmd="${BASH_REMATCH[1]}"
        cmd="${cmd#\"}" ; cmd="${cmd%\"}"
        in_args=0 ; in_env=0
      elif [[ "$line" =~ ^[[:space:]]*args:[[:space:]]*\[(.*)\] ]]; then
        # Inline array: args: ["-y", "pkg"]
        local raw="${BASH_REMATCH[1]}"
        args_arr=$(echo "[$raw]" | jq '.' 2>/dev/null || echo '[]')
        in_args=0 ; in_env=0
      elif [[ "$line" =~ ^[[:space:]]*args: ]]; then
        in_args=1 ; in_env=0
      elif [[ "$line" =~ ^[[:space:]]*env: ]]; then
        in_env=1 ; in_args=0
      elif [[ $in_args -eq 1 && "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
        local val="${BASH_REMATCH[1]}"
        val="${val#\"}" ; val="${val%\"}"
        args_arr=$(echo "$args_arr" | jq --arg v "$val" '. += [$v]')
      elif [[ $in_env -eq 1 && "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*):[[:space:]]*(.*) ]]; then
        local ekey="${BASH_REMATCH[1]}"
        local eval_="${BASH_REMATCH[2]}"
        eval_="${eval_#\"}" ; eval_="${eval_%\"}"
        env_obj=$(echo "$env_obj" | jq --arg k "$ekey" --arg v "$eval_" '.[$k] = $v')
      fi
    done < "$config_file"
    _flush_server

    mcp_json=$(echo "$servers" | jq '
      reduce .[] as $srv ({};
        . + {
          ($srv.name): (
            { command: $srv.command, args: $srv.args }
            + if ($srv.env | length > 0) then { env: $srv.env } else {} end
          )
        }
      ) | { mcpServers: . }
    ')
  else
    primer_error "jq is required for MCP sync"
    return 1
  fi

  echo "$mcp_json" | jq '.' > "$outpath"
  primer_success "MCP config synced to $outpath"

  # Store hash for drift detection
  if type _primer_hash_store &>/dev/null; then
    _primer_hash_store "mcp-json" "$(cat "$outpath")"
  fi
}

# Add an MCP server definition to .ai/mcp-servers.yaml.
# $1 = server name
# $2 = command
# $3 = args (space-separated or JSON array)
primer_mcp_add() {
  local name="${1:?server name required}"
  local cmd="${2:?command required}"
  local args_raw="${3:-}"

  # Find or create the config file
  local ai_dir="${Primer_SOURCES[0]:-$PWD/.ai}"
  local config_file="$ai_dir/mcp-servers.yaml"

  if [[ ! -f "$config_file" ]]; then
    mkdir -p "$ai_dir"
    echo "servers:" > "$config_file"
  fi

  # Format args as YAML inline array
  local args_yaml="[]"
  if [[ -n "$args_raw" ]]; then
    if [[ "$args_raw" == \[* ]]; then
      # Already JSON array format
      args_yaml="$args_raw"
    else
      # Convert space-separated to YAML array
      args_yaml="["
      local first=1
      for arg in $args_raw; do
        [[ $first -eq 1 ]] && first=0 || args_yaml+=", "
        # Strip surrounding quotes if present
        arg="${arg#\"}" ; arg="${arg%\"}"
        arg="${arg#\'}" ; arg="${arg%\'}"
        args_yaml+="\"$arg\""
      done
      args_yaml+="]"
    fi
  fi

  # Append to YAML file
  cat >> "$config_file" << EOF
  - name: $name
    command: $cmd
    args: $args_yaml
EOF

  primer_success "Added MCP server: $name ($cmd)"
  primer_info "Run 'primer seams sync' or 'primer mcp sync' to update .mcp.json"
}
