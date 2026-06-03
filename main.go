package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type hookInput struct {
	HookEventName string          `json:"hook_event_name"`
	Prompt        string          `json:"prompt"`
	ToolName      string          `json:"tool_name"`
	ToolInput     json.RawMessage `json:"tool_input"`
	ToolResponse  json.RawMessage `json:"tool_response"`
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
		fmt.Fprintf(os.Stderr, "agent-guard: %v (allowing through)\n", err)
		os.Exit(0)
	}

	if len(results) == 0 {
		os.Exit(0)
	}

	block(input.HookEventName, summarize(results), input.ToolResponse)
}

func extractContent(in hookInput) string {
	switch in.HookEventName {
	case "UserPromptSubmit":
		return in.Prompt
	case "PostToolUse":
		return extractStrings(in.ToolResponse)
	case "PreToolUse":
		return extractStrings(in.ToolInput)
	default:
		return ""
	}
}

func extractStrings(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var obj any
	if json.Unmarshal(raw, &obj) != nil {
		return string(raw)
	}
	var parts []string
	collectStrings(obj, &parts)
	return strings.Join(parts, "\n")
}

func collectStrings(v any, out *[]string) {
	switch val := v.(type) {
	case string:
		*out = append(*out, val)
	case map[string]any:
		for _, child := range val {
			collectStrings(child, out)
		}
	case []any:
		for _, child := range val {
			collectStrings(child, out)
		}
	}
}

func redactResponse(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return raw
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		redacted, _ := json.Marshal("[REDACTED by agent-guard - credentials detected]")
		return redacted
	}
	var obj any
	if json.Unmarshal(raw, &obj) != nil {
		return raw
	}
	redacted := redactStrings(obj)
	out, err := json.Marshal(redacted)
	if err != nil {
		return raw
	}
	return out
}

var safeFields = map[string]bool{
	"type": true, "numLines": true, "startLine": true,
	"totalLines": true, "interrupted": true, "isImage": true,
}

func redactStrings(v any) any {
	return redactStringsRec(v, "")
}

func redactStringsRec(v any, field string) any {
	switch val := v.(type) {
	case string:
		if !safeFields[field] && len(val) > 0 {
			return "[REDACTED by agent-guard - credentials detected]"
		}
		return val
	case map[string]any:
		result := make(map[string]any, len(val))
		for k, child := range val {
			result[k] = redactStringsRec(child, k)
		}
		return result
	case []any:
		result := make([]any, len(val))
		for i, child := range val {
			result[i] = redactStringsRec(child, "")
		}
		return result
	default:
		return v
	}
}

func resolveTrufflehog() string {
	if p, err := exec.LookPath("trufflehog"); err == nil {
		return p
	}
	home, _ := os.UserHomeDir()
	if home != "" {
		candidate := filepath.Join(home, ".local", "bin", "trufflehog")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return "trufflehog"
}

func trufflehogScan(content string) ([]trufflehogResult, error) {
	cmd := exec.Command(resolveTrufflehog(), "stdin", "--json", "--results=verified,unverified,unknown")
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

func block(event, reason string, toolResponse json.RawMessage) {
	var out []byte
	var err error

	switch event {
	case "UserPromptSubmit":
		out, err = json.Marshal(map[string]string{
			"decision": "block",
			"reason":   reason,
		})
	case "PostToolUse":
		redacted := redactResponse(toolResponse)
		out, err = json.Marshal(map[string]any{
			"hookSpecificOutput": map[string]any{
				"hookEventName":     "PostToolUse",
				"decision":          "block",
				"reason":            reason,
				"updatedToolOutput": json.RawMessage(redacted),
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
		fmt.Fprintf(os.Stderr, "agent-guard: %s\n", reason)
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
	fmt.Fprintf(os.Stderr, "agent-guard: "+format+"\n", args...)
	os.Exit(1)
}
