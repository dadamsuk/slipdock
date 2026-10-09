defmodule SlipdockWeb.InstallController do
  @moduledoc """
  `GET /install.sh` — a POSIX shell script that sets an agent up against *this*
  server: the skills in `~/.claude/skills`, and this server's address saved
  where the skills and the CLI both look for it.

  It needs no token, for the same reason the guide and the skills need none:
  what it installs says how to talk to the API, not what is on it. And it needs
  nothing installed beyond `curl` and `tar`, which is the whole point — the
  `slipdock` CLI is an escript and wants Erlang, which the person whose agent
  wants a board usually has not got.

  `GET /install.ps1` is the same for Windows, in PowerShell: the skills in
  `%USERPROFILE%\\.claude\\skills`, where Claude Code and Claude Desktop on
  Windows look. `install.sh` run under WSL would put them in the WSL home
  instead, which Windows' Claude never reads.

  Served as plain text, not a download, so the script can be read before it is
  run. Anybody who would rather not pipe a script into a shell
  does not have to: paste the prompt from **Set up an agent** instead and the
  agent reads `/api/guide` for itself.
  """
  use SlipdockWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, script(SlipdockWeb.BaseURL.from_conn(conn)))
  end

  # BaseURL already refuses a Host that is not a plain name, so this is the
  # second lock: inside single quotes nothing but a quote means anything.
  defp shell_quote(value), do: String.replace(value, "'", ~S('\''))

  def powershell(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, powershell_script(SlipdockWeb.BaseURL.from_conn(conn)))
  end

  # The same second lock for PowerShell: in a single-quoted string only a
  # quote means anything, and it is doubled.
  defp ps_quote(value), do: String.replace(value, "'", "''")

  # Run as `irm …/install.ps1 | iex`, so it sets no preference and calls no
  # exit: either would land in the person's own PowerShell session.
  defp powershell_script(base) do
    """
    # Set an agent up to work the boards on #{base}, on Windows.
    #
    #   irm #{base}/install.ps1 | iex
    #       into %USERPROFILE%\\.claude\\skills
    #   & ([scriptblock]::Create((irm #{base}/install.ps1))) -Dir C:\\somewhere\\else
    #
    # It writes two things and nothing else:
    #   DIR\\slipdock*\\              the agent skills this server ships
    #   ~\\.config\\slipdock\\url      this server's address, so you need not repeat it
    #                              (unless it already names another server)
    #
    # It does not sign you in. Your agent does that itself.
    param([string]$Dir)

    $Base = '#{ps_quote(base)}'
    if (-not $Dir) {
      $Dir = if ($env:SLIPDOCK_SKILLS_DIR) { $env:SLIPDOCK_SKILLS_DIR } else { Join-Path $HOME '.claude\\skills' }
    }

    if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
      throw 'slipdock: tar.exe is needed (Windows 10 1803 and later have it) and was not found'
    }

    New-Item -ItemType Directory -Force -Path $Dir -ErrorAction Stop | Out-Null
    $Archive = Join-Path ([IO.Path]::GetTempPath()) ('slipdock-skills-' + [guid]::NewGuid() + '.tar.gz')
    try {
      Invoke-WebRequest -UseBasicParsing -Uri "$Base/api/skills.tar.gz" -OutFile $Archive -ErrorAction Stop
      tar.exe -xzf $Archive -C $Dir
      if ($LASTEXITCODE -ne 0) { throw 'slipdock: tar could not unpack the skills' }
    } finally {
      Remove-Item -Force -ErrorAction SilentlyContinue $Archive
    }

    # A url already pointing somewhere else is left alone: the token beside it
    # belongs to that server.
    $Conf = Join-Path $HOME '.config\\slipdock'
    New-Item -ItemType Directory -Force -Path $Conf -ErrorAction Stop | Out-Null
    $UrlFile = Join-Path $Conf 'url'
    $Current = if (Test-Path $UrlFile) { (Get-Content -Raw $UrlFile).Trim() } else { '' }
    if (-not $Current) {
      Set-Content -Path $UrlFile -Value $Base -Encoding ascii
    } elseif ($Current -ne $Base) {
      Write-Warning "slipdock: $UrlFile already names $Current; left it alone."
    }

    Write-Host "Installed the Slipdock skills for ${Base}:"
    Get-ChildItem -Directory -Path $Dir -Filter 'slipdock*' | ForEach-Object { Write-Host "  $($_.FullName)" }
    """
  end

  defp script(base) do
    """
    #!/bin/sh
    # Set an agent up to work the boards on #{base}.
    #
    #   curl -fsSL #{base}/install.sh | sh          # into ~/.claude/skills
    #   curl -fsSL #{base}/install.sh | sh -s DIR   # somewhere else
    #
    # It writes two things and nothing else:
    #   DIR/slipdock*/           the agent skills this server ships
    #   ~/.config/slipdock/url   this server's address, so you need not repeat it
    #                            (unless it already names another server)
    #
    # It does not sign you in. Your agent does that itself, and will have to
    # before it can see any of your boards: it shows you a code, you approve it
    # at #{base}/activate, and the token lands in ~/.config/slipdock/token.
    set -eu

    BASE='#{shell_quote(base)}'
    DIR="${1:-${SLIPDOCK_SKILLS_DIR:-$HOME/.claude/skills}}"

    for tool in curl tar; do
      command -v "$tool" >/dev/null 2>&1 || {
        echo "slipdock: $tool is needed and was not found" >&2
        exit 1
      }
    done

    mkdir -p "$DIR"
    curl -fsSL "$BASE/api/skills.tar.gz" | tar -xzf - -C "$DIR"

    # A url already pointing somewhere else is left alone: the token beside it
    # belongs to that server, and quietly re-pointing it would send the token
    # here on the next call.
    CONF="$HOME/.config/slipdock"
    mkdir -p "$CONF"
    chmod 700 "$CONF"
    CURRENT="$(cat "$CONF/url" 2>/dev/null || true)"
    if [ -z "$CURRENT" ]; then
      (umask 077 && printf '%s\\n' "$BASE" > "$CONF/url")
    elif [ "$CURRENT" != "$BASE" ]; then
      echo "slipdock: $CONF/url already names $CURRENT; left it alone." >&2
      echo "  To switch to this server: slipdock url $BASE" >&2
    fi

    echo "Installed the Slipdock skills for $BASE:"
    for skill in "$DIR"/slipdock "$DIR"/slipdock-*; do
      [ -d "$skill" ] && echo "  $skill"
    done
    cat <<'NEXT'

    Next, in a session with your agent:

      Work from my Slipdock board. Read the guide at the address in
      ~/.config/slipdock/url and follow it.

    Your boards need a sign-in before it can read them, let alone change
    anything, so it should ask you to approve a code straight away.
    NEXT
    """
  end
end
