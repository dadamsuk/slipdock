# Installs the slipdock command on this Windows machine, for you alone, from
# __SLIPDOCK_BASE_COMMENT__. In PowerShell:
#
#   irm __SLIPDOCK_BASE_COMMENT__/cli/install.ps1 | iex
#       install it, or update it: running it again fetches the CLI afresh
#   & ([scriptblock]::Create((irm __SLIPDOCK_BASE_COMMENT__/cli/install.ps1))) -Uninstall
#       take it away again (your sign-in in ~\.config\slipdock is kept)
#   & ([scriptblock]::Create((irm __SLIPDOCK_BASE_COMMENT__/cli/install.ps1))) -AllowUnsigned
#       install a CLI the release key didn't sign (a server built from source
#       serves none), checked against /cli/SHA256SUMS alone;
#       $env:SLIPDOCK_ALLOW_UNSIGNED = '1' before `irm | iex` does the same
#
# It writes, with no admin rights of its own:
#   %LOCALAPPDATA%\Programs\slipdock\slipdock.escript   the CLI, checked against
#                                                        /cli/SHA256SUMS and the
#                                                        release key's signature
#                                                        (with ssh-keygen) first
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
  [switch]$Uninstall,
  [switch]$AllowUnsigned
)

& {
  # Any failure ends the install, rather than only the line it was on. Set in
  # this block, so the person's own session keeps its preference.
  $ErrorActionPreference = 'Stop'
  $Base = '__SLIPDOCK_BASE__'
  # The public half of the project's release key (SlipdockWeb.CLIInstallController
  # writes it in), for /cli/slipdock.escript.sig. Empty on a server built without it.
  $ReleaseKey = '__SLIPDOCK_RELEASE_KEY__'
  $Unsigned = $AllowUnsigned -or ($env:SLIPDOCK_ALLOW_UNSIGNED -eq '1')
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

  # A CLI that can't be checked against the release key (no signature
  # served, no ssh-keygen, no key in this installer) is installed only when
  # -AllowUnsigned or SLIPDOCK_ALLOW_UNSIGNED=1 asks for it: a server built
  # from source serves no signature (404), and then the checksum is all there
  # is to go on. A signature that doesn't verify is refused either way.
  function Confirm-Unsigned([string]$reason) {
    if ($Unsigned) {
      Write-Warning "slipdock: $reason; installing it on the checksum alone, as -AllowUnsigned says"
      return
    }
    throw ("slipdock: REFUSED: $reason; nothing was installed. To install it on the checksum " +
      "alone (a server built from source has no signature), run this again with -AllowUnsigned: " +
      "& ([scriptblock]::Create((irm $Base/cli/install.ps1))) -AllowUnsigned")
  }

  $saved = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  # Everything fetched goes in a folder of its own beside the CLI, so the
  # last step is one move, and the folder goes whatever happens.
  $work = Join-Path $Dir ('.slipdock.' + [guid]::NewGuid() + '.part')
  $download = Join-Path $work 'slipdock.escript'
  try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
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

    $sig = Join-Path $work 'slipdock.escript.sig'
    $signed = $true
    try {
      Invoke-WebRequest -UseBasicParsing -Uri "$Base/cli/slipdock.escript.sig" -OutFile $sig -ErrorAction Stop
    } catch {
      $signed = $false
    }
    $keygen = Get-Command 'ssh-keygen' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $signed) {
      Confirm-Unsigned "$Base serves no signature for the CLI (/cli/slipdock.escript.sig), so it can't be checked against the release key"
    } elseif (-not $keygen) {
      Confirm-Unsigned "there is no ssh-keygen here to check the CLI's signature with (add Windows' OpenSSH Client)"
    } elseif ($ReleaseKey -notmatch '^ssh-ed25519 ') {
      Confirm-Unsigned "$Base serves a signature but this installer has no release key to check it with"
    } else {
      $signers = Join-Path $work 'allowed_signers'
      [IO.File]::WriteAllText($signers, "slipdock-release namespaces=`"slipdock-cli`" $ReleaseKey`n", [Text.Encoding]::ASCII)
      # ssh-keygen reads what was signed on its standard input. The bytes go
      # in as they are: Start-Process and a PowerShell pipe would both pass
      # them through as lines of text first.
      $start = New-Object Diagnostics.ProcessStartInfo
      $start.FileName = $keygen.Source
      $start.Arguments = "-Y verify -f `"$signers`" -I slipdock-release -n slipdock-cli -s `"$sig`""
      $start.UseShellExecute = $false
      $start.RedirectStandardInput = $true
      $start.RedirectStandardOutput = $true
      $start.RedirectStandardError = $true
      $verify = [Diagnostics.Process]::Start($start)
      $said = $verify.StandardOutput.ReadToEndAsync()
      $saidErr = $verify.StandardError.ReadToEndAsync()
      $bytes = [IO.File]::ReadAllBytes($download)
      # It may stop reading early, on a signature it can't parse.
      try { $verify.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length) } catch { }
      try { $verify.StandardInput.Close() } catch { }
      $verify.WaitForExit()
      if ($verify.ExitCode -ne 0) {
        $what = ($said.Result + $saidErr.Result).Trim()
        throw "slipdock: REFUSED: the CLI from $Base is not signed with the project's release key ($what); nothing was installed"
      }
      Write-Host 'slipdock: signature checked against the release key'
    }

    Move-Item -LiteralPath $download -Destination $Cli -Force
  } finally {
    $ProgressPreference = $saved
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
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
