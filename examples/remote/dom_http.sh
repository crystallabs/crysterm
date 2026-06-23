#!/usr/bin/env bash
# Out-of-process handler for the Crysterm HTTP bridge — pure bash + curl + jq.
#
# This is the "behavior" half of a Crysterm app, in the least capable language
# we could pick. It receives UI events over Server-Sent-Events and drives the
# UI back with JSON-RPC commands. No Crystal, no compiler, no SDK.
#
# Start the engine first (crystal run -Dremote examples/remote/dom_http.cr), then run this.
set -euo pipefail
HOST="${CRYSTERM_HOST:-http://127.0.0.1:7000}"
# The CLI passes a token via CRYSTERM_TOKEN when --token is used.
AUTH=(); [ -n "${CRYSTERM_TOKEN:-}" ] && AUTH=(-H "X-Crysterm-Token: ${CRYSTERM_TOKEN}")

# Fire a JSON-RPC command at the engine.
rpc() { curl -s "${AUTH[@]}" -X POST "$HOST/rpc" -d "$1" >/dev/null; }

set_content() {
  rpc "$(jq -nc --arg s "$1" --arg v "$2" \
    '{jsonrpc:"2.0",method:"setContent",params:{selector:$s,value:$v}}')"
}
add_class() {
  rpc "$(jq -nc --arg s "$1" --arg c "$2" \
    '{jsonrpc:"2.0",method:"addClass",params:{selector:$s,class:$c}}')"
}
quit() { rpc '{"jsonrpc":"2.0","method":"quit"}'; }

echo "Connecting to $HOST/events …" >&2
set_content "#status" "{center}Handler connected. Press a button.{/center}"

# Read the SSE stream line by line; act on each event's action / key.
curl -sN "${AUTH[@]}" "$HOST/events" | while IFS= read -r line; do
  # SSE payload lines look like:  data: {...json...}
  [ "${line#data: }" = "$line" ] && continue
  json="${line#data: }"

  action=$(jq -r '.params.action // empty' <<<"$json")
  type=$(jq -r '.params.type   // empty' <<<"$json")
  char=$(jq -r '.params.char   // empty' <<<"$json")

  case "$action" in
    save)
      set_content "#status" "{center}Saved at $(date +%H:%M:%S){/center}"
      add_class   "#save" "done"
      ;;
    ping)
      set_content "#status" "{center}pong{/center}"
      ;;
    quit)
      quit; break
      ;;
  esac

  # Global key handling: quit on 'q'.
  if [ "$type" = "keypress" ] && [ "$char" = "q" ]; then
    quit; break
  fi
done
