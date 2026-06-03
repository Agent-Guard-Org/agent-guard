BINDIR := $(HOME)/.local/bin
SETTINGS := $(HOME)/.claude/settings.json
HOOK_CMD := $(BINDIR)/agent-guard

.PHONY: build clean install hooks hooks-remove test

build:
	go build -o agent-guard .

clean:
	rm -f agent-guard

install: build
	mkdir -p $(BINDIR)
	cp agent-guard $(HOOK_CMD)

hooks: install
	@jq --arg cmd "$(HOOK_CMD)" '.hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // []) + [{"hooks":[{"type":"command","command":$$cmd,"args":[],"timeout":30}]}] | .hooks.PostToolUse = (.hooks.PostToolUse // []) + [{"hooks":[{"type":"command","command":$$cmd,"args":[],"timeout":30}]}]' $(SETTINGS) > $(SETTINGS).tmp && mv $(SETTINGS).tmp $(SETTINGS)
	@echo "hooks added to $(SETTINGS)"

hooks-remove:
	@jq 'del(.hooks.UserPromptSubmit) | del(.hooks.PostToolUse)' \
		$(SETTINGS) > $(SETTINGS).tmp && mv $(SETTINGS).tmp $(SETTINGS)
	@echo "hooks removed from $(SETTINGS)"

test: build
	@PATH="$(CURDIR):/tmp/trufflehog-test:$$PATH" ./test.sh
