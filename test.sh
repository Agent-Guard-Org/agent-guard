#!/usr/bin/env bash
set -euo pipefail

BINARY="${1:-./agent-guard}"

fail=0

run_test() {
	local name="$1"
	local input="$2"
	local expect_fail="${3:-0}"

	if [ "$expect_fail" -eq 1 ]; then
		if echo "$input" | "$BINARY" 2>/dev/null | grep -q "unauthorized key prevented"; then
			echo "PASS: $name"
		else
			echo "FAIL: $name"
			fail=1
		fi
	else
		if echo "$input" | "$BINARY" 2>/dev/null; then
			echo "PASS: $name"
		else
			echo "FAIL: $name"
			fail=1
		fi
	fi
}

run_test "clean prompt" \
	'{"hook_event_name":"UserPromptSubmit","prompt":"hello world"}' 0

run_test "aws credentials blocked" \
	'{"hook_event_name":"UserPromptSubmit","prompt":"aws_access_key_id=AKIAQYLPMN5HHHFPZAM2\naws_secret_access_key=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"}' 1

run_test "post tool use (string)" \
	'{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":"aws_access_key_id=AKIAQYLPMN5HHHFPZAM2\naws_secret_access_key=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"}' 1

run_test "post tool use (object)" \
	'{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"output":"aws_access_key_id=AKIAQYLPMN5HHHFPZAM2\naws_secret_access_key=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"}}' 1

run_test "pre tool use blocked" \
	'{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/test","content":"aws_access_key_id=AKIAQYLPMN5HHHFPZAM2\naws_secret_access_key=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"}}' 1

exit "$fail"
