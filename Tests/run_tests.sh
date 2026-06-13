#!/usr/bin/env bash
# run_tests.sh — executa todos os testes unitários do projeto
# Não requer Xcode instalado; usa apenas o compilador Swift do sistema.
#
# Uso:
#   chmod +x Tests/run_tests.sh
#   ./Tests/run_tests.sh
#
# Pré-requisito: Swift toolchain instalado (vem com o Xcode ou swift.org/download)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.."; pwd)"
TESTS_DIR="$ROOT/Tests"

PASSED=0
FAILED=0

run_test() {
    local file="$1"
    local name="$(basename "$file" .swift)"
    echo
    echo "▶ Running $name..."
    if swift "$file"; then
        PASSED=$((PASSED + 1))
        echo "  → PASSED"
    else
        FAILED=$((FAILED + 1))
        echo "  → FAILED"
    fi
}

echo "================================================================"
echo "  DjiOsmo3Mac — Unit Tests"
echo "  Swift: $(swift --version 2>&1 | head -1)"
echo "================================================================"

run_test "$TESTS_DIR/DUMLCodecTests.swift"
run_test "$TESTS_DIR/AxisOffsetModelTests.swift"

echo
echo "================================================================"
echo "  Results: $PASSED passed, $FAILED failed"
echo "================================================================"

if [ "$FAILED" -gt 0 ]; then
    echo "❌ Test suite FAILED"
    exit 1
else
    echo "✅ All test suites passed"
fi
