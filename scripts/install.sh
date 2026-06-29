#!/usr/bin/env bash
set -euo pipefail

REPO="Agent-Guard-Org/agent-guard"
BINARY="agent-guard"
DEFAULT_BINDIR="$HOME/.local/bin"

CYAN=""
GREEN=""
RED=""
YELLOW=""
BOLD=""
RESET=""
if [ -t 1 ]; then
    CYAN="\033[36m"
    GREEN="\033[32m"
    RED="\033[31m"
    YELLOW="\033[33m"
    BOLD="\033[1m"
    RESET="\033[0m"
fi

info()  { printf "${CYAN}info${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN} ok ${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}warn${RESET} %s\n" "$*" >&2; }
die()   { printf "${RED} err${RESET} %s\n" "$*" >&2; exit 1; }

USAGE="
${BOLD}agent-guard install script${RESET}

Usage: $(basename "$0") [flags]

Flags:
  -b, --bindir DIR          Install directory (default: \$HOME/.local/bin)
  -v, --version VERSION     Install a specific version (default: latest)
  -y, --yes                 Auto-accept all prompts
      --skip-trufflehog     Don't prompt to install trufflehog
      --skip-config         Don't prompt for Claude Code configuration
      --scope SCOPE         Hook scope: global, project, local (prompts if unset)
  -h, --help                Show this help
"

BINDIR=""
VERSION=""
AUTO_YES=0
SKIP_TRUFFLEHOG=0
SKIP_CONFIG=0
SCOPE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--bindir)   BINDIR="$2"; shift 2 ;;
        -v|--version)  VERSION="$2"; shift 2 ;;
        -y|--yes)      AUTO_YES=1; shift ;;
        --skip-trufflehog) SKIP_TRUFFLEHOG=1; shift ;;
        --skip-config)     SKIP_CONFIG=1; shift ;;
        --scope)      SCOPE="$2"; shift 2 ;;
        -h|--help)    printf "%s\n" "$USAGE"; exit 0 ;;
        *)            die "unknown flag: $1" ;;
    esac
done

BINDIR="${BINDIR:-$DEFAULT_BINDIR}"

has_tty() {
    [ -t 0 ] 2>/dev/null
}

prompt_yes() {
    local msg="$1"
    local default="${2:-N}"
    if [ "$AUTO_YES" -eq 1 ]; then
        return 0
    fi
    if ! has_tty; then
        [ "$default" = "Y" ] && return 0
        return 1
    fi
    local prompt_suffix="[y/N]"
    [ "$default" = "Y" ] && prompt_suffix="[Y/n]"
    printf "%s %s " "$msg" "$prompt_suffix"
    read -r answer < /dev/tty
    [ -z "$answer" ] && answer="$default"
    case "$answer" in
        y|Y|yes) return 0 ;;
        *)       return 1 ;;
    esac
}

prompt_choice() {
    local msg="$1"
    shift
    local options=("$@")
    local default="1"
    if [ "$AUTO_YES" -eq 1 ]; then
        echo "$default"
        return
    fi
    if ! has_tty; then
        echo "$default"
        return
    fi
    printf "%s\n" "$msg"
    local i=1
    for opt in "${options[@]}"; do
        printf "  %d) %s\n" "$i" "$opt"
        i=$((i + 1))
    done
    printf "  Enter choice [1]: "
    read -r choice < /dev/tty
    [ -z "$choice" ] && choice="$default"
    echo "$choice"
}

detect_os() {
    case "$(uname -s)" in
        Linux)  echo "linux" ;;
        Darwin) echo "darwin" ;;
        *)      die "unsupported OS: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             die "unsupported arch: $(uname -m)" ;;
    esac
}

get_latest_version() {
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    curl -fsSL "$url" 2>/dev/null | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}

download_binary() {
    local version="$1"
    local os="$2"
    local arch="$3"
    local destdir="$4"

    local version_no_v="${version#v}"
    local archive_name="${BINARY}_${version_no_v}_${os}_${arch}.tar.gz"
    local download_url="https://github.com/${REPO}/releases/download/${version}/${archive_name}"

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    info "downloading ${archive_name}"
    local archive_path="${tmpdir}/${archive_name}"
    curl -fsSL -o "$archive_path" "$download_url" || die "failed to download ${download_url}"

    info "extracting"
    tar -xzf "$archive_path" -C "$tmpdir" || die "failed to extract archive"

    mkdir -p "$destdir"
    cp "${tmpdir}/${BINARY}" "${destdir}/${BINARY}" || die "failed to copy binary"
    chmod +x "${destdir}/${BINARY}"

    local hooks_dir="${destdir}/${BINARY}.hooks"
    if [ -f "${tmpdir}/hooks/hooks.json" ]; then
        mkdir -p "$hooks_dir"
        cp "${tmpdir}/hooks/hooks.json" "${hooks_dir}/hooks.json"
    fi
}

install_trufflehog() {
    local bindir="$1"
    info "installing trufflehog to ${bindir}"
    curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b "$bindir" 2>&1 || {
        warn "trufflehog installation failed, you can install it manually later"
        return 1
    }
    ok "trufflehog installed"
}

