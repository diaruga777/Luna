#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LunaVaultMacCompanion"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/LunaLibraries"
ROOT_PATH="${LUNA_VAULT_MAC_ROOT:-$ROOT_DIR/.vault-mac-dev}"
SECRET="${LUNA_VAULT_MAC_SECRET_BASE64:-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=}" 
SESSION="${LUNA_VAULT_MAC_SESSION:-00000000-0000-0000-0000-000000000001}"
PORT="${LUNA_VAULT_MAC_PORT:-49200}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build --product "$APP_NAME"
APP_BINARY="$(swift build --show-bin-path)/$APP_NAME"

case "$MODE" in
  run)
    exec "$APP_BINARY" --root "$ROOT_PATH" --secret-base64 "$SECRET" --session "$SESSION" --port "$PORT"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" --root "$ROOT_PATH" --secret-base64 "$SECRET" --session "$SESSION" --port "$PORT"
    ;;
  --logs|logs)
    "$APP_BINARY" --root "$ROOT_PATH" --secret-base64 "$SECRET" --session "$SESSION" --port "$PORT" &
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    "$APP_BINARY" --root "$ROOT_PATH" --secret-base64 "$SECRET" --session "$SESSION" --port "$PORT" &
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"com.hsanabria.luna.vault.mac\""
    ;;
  --verify|verify)
    "$APP_BINARY" --root "$ROOT_PATH" --secret-base64 "$SECRET" --session "$SESSION" --port "$PORT" &
    companion_pid=$!
    trap 'kill "$companion_pid" >/dev/null 2>&1 || true' EXIT
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
