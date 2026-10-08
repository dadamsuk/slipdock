# Installs slipdock-runner.ps1: takes jobs from a Slipdock board's runner
# queue and runs a coding agent on them, on this Windows machine. Needs only
# Windows PowerShell 5.1, which Windows has. Run it in PowerShell:
#
#   & ([scriptblock]::Create((irm 'https://your-server/runner/install.ps1'))) `
#     -Url 'https://your-server' -Token 'sdr_...' [options]
#
# The same file for everybody; its SHA-256 is published beside it at
# /runner/SHA256SUMS. It writes, for this user only and with no admin rights:
#
#   %LOCALAPPDATA%\slipdock-runner\slipdock-runner.ps1   the runner
#   %LOCALAPPDATA%\slipdock-runner\config.ps1            its settings and job kinds,
#                                                        readable by you alone
#   a Task Scheduler entry, "Slipdock runner", that starts it when you log on
param(
  [string]$Url = '',
  # Left out, the token in the config already there is kept.
  [string]$Token = '',
  [string]$Pool = 'default',
  [ValidateSet('claude', 'codex', 'custom')][string]$Agent = 'claude',
  [string]$Kind = '',
  # For -Agent custom: PowerShell, run with Invoke-Expression; the prompt is
  # in $env:SLIPDOCK_PROMPT.
  [string]$Command = '',
  # Where jobs run (default: your home); ~\... or ~/... is your home.
  [string]$Cwd = '',
  [string]$PermissionMode = 'acceptEdits',
  # For claude: the Slipdock MCP servers whose tools a job may use without
  # asking, as Claude Code names them, separated by commas; '' for none.
  [string]$McpServers = 'claude_ai_Slipdock,slipdock',
  [int]$Timeout = 3600,
  # Standing instructions, added after every job's prompt.
  [string]$Instructions = '',
  # PowerShell run before each job (the job runs only if it succeeds), and
  # after each however it ended ($env:SLIPDOCK_STATUS, $env:SLIPDOCK_EXIT).
  [string]$BeforeJob = '',
  [string]$AfterJob = '',
  [string]$InstallDir = '',
  # Write everything, start nothing and register nothing.
  [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

function Fail([string]$message) {
  [Console]::Error.WriteLine("slipdock-runner install: $message")
  exit 1
}

if (-not $Url) { Fail '-Url is required: the Slipdock server''s address' }
if ($Url -notmatch '^https?://') { Fail '-Url must start with http:// or https://' }
if ($Pool -notmatch '^[a-z0-9][a-z0-9_-]{0,39}$') { Fail '-Pool must be lower case letters, digits, - or _' }
if (-not $Kind) { $Kind = $Agent }
if ($Kind -notmatch '^[a-z0-9][a-z0-9_-]{0,39}$') { Fail '-Kind must be lower case letters, digits, - or _' }
if ($Agent -eq 'custom' -and -not $Command) { Fail '-Agent custom needs -Command' }
if ($Timeout -lt 60) { Fail '-Timeout must be at least 60 seconds' }
if ($McpServers -notmatch '^[A-Za-z0-9_,-]*$') { Fail '-McpServers must be names of letters, digits, - or _, separated by commas' }

if (-not $InstallDir) {
  $base = $env:LOCALAPPDATA
  if (-not $base) { $base = Join-Path $HOME '.local/share' }
  $InstallDir = Join-Path $base 'slipdock-runner'
}
if (-not $Cwd) { $Cwd = $HOME }
if ($Cwd -match '^~[^\\/]') { Fail '-Cwd can''t be another user''s ~: use a full path, or ~\ for the runner''s own home' }

$Runner = Join-Path $InstallDir 'slipdock-runner.ps1'
$Config = Join-Path $InstallDir 'config.ps1'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows

# Installing again with new settings keeps the token it has.
if (-not $Token -and (Test-Path -LiteralPath $Config)) {
  $Token = & { . $Config; $RunnerToken }
}
if (-not $Token) { Fail '-Token is required: make a runner on the board to get one' }

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# The runner itself.
$RunnerScript = @'
__SLIPDOCK_RUNNER_PS1__
'@
[IO.File]::WriteAllText($Runner, $RunnerScript + "`n", $Utf8)

# The working directory as the config spells it: ~ and ~\... are $HOME.
function WorkDir([string]$path) {
  if ($path -match '^~[\\/]?$') { return '$HOME' }
  if ($path -match '^~[\\/](.*)$') { return 'Join-Path $HOME ' + (Quote $Matches[1]) }
  return Quote $path
}

# A literal string: inside single quotes PowerShell reads nothing, and a
# quote inside is doubled.
function Quote([string]$value) { return "'" + $value.Replace("'", "''") + "'" }

# Free text as a literal here-string, where nothing at all is read - unless
# a line of it would end the here-string, when it is a literal string.
function Literal([string]$text) {
  if ($text -match "(?m)^'@") { return Quote $text }
  return "@'`n" + $text + "`n'@"
}

function Agent-Path([string]$name) {
  $found = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { return $found.Source }
  [Console]::Error.WriteLine("slipdock-runner install: warning: $name is not on your PATH; jobs will fail until it is")
  return $name
}

$fn = 'Job-' + (($Kind -split '[-_]' | Where-Object { $_ } | ForEach-Object {
  $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '')

# Every tool of each Slipdock MCP server: in -p nobody is there to approve one.
$allowedTools = ''
if ($Agent -eq 'claude') {
  $allowedTools = (($McpServers -split ',' | Where-Object { $_ } | ForEach-Object { 'mcp__' + $_ }) -join ',')
}

$agentBin = ''
switch ($Agent) {
  'claude' {
    $agentBin = Agent-Path 'claude'
    $allow = ''
    if ($allowedTools) { $allow = ' --allowedTools $AllowedTools' }
    $job = "function $fn {`n  Set-Location -LiteralPath `$WorkDir`n  & `$AgentBin -p (Protect-Arg `$env:SLIPDOCK_PROMPT) --permission-mode `$PermissionMode$allow`n  exit `$LASTEXITCODE`n}"
  }
  'codex' {
    $agentBin = Agent-Path 'codex'
    $job = "function $fn {`n  Set-Location -LiteralPath `$WorkDir`n  & `$AgentBin exec (Protect-Arg `$env:SLIPDOCK_PROMPT)`n  exit `$LASTEXITCODE`n}"
  }
  'custom' {
    $job = "function $fn {`n  Set-Location -LiteralPath `$WorkDir`n  Invoke-Expression `$CustomCommand`n}"
  }
}

$extra = ''
if ($Instructions) { $extra += "`n# Added after every job's prompt.`n`$JobInstructions = " + (Literal $Instructions) + "`n" }
if ($BeforeJob) { $extra += "`n# Runs before each job; the job runs only if this succeeds.`nfunction Before-Job {`n$BeforeJob`n}`n" }
if ($AfterJob) { $extra += "`n# Runs after each job however it ended, with `$env:SLIPDOCK_EXIT and`n# `$env:SLIPDOCK_STATUS (done, failed, cancelled or timeout).`nfunction After-Job {`n$AfterJob`n}`n" }

$configText = @"
# slipdock-runner config - written by install.ps1, yours to edit. It is
# dot-sourced, so it is PowerShell. It holds the runner's token: keep it yours.
#
# A job of kind K runs the function Job-K below (kind two-words is
# Job-TwoWords). The server never says what to run: a kind with no function
# here is refused. Each job gets SLIPDOCK_PROMPT, SLIPDOCK_JOB_ID,
# SLIPDOCK_JOB_KIND, SLIPDOCK_CARD and SLIPDOCK_CARD_URL in its environment.

`$SlipdockUrl = $(Quote $Url)
`$RunnerToken = $(Quote $Token)
`$Pool = $(Quote $Pool)
`$WorkDir = $(WorkDir $Cwd)
`$JobTimeout = $Timeout
`$PermissionMode = $(Quote $PermissionMode)
`$AllowedTools = $(Quote $allowedTools)
`$AgentBin = $(Quote $agentBin)
`$CustomCommand = $(Quote $Command)

# Windows PowerShell before 7.3 passes an argument with a " in it to a
# program wrongly; this escapes it the way the program will read it back.
function Protect-Arg([string]`$s) {
  if (`$PSVersionTable.PSVersion -ge [version]'7.3' -and `$PSNativeCommandArgumentPassing -ne 'Legacy') { return `$s }
  return ((`$s -replace '(\\*)"', '`$1`$1\"') -replace '(\\+)`$', '`$1`$1')
}

$job

# A kind to try the pipeline with: queue a job of kind echo and its output is
# the prompt it was sent.
function Job-Echo {
  Write-Output `$env:SLIPDOCK_PROMPT
}
$extra
"@

# A config already there is kept beside the new one, never lost.
if (Test-Path -LiteralPath $Config) {
  Copy-Item -LiteralPath $Config -Destination ($Config + '.bak.' + (Get-Date -Format 'yyyyMMddHHmmss'))
}
[IO.File]::WriteAllText($Config, $configText, $Utf8)

# Readable by this user alone: it holds the token.
if ($OnWindows) {
  & icacls.exe $Config /inheritance:r /grant:r "$($env:USERNAME):(F)" | Out-Null
} else {
  & chmod 600 $Config
}

Write-Output "slipdock-runner: installed $Runner"
Write-Output "slipdock-runner: config in $Config (pool $Pool, kind $Kind)"

if ($NoStart) {
  Write-Output "slipdock-runner: start it with: powershell -NoProfile -ExecutionPolicy Bypass -File `"$Runner`""
} elseif (-not $OnWindows) {
  Write-Output "slipdock-runner: not Windows, so no Task Scheduler entry. Run it with: pwsh -File `"$Runner`""
} else {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Runner`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
  Register-ScheduledTask -TaskName 'Slipdock runner' -Action $action -Trigger $trigger -Settings $settings `
    -Description "Takes $Pool jobs from $Url" -Force | Out-Null
  Start-ScheduledTask -TaskName 'Slipdock runner'
  Write-Output "slipdock-runner: started, and starts again when you log on. Logs: $(Join-Path $InstallDir 'runner.log')"
}
