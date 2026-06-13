#!/usr/bin/env bash
# Compiles and runs the standalone unit tests. Requires only the Swift
# toolchain (Command Line Tools) — no Xcode test target needed.
#
#   bash Tests/run_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$BIN_DIR"' EXIT

swiftc -o "$BIN_DIR/duml_tests" \
  DjiOsmo3Mac/DUMLProtocol.swift \
  DjiOsmo3Mac/TelemetryNormalization.swift \
  DjiOsmo3Mac/PitchExperiment.swift \
  Tests/main.swift

"$BIN_DIR/duml_tests"
