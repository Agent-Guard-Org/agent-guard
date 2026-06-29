#Requires -Version 5.1
<#
.SYNOPSIS
    Install agent-guard and configure Claude Code hooks on Windows.

.PARAMETER BinDir
    Directory to install the binary (default: $HOME\.local\bin)

.PARAMETER Version
    Specific version to install (default: latest)

.PARAMETER Yes
    Auto-accept all prompts

.PARAMETER SkipTrufflehog
    Don't prompt to install TruffleHog

.PARAMETER SkipConfig
    Don't prompt for Claude Code configuration

.PARAMETER Scope
    Hook scope: global, project, or local

.EXAMPLE
    irm https://raw.githubusercontent.com/Agent-Guard-Org/agent-guard/main/scripts/install.ps1 | iex

.EXAMPLE
    .\install.ps1 -Yes -Scope global
#>
[CmdletBinding()]
param(
    [string]$BinDir = "",
    [string]$Version = "",
    [switch]$Yes,
    [switch]$SkipTrufflehog,
    [switch]$SkipConfig,
    [ValidateSet("global", "project", "local", "")]
    [string]$Scope = ""
)

$ErrorActionPreference = "Stop"

$Repo   = "Agent-Guard-Org/agent-guard"
$Binary = "agent-guard"

if (-not $BinDir) {
    $BinDir = Join-Path $HOME ".local\bin"
}

function Info  { param($msg) Write-Host "info " -ForegroundColor Cyan   -NoNewline; Write-Host $msg }
function Ok    { param($msg) Write-Host " ok  " -ForegroundColor Green  -NoNewline; Write-Host $msg }
function Warn  { param($msg) Write-Host "warn " -ForegroundColor Yellow -NoNewline; Write-Host $msg -ForegroundColor Yellow }
function Die   { param($msg) Write-Host " err " -ForegroundColor Red    -NoNewline; Write-Host $msg -ForegroundColor Red; exit 1 }

function Prompt-Yes {
    param([string]$Msg, [string]$Default = "N")
    if ($Yes) { return $true }
    $suffix = if ($Default -eq "Y") { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$Msg $suffix"
    if (-not $answer) { $answer = $Default }
    return $answer -match '^[yY]'
}

function Prompt-Choice {
    param([string]$Msg, [string[]]$Options)
    if ($Yes) { return 1 }
    Write-Host $Msg
    for ($i = 0; $i -lt $Options.Length; $i++) {
        Write-Host "  $($i+1)) $($Options[$i])"
    }
    $choice = Read-Host "  Enter choice [1]"
    if (-not $choice) { return 1 }
    return [int]$choice
}

function Get-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { return "amd64" }
        "ARM64" { return "arm64" }
        default { Die "unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
    }
}

function Get-LatestVersion {
    $url = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        $resp = Invoke-RestMethod -Uri $url -UseBasicParsing
        return $resp.tag_name
    } catch {
        Die "failed to find latest release: $_"
    }
}

