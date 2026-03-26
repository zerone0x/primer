#!/usr/bin/env bash
# End-to-end test: simulate a complete Primer lifecycle
# Tests the full workflow from init through emit, kpl, evolve, seams, and budget.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Primer_BIN="$SCRIPT_DIR/../bin/primer"

# ---------------------------------------------------------------------------
# Colors & helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  GREEN='\033[32m' RED='\033[31m' YELLOW='\033[33m' RESET='\033[0m' BOLD='\033[1m'
else
  GREEN='' RED='' YELLOW='' RESET='' BOLD=''
fi

PASS=0
FAIL=0
STEP=0

step() {
  STEP=$((STEP + 1))
  echo ""
  echo -e "${BOLD}[$STEP] $1${RESET}"
}

assert_ok() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    command: $*"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label (file not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_dir_exists() {
  local label="$1" path="$2"
  if [[ -d "$path" ]]; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label (dir not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local label="$1" path="$2" needle="$3"
  if [[ -f "$path" ]] && grep -q "$needle" "$path" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label (\"$needle\" not found in $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_output_contains() {
  local label="$1" needle="$2" output="$3"
  if echo "$output" | grep -q "$needle" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label (\"$needle\" not in output)"
    echo "    output: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_output_not_empty() {
  local label="$1" output="$2"
  if [[ -n "$output" ]]; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label (output was empty)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Setup: create a temp directory simulating a Rust CLI project
# ---------------------------------------------------------------------------
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/primer-e2e-XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$TEST_DIR"

echo "=== Primer End-to-End Test Suite ==="
echo "Working directory: $TEST_DIR"

# ---------------------------------------------------------------------------
# Step 0: Create fake Cargo.toml so stack detection works
# ---------------------------------------------------------------------------
step "Setup: create fake Cargo.toml"

cat > Cargo.toml <<'TOML'
[package]
name = "test-cli"
version = "0.1.0"
edition = "2021"
TOML

assert_file_exists "Cargo.toml created" "$TEST_DIR/Cargo.toml"

# ---------------------------------------------------------------------------
# Step 1: primer init --template rust-cli
# ---------------------------------------------------------------------------
step "primer init --template rust-cli"

# Set env vars so init does not prompt interactively
export Primer_PROJECT_NAME="test-cli"
export Primer_PROJECT_DESC="A test CLI project for e2e testing"

# Pipe "n" to decline auto-emit (we test emit separately)
output=$(echo "n" | "$Primer_BIN" init --template rust-cli 2>&1)
assert_dir_exists ".ai/ directory created" "$TEST_DIR/.ai"
assert_file_exists "project.yaml exists" "$TEST_DIR/.ai/project.yaml"
assert_file_contains "project.yaml has project name" "$TEST_DIR/.ai/project.yaml" "test-cli"
assert_output_contains "init reports template applied" "rust-cli" "$output"

# Verify stack-related knowledge files were copied
assert_dir_exists "knowledge/ dir exists" "$TEST_DIR/.ai/knowledge"
assert_dir_exists "phases/ dir exists" "$TEST_DIR/.ai/phases"

# ---------------------------------------------------------------------------
# Step 2: primer validate
# ---------------------------------------------------------------------------
step "primer validate"

output=$("$Primer_BIN" validate 2>&1)
assert_output_contains "validate finds project.yaml" "project.yaml" "$output"
assert_output_contains "validate passes" "passed" "$output"

# ---------------------------------------------------------------------------
# Step 3: primer emit claude-md
# ---------------------------------------------------------------------------
step "primer emit claude-md"

output=$("$Primer_BIN" emit claude-md 2>&1)
assert_file_exists "CLAUDE.md created" "$TEST_DIR/CLAUDE.md"
assert_file_contains "CLAUDE.md has hash header" "$TEST_DIR/CLAUDE.md" "primer:sha256:"
assert_file_contains "CLAUDE.md has constraints" "$TEST_DIR/CLAUDE.md" "Constraints"
assert_output_contains "emit reports success" "Emitted claude-md" "$output"

# ---------------------------------------------------------------------------
# Step 4: primer emit agents-md
# ---------------------------------------------------------------------------
step "primer emit agents-md"

output=$("$Primer_BIN" emit agents-md 2>&1)
assert_file_exists "AGENTS.md created" "$TEST_DIR/AGENTS.md"
assert_file_contains "AGENTS.md has hash header" "$TEST_DIR/AGENTS.md" "primer:sha256:"
assert_output_contains "emit reports success" "Emitted agents-md" "$output"

# ---------------------------------------------------------------------------
# Step 5: primer kpl init + add gotcha
# ---------------------------------------------------------------------------
step "primer kpl add gotcha"

# Initialize KPL first
"$Primer_BIN" kpl init >/dev/null 2>&1

output=$("$Primer_BIN" kpl add gotcha test-gotcha "Test gotcha for validation" "src/**" high 2>&1)
assert_output_contains "kpl add reports success" "Added gotcha" "$output"
assert_file_contains "gotchas.toml has entry" "$TEST_DIR/.ai/knowledge/gotchas.toml" "test-gotcha"
assert_file_contains "gotchas.toml has summary" "$TEST_DIR/.ai/knowledge/gotchas.toml" "Test gotcha for validation"

# ---------------------------------------------------------------------------
# Step 6: primer kpl query src/main.rs
# ---------------------------------------------------------------------------
step "primer kpl query src/main.rs"

output=$("$Primer_BIN" kpl query src/main.rs 2>&1)
assert_output_contains "query finds test-gotcha" "test-gotcha" "$output"
assert_output_contains "query shows severity" "high" "$output"

# ---------------------------------------------------------------------------
# Step 7: primer kpl budget
# ---------------------------------------------------------------------------
step "primer kpl budget"

output=$("$Primer_BIN" kpl budget 2>&1)
assert_output_contains "budget shows Token Budget header" "Token Budget" "$output"
assert_output_contains "budget shows Tier 0" "Tier 0" "$output"
assert_output_contains "budget shows Tier 1" "Tier 1" "$output"
assert_output_contains "budget shows Tier 2" "Tier 2" "$output"

# ---------------------------------------------------------------------------
# Step 8: Simulate evolution proposal and run primer evolve --auto
# ---------------------------------------------------------------------------
step "primer evolve (simulate proposal)"

mkdir -p "$TEST_DIR/.ai/evolution/proposals"
cat > "$TEST_DIR/.ai/evolution/proposals/add-logging.json" <<'JSON'
{
  "type": "config",
  "agent": "test-agent",
  "timestamp": "2026-03-26T10:00:00Z",
  "change": {
    "section": "constraints",
    "proposed": "Always use structured logging via tracing crate"
  }
}
JSON

assert_file_exists "proposal file created" "$TEST_DIR/.ai/evolution/proposals/add-logging.json"

output=$("$Primer_BIN" evolve --auto 2>&1)
assert_output_contains "evolve finds proposal" "1 proposal" "$output"
assert_output_contains "evolve applies proposal" "Applied" "$output"
assert_output_contains "evolve completes" "Evolution complete" "$output"

# Verify proposal was moved to applied
assert_file_exists "proposal moved to applied" "$TEST_DIR/.ai/evolution/applied/add-logging.json"
assert_file_exists "evolution log has entries" "$TEST_DIR/.ai/evolution/log.jsonl"

# ---------------------------------------------------------------------------
# Step 9: primer seams detect
# ---------------------------------------------------------------------------
step "primer seams detect"

output=$("$Primer_BIN" seams detect 2>&1)
# Output depends on what tools are installed on the test system.
# At minimum, the command should succeed and produce some output.
assert_output_not_empty "seams detect produces output" "$output"

# ---------------------------------------------------------------------------
# Step 10: primer budget
# ---------------------------------------------------------------------------
step "primer budget"

output=$("$Primer_BIN" budget 2>&1)
assert_output_contains "budget shows .ai source" ".ai" "$output"
assert_output_contains "budget shows byte count" "bytes" "$output"
assert_output_contains "budget shows total" "Total" "$output"

# ---------------------------------------------------------------------------
# Step 11: primer --version and help
# ---------------------------------------------------------------------------
step "primer --version and help"

output=$("$Primer_BIN" --version 2>&1)
assert_output_contains "version output" "primer" "$output"

output=$("$Primer_BIN" help 2>&1)
assert_output_contains "help shows init" "init" "$output"
assert_output_contains "help shows emit" "emit" "$output"
assert_output_contains "help shows evolve" "evolve" "$output"
assert_output_contains "help shows kpl" "kpl" "$output"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==============================="
echo "=== E2E Test Results ==="
echo "==============================="
echo -e "  ${GREEN}PASS${RESET}: $PASS"
echo -e "  ${RED}FAIL${RESET}: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}SOME TESTS FAILED${RESET}"
  exit 1
else
  echo -e "${GREEN}ALL TESTS PASSED${RESET}"
  exit 0
fi
