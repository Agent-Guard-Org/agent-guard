package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
