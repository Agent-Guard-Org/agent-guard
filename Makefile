BINDIR := $(HOME)/.local/bin
SETTINGS := $(HOME)/.claude/settings.json
HOOK_CMD := $(BINDIR)/cc-guard

.PHONY: build clean install hooks hooks-remove test

build:
	go build -o cc-guard .

clean:
	rm -f cc-guard

install: build
	mkdir -p $(BINDIR)
	cp cc-guard $(HOOK_CMD)

hooks: install
	@jq --arg cmd "$(HOOK_CMD)" '.hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // []) + [{"hooks":[{"type":"command","command":$$cmd,"args":[],"timeout":30}]}] | .hooks.PostToolUse = (.hooks.PostToolUse // []) + [{"hooks":[{"type":"command","command":$$cmd,"args":[],"timeout":30}]}]' $(SETTINGS) > $(SETTINGS).tmp && mv $(SETTINGS).tmp $(SETTINGS)
	@echo "hooks added to $(SETTINGS)"

hooks-remove:
	@jq 'del(.hooks.UserPromptSubmit) | del(.hooks.PostToolUse)' \
		$(SETTINGS) > $(SETTINGS).tmp && mv $(SETTINGS).tmp $(SETTINGS)
	@echo "hooks removed from $(SETTINGS)"

test: build
	@PATH="$(CURDIR):/tmp/trufflehog-test:$$PATH" && \
	echo '{"hook_event_name":"UserPromptSubmit","prompt":"hello world"}' | ./cc-guard && echo "PASS: clean prompt" || echo "FAIL: clean prompt" && \
	echo '{"hook_event_name":"UserPromptSubmit","prompt":"aws_access_key_id=AKIAQYLPMN5HHHFPZAM2\naws_secret_access_key=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"}' | ./cc-guard | grep -q "unauthorized key prevented" && echo "PASS: aws credentials blocked" || echo "FAIL: aws credentials blocked" && \
	echo '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":"aws_access_key_id=AKIAQYLPMN5HHHFPZAM2\naws_secret_access_key=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"}' | ./cc-guard | grep -q "unauthorized key prevented" && echo "PASS: post tool use (string)" || echo "FAIL: post tool use (string)" && \
	echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"output":"aws_access_key_id=AKIAQYLPMN5HHHFPZAM2\naws_secret_access_key=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"}}' | ./cc-guard | grep -q "unauthorized key prevented" && echo "PASS: post tool use (object)" || echo "FAIL: post tool use (object)" && \
	echo '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/test","content":"aws_access_key_id=AKIAQYLPMN5HHHFPZAM2\naws_secret_access_key=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"}}' | ./cc-guard | grep -q "unauthorized key prevented" && echo "PASS: pre tool use blocked" || echo "FAIL: pre tool use blocked"
