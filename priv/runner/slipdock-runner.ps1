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

$Here = Split-Path -Parent $Config
$RunnerLog = Join-Path $Here 'runner.log'
$Work = Join-Path ([IO.Path]::GetTempPath()) ("slipdock-runner-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows

function Say([string]$message) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " slipdock-runner: " + $message
  [Console]::Error.WriteLine($line)
  try { [IO.File]::AppendAllText($RunnerLog, $line + "`n", $Utf8) } catch { }
}

# POST to the queue. Answers @{ Status; Body; Headers }: Status 0 when
# nothing answered. Windows PowerShell throws on any 4xx/5xx, so the answer
# is taken from the exception as well.
function Send-Slipdock([string]$path, [string]$body, [int]$timeout) {
  $bytes = $Utf8.GetBytes($body)
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($SlipdockUrl + $path) `
      -Headers @{ Authorization = "Bearer $RunnerToken" } `
      -ContentType 'text/plain; charset=utf-8' -Body $bytes -TimeoutSec $timeout
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

function Read-Log {
  $text = ''
  foreach ($f in @('log', 'out', 'err')) {
    $p = Join-Path $Work $f
    if (Test-Path -LiteralPath $p) { $text += [IO.File]::ReadAllText($p, $Utf8) }
  }
  if ($text.Length -gt $LogTail) { $text = $text.Substring($text.Length - $LogTail) }
  return $text
}

function Add-Log([string]$text) {
  [IO.File]::AppendAllText((Join-Path $Work 'log'), $text + "`n", $Utf8)
}

# A hook from the config, its output in the job's log. False when it failed.
function Invoke-Hook([string]$name) {
  if (-not (Test-Function $name)) { return $true }
  $global:LASTEXITCODE = 0
  try {
    $output = & $name 2>&1 | Out-String
    if ($output) { Add-Log $output.TrimEnd() }
    return ($global:LASTEXITCODE -eq 0)
  } catch {
    Add-Log "$name failed: $_"
    return $false
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
  for ($try = 1; $try -le 5; $try++) {
    $a = Send-Slipdock "/api/runner/jobs/$JobId/finish?$query" (Read-Log) 30
    if ($a.Status -eq 200 -or $a.Status -eq 404) { return }
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
  foreach ($f in @('log', 'out', 'err')) { Remove-Item -LiteralPath (Join-Path $Work $f) -ErrorAction SilentlyContinue }
  [IO.File]::WriteAllText((Join-Path $Work 'log'), '', $Utf8)

  $fn = ''
  if ($kind -match '^[a-z0-9][a-z0-9_-]*$') { $fn = Get-JobFunction $kind }
  if (-not $fn -or -not (Test-Function $fn)) {
    Say "job #${JobId}: no $fn in $Config - refused, nothing run"
    Add-Log "no such job kind: $kind (this runner has no $fn)"
    Complete-Job 127 'failed'
    return
  }

  $prompt = $claim.Body
  if ($JobInstructions) { $prompt = $prompt + "`n`n" + $JobInstructions }
  $env:SLIPDOCK_JOB_ID = $JobId
  $env:SLIPDOCK_JOB_KIND = $kind
  $env:SLIPDOCK_CARD = $card
  $env:SLIPDOCK_CARD_URL = Get-Header $claim 'X-Card-Url'
  $env:SLIPDOCK_PROMPT = $prompt

  Say "job #${JobId}: $kind for card #$card"

  if (-not (Invoke-Hook 'Before-Job')) {
    Say "job #${JobId}: Before-Job failed - job not run"
    Add-Log 'slipdock-runner: Before-Job failed, so the job was not run'
    Invoke-AfterJob 1 'failed'
    Complete-Job 1 'failed'
    return
  }

  # The job is a child process running this script again in -RunJob mode, so
  # cancel and timeout can stop it, and everything it started, cleanly.
  $shell = (Get-Process -Id $PID).Path
  $selfPath = $PSCommandPath
  $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$selfPath`"",
    '-Config', "`"$Config`"", '-RunJob', $fn)
  $proc = Start-Process -FilePath $shell -ArgumentList $arguments -PassThru -NoNewWindow `
    -RedirectStandardOutput (Join-Path $Work 'out') -RedirectStandardError (Join-Path $Work 'err')
  $null = $proc.Handle

  $started = Get-Date
  $last = [datetime]::MinValue
  $ended = ''
  while (-not $proc.HasExited) {
    if (((Get-Date) - $started).TotalSeconds -ge $JobTimeout) { $ended = 'timeout'; break }
    if (((Get-Date) - $last).TotalSeconds -ge $Heartbeat) {
      $last = Get-Date
      $a = Send-Slipdock "/api/runner/jobs/$JobId/heartbeat" (Read-Log) 15
      if ($a.Status -eq 200 -and $a.Body.Trim() -eq 'cancel') { $ended = 'cancelled'; break }
      if ($a.Status -eq 404) { $ended = 'lost'; break }
    }
    Start-Sleep -Milliseconds 500
  }

  switch ($ended) {
    'timeout' {
      Say "job #${JobId}: over its ${JobTimeout}s - stopped"
      Stop-JobTree $proc
      Add-Log "slipdock-runner: stopped after ${JobTimeout}s"
      Invoke-AfterJob 124 'timeout'
      Complete-Job 124 'timeout'
    }
    'cancelled' {
      Say "job #${JobId}: cancelled from the board - stopped"
      Stop-JobTree $proc
      Add-Log 'slipdock-runner: cancelled from the board'
      Invoke-AfterJob 130 'cancelled'
      Complete-Job 130 'cancelled'
    }
    'lost' {
      Say "job #${JobId}: no longer this runner's - stopped"
      Stop-JobTree $proc
      Invoke-AfterJob 130 'cancelled'
    }
    default {
      $proc.WaitForExit()
      $rc = $proc.ExitCode
      if ($null -eq $rc) { $rc = 1 }
      Say "job #${JobId}: exit $rc"
      if ($rc -eq 0) { Invoke-AfterJob 0 'done' } else { Invoke-AfterJob $rc 'failed' }
      Complete-Job $rc ''
    }
  }
}

$query = "wait=$Wait"
if ($Pool) { $query += "&pool=$Pool" }
$poolNote = ''
if ($Pool) { $poolNote = " (pool $Pool)" }
Say "taking jobs from $SlipdockUrl$poolNote"
$backoff = 1

try {
  while ($true) {
    $claim = Send-Slipdock "/api/runner/claim?$query" '' ($Wait + 15)
    if ($claim.Status -eq 200) {
      $backoff = 1
      Invoke-Job $claim
    } elseif ($claim.Status -eq 204) {
      $backoff = 1
    } elseif ($claim.Status -eq 401 -or $claim.Status -eq 403) {
      Say "the server refused this runner (HTTP $($claim.Status)): $($claim.Body)"
      exit 1
    } else {
      Say "could not reach the queue (HTTP $($claim.Status)) - trying again in ${backoff}s"
      if ($Once) { exit 1 }
      Start-Sleep -Seconds $backoff
      $backoff = [Math]::Min($backoff * 2, 60)
    }
    if ($Once) { exit 0 }
  }
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