function Install-Binary {
    param([string]$Ver, [string]$Arch, [string]$DestDir)

    $archiveName = "${Binary}_${Ver}_windows_${Arch}.zip"
    $downloadUrl = "https://github.com/$Repo/releases/download/$Ver/$archiveName"

    $tmpDir = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpDir | Out-Null

    try {
        Info "downloading $archiveName"
        $archivePath = Join-Path $tmpDir $archiveName
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing

        Info "extracting"
        Expand-Archive -Path $archivePath -DestinationPath $tmpDir -Force

        if (-not (Test-Path $DestDir)) {
            New-Item -ItemType Directory -Path $DestDir | Out-Null
        }

        $exeName = "${Binary}.exe"
        Copy-Item (Join-Path $tmpDir $exeName) (Join-Path $DestDir $exeName) -Force

        $hooksDir = Join-Path $DestDir "${Binary}.hooks"
        $hooksSource = Join-Path $tmpDir "hooks\hooks.json"
        if (Test-Path $hooksSource) {
            New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
            Copy-Item $hooksSource (Join-Path $hooksDir "hooks.json") -Force
        }
    } finally {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-Trufflehog {
    param([string]$DestDir)
    Info "installing trufflehog to $DestDir"
    try {
        $script = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh" -UseBasicParsing
        # trufflehog doesn't ship a native PS installer; direct user to releases
        Warn "trufflehog has no official Windows installer script."
        Info "download it from: https://github.com/trufflesecurity/trufflehog/releases"
        Info "place trufflehog.exe in $DestDir and make sure it's on your PATH"
    } catch {
        Warn "could not fetch trufflehog info: $_"
    }
}

function Get-SettingsPath {
    param([string]$ScopeVal)
    switch ($ScopeVal) {
        "global"  { return Join-Path $HOME ".claude\settings.json" }
        "project" { return ".claude\settings.json" }
        "local"   { return ".claude\settings.local.json" }
    }
}

function Configure-ClaudeCode {
    param([string]$BinDirVal, [string]$ScopeVal)

    $settingsFile = Get-SettingsPath $ScopeVal
    $hookCommand  = Join-Path $BinDirVal "${Binary}.exe"

    Write-Host ""
    Info "the following hooks will be added to $settingsFile :"
    Write-Host ""
    Write-Host "  UserPromptSubmit -> run agent-guard (block if secrets found)"
    Write-Host "  PostToolUse      -> run agent-guard (block if secrets found)"
    Write-Host ""

    if (-not (Prompt-Yes "Apply these changes?" "N")) {
        Warn "skipping Claude Code configuration"
        return
    }

    $hookEntry = @{
        hooks = @(
            @{
                type    = "command"
                command = $hookCommand
                args    = @()
                timeout = 30
            }
        )
    }

    $dir = Split-Path $settingsFile
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    $settings = if (Test-Path $settingsFile) {
        Get-Content $settingsFile -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{ hooks = [PSCustomObject]@{} }
    }

    if (-not $settings.PSObject.Properties["hooks"]) {
        $settings | Add-Member -MemberType NoteProperty -Name "hooks" -Value ([PSCustomObject]@{})
    }

    foreach ($event in @("UserPromptSubmit", "PostToolUse")) {
        if (-not $settings.hooks.PSObject.Properties[$event]) {
            $settings.hooks | Add-Member -MemberType NoteProperty -Name $event -Value @()
        }
        $settings.hooks.$event += $hookEntry
    }

    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
    Ok "hooks written to $settingsFile"
}

# ── main ─────────────────────────────────────────────────────────────────────

$arch = Get-Arch

if (-not $Version) {
    Info "finding latest version"
    $Version = Get-LatestVersion
}
Info "installing $Binary $Version (windows/$arch)"

Install-Binary -Ver $Version -Arch $arch -DestDir $BinDir
Ok "$Binary installed to $BinDir\${Binary}.exe"

if (-not $SkipTrufflehog) {
    if (-not (Get-Command trufflehog -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Warn "trufflehog not found"
        if (Prompt-Yes "Show trufflehog install instructions?" "Y") {
            Install-Trufflehog $BinDir
        }
    } else {
        Ok "trufflehog found at $(Get-Command trufflehog | Select-Object -ExpandProperty Source)"
    }
}

if (-not $SkipConfig) {
    if (-not $Scope) {
        $choice = Prompt-Choice `
            "Where should agent-guard hooks be installed?" `
            @(
                "Global (~\.claude\settings.json) — applies to all your projects",
                "Project (.claude\settings.json) — current project only",
                "Local (.claude\settings.local.json) — current project, gitignored"
            )
        $Scope = @("global", "project", "local")[$choice - 1]
    }
    Configure-ClaudeCode -BinDirVal $BinDir -ScopeVal $Scope
}

Write-Host ""
Ok "done! $Binary $Version is ready."

$pathDirs = $env:PATH -split ";"
if ($pathDirs -notcontains $BinDir) {
    Warn "add $BinDir to your PATH if it's not already there"
    Info "run: [Environment]::SetEnvironmentVariable('PATH', `$env:PATH + ';$BinDir', 'User')"
}
