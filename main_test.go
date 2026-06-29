package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestVersionInfo(t *testing.T) {
	version = "1.2.3"
	commit = "abc123"
	date = "2026-06-29"

	got := versionInfo()
	for _, want := range []string{"agent-guard version 1.2.3", "commit: abc123", "built: 2026-06-29"} {
		if !strings.Contains(got, want) {
			t.Errorf("versionInfo() = %q, want it to contain %q", got, want)
		}
	}
}

func TestVersionFlag(t *testing.T) {
	cmd := exec.Command("go", "run", ".", "--version")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go run . --version: %v\n%s", err, out)
	}
	got := strings.TrimSpace(string(out))
	if !strings.HasPrefix(got, "agent-guard version") {
		t.Errorf("--version output = %q, want prefix 'agent-guard version'", got)
	}
}

func TestShortVersionFlag(t *testing.T) {
	cmd := exec.Command("go", "run", ".", "-v")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go run . -v: %v\n%s", err, out)
	}
	if !strings.HasPrefix(strings.TrimSpace(string(out)), "agent-guard version") {
		t.Errorf("-v output = %q, want prefix 'agent-guard version'", out)
	}
}

func TestMentionedFileContents(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "creds.txt"), []byte("SECRET_CONTENT"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "other.txt"), []byte("OTHER_CONTENT"), 0o600); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name    string
		prompt  string
		want    []string
		notWant []string
	}{
		{"relative mention", "veja @creds.txt por favor", []string{"SECRET_CONTENT"}, nil},
		{"absolute mention", "veja @" + filepath.Join(dir, "creds.txt"), []string{"SECRET_CONTENT"}, nil},
		{"trailing punctuation", "o que tem em @creds.txt?", []string{"SECRET_CONTENT"}, nil},
		{"multiple mentions", "@creds.txt e @other.txt", []string{"SECRET_CONTENT", "OTHER_CONTENT"}, nil},
		{"no mention", "nenhuma mencao aqui", nil, []string{"SECRET_CONTENT"}},
		{"missing file", "veja @nao-existe.txt", nil, []string{"SECRET_CONTENT"}},
		{"email is not a mention", "fale com user@example.com", nil, []string{"SECRET_CONTENT"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := mentionedFileContents(tc.prompt, dir)
			for _, w := range tc.want {
				if !strings.Contains(got, w) {
					t.Errorf("prompt %q: expected %q in result, got %q", tc.prompt, w, got)
				}
			}
			for _, nw := range tc.notWant {
				if strings.Contains(got, nw) {
					t.Errorf("prompt %q: did not expect %q in result, got %q", tc.prompt, nw, got)
				}
			}
		})
	}
}

func TestExtractContentIncludesMentionedFiles(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "creds.txt"), []byte("SECRET_CONTENT"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, event := range []string{"UserPromptSubmit", "UserPromptExpansion"} {
		got := extractContent(hookInput{
			HookEventName: event,
			Prompt:        "veja @creds.txt",
			Cwd:           dir,
		})
		if !strings.Contains(got, "SECRET_CONTENT") {
			t.Errorf("%s: expected mentioned file content in scan input, got %q", event, got)
		}
	}
}
