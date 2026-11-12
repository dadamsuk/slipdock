defmodule SlipdockWeb.AgenticLive.Hub do
  @moduledoc """
  The places the Agentic Building page leads to (#2012): Right now (#2103),
  Runners, Findings, Ledger and Health, each with a count that says whether
  it needs a look, read from the board's tree. Findings counts the proposals
  drafted from them, which wait on a person, not the open findings, which
  triage and the server handle (#2123).

  `counts/1` reads them; `tiles/2` turns them into what the page draws:
  each tile's key, title, icon, path, the number and the line under it,
  and `attention` (`:warning`, `:info` or nil) for a tile that needs a look.
  """
  use SlipdockWeb, :verified_routes

  alias Slipdock.{Findings, Health, Ledger, Now, Runners}
  alias Slipdock.Findings.Awaiting
  alias Slipdock.Boards.Board

  @doc "The counts for `board`'s tree."
  def counts(%Board{} = board) do
    runners = Runners.list_runners(board)
    root = Board.root_id(board)

    jobs = Runners.active_job_counts(root)

    active = Health.list_active(board)
    now = Now.counts(board)

    %{
      working: now.working,
      in_progress: now.in_progress,
      runners: length(runners),
      online: Enum.count(runners, &Runners.online?/1),
      running: Map.get(jobs, "claimed", 0) + Map.get(jobs, "running", 0),
      queued: Map.get(jobs, "queued", 0),
      findings:
        case Findings.list(board) do
          {:ok, open} -> length(open)
          _ -> 0
        end,
      proposals: Awaiting.count(board),
      shipped:
        case Ledger.since(board) do
          {:ok, ledger} -> ledger.count
          _ -> 0
        end,
      stuck: length(active),
      flagged: Enum.count(active, &(&1.status == "flagged"))
    }
  end

  @doc "The tiles the page draws, from `counts/1`."
  def tiles(%Board{} = board, c) do
    [
      %{
        key: "now",
        title: "Right now",
        icon: "hero-bolt",
        path: ~p"/boards/#{board}/now",
        number: "#{c.working}",
        unit: "working",
        line: now_line(c),
        attention: nil
      },
      %{
        key: "runners",
        title: "Runners",
        icon: "hero-cpu-chip",
        path: ~p"/boards/#{board}/automations",
        number: "#{c.online}/#{c.runners}",
        unit: "online",
        line: runners_line(c),
        attention: runners_attention(c)
      },
      %{
        key: "findings",
        title: "Findings",
        icon: "hero-light-bulb",
        path: ~p"/boards/#{board}/findings",
        # What waits on the person (#2123): the proposals drafted from
        # findings. The open findings are being handled, so they are the line.
        number: "#{c.proposals}",
        unit: if(c.proposals == 1, do: "proposal", else: "proposals"),
        line: findings_line(c),
        attention: if(c.proposals > 0, do: :info)
      },
      %{
        key: "ledger",
        title: "Ledger",
        icon: "hero-document-check",
        path: ~p"/boards/#{board}/ledger",
        number: "#{c.shipped}",
        unit: "shipped",
        line: if(c.shipped == 0, do: "Nothing since yesterday", else: "Since 07:00 yesterday"),
        attention: if(c.shipped > 0, do: :info)
      },
      %{
        key: "health",
        title: "Health",
        icon: "hero-lifebuoy",
        path: ~p"/boards/#{board}/health",
        number: "#{c.stuck}",
        unit: "stuck",
        line: health_line(c),
        attention:
          cond do
            c.flagged > 0 -> :warning
            c.stuck > 0 -> :info
            true -> nil
          end
      }
    ]
  end

  # Right now's line (#2103): the cards in progress and the jobs queued.
  defp now_line(%{in_progress: 0, queued: 0}), do: "Nothing in progress"

  defp now_line(c) do
    cards =
      if c.in_progress == 1, do: "1 card in progress", else: "#{c.in_progress} cards in progress"

    "#{cards}, #{c.queued} queued"
  end

  defp runners_line(%{runners: 0}), do: "None connected yet"

  defp runners_line(c) do
    jobs = if c.running == 1, do: "1 job running", else: "#{c.running} jobs running"
    if c.queued > 0, do: "#{jobs}, #{c.queued} queued", else: jobs
  end

  # No runner online with work waiting for one is what needs a look.
  defp runners_attention(%{runners: n, online: 0, queued: q}) when n > 0 and q > 0, do: :warning
  defp runners_attention(%{runners: n, online: 0}) when n > 0, do: :info
  defp runners_attention(_c), do: nil

  defp health_line(%{stuck: 0}), do: "All clear"
  defp health_line(%{flagged: 0}), do: "The monitor is trying fixes"
  defp health_line(%{flagged: 1}), do: "1 needs a person"
  defp health_line(%{flagged: f}), do: "#{f} need a person"

  defp findings_line(%{proposals: p, findings: f}) do
    waiting = if p == 0, do: "Nothing waiting on you", else: "To apply or dismiss"

    handling =
      if f == 0, do: nil, else: "#{f} #{if f == 1, do: "finding", else: "findings"} being handled"

    Enum.join(Enum.reject([waiting, handling], &is_nil/1), " · ")
  end
end
