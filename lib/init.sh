#!/usr/bin/env bash
# primer/lib/init.sh — Template discovery, application, and stack auto-detection
# Part of Primer (Portable AI Infrastructure Config)

# ---------------------------------------------------------------------------
# Template registry
# ---------------------------------------------------------------------------

Primer_TEMPLATES_DIR="${Primer_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/templates"

# List available templates with descriptions.
# Reads the stack.language and stack.framework from each template's project.yaml.
primer_list_templates() {
  local tdir
  for tdir in "$Primer_TEMPLATES_DIR"/*/; do
    [[ -d "$tdir" ]] || continue
    local name
    name="$(basename "$tdir")"
    local desc=""
    local yaml="$tdir/.ai/project.yaml"
    if [[ -f "$yaml" ]]; then
      local lang="" framework=""
      lang=$(grep -E '^\s+language:' "$yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"')
      framework=$(grep -E '^\s+framework:' "$yaml" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"')
      [[ -n "$lang" ]] && desc="$lang"
      [[ -n "$framework" ]] && desc="${desc:+$desc / }$framework"
    fi
    printf "  %-20s %s\n" "$name" "${desc:+($desc)}"
  done
}

# ---------------------------------------------------------------------------
# Stack auto-detection
# ---------------------------------------------------------------------------

# Detect the project stack from files in the current directory.
# Returns a template name or empty string.
primer_detect_stack() {
  local dir="${1:-$PWD}"

  # Rust
  if [[ -f "$dir/Cargo.toml" ]]; then
    echo "rust-cli"
    return 0
  fi

  # Next.js (check before generic Node — next.config.* is specific)
  if [[ -f "$dir/next.config.js" || -f "$dir/next.config.mjs" || -f "$dir/next.config.ts" ]]; then
    echo "nextjs-app"
    return 0
  fi

  # Go
  if [[ -f "$dir/go.mod" ]]; then
    echo "go-service"
    return 0
  fi

  # Python API (check for FastAPI/Flask/Django markers)
  if [[ -f "$dir/requirements.txt" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
    # Look for API framework indicators
    if grep -qE '(fastapi|flask|django|starlette)' "$dir/requirements.txt" 2>/dev/null ||
       grep -qE '(fastapi|flask|django|starlette)' "$dir/pyproject.toml" 2>/dev/null; then
      echo "python-api"
      return 0
    fi
    # Default to python-api for any Python project
    echo "python-api"
    return 0
  fi

  # TypeScript library (check for tsconfig + no framework indicators)
  if [[ -f "$dir/tsconfig.json" ]]; then
    # Check if it is a library (has main/exports in package.json, no next/nuxt)
    if [[ -f "$dir/package.json" ]]; then
      if grep -qE '"(main|exports)"' "$dir/package.json" 2>/dev/null &&
         ! grep -qE '"(next|nuxt|gatsby|remix)"' "$dir/package.json" 2>/dev/null; then
        echo "typescript-lib"
        return 0
      fi
    fi
  fi

  # No match
  return 1
}

# ---------------------------------------------------------------------------
# Template application
# ---------------------------------------------------------------------------

# Initialize a project with a Primer template.
# $1 = template name (optional — auto-detects if not provided)
# Reads project name/description interactively or from environment.
primer_init() {
  local template="${1:-}"
  local target_dir="$PWD"
  local ai_dir="$target_dir/.ai"

  # Check if .ai/ already exists
  if [[ -d "$ai_dir" ]]; then
    primer_warn ".ai/ directory already exists at $ai_dir"
    echo -n "  Overwrite? [y/N] "
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      primer_info "Aborted."
      return 0
    fi
  fi

  # Auto-detect stack if no template specified
  if [[ -z "$template" ]]; then
    primer_info "No template specified — detecting stack..."
    template=$(primer_detect_stack "$target_dir") || true
    if [[ -n "$template" ]]; then
      primer_info "Detected stack: ${BOLD:-}$template${RESET:-}"
      echo -n "  Use this template? [Y/n] "
      read -r answer
      if [[ "$answer" == "n" || "$answer" == "N" ]]; then
        primer_info "Available templates:"
        primer_list_templates
        echo -n "  Enter template name: "
        read -r template
      fi
    else
      primer_warn "Could not detect stack."
      primer_info "Available templates:"
      primer_list_templates
      echo -n "  Enter template name: "
      read -r template
    fi
  fi

  # Validate template exists
  local template_dir="$Primer_TEMPLATES_DIR/$template"
  if [[ ! -d "$template_dir/.ai" ]]; then
    primer_error "Template not found: $template"
    primer_info "Available templates:"
    primer_list_templates
    return 1
  fi

  # Get project name
  local project_name="${Primer_PROJECT_NAME:-}"
  if [[ -z "$project_name" ]]; then
    # Default to directory name, lowercased and hyphenated
    local default_name
    default_name=$(basename "$target_dir" | tr '[:upper:]' '[:lower:]' | tr ' _' '--' | sed 's/[^a-z0-9-]//g')
    echo -n "  Project name [$default_name]: "
    read -r project_name
    project_name="${project_name:-$default_name}"
  fi

  # Get project description
  local project_desc="${Primer_PROJECT_DESC:-}"
  if [[ -z "$project_desc" ]]; then
    echo -n "  Project description: "
    read -r project_desc
  fi

  # Copy template files
  primer_info "Applying template: ${BOLD:-}$template${RESET:-}"

  # Create directory structure (preserve existing plugins, evolution dirs)
  mkdir -p "$ai_dir"/{plugins/{commands,generators,hooks,validators},evolution/{proposals,applied},knowledge,phases}

  # Copy template .ai/ contents
  # Use cp -R to copy recursively; skip directories that we created above
  if [[ -d "$template_dir/.ai/knowledge" ]]; then
    cp -f "$template_dir/.ai/knowledge/"* "$ai_dir/knowledge/" 2>/dev/null || true
  fi
  if [[ -d "$template_dir/.ai/phases" ]]; then
    cp -f "$template_dir/.ai/phases/"* "$ai_dir/phases/" 2>/dev/null || true
  fi

  # Copy and customize project.yaml
  local today
  today=$(date -u +"%Y-%m-%d")

  if [[ -f "$template_dir/.ai/project.yaml" ]]; then
    # Replace placeholder values safely by processing line-by-line.
    # Escape double quotes in user-provided strings for valid YAML.
    # Strip newlines to prevent multi-line injection.
    local safe_name safe_desc
    safe_name=$(printf '%s' "$project_name" | tr -d '\n' | sed 's/"/\\"/g')
    safe_desc=$(printf '%s' "$project_desc" | tr -d '\n' | sed 's/"/\\"/g')
    while IFS= read -r line; do
      if [[ "$line" =~ ^([[:space:]]*)name:[[:space:]]*\"\" ]]; then
        echo "${BASH_REMATCH[1]}name: \"$safe_name\""
      elif [[ "$line" =~ ^([[:space:]]*)description:[[:space:]]*\"\" ]]; then
        echo "${BASH_REMATCH[1]}description: \"$safe_desc\""
      else
        echo "$line"
      fi
    done < "$template_dir/.ai/project.yaml" > "$ai_dir/project.yaml"
  fi

  primer_success "Created .ai/ from template '$template'"
  primer_info "  project.yaml  — edit constraints and build commands"
  primer_info "  knowledge/    — gotchas and constraints for your stack"
  primer_info "  phases/       — bootstrap and growth phase guidance"

  # Auto-emit if primer_emit_all is available
  if type primer_emit_all &>/dev/null; then
    echo -n "  Generate tool-native configs now? [Y/n] "
    read -r answer
    if [[ "$answer" != "n" && "$answer" != "N" ]]; then
      # Re-discover sources now that .ai/ exists
      primer_discover_sources
      primer_load_config
      primer_emit_all "$target_dir"
    fi
  fi
}
