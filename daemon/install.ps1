# Installs slipdock-runner, the Slipdock runner daemon, on Windows
# (PowerShell 5.1 or later):
#
#   irm https://github.com/dadamsuk/slipdock/releases/latest/download/install.ps1 | iex
#
# It downloads the latest release's manifest and its signature, checks the
# signature against the project's release key written into this script
# (with ssh-keygen -Y verify, from Windows' OpenSSH client), and only then
# downloads the binary for this machine, checks its SHA-256 against the
# signed manifest and puts it in place. Nothing unchecked is installed.
#
# What this can't do is vouch for itself: the key comes inside this script,
# so the first install is only as trustworthy as the download of the
# script. After that the daemon checks every update against the key built
# into it, whichever host serves the update. (The manual's Machines page.)
#
#   SLIPDOCK_RUNNER_BIN     where to put it (default %LOCALAPPDATA%\Programs\slipdock-runner)
#   SLIPDOCK_RUNNER_SOURCE  where releases come from (default: GitHub)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Written in by the release job from daemon/internal/release/release_key.pub.
$ReleaseKey = '__SLIPDOCK_RELEASE_KEY__'
$Source = if ($env:SLIPDOCK_RUNNER_SOURCE) { $env:SLIPDOCK_RUNNER_SOURCE.TrimEnd('/') } else { 'https://github.com/dadamsuk/slipdock/releases/latest/download' }
$Bin = if ($env:SLIPDOCK_RUNNER_BIN) { $env:SLIPDOCK_RUNNER_BIN } else { Join-Path $env:LOCALAPPDATA 'Programs\slipdock-runner' }

# Thrown, not exit: run as `irm … | iex`, exit would close the window.
function Fail([string]$message) {
    throw "slipdock-runner install: $message"
}

if (-not $ReleaseKey.StartsWith('ssh-ed25519 ')) {
    Fail "this installer has no release key, so it can't check what it downloads: use the install.ps1 from a release"
}

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { Fail "no build for $($env:PROCESSOR_ARCHITECTURE)" }
}

$keygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
if (-not $keygen) {
    Fail "needs ssh-keygen to check the release's signature: add the OpenSSH Client (Settings, Optional features)"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("slipdock-runner-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

function Fetch([string]$name) {
    $out = Join-Path $tmp $name
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$Source/$name" -OutFile $out
    } catch {
        Fail "can't download $name from ${Source}: $($_.Exception.Message)"
    }
    return $out
}

try {
    $manifest = Fetch 'release.json'
    $sig = Fetch 'release.json.sig'

    $signers = Join-Path $tmp 'allowed_signers'
    [IO.File]::WriteAllText($signers, "slipdock-release namespaces=`"slipdock-runner`" $ReleaseKey`n")
    # The manifest goes to ssh-keygen as a file on stdin, byte for byte:
    # PowerShell's own pipe would re-encode it.
    $verifyOut = Join-Path $tmp 'verify.out'
    $p = Start-Process -FilePath $keygen.Source -NoNewWindow -Wait -PassThru `
        -ArgumentList @('-Y', 'verify', '-f', "`"$signers`"", '-I', 'slipdock-release', '-n', 'slipdock-runner', '-s', "`"$sig`"") `
        -RedirectStandardInput $manifest -RedirectStandardOutput $verifyOut -RedirectStandardError (Join-Path $tmp 'verify.err')
    if ($p.ExitCode -ne 0) {
        Get-Content (Join-Path $tmp 'verify.err') | ForEach-Object { [Console]::Error.WriteLine($_) }
        Fail "REFUSED: release.json from $Source is not signed with the project's release key; nothing was installed"
    }

    # Signed, so what it says is the project's.
    $release = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
    $file = $release.files."windows/$arch"
    if (-not $file) { Fail "release $($release.version) has no build for windows/$arch" }
    if ($file.name -notmatch '^[A-Za-z0-9._-]+$') { Fail "release.json names a file it shouldn't: $($file.name)" }

    $downloaded = Fetch $file.name
    $got = (Get-FileHash -Algorithm SHA256 -Path $downloaded).Hash.ToLowerInvariant()
    if ($got -ne $file.sha256) {
        Fail "REFUSED: $($file.name)'s SHA-256 is $got, but the signed manifest says $($file.sha256); nothing was installed"
    }

    New-Item -ItemType Directory -Force -Path $Bin | Out-Null
    $target = Join-Path $Bin 'slipdock-runner.exe'
    if (Test-Path $target) {
        # A running binary can be renamed but not replaced.
        Move-Item -Force $target "$target.old"
    }
    Move-Item -Force $downloaded $target
    Remove-Item -Force "$target.old" -ErrorAction SilentlyContinue

    Write-Host "slipdock-runner install: installed slipdock-runner $($release.version) in $Bin, its signature and checksum checked"
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (($userPath -split ';') -contains $Bin)) {
        Write-Host "slipdock-runner install: $Bin is not on your PATH: add it, or run `"$target`""
    }
    Write-Host 'slipdock-runner install: next: slipdock-runner init'
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
