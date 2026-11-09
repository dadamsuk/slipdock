defmodule SlipdockWeb.RetiredRunnerController do
  @moduledoc """
  Where the shell and PowerShell runners, their installers, checksums and
  hook examples were served (`/runner/install.sh`, `/runner/install.ps1`,
  `/runner/slipdock-runner`, `/runner/slipdock-runner.ps1`,
  `/runner/SHA256SUMS`, `/runner/examples/…`). They were retired for the
  runner daemon (#2582, W-2544 §10), so every path under `/runner/` answers
  410 Gone, saying where to go instead.

  The body is comment lines only, in both shells' syntax: `curl -fsSL … | sh`
  and `irm … | iex` stop at the 410, and a pipe without `-f` runs nothing.
  A shell runner still installed keeps its last script, but can no longer
  update itself or be installed again: it moves onto a machine (W-1951
  §Runbooks, *Moving a machine's runners onto the daemon*).
  """
  use SlipdockWeb, :controller

  def gone(conn, _params) do
    machines = url(conn, ~p"/account/machines")

    body = """
    # Gone: the shell and PowerShell runners were retired for the runner daemon (#2582).
    # Install the daemon and enrol the machine from Account > Machines: #{machines}
    # The manual's Machines page says how: docs/manual/machines.md
    """

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(410, body)
  end
end
