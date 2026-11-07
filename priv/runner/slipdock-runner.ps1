# slipdock-runner.ps1 - takes jobs from a Slipdock board's runner queue and
# runs them on this machine. Windows PowerShell 5.1 (built into Windows) or
# PowerShell 7; nothing else.
#
#   slipdock-runner.ps1                  run until stopped
#   slipdock-runner.ps1 -Once            take at most one job, then exit
#   slipdock-runner.ps1 -Config FILE     another config than the default
#
# What runs is decided here, never by the server: a job arrives as an id, a
# kind, a card and a prompt, and the config's Job-<Kind> function says what
# that kind means (kind "two-words" is Job-TwoWords). A kind the config has
# no function for is refused, and nothing runs. The prompt only ever reaches
# a job as $env:SLIPDOCK_PROMPT.
#
# The config (default %LOCALAPPDATA%\slipdock-runner\config.ps1) is
# dot-sourced: it sets $SlipdockUrl and $RunnerToken, optionally $Pool,
# $Wait, $Heartbeat, $JobTimeout and $JobInstructions (added after every
# prompt), and defines the Job-<Kind> functions - and, if it likes,
# Before-Job (the job runs only if it succeeds) and After-Job (always, with
# $env:SLIPDOCK_EXIT and $env:SLIPDOCK_STATUS: done, failed, cancelled or
# timeout).
#
# Profiles (#1953): on a board with profiles on, each job says its card's
# profile (docs, fix, feature, schema, security or spike) as
# $env:SLIPDOCK_PROFILE. When the config sets $MODEL_<profile> ($MODEL_docs,
# $MODEL_schema, ...; all unset by default), $env:SLIPDOCK_MODEL holds it for
# that job, for the job's own command to pass on (the installer's claude and
# codex jobs do, when it is set). The server sends the word only; what it
# means is this config's.
#
# Lanes, off unless the config sets $Worktree = $true: each job runs in a git
# worktree of its own, on a branch named for its card (card-<id>), so jobs
# side by side never share a working tree. $WorktreeRepo is the repository
# (default: the directory the runner started in), $WorktreeDir where the
# worktrees go (default: <repo>-lanes beside it). A clean worktree is removed
# after the job; one with uncommitted changes is kept, and the job's log says so.
#
# Built in: the merge kind (#1656), for boards that ship by pull request.
# Accepting a card there queues a merge job, and this runner merges the
# card's pull request, needing git and a signed-in gh (GitHub CLI), run in
# the runner's repository: $WorktreeRepo, else $WorkDir, else the directory
# the runner started in (#1666). It merges only a pull request in that
# repository's origin, still open, whose head is the commit that was
# accepted, and reports the merge commit. $Merge = $false in the config turns
# it off; a config's own Job-Merge replaces it. Every claim tells the server
# which kinds this runner takes, so merge jobs only come to runners that can.
#
# Keeping current (#1658), off unless the config sets $SelfUpdate = $true
# (new installs do): every claim says which script this is (its own
# SHA-256, line endings as served), and the server answers with the one it
# hands out, on an empty claim, on one that hands out a job, and on each
# job's finish. When they differ, the runner updates between jobs (#1925):
# after an empty claim, or after a job's finish is reported and before the
# next claim, never during a job, so a busy queue can't keep an old script
# running. It fetches the script and SHA256SUMS from the server (or
# $SelfUpdateUrl), and replaces itself only if the download's SHA-256
# matches both; then it starts again, and the old script claims nothing
# more. A failed fetch or a mismatch keeps this script, says so in the log,
# and isn't tried again for that version. The config is never touched.
#
# Live log (#1870): while a job runs, the runner sends its agent's Claude
# Code transcript to the server about every $TranscriptEvery seconds
# (default 60; 0 turns it off), and once more as the job ends, so the job
# can be watched from the board. The transcript is the newest .jsonl under
# $Transcripts (default ~\.claude\projects, one level of project folders)
# written since the job started that mentions the card's link. Each send is
# the lines the server hasn't got, at most $TranscriptSend bytes (default
# 524288), any line over $TranscriptLine bytes (default 32768) replaced by
# a line saying how long it was, and this machine's Slipdock tokens taken
# out: the runner's, $env:SLIPDOCK_TOKEN and the slipdock CLI's saved ones.
# A send that fails never stops the job; the next one catches up.
#
# Drift (#1795): every claim also says the SHA-256 of each slipdock skill
# installed under $SkillsDir (default ~\.claude\skills) and of the slipdock
# CLI ($SlipdockCli, else the escript beside the slipdock on the PATH), and
# the runners list shows any that differ from the server's. Nothing is
# changed on this machine.
param(
  [string]$Config = '',
  [switch]$Once,
  # Internal: run one job function in this process, as the job's own child.
  [string]$RunJob = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

if (-not $Config) {
  $base = $env:LOCALAPPDATA
  if (-not $base) { $base = Join-Path $HOME '.local/share' }
  $Config = Join-Path (Join-Path $base 'slipdock-runner') 'config.ps1'
}

if (-not (Test-Path -LiteralPath $Config)) {
  [Console]::Error.WriteLine("slipdock-runner: no config at $Config")
  exit 2
}

# The built-in merge (see above), defined before the config so that a
# config's own Job-Merge replaces it. The server sends only data: the pull
# request's URL and the accepted commit, both checked here before use.
function Job-Merge {
  $pr = "$env:SLIPDOCK_MERGE_PR"
  $want = "$env:SLIPDOCK_MERGE_COMMIT"
  if (-not $pr) { Write-Output 'merge: the card names no pull request (its evidence has no PR URL)'; exit 2 }
  if (-not $want) { Write-Output 'merge: the card names no accepted commit'; exit 2 }
  if ($pr -notmatch '^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([0-9]+)/*$') {
    Write-Output "merge: $pr is not a GitHub pull request URL"; exit 2
  }
  $prRepo = $Matches[1]
  $num = $Matches[2]
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Output 'merge: git is not installed'; exit 2 }
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Write-Output 'merge: gh (GitHub CLI) is not installed'; exit 2 }
  $ErrorActionPreference = 'Continue'
  $origin = ((& git remote get-url origin 2>$null) | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $origin) { Write-Output "merge: $((Get-Location).Path) has no origin remote"; exit 2 }
  $repo = $origin -replace '\.git$', '' -replace '/+$', '' -replace '^git@github\.com:', '' `
    -replace '^ssh://git@github\.com/', '' -replace '^https://([^@/]*@)?github\.com/', ''
  if ($repo.ToLower() -ne $prRepo.ToLower()) {
    Write-Output "merge: the pull request is in $prRepo, but this runner's repository is $origin; nothing merged"; exit 2
  }
  & gh auth status *> $null
  if ($LASTEXITCODE -ne 0) { Write-Output 'merge: gh is not signed in (run gh auth login)'; exit 2 }
  $info = ((& gh pr view $num --repo $prRepo --json state,headRefOid --jq '.state + " " + .headRefOid' 2>&1) | Out-String).Trim()
  if ($LASTEXITCODE -ne 0) { Write-Output "merge: could not read ${pr}: $info"; exit 2 }
  $state, $head = $info -split ' ', 2
  if ($state -ne 'OPEN') { Write-Output "merge: $pr is $state, not open; nothing merged"; exit 2 }
  if ($want -notmatch '^[0-9a-fA-F]+$') { Write-Output "merge: the accepted commit $want is not a commit id"; exit 2 }
  if (-not $head.ToLower().StartsWith($want.ToLower())) {
    Write-Output "merge: $pr's head is $head, not the accepted commit $want (it moved after the card was accepted); nothing merged"; exit 2
  }
  # gh's own words are the reason (#1666): a conflict reads differently from
  # a failing check or branch protection, and only a conflict wants a rebase.
  $said = ((& gh pr merge $num --repo $prRepo --merge --match-head-commit $head --subject "Merge PR ${num}: card #$env:SLIPDOCK_CARD" 2>&1) | Out-String)
  if ($LASTEXITCODE -ne 0) {
    $said = ($said -replace '\s+', ' ').Trim()
    if (-not $said) { $said = 'gh gave no reason' }
    Write-Output "merge: gh pr merge refused ${pr}: $said"; exit 3
  }
  if ($said.Trim()) { Write-Output $said.Trim() }
  $sha = ((& gh pr view $num --repo $prRepo --json mergeCommit --jq '.mergeCommit.oid' 2>$null) | Out-String).Trim()
  $shown = $sha
  if (-not $shown) { $shown = 'an unknown commit' }
  Write-Output "merge: merged $pr (head $head) as $shown"
  if ($env:SLIPDOCK_MERGED_FILE) { [IO.File]::WriteAllText($env:SLIPDOCK_MERGED_FILE, $sha) }
  exit 0
}

. $Config

# The job itself, in its own process: the config's function, its exit code.
if ($RunJob) {
  $global:LASTEXITCODE = 0
  try {
    & $RunJob
  } catch {
    [Console]::Error.WriteLine("$_")
    exit 1
  }
  exit $global:LASTEXITCODE
}

if (-not $SlipdockUrl) { [Console]::Error.WriteLine('slipdock-runner: the config must set $SlipdockUrl'); exit 2 }
if (-not $RunnerToken) { [Console]::Error.WriteLine('slipdock-runner: the config must set $RunnerToken'); exit 2 }
$SlipdockUrl = $SlipdockUrl.TrimEnd('/')
# $null, not falsy: a config may well say $Wait = 0.
if ($null -eq $Wait) { $Wait = 25 }
if ($null -eq $Heartbeat) { $Heartbeat = 20 }
if ($null -eq $JobTimeout) { $JobTimeout = 3600 }
if ($null -eq $LogTail) { $LogTail = 8000 }
if ($null -eq $TranscriptEvery) { $TranscriptEvery = 60 }
if (-not $Transcripts) {
  $claudeHome = $env:CLAUDE_CONFIG_DIR
  if (-not $claudeHome) { $claudeHome = Join-Path $HOME '.claude' }
  $Transcripts = Join-Path $claudeHome 'projects'
}
if (-not $TranscriptSend) { $TranscriptSend = 524288 }
if (-not $TranscriptLine) { $TranscriptLine = 32768 }
if (($null -ne $Merge) -and (-not $Merge -or ("$Merge" -in @('0', 'no', 'false', 'off')))) {
  Remove-Item Function:Job-Merge -ErrorAction SilentlyContinue
}

$Here = Split-Path -Parent $Config
# Runner NAME's config is config-NAME.ps1, and its log runner-NAME.log.
$RunnerLog = Join-Path $Here 'runner.log'
if ((Split-Path -Leaf $Config) -match '^config-(.+)\.ps1$') { $RunnerLog = Join-Path $Here "runner-$($Matches[1]).log" }
$Work = Join-Path ([IO.Path]::GetTempPath()) ("slipdock-runner-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows

function Say([string]$message) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " slipdock-runner: " + $message
  [Console]::Error.WriteLine($line)
  try { [IO.File]::AppendAllText($RunnerLog, $line + "`n", $Utf8) } catch { }
}

