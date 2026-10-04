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

    BASE="#{base}"
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
