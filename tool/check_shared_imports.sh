#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="$ROOT_DIR/lib/services"

# Guardrail: shared services should avoid direct dart:io imports.
# Platform-specific files are allowed via explicit allowlist.
ALLOWLIST_REGEX='(ble_service\.dart|wifi_direct_service\.dart|desktop_tray_service\.dart|update_service\.dart|voice_service\.dart|image_service\.dart|story_service\.dart|google_drive_channel_backup\.dart|channel_backup_service\.dart|chat_storage_service\.dart|channel_service\.dart|group_service\.dart|media_upload_queue\.dart|broadcast_outbox_service\.dart)'

matches="$(rg -n "import 'dart:io';" "$TARGET_DIR" || true)"
if [[ -z "$matches" ]]; then
  echo "OK: no dart:io imports in $TARGET_DIR"
  exit 0
fi

violations="$(echo "$matches" | rg -v "$ALLOWLIST_REGEX" || true)"
if [[ -n "$violations" ]]; then
  echo "Found disallowed dart:io imports:"
  echo "$violations"
  exit 1
fi

echo "OK: dart:io imports are within allowlist"