# A web call's time limit. PowerShell 7.4's -TimeoutSec stops only the wait
# for the answer's headers: a server that sends them and then stalls in the
# body holds the call until it hangs up (#1854), so where there is an
# -OperationTimeoutSeconds that is set as well. Windows PowerShell has none,
# and its -TimeoutSec covers the call.
$ReadTimeout = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')
function Get-WebTimeout([int]$timeout) {
  $limit = @{ TimeoutSec = $timeout }
  if ($ReadTimeout) { $limit['OperationTimeoutSeconds'] = $timeout }
  return $limit
}

# POST to the queue. Answers @{ Status; Body; Headers }: Status 0 when
# nothing answered. Windows PowerShell throws on any 4xx/5xx, so the answer
# is taken from the exception as well.
function Send-Slipdock([string]$path, [string]$body, [int]$timeout, [hashtable]$extra = @{}) {
  $bytes = $Utf8.GetBytes($body)
  $headers = @{ Authorization = "Bearer $RunnerToken" }
  foreach ($k in $extra.Keys) { $headers[$k] = $extra[$k] }
  $limit = Get-WebTimeout $timeout
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($SlipdockUrl + $path) `
      -Headers $headers `
      -ContentType 'text/plain; charset=utf-8' -Body $bytes @limit
    $content = $r.Content
    if ($content -is [byte[]]) { $content = $Utf8.GetString($content) }
    return @{ Status = [int]$r.StatusCode; Body = [string]$content; Headers = $r.Headers }
  } catch {
    $response = $_.Exception.Response
    if ($response) {
      $text = ''
      if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $text = $_.ErrorDetails.Message }
      return @{ Status = [int]$response.StatusCode; Body = $text; Headers = @{} }
    }
    return @{ Status = 0; Body = "$_"; Headers = @{} }
  }
}

