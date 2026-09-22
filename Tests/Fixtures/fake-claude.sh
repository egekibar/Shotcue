#!/bin/bash
# Fake `claude` binary for tests.
#   FAKE_CLAUDE_ARGS_FILE   if set, argv + CWD + selected env vars are written there
#   FAKE_CLAUDE_SCENARIO    success (default) | max_turns | error | slow | hang
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = "--version" ]; then echo "2.1.278 (Claude Code)"; exit 0; fi
if [ -n "${FAKE_CLAUDE_ARGS_FILE:-}" ]; then
  { printf '%s\n' "$@"; printf 'CWD=%s\n' "$PWD"; env | grep -E '^(HOME|PATH|ANTHROPIC_API_KEY)=' || true; } > "$FAKE_CLAUDE_ARGS_FILE"
fi
SID="3f2a9c40-7b18-4c6d-9e51-8a2b1d4f0c73"
case "${FAKE_CLAUDE_SCENARIO:-success}" in
  success)   cat "$DIR/sample-stream.jsonl" ;;
  max_turns) head -n 3 "$DIR/sample-stream.jsonl"
             echo "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"duration_ms\":1000,\"num_turns\":30,\"session_id\":\"$SID\",\"total_cost_usd\":0.1,\"permission_denials\":[]}" ;;
  error)     echo "Error: not logged in. Run 'claude login'." >&2; exit 1 ;;
  slow)      head -n 2 "$DIR/sample-stream.jsonl"; sleep 1; tail -n +3 "$DIR/sample-stream.jsonl" ;;
  hang)      head -n 2 "$DIR/sample-stream.jsonl"; sleep 300 ;;
  *)         echo "unknown scenario" >&2; exit 2 ;;
esac
