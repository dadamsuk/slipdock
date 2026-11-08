defmodule SlipdockWeb.AgenticHubTest do
  @moduledoc """
  Findings, Ledger, Health and Runners reached from the Agentic Building
  page (#2012): its tiles with their counts, links and whether each
  needs a look; the way back from Findings, Ledger and Health; the Runners
  header without its old buttons; and the pages still opening by URL with
  the switch off.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo, Runners}
  alias Slipdock.Boards.Card
  alias Slipdock.Findings.Finding
  alias Slipdock.Health.Incident
  alias Slipdock.Runners.{Job, Runner}
  alias SlipdockWeb.AgenticLive.Hub

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Hub", "code" => unique_code()}, owner: owner)
    {:ok, board} = Boards.update_board(board, %{"agentic_building" => true})
    %{board: board, owner: owner}
  end

  defp runner(board, pool, seen) do
    {:ok, runner, _token} = Runners.create_runner(board, %{"name" => "r-#{pool}", "pool" => pool})
    Repo.update!(Ecto.Changeset.change(runner, last_seen_at: seen))
  end

  defp job(board, card, status) do
    Repo.insert!(%Job{
      board_id: board.id,
      root_board_id: board.id,
      card_id: card.id,
      pool: "dev",
      kind: "claude",
      prompt: "Work it",
      status: status
    })
  end

  defp shipped(board) do
    card = card_fixture(List.last(board.columns), %{"title" => "Shipped"})
    at = DateTime.add(DateTime.utc_now(:second), -3600, :second)

    Repo.update_all(from(c in Card, where: c.id == ^card.id),
      set: [completed: true, completed_at: at]
    )

    card
  end

  defp tile(view, key), do: "#agentic-tile-#{key}"

  test "a quiet board: five tiles, each linking its page, none asking for a look", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")

    for {key, path} <- [
          {"now", "/boards/#{ctx.board.id}/now"},
          {"runners", "/boards/#{ctx.board.id}/automations"},
          {"findings", "/boards/#{ctx.board.id}/findings"},
          {"ledger", "/boards/#{ctx.board.id}/ledger"},
          {"health", "/boards/#{ctx.board.id}/health"}
        ],
        do: assert(has_element?(view, ~s(#{tile(view, key)}[href="#{path}"])))

    assert has_element?(view, "#{tile(view, "runners")} [data-role=tile-line]", "None connected")
    assert has_element?(view, "#{tile(view, "findings")} [data-role=tile-number]", "0")
    assert has_element?(view, "#{tile(view, "ledger")} [data-role=tile-line]", "Nothing since")
    assert has_element?(view, "#{tile(view, "health")} [data-role=tile-line]", "All clear")
    refute has_element?(view, "#agentic-hub [data-attention]")
  end

  test "each tile counts its place and says when it needs a look", ctx do
    card = card_fixture(hd(ctx.board.columns), %{"title" => "Work"})
    runner(ctx.board, "dev", DateTime.utc_now(:second))
    runner(ctx.board, "old", DateTime.add(DateTime.utc_now(:second), -86_400, :second))
    job(ctx.board, card, "running")
    job(ctx.board, card, "queued")
    job(ctx.board, card, "done")

    for status <- ~w(open open dismissed),
        do:
          Repo.insert!(%Finding{
            board_id: ctx.board.id,
            card_id: card.id,
            kind: "gotcha",
            source: "agent",
            text: "a lesson #{System.unique_integer()}",
            status: status
          })

    shipped(ctx.board)
    shipped(ctx.board)

    for status <- ~w(open flagged fixed),
        do:
          Repo.insert!(%Incident{
            board_id: ctx.board.id,
            detector: "probe",
            fingerprint: "f#{System.unique_integer()}",
            summary: "Stuck #{status}",
            status: status
          })

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")

    assert has_element?(view, "#{tile(view, "runners")} [data-role=tile-number]", "1/2")

    assert has_element?(
             view,
             "#{tile(view, "runners")} [data-role=tile-line]",
             "1 job running, 1 queued"
           )

    assert has_element?(view, "#{tile(view, "findings")} [data-role=tile-number]", "2")
    assert has_element?(view, ~s(#{tile(view, "findings")}[data-attention="info"]))
    assert has_element?(view, "#{tile(view, "ledger")} [data-role=tile-number]", "2")
    assert has_element?(view, "#{tile(view, "health")} [data-role=tile-number]", "2")
    assert has_element?(view, "#{tile(view, "health")} [data-role=tile-line]", "1 needs a person")
    assert has_element?(view, ~s(#{tile(view, "health")}[data-attention="warning"]))
  end

  test "runners all offline with work queued is a warning; offline and idle only a dot", ctx do
    card = card_fixture(hd(ctx.board.columns), %{"title" => "Work"})
    runner(ctx.board, "dev", DateTime.add(DateTime.utc_now(:second), -86_400, :second))

    c = Hub.counts(ctx.board)
    assert {c.runners, c.online, c.queued} == {1, 0, 0}
    assert Enum.find(Hub.tiles(ctx.board, c), &(&1.key == "runners")).attention == :info

    job(ctx.board, card, "queued")
    c = Hub.counts(ctx.board)
    assert Enum.find(Hub.tiles(ctx.board, c), &(&1.key == "runners")).attention == :warning
  end

  test "the counts are read again while the page is open", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
    assert has_element?(view, "#{tile(view, "ledger")} [data-role=tile-number]", "0")

    shipped(ctx.board)
    send(view.pid, :hub)
    assert has_element?(view, "#{tile(view, "ledger")} [data-role=tile-number]", "1")
  end

  test "Findings, Ledger and Health lead back to Agentic Building beside the board", ctx do
    for page <- ~w(findings ledger health) do
      {:ok, view, _} = live(ctx.conn, "/boards/#{ctx.board.id}/#{page}")
      assert has_element?(view, ~s(#agentic-back[href="/boards/#{ctx.board.id}/agentic"]))
    end

    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/agentic")
    refute has_element?(view, "#agentic-back")
  end

  test "with the switch off the pages still open, with no way back to a hidden page", ctx do
    {:ok, board} = Boards.update_board(ctx.board, %{"agentic_building" => false})

    for page <- ~w(findings ledger health) do
      {:ok, view, _} = live(ctx.conn, "/boards/#{board.id}/#{page}")
      refute has_element?(view, "#agentic-back")
    end
  end

  test "the Runners header no longer carries Findings, Ledger and Health", ctx do
    {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/automations")
    assert has_element?(view, "#board-runners")

    for id <- ~w(runners-findings runners-ledger runners-health),
        do: refute(has_element?(view, "##{id}"))
  end

  test "a runner is online when seen within three of its leases" do
    now = DateTime.utc_now(:second)
    refute Runners.online?(%Runner{last_seen_at: nil})
    assert Runners.online?(%Runner{last_seen_at: now})
    refute Runners.online?(%Runner{last_seen_at: DateTime.add(now, -3600, :second)})
  end

  test "the help pages send people to the tiles, not the Runners panel" do
    for file <- ~w(guides flow) do
      text =
        "lib/slipdock_web/live/help_live/#{file}.ex"
        |> File.read!()
        |> String.replace(~r/\s+/, " ")

      refute text =~ "beside <em>Health</em>", file
      refute text =~ "beside <em>Findings</em>", file
      assert text =~ "<em>Agentic Building</em>", file
    end
  end
end