function Get-Header($answer, [string]$name) {
  $value = $answer.Headers[$name]
  if ($null -eq $value) { return '' }
  return [string]($value | Select-Object -First 1)
}

function Test-Function([string]$name) {
  return [bool](Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)
}

# "two-words" -> "Job-TwoWords"
function Get-JobFunction([string]$kind) {
  $parts = $kind -split '[-_]' | Where-Object { $_ } | ForEach-Object {
    $_.Substring(0, 1).ToUpper() + $_.Substring(1)
  }
  return 'Job-' + ($parts -join '')
}

# Every process below $id, read before any is stopped: a child whose parent
# goes is lost otherwise.
function Get-Descendants([int]$id) {
  $pairs = @()
  if ($OnWindows) {
    $pairs = Get-CimInstance Win32_Process | ForEach-Object { ,@([int]$_.ProcessId, [int]$_.ParentProcessId) }
  } else {
    $pairs = (& ps -A -o pid= -o ppid=) | ForEach-Object {
      $f = $_.Trim() -split '\s+'
      ,@([int]$f[0], [int]$f[1])
    }
  }
  $found = @{ $id = $true }
  $more = $true
  while ($more) {
    $more = $false
    foreach ($p in $pairs) {
      if (-not $found.ContainsKey($p[0]) -and $found.ContainsKey($p[1])) { $found[$p[0]] = $true; $more = $true }
    }
  }
  return @($found.Keys | Where-Object { $_ -ne $id })
}

function Stop-JobTree([System.Diagnostics.Process]$proc) {
  if ($OnWindows) {
    & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
  } else {
    $tree = @(Get-Descendants $proc.Id) + $proc.Id
    foreach ($id in $tree) { try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { } }
  }
  try { $proc.WaitForExit(10000) | Out-Null } catch { }
}

# The job's out and err are read while it still writes them, and Windows
# PowerShell's Start-Process holds them open without read sharing, so
# ReadAllText fails there (#1481): each is opened sharing read and write, and
# one that still can't be read is left out of this heartbeat's log.
function Read-Log {
  $text = ''
  foreach ($f in @('log', 'out', 'err')) {
    $p = Join-Path $Work $f
    if (Test-Path -LiteralPath $p) {
      try {
        $fs = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $text += (New-Object IO.StreamReader($fs, $Utf8)).ReadToEnd() } finally { $fs.Dispose() }
      } catch { }
    }
  }
  if ($text.Length -gt $LogTail) { $text = $text.Substring($text.Length - $LogTail) }
  return $text
}

# The live log (#1870). Tx is the job's transcript once found, TxLines the
# lines the server holds, TxDone set once it says the log is full.
$script:Tx = ''
$script:TxLines = 0
$script:TxDone = $false
$script:TxFailed = $false
$script:TxSecrets = @()
$script:TxStarted = [datetime]::MinValue

