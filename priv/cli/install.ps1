# Installs the slipdock command on this Windows machine, for you alone, from
# __SLIPDOCK_BASE_COMMENT__. In PowerShell:
#
#   irm __SLIPDOCK_BASE_COMMENT__/cli/install.ps1 | iex
#       install it, or update it: running it again fetches the CLI afresh
#   & ([scriptblock]::Create((irm __SLIPDOCK_BASE_COMMENT__/cli/install.ps1))) -Uninstall
#       take it away again (your sign-in in ~\.config\slipdock is kept)
#
# It writes, with no admin rights of its own:
#   %LOCALAPPDATA%\Programs\slipdock\slipdock.escript   the CLI, checked against
#                                                        /cli/SHA256SUMS first
#   %LOCALAPPDATA%\Programs\slipdock\slipdock.cmd       what runs it, so `slipdock`
#                                                        works in PowerShell and cmd
#   that folder on your PATH, and SLIPDOCK_CLI_DIR naming it
#   ~\.config\slipdock\url    this server's address (unless it names another)
#
# The CLI is an Erlang escript, so it needs Erlang/OTP 27 or later. If there is
# none, it is installed with winget (Erlang.ErlangOTP), and Windows asks for
# admin rights for that once. -NoErlang stops instead, to install it yourself
# from https://www.erlang.org/downloads; -Escript names an escript.exe this
# can't find on its own.
#
# Run as `irm ... | iex`, it runs in your own PowerShell session, so it calls
# no exit, and its work is done inside a block of its own so that its
# functions and preferences go when it does.
param(
  [string]$Dir,
  [string]$Escript,
  [switch]$NoErlang,
  [switch]$NoPath,
  [switch]$Uninstall
)

