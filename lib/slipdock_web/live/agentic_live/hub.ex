defmodule SlipdockWeb.AgenticLive.Hub do
  @moduledoc """
  The four places the Agentic Building page leads to (#2012): Runners,
  Findings, Ledger and Health, each with a count that says whether it needs
  a look, read from the board's tree.

  `counts/1` reads them; `tiles/2` turns them into what the page draws:
  each tile's key, title, icon, path, the number and the line under it,
  and `attention` (`:warning`, `:info` or nil) for a tile that needs a look.
  """
  use SlipdockWeb, :verified_routes

  import Ecto.Query

  alias Slipdock.{Findings, Health, Ledger, Repo, Runners}
  alias Slipdock.Boards.Board
  alias Slipdock.Runners.Job

  @doc "The counts for `board`'s tree."
  def counts(%Board{} = board) do
    runners = Runners.list_runners(board)
    root = Board.root_id(board)

    jobs =
      from(j in Job,
        where: j.root_board_id == ^root and j.status in ~w(queued claimed running),
        group_by: j.status,
        select: {j.status, count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    active = Health.list_active(board)

    %{
      runners: length(runners),
      online: Enum.count(runners, &Runners.online?/1),
      running: Map.get(jobs, "claimed", 0) + Map.get(jobs, "running", 0),
      queued: Map.get(jobs, "queued", 0),
      findings:
        case Findings.list(board) do
          {:ok, open} -> length(open)
          _ -> 0
        end,
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
        number: "#{c.findings}",
        unit: "open",
        line: if(c.findings == 0, do: "Nothing to triage", else: "To promote, merge or dismiss"),
        attention: if(c.findings > 0, do: :info)
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
end
