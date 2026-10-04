# Writes the .env that `docker compose up -d` reads, by asking rather than by
# expecting you to know which of a dozen variables matter.
#
#   curl.exe -O https://raw.githubusercontent.com/dadamsuk/slipdock/main/setup.ps1
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#
# The PowerShell twin of setup.sh, for Windows without WSL or Git Bash. It only
# writes .env: it starts nothing, touches no Docker, and needs none of the rest
# of the repository, so you can read it first and running it twice is safe.
#
# Written for Windows PowerShell 5.1 as well as PowerShell 7, so it avoids the
# newer syntax (no ternaries, no null-coalescing) that 5.1 cannot parse.

[CmdletBinding()]
param([string]$EnvFile = ".env")

$ErrorActionPreference = "Stop"

function Ask {
    param([string]$Prompt, [string]$Default = "")

    if ($Default -ne "") { $shown = "$Prompt [$Default]" } else { $shown = $Prompt }
    $answer = Read-Host $shown
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function AskSecret {
    param([string]$Prompt)

    # Not echoed while it is typed. Piped answers arrive as plain text anyway.
    $secure = Read-Host $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# A value from an existing env file, or "".
function EnvValue {
    param([string]$Path, [string]$Name)

    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $found = ""
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line.StartsWith("$Name=")) { $found = $line.Substring($Name.Length + 1) }
    }
    return $found
}

# 32 hex characters, which need no quoting in a URL or a .env.
function RandomPassword {
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

# Everything written here holds secrets, so only the person running this may
# read it. Best effort: a filesystem without ACLs keeps whatever it had.
function MakePrivate {
    param([string]$Path)

    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, "FullControl", "Allow")))
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-Host "   (Could not restrict who may read ${Path}: $($_.Exception.Message))"
    }
}

function AskYesNo {
    param([string]$Prompt, [string]$Default = "n")

    if ($Default -eq "y") { $shown = "$Prompt [Y/n]" } else { $shown = "$Prompt [y/N]" }
    $answer = Read-Host $shown
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    return ($answer.Trim().ToLower().StartsWith("y"))
}

Write-Host ""
Write-Host "Setting up Slipdock. Five questions, then a .env you can edit by hand"
Write-Host "afterwards. Press enter to take the suggestion in brackets."
Write-Host ""

$dbPassword = ""; $keepDbDefault = $false
if (Test-Path -LiteralPath $EnvFile) {
    Write-Host "There is already a $EnvFile here."
    if (-not (AskYesNo "Replace it? (a copy is kept as $EnvFile.bak)" "n")) {
        Write-Host "Left alone. Nothing written."
        exit 0
    }
    Copy-Item -LiteralPath $EnvFile -Destination "$EnvFile.bak" -Force
    MakePrivate "$EnvFile.bak"
    Write-Host "Kept the old one as $EnvFile.bak."
    # Postgres sets its password once, when its volume is first created, so an
    # install that already has one keeps it, and one still on the default
    # stays there rather than being locked out.
    $dbPassword = EnvValue $EnvFile "POSTGRES_PASSWORD"
    if ($dbPassword -eq "") { $keepDbDefault = $true }
    Write-Host ""
}

# 1 - the name people type -----------------------------------------------------
Write-Host "1. The hostname people will see in the browser's address bar."
Write-Host "   Not the domain you own - the exact name they type. If Cloudflare or"
Write-Host "   nginx serves this at app.example.com, that is the answer, even when"
Write-Host "   you also own example.com."
Write-Host "   Sign-in links are built from it, and live updates are refused for any"
Write-Host "   other name, so this is the setting that most needs to be right."

$fallback = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($fallback)) { $fallback = "localhost" }
$slipHost = Ask "   Hostname" $fallback
while ([string]::IsNullOrWhiteSpace($slipHost)) {
    $slipHost = Ask "   Hostname (required)" ""
}

# 2 - what sits in front -------------------------------------------------------
Write-Host ""
Write-Host "2. Is there a TLS proxy in front of it - Cloudflare, Caddy, nginx, a"
Write-Host "   tunnel? Answer yes if people reach it over https."
$proxied = AskYesNo "   Behind https" "n"

if ($proxied) {
    $scheme = "https"
    $urlPort = Ask "   Port people connect to" "443"
} else {
    $scheme = "http"
    $urlPort = ""
}

# 3 - the port this machine listens on -----------------------------------------
Write-Host ""
Write-Host "3. The port on *this* machine for Slipdock to listen on."
if ($proxied) {
    Write-Host "   Your proxy forwards to it. It does not need to be reachable from"
    Write-Host "   outside, so the suggestion listens on this machine only. If the"
    Write-Host "   proxy is on another machine, answer 4000 to listen on every address."
    $publish = Ask "   Listen on" "127.0.0.1:4000"
} else {
    $publish = Ask "   Listen on" "4000"
}

# With nothing in front, the port people connect to is the one it listens on.
if (-not $proxied) {
    $urlPort = ($publish -split ":")[-1]
}

