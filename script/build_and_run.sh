#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LunaVaultMacCompanion"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/LunaLibraries"
ROOT_PATH="${LUNA_VAULT_MAC_ROOT:-$ROOT_DIR/.vault-mac-dev}"
PORT="${LUNA_VAULT_MAC_PORT:-49200}"
BIND_HOST="${LUNA_VAULT_MAC_BIND_HOST:-127.0.0.1}"
CREDENTIAL_PATH="${LUNA_VAULT_MAC_CREDENTIAL:-$ROOT_PATH/pairing.credential}"
ENDPOINT_BINDING="${LUNA_VAULT_MAC_ENDPOINT_BINDING:-lanBonjour:vault-mac.local:$PORT}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build --product "$APP_NAME"
APP_BINARY="$(swift build --show-bin-path)/$APP_NAME"
if [[ ! -f "$CREDENTIAL_PATH" ]]; then
  "$APP_BINARY" --initialize --root "$ROOT_PATH" --endpoint-binding "$ENDPOINT_BINDING"
fi

RUN_ARGS=(--root "$ROOT_PATH" --credential "$CREDENTIAL_PATH" --bind-host "$BIND_HOST" --port "$PORT" --bonjour-name "Luna Vault")

case "$MODE" in
  run)
    exec "$APP_BINARY" "${RUN_ARGS[@]}"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY" "${RUN_ARGS[@]}"
    ;;
  --logs|logs)
    "$APP_BINARY" "${RUN_ARGS[@]}" &
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    "$APP_BINARY" "${RUN_ARGS[@]}" &
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"com.hsanabria.luna.vault.mac\""
    ;;
  --verify|verify)
    "$APP_BINARY" "${RUN_ARGS[@]}" &
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
