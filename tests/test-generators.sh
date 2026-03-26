#!/usr/bin/env bash
# Test all generators with sample project.yaml input
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Primer_ROOT="$(dirname "$SCRIPT_DIR")"
SAMPLE_YAML="$SCRIPT_DIR/sample-project.yaml"
OUTDIR="$SCRIPT_DIR/output"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# Source libs for YAML-to-JSON conversion
source "$Primer_ROOT/lib/core.sh"
source "$Primer_ROOT/lib/emit.sh"

# Convert sample YAML to JSON
CONFIG_JSON=$(primer_config_to_json "$SAMPLE_YAML")

echo "=== Config JSON ==="
echo "$CONFIG_JSON" | jq .
echo ""

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local generator="$Primer_ROOT/plugins/generators/${name}.sh"
  local outfile="$OUTDIR/${name}.out"

  echo "--- Testing: $name ---"

  # Test --schema
  if "$generator" --schema | jq . > /dev/null 2>&1; then
    echo "  --schema: OK"
  else
    echo "  --schema: FAIL"
    ((FAIL++))
    return
  fi

  # Test --describe
  local desc
  desc=$("$generator" --describe)
  if [[ -n "$desc" ]]; then
    echo "  --describe: OK ($desc)"
  else
    echo "  --describe: FAIL (empty)"
    ((FAIL++))
    return
  fi

  # Test --exec
  if echo "$CONFIG_JSON" | "$generator" --exec > "$outfile" 2>/dev/null; then
    local lines
    lines=$(wc -l < "$outfile")
    local size
    size=$(wc -c < "$outfile")
    echo "  --exec: OK ($lines lines, $size bytes)"

    # Verify hash header exists
    if head -1 "$outfile" | grep -qE '(primer:sha256:|# primer:sha256:)'; then
      echo "  hash header: OK"
    else
      echo "  hash header: FAIL (first line: $(head -1 "$outfile"))"
      ((FAIL++))
      return
    fi

    ((PASS++))
  else
    echo "  --exec: FAIL (exit code $?)"
    ((FAIL++))
    return
  fi

  echo ""
}

run_test "claude-md"
run_test "agents-md"
run_test "cursorrules"
run_test "hermes-md"

echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo ""

# Show generated outputs
for f in "$OUTDIR"/*.out; do
  echo "========================================"
  echo "FILE: $(basename "$f")"
  echo "========================================"
  cat "$f"
  echo ""
done

exit $FAIL