json_set_field() {
    local file="$1"
    local keypath="$2"
    local value="$3"

    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        if [ -s "$file" ]; then
            jq --argjson val "$value" "$keypath += \$val" "$file" > "$tmp"
        else
            echo "{}" | jq --argjson val "$value" "$keypath += \$val" > "$tmp"
        fi
        mv "$tmp" "$file"
    else
        if [ ! -s "$file" ]; then
            printf '{"hooks":{}}' > "$file"
        fi
        warn "jq not found, cannot auto-merge JSON. Please add hooks manually."
        return 1
    fi
}

get_settings_path() {
    local scope="$1"
    case "$scope" in
        global)
            echo "$HOME/.claude/settings.json"
            ;;
        project)
            echo ".claude/settings.json"
            ;;
        local)
            echo ".claude/settings.local.json"
            ;;
    esac
}

configure_claude_code() {
    local bindir="$1"
    local scope="$2"
    local settings_file

    settings_file="$(get_settings_path "$scope")"

    if [ "$scope" = "global" ]; then
        mkdir -p "$(dirname "$settings_file")"
    fi

    local hook_command="${bindir}/${BINARY}"
    local hooks_json
    hooks_json=$(cat <<EOF
[
  {
    "hooks": [
      {
        "type": "command",
        "command": "${hook_command}",
        "args": [],
        "timeout": 30
      }
    ]
  }
]
EOF
)

    local existing=""
    if [ -f "$settings_file" ]; then
        existing="$(cat "$settings_file")"
    fi

    printf "\n"
    info "the following hooks will be added to ${BOLD}${settings_file}${RESET}:"
    printf "\n"
    printf "  %sUserPromptSubmit%s → run agent-guard (block if secrets found)\n" "$CYAN" "$RESET"
    printf "  %sPostToolUse%s      → run agent-guard (block if secrets found)\n" "$CYAN" "$RESET"
    printf "\n"

    if ! prompt_yes "Apply these changes?" "N"; then
        warn "skipping Claude Code configuration"
        return
    fi

    local update_cmd
    update_cmd=$(cat <<'JQ'
.hooks += {
  "UserPromptSubmit": [],
  "PostToolUse": []
} |
.hooks.UserPromptSubmit = (
  (.hooks.UserPromptSubmit // []) +
  [{"hooks": [{"type": "command", "command": ($cmd + "/" + $bin), "args": [], "timeout": 30}]}]
) |
.hooks.PostToolUse = (
  (.hooks.PostToolUse // []) +
  [{"hooks": [{"type": "command", "command": ($cmd + "/" + $bin), "args": [], "timeout": 30}]}]
)
JQ
)

    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        if [ -s "$settings_file" ]; then
            jq --arg cmd "$bindir" --arg bin "$BINARY" "$update_cmd" "$settings_file" > "$tmp"
        else
            echo '{}' | jq --arg cmd "$bindir" --arg bin "$BINARY" "$update_cmd" > "$tmp"
        fi
        mv "$tmp" "$settings_file"
        ok "hooks written to ${settings_file}"
    else
        warn "jq not found — cannot auto-merge JSON."
        info "add this to ${settings_file}:"
        cat <<JSONEOF

{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${hook_command}",
            "args": [],
            "timeout": 30
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${hook_command}",
            "args": [],
            "timeout": 30
          }
        ]
      }
    ]
  }
}
JSONEOF
    fi
}

main() {
    local os arch
    os="$(detect_os)"
    arch="$(detect_arch)"

    if [ -z "$VERSION" ]; then
        info "finding latest version"
        VERSION="$(get_latest_version)" || die "failed to find latest release"
    fi
    info "installing agent-guard ${VERSION} (${os}/${arch})"

    download_binary "$VERSION" "$os" "$arch" "$BINDIR"
    ok "agent-guard installed to ${BINDIR}/${BINARY}"

    if [ "$SKIP_TRUFFLEHOG" -eq 0 ]; then
        if ! command -v trufflehog >/dev/null 2>&1; then
            printf "\n"
            warn "trufflehog not found"
            if prompt_yes "Install trufflehog to ${BINDIR}?" "Y"; then
                install_trufflehog "$BINDIR"
            else
                info "you can install trufflehog later: https://github.com/trufflesecurity/trufflehog#installation"
            fi
        else
            ok "trufflehog found at $(command -v trufflehog)"
        fi
    fi

    if [ "$SKIP_CONFIG" -eq 0 ]; then
        if [ -z "$SCOPE" ]; then
            local choice
            choice="$(prompt_choice \
                "Where should agent-guard hooks be installed?" \
                "Global (~/.claude/settings.json) — applies to all your projects" \
                "Project (.claude/settings.json) — current project only" \
                "Local (.claude/settings.local.json) — current project, gitignored")"
            case "$choice" in
                1) SCOPE="global" ;;
                2) SCOPE="project" ;;
                3) SCOPE="local" ;;
                *) SCOPE="global" ;;
            esac
        fi
        configure_claude_code "$BINDIR" "$SCOPE"
    fi

    printf "\n"
    ok "done! agent-guard ${VERSION} is ready."
    if ! echo "$PATH" | grep -q "$BINDIR"; then
        warn "add ${BINDIR} to your PATH if it's not already there"
    fi
}

main