& {
  # Any failure ends the install, rather than only the line it was on. Set in
  # this block, so the person's own session keeps its preference.
  $ErrorActionPreference = 'Stop'
  $Base = '__SLIPDOCK_BASE__'
  $OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows

  if (-not $Dir) {
    $root = $env:LOCALAPPDATA
    if (-not $root) { $root = Join-Path $HOME '.local/share' }
    $Dir = Join-Path $root 'Programs\slipdock'
  }
  $Cli = Join-Path $Dir 'slipdock.escript'
  $Shim = Join-Path $Dir 'slipdock.cmd'

  # The user's PATH as the registry holds it, %VARS% unexpanded: going
  # through [Environment] would expand them and write them back flattened.
  function Get-UserPath {
    $key = Get-Item -Path 'HKCU:\Environment'
    return [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
  }

  function Set-UserPath([string[]]$parts) {
    Set-ItemProperty -Path 'HKCU:\Environment' -Name 'Path' -Type ExpandString -Value ($parts -join ';')
  }

  if ($Uninstall) {
    if ($OnWindows -and -not $NoPath) {
      $parts = @((Get-UserPath) -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $Dir.TrimEnd('\')) })
      Set-UserPath $parts
      # Setting it through [Environment] tells open programs PATH has changed.
      [Environment]::SetEnvironmentVariable('SLIPDOCK_CLI_DIR', $null, 'User')
    }
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force }
    Write-Host "slipdock: removed $Dir"
    Write-Host 'slipdock: left alone: your sign-in in ~\.config\slipdock, and Erlang'
    return
  }

  # escript.exe on the PATH, else where the Erlang installer puts it: the
  # Erlang installer does not add itself to the PATH.
  function Find-Escript {
    $cmd = Get-Command 'escript.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
      if (-not $root) { continue }
      $found = Get-ChildItem -Path $root -Directory -Filter 'erl*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'bin\escript.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Sort-Object -Descending |
        Select-Object -First 1
      if ($found) { return $found }
    }
    return $null
  }

  if (-not $Escript) { $Escript = Find-Escript }
  if (-not $Escript) {
    if ($NoErlang) {
      throw 'slipdock: Erlang/OTP 27 or later is needed and was not found. Install it from https://www.erlang.org/downloads and run this again (or pass -Escript C:\path\to\escript.exe)'
    }
    if (-not (Get-Command 'winget.exe' -ErrorAction SilentlyContinue)) {
      throw 'slipdock: Erlang/OTP 27 or later is needed, and winget is not here to install it. Install it from https://www.erlang.org/downloads and run this again'
    }
    Write-Host 'slipdock: installing Erlang/OTP with winget; Windows will ask for admin rights...'
    & winget.exe install --id Erlang.ErlangOTP --exact --silent --accept-package-agreements --accept-source-agreements
    $Escript = Find-Escript
    if (-not $Escript) {
      throw "slipdock: winget finished (exit $LASTEXITCODE) but no escript.exe turned up. Install Erlang/OTP from https://www.erlang.org/downloads and run this again"
    }
  }
  if (-not (Test-Path -LiteralPath $Escript)) { throw "slipdock: there is no $Escript" }
  $ErlBin = Split-Path -Parent $Escript

  # The CLI is built on OTP 27; an older Erlang cannot load it.
  $Erl = Join-Path $ErlBin ('erl' + [IO.Path]::GetExtension($Escript))
  if (Test-Path -LiteralPath $Erl) {
    $otp = & $Erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)),halt().' 2>$null
    if (("$otp" -match '^\d+$') -and ([int]"$otp" -lt 27)) {
      throw "slipdock: $Erl is Erlang/OTP $otp; the CLI needs 27 or later. Update Erlang (winget upgrade Erlang.ErlangOTP) and run this again"
    }
  }

  New-Item -ItemType Directory -Force -Path $Dir -ErrorAction Stop | Out-Null

  $saved = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  $download = Join-Path $Dir ('slipdock.escript.' + [guid]::NewGuid() + '.part')
  try {
    $sums = (Invoke-WebRequest -UseBasicParsing -Uri "$Base/cli/SHA256SUMS" -ErrorAction Stop).Content
    # PowerShell 7 hands back bytes for anything not labelled text.
    if ($sums -is [byte[]]) { $sums = [Text.Encoding]::ASCII.GetString($sums) }
    $line = $sums -split "`n" | Where-Object { $_ -match '^([0-9a-f]{64})\s+slipdock\.escript\s*$' } | Select-Object -First 1
    if (-not $line) { throw "slipdock: $Base/cli/SHA256SUMS has no checksum for slipdock.escript" }
    $want = ($line -split '\s+')[0]

    Invoke-WebRequest -UseBasicParsing -Uri "$Base/cli/slipdock.escript" -OutFile $download -ErrorAction Stop
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash.ToLowerInvariant()
    if ($got -ne $want) {
      throw "slipdock: the CLI downloaded from $Base does not match its published checksum (got $got, expected $want); nothing was installed"
    }
    Move-Item -LiteralPath $download -Destination $Cli -Force
  } finally {
    $ProgressPreference = $saved
    if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
  }

  # cmd reads its scripts in the console's code page, so this is ASCII. Erlang
  # goes on the front of PATH for the CLI's own use: `slipdock sync service`
  # looks escript up there.
  $shimText = "@echo off`r`n" +
    "setlocal`r`n" +
    "set `"PATH=$ErlBin;%PATH%`"`r`n" +
    "`"$Escript`" `"%~dp0slipdock.escript`" %*`r`n" +
    "exit /b %ERRORLEVEL%`r`n"
  [IO.File]::WriteAllText($Shim, $shimText, [Text.Encoding]::ASCII)

  if ($OnWindows -and -not $NoPath) {
    $parts = @((Get-UserPath) -split ';' | Where-Object { $_ })
    if (-not ($parts | Where-Object { $_.TrimEnd('\') -eq $Dir.TrimEnd('\') })) {
      Set-UserPath ($parts + $Dir)
    }
    [Environment]::SetEnvironmentVariable('SLIPDOCK_CLI_DIR', $Dir, 'User')
    if (-not (($env:Path -split ';') -contains $Dir)) { $env:Path = "$Dir;$env:Path" }
  }

  # A url already pointing somewhere else is left alone: the token beside it
  # belongs to that server.
  $Conf = Join-Path $HOME '.config\slipdock'
  New-Item -ItemType Directory -Force -Path $Conf -ErrorAction Stop | Out-Null
  $UrlFile = Join-Path $Conf 'url'
  $Current = ''
  if (Test-Path -LiteralPath $UrlFile) { $Current = (Get-Content -Raw -LiteralPath $UrlFile).Trim() }
  if (-not $Current) {
    Set-Content -LiteralPath $UrlFile -Value $Base -Encoding ascii
  } elseif ($Current -ne $Base) {
    Write-Warning "slipdock: $UrlFile already names $Current; left it alone. To use this server: slipdock url $Base"
  }

  Write-Host "slipdock: installed $Cli"
  Write-Host "slipdock: run with $Escript"
  Write-Host ''
  Write-Host 'Next, sign in (it shows a code to approve in your browser):'
  Write-Host ''
  Write-Host '  slipdock auth'
  Write-Host '  slipdock whoami'
  if ($OnWindows -and -not $NoPath) {
    Write-Host ''
    Write-Host 'Windows that were already open will not find slipdock until they are reopened.'
  }
}
