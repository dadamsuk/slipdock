# runner_smoke.ps1 - runs priv/runner/slipdock-runner.ps1 -Once against a
# fake queue on a loopback port, with a job that writes to stdout and stderr
# across several heartbeats, and checks the runner heartbeats with its output
# and finishes it.
#
# For Windows PowerShell 5.1, which the ExUnit tests (pwsh on Linux) can't
# stand in for: its Start-Process holds the job's out and err open without
# read sharing, and the heartbeat reading them stopped the runner (#1481).
# CI runs this on windows-latest; runner_powershell_test.exs runs it under
# pwsh too, so it keeps working.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\powershell\runner_smoke.ps1
param(
  [string]$Runner = (Join-Path $PSScriptRoot '..\..\priv\runner\slipdock-runner.ps1')
)

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$shell = (Get-Process -Id $PID).Path
Write-Output "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) at $shell"

$probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()

$dir = Join-Path ([IO.Path]::GetTempPath()) ("slipdock-smoke-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$config = Join-Path $dir 'config.ps1'
[IO.File]::WriteAllText($config, @"
`$SlipdockUrl = 'http://localhost:$port'
`$RunnerToken = 'smoke'
`$Wait = 0
`$Heartbeat = 1
`$JobTimeout = 60
function Job-Chatty {
  foreach (`$i in 1..6) {
    Write-Output "line `$i"
    [Console]::Error.WriteLine("err `$i")
    Start-Sleep -Seconds 1
  }
}
"@, $Utf8)

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()

$proc = Start-Process -FilePath $shell -PassThru -NoNewWindow `
  -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$Runner`"", '-Once', '-Config', "`"$config`"") `
  -RedirectStandardOutput (Join-Path $dir 'runner.out') -RedirectStandardError (Join-Path $dir 'runner.err')
$null = $proc.Handle

$claimed = $false
$heartbeats = @()
$finish = $null
$deadline = (Get-Date).AddSeconds(120)
try {
  while (-not $finish -and (Get-Date) -lt $deadline) {
    $next = $listener.GetContextAsync()
    while (-not $next.Wait(500)) {
      if ($proc.HasExited -or (Get-Date) -ge $deadline) { break }
    }
    if (-not $next.IsCompleted) { break }
    $ctx = $next.Result
    $path = $ctx.Request.Url.AbsolutePath
    $body = (New-Object IO.StreamReader($ctx.Request.InputStream, $Utf8)).ReadToEnd()
    $res = $ctx.Response
    $answer = ''
    if ($path -eq '/api/runner/claim') {
      if ($claimed) {
        $res.StatusCode = 204
      } else {
        $claimed = $true
        $res.Headers.Add('X-Job-Id', '7')
        $res.Headers.Add('X-Job-Kind', 'chatty')
        $res.Headers.Add('X-Card-Id', '1')
        $answer = 'go'
      }
    } elseif ($path -eq '/api/runner/jobs/7/heartbeat') {
      $heartbeats += $body
      $answer = 'ok'
    } elseif ($path -eq '/api/runner/jobs/7/finish') {
      $finish = @{ Query = $ctx.Request.Url.Query; Body = $body }
      $answer = 'ok'
    } else {
      $res.StatusCode = 404
    }
    $bytes = $Utf8.GetBytes($answer)
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
  }
  if (-not $proc.WaitForExit(30000)) { Stop-Process -Id $proc.Id -Force }
} finally {
  $listener.Stop()
}

$problems = @()
if (-not $claimed) { $problems += 'the runner never claimed the job' }
if ($heartbeats.Count -lt 2) { $problems += "only $($heartbeats.Count) heartbeat(s)" }
if (-not ($heartbeats | Where-Object { $_ -match 'line \d' })) { $problems += "no heartbeat carried the job's output" }
if (-not $finish) {
  $problems += 'the job was never finished'
} else {
  if ($finish.Query -notmatch 'exit=0') { $problems += "finished with $($finish.Query)" }
  if ($finish.Body -notmatch 'line 6' -or $finish.Body -notmatch 'err 6') { $problems += "the finish lacked the job's last output: $($finish.Body)" }
}
if ($proc.HasExited -and $proc.ExitCode -ne 0) { $problems += "the runner exited $($proc.ExitCode)" }

if ($problems) {
  Write-Output '--- runner stderr ---'
  Get-Content -LiteralPath (Join-Path $dir 'runner.err') -ErrorAction SilentlyContinue
  foreach ($p in $problems) { Write-Output "FAIL: $p" }
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  exit 1
}

Write-Output "ok: $($heartbeats.Count) heartbeats, finished with $($finish.Query)"
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
exit 0
