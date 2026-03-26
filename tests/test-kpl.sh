#!/usr/bin/env bash
# primer/tests/test-kpl.sh — KPL integration test
# Adds 3 entries, queries them, checks inject output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Work in a temp directory
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$TEST_DIR"

export Primer_KPL_DIR="$TEST_DIR/.ai/knowledge"
export Primer_KPL_TEMPLATE_DIR="$SCRIPT_DIR/../templates/knowledge/.ai/knowledge"

source "$LIB_DIR/kpl.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    got: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== KPL Test Suite ==="
echo ""

# --- Test: init ---
echo "[1] primer_kpl_init"
out=$(primer_kpl_init)
assert_contains "init message" "initialized" "$out"
assert_eq "manifest exists" "yes" "$([[ -f "$Primer_KPL_DIR/manifest.toml" ]] && echo yes || echo no)"
assert_eq "gotchas exists" "yes" "$([[ -f "$Primer_KPL_DIR/gotchas.toml" ]] && echo yes || echo no)"
assert_eq "decisions template exists" "yes" "$([[ -f "$Primer_KPL_DIR/decisions/TEMPLATE.md" ]] && echo yes || echo no)"

# Re-init is idempotent
out=$(primer_kpl_init)
assert_contains "re-init is safe" "already initialized" "$out"

echo ""

# --- Test: add 3 entries ---
echo "[2] primer_kpl_add (3 entries)"

out=$(primer_kpl_add gotcha "no-orm-cache" "ORM caching disabled intentionally for consistency" "src/db/**,src/models/**" "high")
assert_contains "add gotcha" "Added gotcha" "$out"

out=$(primer_kpl_add constraint "no-eval" "Never use eval() in user-facing code" "src/**" "high")
assert_contains "add constraint" "Added constraint" "$out"

out=$(primer_kpl_add failure "redis-timeout-2026" "Redis connection pool exhausted under load, fixed by increasing max_connections" "src/cache/**,lib/redis.ts" "medium")
assert_contains "add failure" "Added failure" "$out"

# Verify files have content
gotcha_content=$(cat "$Primer_KPL_DIR/gotchas.toml")
assert_contains "gotcha in file" "no-orm-cache" "$gotcha_content"

constraint_content=$(cat "$Primer_KPL_DIR/constraints.toml")
assert_contains "constraint in file" "no-eval" "$constraint_content"

failure_content=$(cat "$Primer_KPL_DIR/failures.toml")
assert_contains "failure in file" "redis-timeout-2026" "$failure_content"

echo ""

# --- Test: query ---
echo "[3] primer_kpl_query"

# Query matching src/db/connection.ts -> should match gotcha + constraint
out=$(primer_kpl_query "src/db/connection.ts")
assert_contains "query finds gotcha" "no-orm-cache" "$out"
assert_contains "query finds constraint" "no-eval" "$out"

# Query matching src/cache/redis.ts -> should match constraint + failure
out=$(primer_kpl_query "src/cache/redis.ts")
assert_contains "query finds constraint for cache" "no-eval" "$out"
assert_contains "query finds failure for cache" "redis-timeout-2026" "$out"

# Query non-matching path
out=$(primer_kpl_query "docs/readme.md")
assert_contains "no match for unrelated path" "No matching" "$out"

echo ""

# --- Test: budget ---
echo "[4] primer_kpl_budget"
out=$(primer_kpl_budget)
assert_contains "budget header" "Token Budget" "$out"
assert_contains "budget tier0" "Tier 0" "$out"
assert_contains "budget tier1" "Tier 1" "$out"

echo ""

# --- Test: inject ---
echo "[5] primer_kpl_inject"

out=$(primer_kpl_inject "src/db/connection.ts" "claude-md")
assert_contains "inject has header" "Knowledge" "$out"
assert_contains "inject has gotcha" "no-orm-cache" "$out"

out=$(primer_kpl_inject "src/cache/redis.ts" "agents-md")
assert_contains "inject agents-md format" "no-eval" "$out"

out=$(primer_kpl_inject "docs/readme.md" "raw")
assert_contains "inject raw header" "KPL:" "$out"

echo ""

# --- Test: prune (no stale entries) ---
echo "[6] primer_kpl_prune"
out=$(primer_kpl_prune)
assert_contains "prune finds nothing" "No stale" "$out"

echo ""

# --- Summary ---
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
else
  echo "ALL TESTS PASSED"
  exit 0
fi
