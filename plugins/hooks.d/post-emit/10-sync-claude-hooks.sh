#!/usr/bin/env bash
# primer/plugins/hooks.d/post-emit/10-sync-claude-hooks.sh
# Hook: Sync Primer hook definitions to Claude Code's settings.local.json.
#
# Reads .ai/hooks/ YAML definitions and translates them to Claude Code's
# hook format, writing to .claude/settings.local.json.
# Never overwrites the user's main settings.json — only settings.local.json.
#
# Claude Code hook format (settings.json):
# {
#   "hooks": {
#     "PostToolUse": [{ "matcher": "...", "hooks": [{"type": "command", "command": "..."}] }],
#     "PreToolUse": [{ "matcher": "...", "hooks": [{"type": "command", "command": "..."}] }],
#     ...
#   }
# }
#
# Primer hook mapping:
#   pre-emit     -> PreToolUse (Write matcher)
#   post-emit    -> PostToolUse (Write matcher)
#   pre-generate -> PreToolUse (Read matcher)
#   on-error     -> PostToolUse (Bash matcher, on error)
set -euo pipefail

# Pass through stdin (this hook is in the post-emit pipeline)
INPUT=$(cat)

# We need jq for JSON manipulation
if ! command -v jq &>/dev/null; then
  echo "$INPUT"
  exit 0
fi

# Find .ai/hooks/ directory
HOOKS_DIR=""
dir="$PWD"
while true; do
  if [[ -d "$dir/.ai/hooks" ]]; then
    HOOKS_DIR="$dir/.ai/hooks"
    break
  fi
  [[ "$dir" == "$HOME" || "$dir" == "/" ]] && break
  dir="$(dirname "$dir")"
done

# Also check for hook definitions in .ai/claude-hooks.yaml
HOOKS_YAML=""
dir="$PWD"
while true; do
  if [[ -f "$dir/.ai/claude-hooks.yaml" ]]; then
    HOOKS_YAML="$dir/.ai/claude-hooks.yaml"
    break
  fi
  [[ "$dir" == "$HOME" || "$dir" == "/" ]] && break
  dir="$(dirname "$dir")"
done

# If no hook definitions found, pass through
if [[ -z "$HOOKS_DIR" && -z "$HOOKS_YAML" ]]; then
  echo "$INPUT"
  exit 0
fi

# Build Claude Code hooks JSON
CLAUDE_HOOKS='{}'

# Process individual hook scripts in .ai/hooks/
if [[ -n "$HOOKS_DIR" && -d "$HOOKS_DIR" ]]; then
  # Map Primer stages to Claude Code event names
  for stage_dir in "$HOOKS_DIR"/*/; do
    [[ -d "$stage_dir" ]] || continue
    stage="$(basename "$stage_dir")"

    # Determine Claude Code event and matcher
    case "$stage" in
      PreToolUse|PostToolUse|Notification|Stop|SubagentStop)
        # Already a Claude Code event name — use directly
        claude_event="$stage"
        ;;
      pre-tool-use)   claude_event="PreToolUse" ;;
      post-tool-use)  claude_event="PostToolUse" ;;
      notification)   claude_event="Notification" ;;
      stop)           claude_event="Stop" ;;
      subagent-stop)  claude_event="SubagentStop" ;;
      *)
        # Skip stages that do not map to Claude Code events
        continue
        ;;
    esac

    for hook_script in "$stage_dir"*; do
      [[ -f "$hook_script" && -x "$hook_script" ]] || continue

      local_bname="$(basename "$hook_script")"

      # Extract matcher from filename convention: NN-matcher-description.sh
      # e.g., 10-Write-validate.sh -> matcher="Write"
      local_matcher=""
      if [[ "$local_bname" =~ ^[0-9]+-([A-Za-z]+)- ]]; then
        local_matcher="${BASH_REMATCH[1]}"
      fi

      # Build the hook entry
      hook_entry=$(jq -n \
        --arg matcher "${local_matcher:-}" \
        --arg cmd "$hook_script" \
        '{
          matcher: $matcher,
          hooks: [{ type: "command", command: $cmd }]
        }')

      # Append to the event array
      CLAUDE_HOOKS=$(echo "$CLAUDE_HOOKS" | jq \
        --arg event "$claude_event" \
        --argjson entry "$hook_entry" \
        '.[$event] = ((.[$event] // []) + [$entry])')
    done
  done
fi

# Process .ai/claude-hooks.yaml if it exists
if [[ -n "$HOOKS_YAML" && -f "$HOOKS_YAML" ]] && command -v yq &>/dev/null; then
  yaml_hooks=$(yq eval -o=json "$HOOKS_YAML" 2>/dev/null || echo '{}')
  # Merge YAML-defined hooks (they take precedence)
  CLAUDE_HOOKS=$(jq -n \
    --argjson a "$CLAUDE_HOOKS" \
    --argjson b "$yaml_hooks" \
    '$a * $b')
fi

# Only write if we have hooks to sync
hook_count=$(echo "$CLAUDE_HOOKS" | jq 'to_entries | map(.value | length) | add // 0' 2>/dev/null)
if [[ "$hook_count" == "0" ]]; then
  echo "$INPUT"
  exit 0
fi

# Write to .claude/settings.local.json (merge with existing content)
SETTINGS_DIR="$PWD/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.local.json"
mkdir -p "$SETTINGS_DIR"

if [[ -f "$SETTINGS_FILE" ]]; then
  # Merge: update only the "hooks" key, preserve everything else
  EXISTING=$(cat "$SETTINGS_FILE")
  UPDATED=$(echo "$EXISTING" | jq --argjson hooks "$CLAUDE_HOOKS" '.hooks = $hooks')
else
  UPDATED=$(jq -n --argjson hooks "$CLAUDE_HOOKS" '{ hooks: $hooks }')
fi

echo "$UPDATED" | jq '.' > "$SETTINGS_FILE"

# Emit the input unchanged (this hook has side effects but does not alter the pipeline)
echo "$INPUT"
