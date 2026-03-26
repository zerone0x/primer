#!/usr/bin/env bash
# Run all Primer test files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -t 1 ]]; then
  BOLD='\033[1m' GREEN='\033[32m' RED='\033[31m' RESET='\033[0m'
else
  BOLD='' GREEN='' RED='' RESET=''
fi

total=0
passed=0
failed=0
failed_tests=()

echo -e "${BOLD}=== Primer Test Runner ===${RESET}"
echo ""

for test in "$SCRIPT_DIR"/test-*.sh; do
  [[ "$(basename "$test")" == "test-all.sh" ]] && continue
  [[ -f "$test" ]] || continue

  total=$((total + 1))
  name="$(basename "$test")"

  echo -e "${BOLD}=== Running $name ===${RESET}"
  if bash "$test"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    failed_tests+=("$name")
  fi
  echo ""
done

echo -e "${BOLD}=== Overall Results ===${RESET}"
echo "  Total:  $total"
echo -e "  ${GREEN}Passed${RESET}: $passed"
echo -e "  ${RED}Failed${RESET}: $failed"

if [[ $failed -gt 0 ]]; then
  echo ""
  echo "Failed tests:"
  for t in "${failed_tests[@]}"; do
    echo "  - $t"
  done
  exit 1
else
  echo ""
  echo -e "${GREEN}All test suites passed.${RESET}"
  exit 0
fi
