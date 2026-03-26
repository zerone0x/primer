#!/usr/bin/env bash
# Primer Schema Validator Plugin
# Validates project.yaml (as JSON) against project.v1.json using jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$(cd "$SCRIPT_DIR/../../schema" && pwd)"
PROJECT_SCHEMA="$SCHEMA_DIR/project.v1.json"

# --- Plugin interface ---

if [[ "${1:-}" == "--schema" ]]; then
  cat <<'SCHEMA'
{
  "name": "schema",
  "version": "1.0.0",
  "type": "validator",
  "input": "json",
  "description": "Validates project configuration against project.v1.json schema"
}
SCHEMA
  exit 0
fi

if [[ "${1:-}" == "--describe" ]]; then
  echo "Schema validator: checks project.yaml (as JSON) against the Primer project.v1 schema."
  echo "Validates required fields, types, enums, string patterns, and constraint lengths."
  exit 0
fi

if [[ "${1:-}" != "--exec" ]]; then
  echo "Usage: $0 [--schema | --describe | --exec]" >&2
  echo "  --schema    Output plugin metadata as JSON" >&2
  echo "  --describe  Output human-readable description" >&2
  echo "  --exec      Validate JSON from stdin against project.v1.json" >&2
  exit 1
fi

# --- Validation logic (--exec) ---

if ! command -v jq &>/dev/null; then
  echo '{"valid":false,"errors":["jq is required but not installed"]}' >&2
  exit 1
fi

INPUT=$(cat)

errors=()

add_error() {
  errors+=("$1")
}

# Helper: extract a value with jq, empty string if null
jval() {
  echo "$INPUT" | jq -r "$1 // empty" 2>/dev/null
}

jtype() {
  echo "$INPUT" | jq -r "$1 | type" 2>/dev/null
}

# Check top-level is an object
if [[ "$(jtype '.')" != "object" ]]; then
  add_error "Root must be a JSON object"
  # Can't continue
  printf '{"valid":false,"errors":%s}\n' "$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)"
  exit 1
fi

# --- Required fields ---

# version
v=$(jval '.version')
if [[ -z "$v" ]]; then
  add_error "Missing required field: version"
elif [[ "$v" != "1" ]]; then
  add_error "version must be '1', got '$v'"
fi

# project
if [[ "$(jtype '.project')" != "object" ]]; then
  add_error "Missing or invalid required field: project (must be object)"
else
  # project.name
  pname=$(jval '.project.name')
  if [[ -z "$pname" ]]; then
    add_error "Missing required field: project.name"
  elif ! echo "$pname" | grep -qE '^[a-z0-9-]+$'; then
    add_error "project.name must match ^[a-z0-9-]+\$, got '$pname'"
  fi

  # project.description
  pdesc=$(jval '.project.description')
  if [[ -z "$pdesc" ]]; then
    add_error "Missing required field: project.description"
  else
    pdesc_len=${#pdesc}
    if (( pdesc_len > 200 )); then
      add_error "project.description exceeds 200 characters ($pdesc_len)"
    fi
  fi

  # project.repository (optional, but if present must be URL)
  prepo=$(jval '.project.repository')
  if [[ -n "$prepo" ]]; then
    if ! echo "$prepo" | grep -qE '^https?://'; then
      add_error "project.repository must be a URL starting with http(s)://, got '$prepo'"
    fi
  fi
fi

# phase
phase=$(jval '.phase')
if [[ -z "$phase" ]]; then
  add_error "Missing required field: phase"
elif [[ "$phase" != "bootstrap" && "$phase" != "growth" && "$phase" != "mature" && "$phase" != "legacy" ]]; then
  add_error "phase must be one of [bootstrap, growth, mature, legacy], got '$phase'"
fi

# constraints
constraints_type=$(jtype '.constraints')
if [[ "$constraints_type" != "array" ]]; then
  add_error "Missing or invalid required field: constraints (must be array)"
else
  constraints_len=$(echo "$INPUT" | jq '.constraints | length')
  if (( constraints_len == 0 )); then
    add_error "constraints array must not be empty"
  fi

  # Check each constraint is a string >= 20 chars
  while IFS= read -r line; do
    ctype=$(echo "$line" | jq -r '.type')
    cval=$(echo "$line" | jq -r '.value')
    cidx=$(echo "$line" | jq -r '.idx')
    if [[ "$ctype" != "string" ]]; then
      add_error "constraints[$cidx] must be a string, got $ctype"
    else
      clen=${#cval}
      if (( clen < 20 )); then
        add_error "constraints[$cidx] must be at least 20 characters ($clen chars): '$cval'"
      fi
    fi
  done < <(echo "$INPUT" | jq -c '.constraints | to_entries[] | {idx: .key, type: (.value | type), value: (.value // "" | tostring)}')
fi

# --- Optional fields type checks ---

# build
build_type=$(jtype '.build')
if [[ "$build_type" != "null" && "$build_type" != "object" ]]; then
  add_error "build must be an object if present"
elif [[ "$build_type" == "object" ]]; then
  for key in test lint deploy_staging deploy_prod; do
    kt=$(echo "$INPUT" | jq -r ".build.\"$key\" | type" 2>/dev/null)
    if [[ "$kt" != "null" && "$kt" != "string" ]]; then
      add_error "build.$key must be a string, got $kt"
    fi
  done
fi

# stack
stack_type=$(jtype '.stack')
if [[ "$stack_type" != "null" && "$stack_type" != "object" ]]; then
  add_error "stack must be an object if present"
elif [[ "$stack_type" == "object" ]]; then
  for key in language framework database infra ci; do
    kt=$(echo "$INPUT" | jq -r ".stack.\"$key\" | type" 2>/dev/null)
    if [[ "$kt" != "null" && "$kt" != "string" ]]; then
      add_error "stack.$key must be a string, got $kt"
    fi
  done
fi

# context_loading
cl_type=$(jtype '.context_loading')
if [[ "$cl_type" != "null" && "$cl_type" != "object" ]]; then
  add_error "context_loading must be an object if present"
elif [[ "$cl_type" == "object" ]]; then
  # always: array of strings
  al_type=$(echo "$INPUT" | jq -r '.context_loading.always | type' 2>/dev/null)
  if [[ "$al_type" != "null" && "$al_type" != "array" ]]; then
    add_error "context_loading.always must be an array"
  fi
  # on_path: object of glob->array
  op_type=$(echo "$INPUT" | jq -r '.context_loading.on_path | type' 2>/dev/null)
  if [[ "$op_type" != "null" && "$op_type" != "object" ]]; then
    add_error "context_loading.on_path must be an object"
  fi
  # on_demand: array of strings
  od_type=$(echo "$INPUT" | jq -r '.context_loading.on_demand | type' 2>/dev/null)
  if [[ "$od_type" != "null" && "$od_type" != "array" ]]; then
    add_error "context_loading.on_demand must be an array"
  fi
fi

# --- Output result ---

if [[ ${#errors[@]} -eq 0 ]]; then
  echo '{"valid":true,"errors":[]}'
  exit 0
else
  errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
  printf '{"valid":false,"errors":%s}\n' "$errors_json"
  exit 1
fi
