defmodule SlipdockWeb.WikiTreePerfTest do
  @moduledoc """
  The tree with a 10,000-page wiki (W-103 R11.2): a first draw and opening a
  folder of 5,000 notes stay quick, and neither ever reads a page's body.

  The targets are 200 ms for the first draw and 100 ms to open a folder.
  CI machines are slower and busier than the ones people read on, so the
  bounds asserted here are looser. They catch the tree going back to loading
  everything, which costs seconds at this size, without failing on a slow
  runner. The body check is the strict one.
  """
  use SlipdockWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import SlipdockWeb.WikiTreeHelpers

  alias Slipdock.Repo
  alias Slipdock.Wiki
  alias Slipdock.Wiki.Page

  @moduletag timeout: 300_000

  setup %{user: user} do
    board = board_fixture(%{"name" => "Big", "code" => "bigtree"}, owner: user)
    {:ok, inbox} = Wiki.create_folder(board, %{"name" => "Inbox"})
    topics = for n <- 1..50, do: elem(Wiki.create_folder(board, %{"name" => "Topic #{n}"}), 1)

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    tag = System.unique_integer([:positive])
    body = String.duplicate("A paragraph of a note that is long enough to matter. ", 40)

    row = fn n, folder_id ->
      %{
        board_id: board.id,
        folder_id: folder_id,
        title: "Note #{n}",
        slug: "note-#{n}",
        code: "PT#{tag}-#{n}",
        number: n,
        body: body,
        position: n,
        status: "published",
        content_hash: "x",
        inserted_at: now,
        updated_at: now
      }
    end

    rows =
      for(n <- 1..5000, do: row.(n, inbox.id)) ++
        for {folder, i} <- Enum.with_index(topics),
            n <- 1..100,
            do: row.(5000 + i * 100 + n, folder.id)

    rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all(Page, &1))
    assert Repo.aggregate(Page, :count) >= 10_000
    # What autovacuum does after a bulk import: without it, the planner takes
    # the pages table for the few rows it held before, and joins it to itself
    # row by row.
    Repo.query!("ANALYZE pages")

    %{board: board, inbox: inbox}
  end

  # Milliseconds `fun` takes, best of three: the first run warms caches a
  # reader's second visit would have warm too.
  defp best_of_three(fun) do
    1..3
    |> Enum.map(fn _ ->
      {us, _} = :timer.tc(fun)
      div(us, 1000)
    end)
    |> Enum.min()
  end

  defp body_reads(pid, fun) do
    test = self()
    id = "tree-body-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:slipdock, :repo, :query],
      fn _event, _measure, meta, _ ->
        if meta.source == "pages" and self() == pid and meta.query =~ ~r/\."body"/,
          do: send(test, {:body_read, id, meta.query})
      end,
      nil
    )

    try do
      fun.()
      receive_all(id, [])
    after
      :telemetry.detach(id)
    end
  end

  defp receive_all(id, acc) do
    receive do
      {:body_read, ^id, q} -> receive_all(id, [q | acc])
    after
      0 -> acc
    end
  end

  test "the first draw and opening a 5,000-note folder stay quick", %{
    conn: conn,
    board: board,
    inbox: inbox
  } do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{"note-1"}")

    first = best_of_three(fn -> tree_load(view) end)
    reply = tree_load(view)
    assert length(reply.nodes["root"]) == 51
    assert %{pages: 5000, count: 5000} = row(reply, "root", "Inbox")
    refute reply.small

    open =
      best_of_three(fn ->
        tree_load(view, %{"keys" => ["folder:#{inbox.id}"], "only" => true})
      end)

    rows =
      tree_load(view, %{"keys" => ["folder:#{inbox.id}"], "only" => true}).nodes[
        "folder:#{inbox.id}"
      ]

    # A page of rows, and where to ask for the rest.
    assert length(rows) == 501
    assert %{kind: "more", offset: 500} = List.last(rows)

    index = best_of_three(fn -> {:ok, _, _} = live(conn, ~p"/boards/#{board}/wiki") end)

    IO.puts(
      "\n    tree with 10,000 pages: first draw #{first} ms, " <>
        "open a 5,000-note folder #{open} ms, the wiki's index #{index} ms"
    )

    assert first < 1_000
    assert open < 1_000
    assert index < 2_000
  end

  test "the tree never reads a page's body", %{conn: conn, board: board, inbox: inbox} do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/wiki/#{"note-1"}")

    reads =
      body_reads(view.pid, fn ->
        tree_load(view)
        tree_load(view, %{"keys" => ["folder:#{inbox.id}"], "only" => true})
        tree_load(view, %{"all" => true})
        render_hook(view, "tree_children", %{"key" => "folder:#{inbox.id}", "offset" => 500})
        view |> form("#wiki-search") |> render_change(%{"q" => "note 42"})
        tree_load(view)
      end)

    assert reads == []
  end
end
