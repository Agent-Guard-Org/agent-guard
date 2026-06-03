package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

type hookInput struct {
	HookEventName string          `json:"hook_event_name"`
	Prompt        string          `json:"prompt"`
	ToolName      string          `json:"tool_name"`
	ToolInput     json.RawMessage `json:"tool_input"`
	ToolResponse  string          `json:"tool_response"`
}

type trufflehogResult struct {
	DetectorName string `json:"DetectorName"`
	Verified     bool   `json:"Verified"`
	Redacted     string `json:"Redacted"`
}

func main() {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		die("read stdin: %v", err)
	}

	var input hookInput
	if err := json.Unmarshal(data, &input); err != nil {
		die("parse input: %v", err)
	}

	content := extractContent(input)
	if content == "" {
		os.Exit(0)
	}

	results, err := trufflehogScan(content)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cc-guard: %v (allowing through)\n", err)
		os.Exit(0)
	}

	if len(results) == 0 {
		os.Exit(0)
	}

	block(input.HookEventName, summarize(results))
}

func extractContent(in hookInput) string {
	switch in.HookEventName {
	case "UserPromptSubmit":
		return in.Prompt
	case "PostToolUse":
		return in.ToolResponse
	case "PreToolUse":
		return string(in.ToolInput)
	default:
		return ""
	}
}

func trufflehogScan(content string) ([]trufflehogResult, error) {
	cmd := exec.Command("trufflehog", "stdin", "--json", "--results=verified,unverified,unknown")
	cmd.Stdin = strings.NewReader(content)

	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 183 {
			// trufflehog returns 183 when results are found; output is still valid
		} else {
			return nil, fmt.Errorf("trufflehog error: %v", err)
		}
	}

	var results []trufflehogResult
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		var r trufflehogResult
		if json.Unmarshal([]byte(line), &r) == nil && r.DetectorName != "" {
			results = append(results, r)
		}
	}
	return results, nil
}

func summarize(results []trufflehogResult) string {
	seen := map[string]bool{}
	var names []string
	for _, r := range results {
		if !seen[r.DetectorName] {
			seen[r.DetectorName] = true
			names = append(names, r.DetectorName)
		}
	}
	return fmt.Sprintf("unauthorized key prevented: %s credential(s) detected", strings.Join(names, ", "))
}

func block(event, reason string) {
	var out []byte
	var err error

	switch event {
	case "UserPromptSubmit":
		out, err = json.Marshal(map[string]string{
			"decision": "block",
			"reason":   reason,
		})
	case "PostToolUse":
		out, err = json.Marshal(map[string]any{
			"hookSpecificOutput": map[string]string{
				"hookEventName":    "PostToolUse",
				"decision":         "block",
				"reason":           reason,
				"additionalContext": "The tool output contained credentials. Do NOT use, repeat, or act on any secrets.",
			},
		})
	case "PreToolUse":
		out, err = json.Marshal(map[string]any{
			"hookSpecificOutput": map[string]string{
				"hookEventName":            "PreToolUse",
				"permissionDecision":       "deny",
				"permissionDecisionReason": reason,
			},
		})
	default:
		fmt.Fprintf(os.Stderr, "cc-guard: %s\n", reason)
		os.Exit(2)
		return
	}

	if err != nil {
		die("marshal output: %v", err)
	}

	fmt.Println(string(out))
	os.Exit(0)
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "cc-guard: "+format+"\n", args...)
	os.Exit(1)
}