# 4 - who runs it --------------------------------------------------------------
Write-Host ""
Write-Host "4. Your email address. Setting it makes you the admin and skips the"
Write-Host "   browser setup wizard; leave it empty to use the wizard instead."
$admin = Ask "   Admin email" ""

# 5 - mail ---------------------------------------------------------------------
Write-Host ""
Write-Host "5. A mail server, so sign-in codes can be emailed. Without one they are"
Write-Host "   written to the log, which is fine for a server only you use."
$wantMail = AskYesNo "   Set up email now" "n"

$smtpHost = ""; $smtpPort = ""; $smtpUser = ""; $smtpPass = ""; $smtpFrom = ""
if ($wantMail) {
    $smtpHost = Ask "   SMTP host" ""
    $smtpPort = Ask "   SMTP port" "587"
    if ($admin -ne "") { $fromDefault = $admin } else { $fromDefault = "slipdock@$slipHost" }
    $smtpFrom = Ask "   Send from" $fromDefault
    $smtpUser = Ask "   Username (empty for an IP-authorised relay)" ""
    if ($smtpUser -ne "") { $smtpPass = AskSecret "   Password (not shown)" }
}

# The bundled Postgres' password: a random one for a new install rather than
# the published default.
if ($dbPassword -eq "" -and -not $keepDbDefault) { $dbPassword = RandomPassword }

# - write it out ---------------------------------------------------------------
$stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Written by setup.ps1 on $stamp.")
$lines.Add("# Edit freely; .env.example lists every setting with its default.")
$lines.Add("#")
$lines.Add("# After changing anything here: docker compose up -d")
$lines.Add("# Not 'restart' - that reuses the container and re-reads nothing.")
$lines.Add("")
$lines.Add("PHX_HOST=$slipHost")
$lines.Add("SLIPDOCK_PUBLISH=$publish")
$lines.Add("SLIPDOCK_URL_SCHEME=$scheme")
$lines.Add("SLIPDOCK_URL_PORT=$urlPort")
if ($admin -ne "") { $lines.Add("SLIPDOCK_ADMIN_EMAIL=$admin") }
$lines.Add("")
if ($keepDbDefault) {
    $lines.Add("# The database password is still compose.yaml's default. Postgres only")
    $lines.Add("# reads POSTGRES_PASSWORD when its volume is first created, so change it")
    $lines.Add("# with ALTER USER inside the database before setting it here.")
} else {
    $lines.Add("# Read by Postgres once, when its volume is first created; see compose.yaml.")
    $lines.Add("POSTGRES_PASSWORD=$dbPassword")
}
if ($smtpHost -ne "") {
    $lines.Add("")
    $lines.Add("SLIPDOCK_SMTP_HOST=$smtpHost")
    $lines.Add("SLIPDOCK_SMTP_PORT=$smtpPort")
    $lines.Add("SLIPDOCK_SMTP_FROM=$smtpFrom")
    if ($smtpUser -ne "") { $lines.Add("SLIPDOCK_SMTP_USER=$smtpUser") }
    if ($smtpPass -ne "") { $lines.Add("SLIPDOCK_SMTP_PASSWORD=$smtpPass") }
}

# LF endings and no BOM, deliberately. Docker Compose keeps a trailing carriage
# return as part of the value, so a CRLF .env written on Windows yields a
# hostname with an invisible \r on the end and an error nobody can read.
$text = ($lines -join "`n") + "`n"
$envPath = Join-Path (Get-Location).Path $EnvFile
# Created empty and made private first, so the secrets never sit in a file
# anybody else can read.
[System.IO.File]::WriteAllText($envPath, "", (New-Object System.Text.UTF8Encoding $false))
MakePrivate $envPath
[System.IO.File]::WriteAllText($envPath, $text, (New-Object System.Text.UTF8Encoding $false))

Write-Host ""
Write-Host "Written ${EnvFile}:"
Write-Host ""
foreach ($line in $lines) {
    if ($line -like "SLIPDOCK_SMTP_PASSWORD=*") {
        Write-Host "    SLIPDOCK_SMTP_PASSWORD=********"
    } elseif ($line -like "POSTGRES_PASSWORD=*") {
        Write-Host "    POSTGRES_PASSWORD=********"
    } else {
        Write-Host "    $line"
    }
}

# ${} around each name: a bare "$slipHost:" reads as a scope qualifier.
if ($urlPort -eq "443" -or $urlPort -eq "80") { $shownUrl = "${scheme}://${slipHost}" }
else { $shownUrl = "${scheme}://${slipHost}:${urlPort}" }

Write-Host ""
Write-Host "Slipdock will answer to $shownUrl"
Write-Host ""
Write-Host "Next:"
Write-Host "    docker compose up -d"
Write-Host "    docker compose logs -f slipdock"
Write-Host ""
if ($admin -eq "") {
    Write-Host "The log will show a setup wizard link with a one-time token. Open it."
} else {
    Write-Host "You are the admin ($admin). Ask for a sign-in code at the login page;"
    Write-Host "with no mail server configured it is written to the log."
}
Write-Host ""
