#!/usr/bin/env bash
# Post-edit hook: format the edited file with the same tools pre-commit runs.
set -euo pipefail

FILE="$(jq -r '.tool_input.file_path // empty')"
[[ -n "$FILE" && -f "$FILE" ]] || exit 0

case "$FILE" in
  *.sh)
    if command -v shellharden >/dev/null 2>&1; then
      shellharden --replace "$FILE" 2>/dev/null || true
    fi
    if head -1 "$FILE" | grep -q '^#!'; then
      chmod +x "$FILE"
    fi
    ;;
  *.md)
    if command -v markdownlint-cli2 >/dev/null 2>&1; then
      markdownlint-cli2 --fix "$FILE" >/dev/null 2>&1 || true
    fi
    ;;
  *.tf | *.tftest.hcl)
    if command -v terraform >/dev/null 2>&1; then
      terraform fmt "$FILE" >/dev/null 2>&1 || true
    fi
    ;;
  *.py)
    if command -v uvx >/dev/null 2>&1; then
      uvx ruff@0.16.9 format --quiet "$FILE" 2>/dev/null || true
    fi
    ;;
esac