# This machine's Slipdock tokens, read again for each job: the runner's,
# $env:SLIPDOCK_TOKEN and the CLI's (~\.config\slipdock, and under
# XDG_CONFIG_HOME if that is set).
function Get-Secrets {
  $list = @($RunnerToken, $env:SLIPDOCK_TOKEN)
  $dirs = @(Join-Path (Join-Path $HOME '.config') 'slipdock')
  if ($env:XDG_CONFIG_HOME) { $dirs += Join-Path $env:XDG_CONFIG_HOME 'slipdock' }
  foreach ($d in $dirs) {
    $files = @(Join-Path $d 'token')
    $more = Join-Path $d 'tokens'
    if (Test-Path -LiteralPath $more -PathType Container) {
      $files += @(Get-ChildItem -LiteralPath $more -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    foreach ($f in $files) {
      if (Test-Path -LiteralPath $f -PathType Leaf) {
        try { $list += ([IO.File]::ReadAllText($f)).Trim() } catch { }
      }
    }
  }
  return @($list | Where-Object { $_ -and ($_ -cmatch '^[A-Za-z0-9_.~+/=-]{8,}$') } | Sort-Object -Unique)
}

# A file another process is still writing, read without locking it out.
function Read-Shared([string]$path) {
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try { return (New-Object IO.StreamReader($fs, $Utf8)).ReadToEnd() } finally { $fs.Dispose() }
}

# Sets Tx to the job's transcript: the newest .jsonl in a folder under
# $Transcripts, written since the job started, that names the card's link.
# Kept once found.
function Find-Transcript {
  if ($script:Tx) { return $true }
  if (-not $env:SLIPDOCK_CARD_URL -or -not (Test-Path -LiteralPath $Transcripts -PathType Container)) { return $false }
  $files = @(Get-ChildItem -LiteralPath $Transcripts -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
  foreach ($d in @(Get-ChildItem -LiteralPath $Transcripts -Directory -ErrorAction SilentlyContinue)) {
    $files += @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
  }
  $recent = @($files | Where-Object { $_.LastWriteTimeUtc -gt $script:TxStarted } | Sort-Object LastWriteTimeUtc -Descending)
  foreach ($f in $recent) {
    $named = $false
    try { $named = (Read-Shared $f.FullName).Contains($env:SLIPDOCK_CARD_URL) } catch { }
    if ($named) {
      $script:Tx = $f.FullName
      Add-Log "slipdock-runner: sending the transcript $($script:Tx) as the job's live log"
      return $true
    }
  }
  return $false
}

# Sends the transcript's lines the server hasn't got: whole lines from
# TxLines, and the server's answer says where the next starts. A failed
# send is left for the next; at the end ($final) it sends until caught up,
# trying a failed send three more times.
function Send-Transcript([bool]$final = $false) {
  if ($TranscriptEvery -le 0 -or $script:TxDone) { return }
  if (-not (Find-Transcript)) { return }
  $rounds = 2
  if ($final) { $rounds = 50 }
  $retry = 0
  while ($rounds -gt 0) {
    $rounds--
    $text = ''
    try { $text = Read-Shared $script:Tx } catch { return }
    # Whole lines only: one still being written waits for the next send.
    $end = $text.LastIndexOf("`n")
    if ($end -lt 0) { return }
    $lines = $text.Substring(0, $end).Split("`n")
    if ($lines.Count -le $script:TxLines) { return }
    $sb = New-Object Text.StringBuilder
    $size = 0
    for ($i = $script:TxLines; $i -lt $lines.Count; $i++) {
      $line = $lines[$i].TrimEnd("`r")
      $n = $Utf8.GetByteCount($line)
      if ($n -gt $TranscriptLine) {
        $line = '{"type":"slipdock_cut","bytes":' + $n + ',"limit":' + $TranscriptLine + '}'
        $n = $line.Length
      }
      if ($i -gt $script:TxLines -and ($size + $n + 1) -gt $TranscriptSend) { break }
      $size += $n + 1
      foreach ($secret in $script:TxSecrets) { $line = $line.Replace($secret, '[redacted]') }
      [void]$sb.Append($line).Append("`n")
    }
    $a = Send-Slipdock "/api/runner/jobs/$JobId/transcript?from=$($script:TxLines)" $sb.ToString() 15
    $said = ([string]$a.Body).Trim() -split ' '
    $held = -1
    if ($said.Count -ge 2 -and $said[1] -match '^[0-9]+$') { $held = [int]$said[1] }
    if (($a.Status -eq 200 -and $said[0] -eq 'ok') -or ($a.Status -eq 409 -and $said[0] -eq 'from')) {
      $script:TxFailed = $false
      if ($held -ge 0) { $script:TxLines = $held }
    } elseif ($a.Status -eq 200 -and $said[0] -eq 'capped') {
      Add-Log "slipdock-runner: the server's log for this job is full; the rest of the transcript is not sent"
      $script:TxDone = $true
      return
    } else {
      if (-not $script:TxFailed) { Say "job #${JobId}: could not send the transcript (HTTP $($a.Status)); trying again later" }
      $script:TxFailed = $true
      # At the end there is no next send: a few more tries, a little apart.
      $retry++
      if (-not $final -or $retry -gt 3) { return }
      Start-Sleep -Seconds $retry
    }
  }
}

function Add-Log([string]$text) {
  [IO.File]::AppendAllText((Join-Path $Work 'log'), $text + "`n", $Utf8)
}

# git, its output as one string and its exit code in $script:GitExit. Run
# with errors not stopping anything: git writes its progress to stderr.
function Invoke-Git {
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git @args 2>&1 | ForEach-Object { "$_" }
    $script:GitExit = $LASTEXITCODE
  } catch {
    $out = "$_"
    $script:GitExit = 1
  } finally {
    $ErrorActionPreference = $eap
  }
  return (@($out) -join "`n").Trim()
}

# With $Worktree on, makes (or reuses) the card's worktree and sets
# $script:Lane to it; the job and its hooks run there. Off, or with no card
# or no repository, $Lane stays empty and the job runs in place, which the
# log says. False only when the worktree can't be made: the job then doesn't
# run, since running it in the shared tree is what the setting is for.
function Open-Lane([string]$card) {
  $script:Lane = ''
  if (-not $Worktree -or ("$Worktree" -in @('0', 'no', 'false', 'off'))) { return $true }
  $here = (Get-Location).Path
  $repo = $WorktreeRepo
  if (-not $repo) { $repo = $here }
  if (-not $card) { Add-Log "slipdock-runner: the job has no card, so no worktree; it runs in $here"; return $true }
  $top = ''
  if (Get-Command git -ErrorAction SilentlyContinue) {
    $top = Invoke-Git -C $repo rev-parse --show-toplevel
    if ($script:GitExit -ne 0) { $top = '' }
  }
  if (-not $top) {
    Add-Log "slipdock-runner: $repo is not a git repository, so no worktree; the job runs in $here"
    return $true
  }
  $branch = "card-$card"
  $base = $WorktreeDir
  if (-not $base) { $base = "$top-lanes" }
  $path = (Join-Path $base $branch) -replace '\\', '/'
  if (Test-Path -LiteralPath $path) {
    $null = Invoke-Git -C $path rev-parse --git-dir
    if ($script:GitExit -ne 0) {
      Add-Log "slipdock-runner: $path is there but is not a worktree, so the job was not run"
      return $false
    }
    $on = Invoke-Git -C $path rev-parse --abbrev-ref HEAD
    Add-Log "slipdock-runner: worktree $path (kept from before) on $on"
  } else {
    $null = Invoke-Git -C $top show-ref --verify --quiet "refs/heads/$branch"
    if ($script:GitExit -eq 0) {
      $out = Invoke-Git -C $top worktree add $path $branch
    } else {
      $out = Invoke-Git -C $top worktree add -b $branch $path HEAD
    }
    if ($out) { Add-Log $out }
    if ($script:GitExit -ne 0) {
      Add-Log "slipdock-runner: could not make worktree $path, so the job was not run"
      return $false
    }
    Add-Log "slipdock-runner: worktree $path on branch $branch"
  }
  $script:Lane = $path
  $script:LaneRepo = $top
  $script:LaneBranch = $branch
  $env:SLIPDOCK_WORKTREE = $path
  return $true
}

# After the job: a clean worktree is removed, and its branch deleted if it is
# merged (git branch -d); anything uncommitted keeps it.
function Close-Lane {
  if (-not $script:Lane) { return }
  $lane = $script:Lane
  $dirty = Invoke-Git -C $lane status --porcelain
  if ($dirty) {
    Add-Log "slipdock-runner: worktree $lane has uncommitted changes, so it is kept"
  } else {
    $out = Invoke-Git -C $script:LaneRepo worktree remove $lane
    if ($script:GitExit -ne 0) {
      if ($out) { Add-Log $out }
      Add-Log "slipdock-runner: could not remove worktree $lane, so it is kept"
    } else {
      $null = Invoke-Git -C $script:LaneRepo branch -d $script:LaneBranch
      if ($script:GitExit -eq 0) {
        Add-Log "slipdock-runner: worktree $lane removed"
      } else {
        Add-Log "slipdock-runner: worktree $lane removed; branch $($script:LaneBranch) kept (not merged)"
      }
    }
  }
  $script:Lane = ''
  Remove-Item Env:SLIPDOCK_WORKTREE -ErrorAction SilentlyContinue
}

# A hook from the config, its output in the job's log. False when it failed.
# It runs in the job's worktree when it has one.
function Invoke-Hook([string]$name) {
  if (-not (Test-Function $name)) { return $true }
  $global:LASTEXITCODE = 0
  $moved = $false
  $at = $script:Lane
  if (-not $at) { $at = $script:JobDir }
  try {
    if ($at) { Push-Location -LiteralPath $at; $moved = $true }
    $output = & $name 2>&1 | Out-String
    if ($output) { Add-Log $output.TrimEnd() }
    return ($global:LASTEXITCODE -eq 0)
  } catch {
    Add-Log "$name failed: $_"
    return $false
  } finally {
    if ($moved) { Pop-Location }
  }
}

function Invoke-AfterJob([int]$exitCode, [string]$status) {
  $env:SLIPDOCK_EXIT = "$exitCode"
  $env:SLIPDOCK_STATUS = $status
  if (-not (Invoke-Hook 'After-Job')) { Say "job #${JobId}: After-Job failed" }
}

function Complete-Job([int]$exitCode, [string]$status) {
  $query = "exit=$exitCode"
  if ($status) { $query += "&status=$status" }
  $mergedFile = Join-Path $Work 'merged'
  if (Test-Path -LiteralPath $mergedFile) {
    $merged = ([IO.File]::ReadAllText($mergedFile)).Trim()
    if ($merged -match '^[0-9a-fA-F]+$') { $query += "&merged=$merged" }
  }
  for ($try = 1; $try -le 5; $try++) {
    $a = Send-Slipdock "/api/runner/jobs/$JobId/finish?$query" (Read-Log) 30
    if ($a.Status -eq 200) {
      # The script the server hands out now, which a deploy during the job
      # may have changed since the claim (#1925).
      $script:FinishLatest = Get-Header $a 'X-Runner-Latest'
      return
    }
    if ($a.Status -eq 404) { return }
    Start-Sleep -Seconds ($try * 2)
  }
  Say "job #${JobId}: could not report it finished (HTTP $($a.Status))"
}

function Invoke-Job($claim) {
  $script:JobId = Get-Header $claim 'X-Job-Id'
  $kind = Get-Header $claim 'X-Job-Kind'
  $card = Get-Header $claim 'X-Card-Id'

  # These came from the server, so they are checked before anything uses them.
  if ($JobId -notmatch '^[0-9]+$') { Say 'the server sent a job with no usable id'; return }
  if ($card -notmatch '^[0-9]+$') { $card = '' }
  foreach ($f in @('log', 'out', 'err', 'merged')) { Remove-Item -LiteralPath (Join-Path $Work $f) -ErrorAction SilentlyContinue }
  [IO.File]::WriteAllText((Join-Path $Work 'log'), '', $Utf8)
  # The live log's starting point: a transcript written after this is the job's.
  $script:TxStarted = (Get-Date).ToUniversalTime()
  $script:Tx = ''
  $script:TxLines = 0
  $script:TxDone = ($kind -eq 'merge')
  $script:TxFailed = $false
  $script:TxSecrets = Get-Secrets

  $fn = ''
  if ($kind -match '^[a-z0-9][a-z0-9_-]*$') { $fn = Get-JobFunction $kind }
  if (-not $fn -or -not (Test-Function $fn)) {
    Say "job #${JobId}: no $fn in $Config - refused, nothing run"
    Add-Log "no such job kind: $kind (this runner has no $fn)"
    Complete-Job 127 'failed'
    return
  }

  $prompt = $claim.Body
  # Not for a verify job, whose agent checks the work rather than doing it.
  if ($JobInstructions -and $kind -ne 'verify' -and $kind -ne 'merge') { $prompt = $prompt + "`n`n" + $JobInstructions }
  # A merge job's pull request and accepted commit (data, checked by Job-Merge).
  $env:SLIPDOCK_MERGE_PR = Get-Header $claim 'X-Merge-Pr'
  $env:SLIPDOCK_MERGE_COMMIT = Get-Header $claim 'X-Merge-Commit'
  $env:SLIPDOCK_MERGED_FILE = Join-Path $Work 'merged'
  $env:SLIPDOCK_JOB_ID = $JobId
  $env:SLIPDOCK_JOB_KIND = $kind
  $env:SLIPDOCK_CARD = $card
  $env:SLIPDOCK_CARD_URL = Get-Header $claim 'X-Card-Url'
  $env:SLIPDOCK_PROMPT = $prompt
  # The card's profile (#1953), with profiles on: a word, checked against
  # the fixed list, and this config's $MODEL_<profile> for it, if it sets one.
  $cardProfile = "$(Get-Header $claim 'X-Card-Profile')"
  if (@('docs', 'fix', 'feature', 'schema', 'security', 'spike') -cnotcontains $cardProfile) { $cardProfile = '' }
  $env:SLIPDOCK_PROFILE = $cardProfile
  $env:SLIPDOCK_MODEL = ''
  if ($cardProfile) { $env:SLIPDOCK_MODEL = "$(Get-Variable -Name "MODEL_$cardProfile" -ValueOnly -ErrorAction SilentlyContinue)" }

  Say "job #${JobId}: $kind for card #$card"

  # A merge runs in the repository itself: its card's branch is the pull
  # request's, and nothing is built. That is the runner's repository wherever
  # the runner was started (a service starts it elsewhere, #1666).
  $script:Lane = ''
  $script:JobDir = ''
  if ($kind -eq 'merge') {
    if ($WorktreeRepo) { $script:JobDir = "$WorktreeRepo" } elseif ($WorkDir) { $script:JobDir = "$WorkDir" }
  }
  if ($kind -ne 'merge' -and -not (Open-Lane $card)) {
    Say "job #${JobId}: no worktree for it - job not run"
    Invoke-AfterJob 1 'failed'
    Complete-Job 1 'failed'
    return
  }

  if (-not (Invoke-Hook 'Before-Job')) {
    Say "job #${JobId}: Before-Job failed - job not run"
    Add-Log 'slipdock-runner: Before-Job failed, so the job was not run'
    Invoke-AfterJob 1 'failed'
    Close-Lane
    Complete-Job 1 'failed'
    return
  }

  # Anything that goes wrong from here on is said in the runner's log, the
  # job is stopped and failed, and the runner carries on: left to stop the
  # runner, it would leave the job's process running with nobody to report
  # on it, and the error on a stderr nobody sees (#1481).
  $proc = $null
  try {
    # The job is a child process running this script again in -RunJob mode, so
    # cancel and timeout can stop it, and everything it started, cleanly.
    $shell = (Get-Process -Id $PID).Path
    $selfPath = $PSCommandPath
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$selfPath`"",
      '-Config', "`"$Config`"", '-RunJob', $fn)
    $where = $script:Lane
    if (-not $where) { $where = $script:JobDir }
    if (-not $where) { $where = (Get-Location).Path }
    $proc = Start-Process -FilePath $shell -ArgumentList $arguments -PassThru -NoNewWindow -WorkingDirectory $where `
      -RedirectStandardOutput (Join-Path $Work 'out') -RedirectStandardError (Join-Path $Work 'err')
    $null = $proc.Handle

    $started = Get-Date
    $last = [datetime]::MinValue
    $lastTx = Get-Date
    $ended = ''
    while (-not $proc.HasExited) {
      if (((Get-Date) - $started).TotalSeconds -ge $JobTimeout) { $ended = 'timeout'; break }
      if (((Get-Date) - $last).TotalSeconds -ge $Heartbeat) {
        $last = Get-Date
        $a = Send-Slipdock "/api/runner/jobs/$JobId/heartbeat" (Read-Log) 15
        if ($a.Status -eq 200 -and $a.Body.Trim() -eq 'cancel') { $ended = 'cancelled'; break }
        if ($a.Status -eq 404) { $ended = 'lost'; break }
      }
      if ($TranscriptEvery -gt 0 -and ((Get-Date) - $lastTx).TotalSeconds -ge $TranscriptEvery) {
        $lastTx = Get-Date
        Send-Transcript
      }
      Start-Sleep -Milliseconds 500
    }

    switch ($ended) {
      'timeout' {
        Say "job #${JobId}: over its ${JobTimeout}s - stopped"
        Stop-JobTree $proc
        Add-Log "slipdock-runner: stopped after ${JobTimeout}s"
        Send-Transcript $true
        Invoke-AfterJob 124 'timeout'
        Close-Lane
        Complete-Job 124 'timeout'
      }
      'cancelled' {
        Say "job #${JobId}: cancelled from the board - stopped"
        Stop-JobTree $proc
        Add-Log 'slipdock-runner: cancelled from the board'
        Send-Transcript $true
        Invoke-AfterJob 130 'cancelled'
        Close-Lane
        Complete-Job 130 'cancelled'
      }
      'lost' {
        Say "job #${JobId}: no longer this runner's - stopped"
        Stop-JobTree $proc
        Invoke-AfterJob 130 'cancelled'
        Close-Lane
      }
      default {
        $proc.WaitForExit()
        $rc = $proc.ExitCode
        if ($null -eq $rc) { $rc = 1 }
        Say "job #${JobId}: exit $rc"
        Send-Transcript $true
        if ($rc -eq 0) { Invoke-AfterJob 0 'done' } else { Invoke-AfterJob $rc 'failed' }
        Close-Lane
        Complete-Job $rc ''
      }
    }
  } catch {
    $err = $_
    Say "job #${JobId}: the runner failed while running it - $($err.Exception.Message) (line $($err.InvocationInfo.ScriptLineNumber)); stopped and failed"
    try {
      if ($proc -and -not $proc.HasExited) { Stop-JobTree $proc }
      Add-Log "slipdock-runner: failed while running the job: $($err.Exception.Message)"
      Invoke-AfterJob 1 'failed'
      Close-Lane
      Complete-Job 1 'failed'
    } catch {
      Say "job #${JobId}: and could not finish it - $_"
    }
  }
}

# The kinds this runner takes, said on every claim (X-Runner-Kinds): each
# Job-<Kind> function, "Job-TwoWords" as two-words, the built-in merge too.
$Kinds = (@(Get-ChildItem Function:Job-* | ForEach-Object {
      (($_.Name.Substring(4) -creplace '([a-z0-9])([A-Z])', '$1-$2')).ToLower()
    }) | Sort-Object -Unique) -join ','
$KindsHeader = @{ 'X-Runner-Kinds' = $Kinds }

# The SHA-256 of some bytes, in lower-case hex.
function Get-Sha256([byte[]]$bytes) {
  $hasher = [Security.Cryptography.SHA256]::Create()
  try { return (($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $hasher.Dispose() }
}

# This script's SHA-256 as the server hands it out: LF line endings and one
# final newline, whatever an installer or Windows did to them (#1658).
function Get-ScriptSha([string]$path) {
  $text = [IO.File]::ReadAllText($path) -replace "`r`n", "`n"
  return Get-Sha256 ($Utf8.GetBytes($text.TrimEnd("`n") + "`n"))
}

$MySha = ''
try { $MySha = Get-ScriptSha $PSCommandPath } catch { }
if ($MySha) { $KindsHeader['X-Runner-Version'] = "ps1 $MySha" }
$SkipSha = ''
$FinishLatest = ''

# What this machine has installed (#1795): each slipdock skill's SKILL.md
# (line endings as LF, as the server's copy is) and the CLI, by SHA-256.
if (-not $SkillsDir) { $SkillsDir = Join-Path (Join-Path $HOME '.claude') 'skills' }
function Get-InstalledSkills {
  $pairs = @()
  if (Test-Path -LiteralPath $SkillsDir) {
    foreach ($dir in (Get-ChildItem -LiteralPath $SkillsDir -Directory -Filter 'slipdock*' | Sort-Object Name)) {
      $file = Join-Path $dir.FullName 'SKILL.md'
      if (-not (Test-Path -LiteralPath $file)) { continue }
      try {
        $text = [IO.File]::ReadAllText($file) -replace "`r`n", "`n"
        $pairs += ($dir.Name + '=' + (Get-Sha256 ($Utf8.GetBytes($text))))
      } catch { }
    }
  }
  if ($pairs.Count -eq 0) { return 'none' }
  return ($pairs -join ',')
}
function Get-InstalledCli {
  $path = $SlipdockCli
  if (-not $path) {
    $cmd = Get-Command 'slipdock' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) {
      $path = $cmd.Source
      # The Windows install runs slipdock.escript through slipdock.cmd.
      $beside = Join-Path (Split-Path -Parent $path) 'slipdock.escript'
      if ($path -like '*.cmd' -and (Test-Path -LiteralPath $beside)) { $path = $beside }
    }
  }
  if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'none' }
  try { return Get-Sha256 ([IO.File]::ReadAllBytes($path)) } catch { return '' }
}
# Said again on every claim, so an edit while it waits shows on the next one.
function Update-ClaimHeaders {
  $KindsHeader['X-Runner-Skills'] = Get-InstalledSkills
  $cli = Get-InstalledCli
  if ($cli) { $KindsHeader['X-Runner-CLI'] = $cli } else { $KindsHeader.Remove('X-Runner-CLI') }
}

# Bytes from the server, or from a file:// URL.
function Get-Remote([string]$url) {
  if ($url -like 'file://*') { return [IO.File]::ReadAllBytes(([Uri]$url).LocalPath) }
  $limit = Get-WebTimeout 60
  $r = Invoke-WebRequest -UseBasicParsing -Uri $url @limit
  if ($r.RawContentStream) { return $r.RawContentStream.ToArray() }
  return $Utf8.GetBytes([string]$r.Content)
}

# Between jobs: fetch the script and its checksums, and put the script in
# place of this one only if its SHA-256 matches both the published sum and
# $latest. True when it was replaced.
function Update-Self([string]$latest) {
  $base = $SelfUpdateUrl
  if (-not $base) { $base = "$SlipdockUrl/runner" }
  $base = $base.TrimEnd('/')
  try {
    $new = Get-Remote "$base/slipdock-runner.ps1"
    $sums = $Utf8.GetString((Get-Remote "$base/SHA256SUMS"))
  } catch {
    Say "self-update: could not fetch the new script from ${base}: $($_.Exception.Message); keeping this one"
    return $false
  }
  $got = Get-Sha256 $new
  $published = ''
  foreach ($line in ($sums -split "`n")) {
    $f = $line.Trim() -split '\s+'
    if ($f.Count -ge 2 -and $f[1] -eq 'slipdock-runner.ps1') { $published = $f[0] }
  }
  if ($got -ne $published -or $got -ne $latest) {
    Say "self-update: checksum mismatch (got $got, published $published, expected $latest); keeping this script"
    return $false
  }
  try {
    $tmp = "$PSCommandPath.new"
    [IO.File]::WriteAllBytes($tmp, $new)
    Move-Item -LiteralPath $tmp -Destination $PSCommandPath -Force
  } catch {
    Say "self-update: could not replace ${PSCommandPath}: $($_.Exception.Message); keeping this script"
    return $false
  }
  Say "self-update: replaced $PSCommandPath ($MySha -> $got)"
  return $true
}

# Between jobs, with $SelfUpdate on (#1658, #1925): when $latest is a script
# other than this one, replace this one with it and start again. Returns only
# when this script carries on: $SelfUpdate off, nothing newer, or an update
# that failed (not tried again for $latest).
function Invoke-KeepCurrent([string]$latest) {
  if (-not $SelfUpdate -or ("$SelfUpdate" -in @('0', 'no', 'false', 'off'))) { return }
  if ($latest -notmatch '^[0-9a-f]{64}$' -or $latest -eq $MySha -or $latest -eq $script:SkipSha) { return }
  if (Update-Self $latest) {
    if ($Once) { exit 0 }
    # Start again as the new script, with the same arguments.
    $shell = (Get-Process -Id $PID).Path
    $again = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Config', "`"$Config`"")
    Start-Process -FilePath $shell -ArgumentList $again -NoNewWindow | Out-Null
    exit 0
  }
  $script:SkipSha = $latest
}

$query = "wait=$Wait"
if ($Pool) { $query += "&pool=$Pool" }
$poolNote = ''
if ($Pool) { $poolNote = " (pool $Pool)" }
Say "taking jobs from $SlipdockUrl$poolNote"
$backoff = 1
# Gateway errors in a row that were retried without a word.
$quiet = 0

try {
  while ($true) {
    # Nothing that goes wrong in a round stops the runner without a word in
    # its log: the task's window is hidden, so stderr reaches nobody (#1481).
    try {
      Update-ClaimHeaders
      $claim = Send-Slipdock "/api/runner/claim?$query" '' ($Wait + 15) $KindsHeader
      if ($claim.Status -eq 200) {
        $backoff = 1
        $quiet = 0
        $latest = Get-Header $claim 'X-Runner-Latest'
        $script:FinishLatest = ''
        Invoke-Job $claim
        # Between jobs (#1925): the job's finish is reported, the next claim
        # not yet made. The finish's answer is the newer word, if it came.
        if ($script:FinishLatest) { $latest = $script:FinishLatest }
        Invoke-KeepCurrent $latest
      } elseif ($claim.Status -eq 204) {
        $backoff = 1
        $quiet = 0
        # Between jobs: keep current, if the config asks (#1658).
        Invoke-KeepCurrent (Get-Header $claim 'X-Runner-Latest')
        # A server stopping for a deploy says how long to wait before asking
        # again, by when its replacement is there to answer.
        $pause = 0
        if ([int]::TryParse((Get-Header $claim 'Retry-After'), [ref]$pause) -and $pause -gt 0 -and -not $Once) {
          Start-Sleep -Seconds ([Math]::Min($pause, 60))
        }
      } elseif ($claim.Status -eq 401 -or $claim.Status -eq 403) {
        Say "the server refused this runner (HTTP $($claim.Status)): $($claim.Body)"
        exit 1
      } elseif (-not $Once -and $claim.Status -in @(0, 502, 503, 504) -and $quiet -lt 3) {
        # A claim the proxy lost when the app went down for a deploy (502, or
        # the connection dropped without a proxy) is retried at once, and
        # quietly: only a few in a row are worth a line in the log.
        $quiet++
        Start-Sleep -Seconds 1
      } else {
        Say "could not reach the queue (HTTP $($claim.Status)) - trying again in ${backoff}s"
        if ($Once) { exit 1 }
        Start-Sleep -Seconds $backoff
        $backoff = [Math]::Min($backoff * 2, 60)
      }
    } catch {
      Say "runner error: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber)) - trying again in ${backoff}s"
      if ($Once) { exit 1 }
      Start-Sleep -Seconds $backoff
      $backoff = [Math]::Min($backoff * 2, 60)
    }
    if ($Once) { exit 0 }
  }
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
