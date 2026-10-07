defmodule Slipdock.Search.EmbeddingTest do
  @moduledoc """
  What ends up in the index and what does not: the `Embedding` schema itself,
  the paths into it (cards, comments, status updates, pages, the queue), and
  every way the embedding model can let it down. The model is
  `Slipdock.AIStub` throughout; nothing leaves the machine.
  """
  # Sync: drives `Slipdock.Search.Indexer`, one queue for the node in a process
  # started at boot, so the AI stub has to be shared (see CONTRIBUTING.md).
  use Slipdock.DataCase, async: false

  import ExUnit.CaptureLog
  import Slipdock.Fixtures

  alias Slipdock.{AI, AIStub, Boards, Search}
  alias Slipdock.AI.Embeddings
  alias Slipdock.Search.{Embedding, Indexer, Vector}

  setup do
    AIStub.share()
    AIStub.stub_embeddings()

    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Delivery"}, owner: owner)

    %{owner: owner, board: board, column: hd(board.columns)}
  end

  defp rows_for(card_id),
    do: Repo.all(from(e in Embedding, where: e.card_id == ^card_id, order_by: e.kind))

  defp page_rows(page_id), do: Repo.all(from(e in Embedding, where: e.page_id == ^page_id))

  # Answers every embedding call with `fun.(decoded_body)` as the JSON reply.
  defp stub_embedding_reply(fun) do
    Req.Test.stub(Slipdock.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Req.Test.json(conn, fun.(Jason.decode!(body)))
    end)
  end

  defp put_ai_config(changes) do
    previous = Application.get_env(:slipdock, :ai)
    Application.put_env(:slipdock, :ai, Keyword.merge(previous, changes))
    on_exit(fn -> Application.put_env(:slipdock, :ai, previous) end)
  end

  describe "the schema" do
    setup ctx, do: %{card: card_fixture(ctx.column, %{"title" => "Indexed"})}

    defp valid_attrs(%{board: board, card: card}) do
      %{
        kind: "card",
        source_id: card.id,
        card_id: card.id,
        board_id: board.id,
        body: "Board: Delivery\nSomething",
        content_hash: "abc",
        model: "test/embed",
        dimensions: 2,
        vector: Vector.pack([1.0, 0.0])
      }
    end

    test "a complete chunk is valid and section defaults to empty", ctx do
      changeset = Embedding.changeset(%Embedding{}, valid_attrs(ctx))
      assert changeset.valid?

      {:ok, row} = Repo.insert(changeset)
      assert row.section == ""
      assert Vector.unpack(row.vector) == [1.0, 0.0]
    end

    test "every stored field is required", ctx do
      changeset = Embedding.changeset(%Embedding{}, %{section: "x"})
      refute changeset.valid?

      required = ~w(kind source_id board_id body content_hash model dimensions vector)a
      assert Enum.sort(Keyword.keys(changeset.errors)) == Enum.sort(required)

      # And none of them is required on its own account only.
      assert Embedding.changeset(%Embedding{}, Map.delete(valid_attrs(ctx), :vector)).errors ==
               [vector: {"can't be blank", [validation: :required]}]
    end

    test "an unknown kind is refused", ctx do
      changeset = Embedding.changeset(%Embedding{}, %{valid_attrs(ctx) | kind: "attachment"})
      assert {"is invalid", _} = changeset.errors[:kind]
    end

    test "one row per kind, source and section — a duplicate is an error, not a crash",
         ctx do
      {:ok, _} = Repo.insert(Embedding.changeset(%Embedding{}, valid_attrs(ctx)))

      assert {:error, changeset} =
               Repo.insert(Embedding.changeset(%Embedding{}, valid_attrs(ctx)))

      assert {"has already been taken", _} = changeset.errors[:kind]

      # A different section of the same source is a different chunk.
      assert {:ok, _} =
               Repo.insert(
                 Embedding.changeset(%Embedding{}, Map.put(valid_attrs(ctx), :section, "Setup"))
               )
    end

    test "a chunk belongs to exactly one of a card or a page", ctx do
      page = page_fixture(ctx.board, %{"title" => "Runbook"})

      for attrs <- [
            %{valid_attrs(ctx) | card_id: nil},
            Map.put(valid_attrs(ctx), :page_id, page.id)
          ] do
        assert {:error, changeset} = Repo.insert(Embedding.changeset(%Embedding{}, attrs))
        assert {"must belong to exactly one of a card or a page", _} = changeset.errors[:card_id]
      end

      page_attrs =
        Map.merge(valid_attrs(ctx), %{
          kind: "page",
          source_id: page.id,
          card_id: nil,
          page_id: page.id
        })

      assert {:ok, %Embedding{page_id: page_id, card_id: nil}} =
               Repo.insert(Embedding.changeset(%Embedding{}, page_attrs))

      assert page_id == page.id
    end

    test "kinds, labels and which kinds are pages" do
      assert Embedding.kinds() == ~w(card comment status_update page page_section)

      assert Enum.map(Embedding.kinds(), &Embedding.label/1) ==
               ["card", "comment", "status update", "page", "page section"]

      # Something the schema does not know is shown as it is rather than raising.
      assert Embedding.label("attachment") == "attachment"

      assert Enum.filter(Embedding.kinds(), &Embedding.page?/1) == ~w(page page_section)
      refute Embedding.page?("attachment")
    end
  end

  describe "what gets indexed" do
    test "a card, its comments and its status updates each become a row", ctx do
      card = card_fixture(ctx.column, %{"title" => "Rotate the Stripe keys"})
      {:ok, comment} = Boards.add_comment(card, "Finance have to approve first")

      {:ok, update} =
        Boards.add_status_update(card, ctx.owner, %{"health" => "at_risk", "body" => "Slipping"})

      # The struct is accepted as well as the id.
      assert {:ok, %{embedded: 3, unchanged: 0, removed: 0}} = Search.index_card(card)

      rows = rows_for(card.id)

      assert Enum.map(rows, &{&1.kind, &1.source_id}) |> Enum.sort() ==
               Enum.sort([
                 {"card", card.id},
                 {"comment", comment.id},
                 {"status_update", update.id}
               ])

      for row <- rows do
        assert row.board_id == ctx.board.id
        assert row.page_id == nil
        assert row.model == Embeddings.model()
        # As many dimensions as were asked for, stored unit length.
        assert row.dimensions == Embeddings.dimensions()
        assert Vector.size(row.vector) == row.dimensions
        assert_in_delta Vector.similarity(row.vector, row.vector), 1.0, 0.0001
      end

      assert Enum.find(rows, &(&1.kind == "status_update")).body =~ "Slipping"
    end

    test "a card that has gone is forgotten rather than indexed", ctx do
      card = card_fixture(ctx.column, %{"title" => "Short-lived"})
      {:ok, _} = Search.index_card(card.id)
      # Gone without the delete hook having run, as when the queue is behind.
      Repo.delete_all(from(c in Boards.Card, where: c.id == ^card.id))

      assert Search.index_card(card.id) == {:ok, %{embedded: 0, unchanged: 0, removed: 0}}
      assert rows_for(card.id) == []
    end

    test "nothing to index is no call to the model at all" do
      assert Search.index_cards([]) == {:ok, %{embedded: 0, unchanged: 0, removed: 0}}
      assert Search.index_pages([]) == {:ok, %{embedded: 0, unchanged: 0, removed: 0}}
      assert Search.load_cards([]) == []
      assert Search.load_pages([]) == []
      refute_received {:embed_request, _}
    end

    test "a page is indexed, and a missing page is forgotten", ctx do
      page =
        page_fixture(ctx.board, %{
          "title" => "Deploy runbook",
          "body" => "## Before\n\nTake a backup.\n\n## Rollback\n\nRestore the backup."
        })

      assert {:ok, %{embedded: n}} = Search.index_page(page)
      assert n >= 1

      rows = page_rows(page.id)
      assert Enum.all?(rows, &(&1.board_id == ctx.board.id and &1.card_id == nil))
      assert Enum.any?(rows, &(&1.body =~ "Restore the backup"))

      Repo.delete!(page)
      assert {:ok, %{removed: 0}} = Search.index_page(page.id)
      assert page_rows(page.id) == []
    end

    test "a changed dimension setting makes every chunk stale", ctx do
      card = card_fixture(ctx.column, %{"title" => "Alpha"})
      {:ok, _} = Search.index_card(card.id)

      put_ai_config(embed_dimensions: 16)
      assert {:ok, %{embedded: 1, unchanged: 0}} = Search.index_card(card.id)

      assert_received {:embed_request, %{"dimensions" => 16}}
      assert [%{dimensions: 16}] = rows_for(card.id)

      # Asked again at the same size, nothing is re-embedded.
      assert {:ok, %{embedded: 0, unchanged: 1}} = Search.index_card(card.id)
    end

    test "without a dimension setting none is sent", ctx do
      put_ai_config(embed_dimensions: nil)
      card = card_fixture(ctx.column, %{"title" => "Alpha"})
      {:ok, _} = Search.index_card(card.id)

      assert_received {:embed_request, body}
      refute Map.has_key?(body, "dimensions")
      assert body["model"] == Embeddings.model()
      assert body["encoding_format"] == "float"
    end
  end

  describe "the model's input" do
    test "blank text is sent as a single space and long text is cut short" do
      long = String.duplicate("a", 30_000)
      assert {:ok, [_, _]} = Embeddings.embed_all(["   ", long])

      assert_received {:embed_request, %{"input" => [" ", sent]}}
      assert String.length(sent) == 24_000
    end

    test "embed/1 gives back one unit-length vector" do
      assert {:ok, vector} = Embeddings.embed("rollback the deploy")
      assert length(vector) == Embeddings.dimensions()
      assert_in_delta Enum.reduce(vector, 0.0, &(&2 + &1 * &1)), 1.0, 0.0001
    end

    test "an all-zero vector is kept as it is rather than divided by zero" do
      stub_embedding_reply(fn _ ->
        %{"data" => [%{"index" => 0, "embedding" => [0.0, 0.0, 0.0]}]}
      end)

      assert Embeddings.embed("nothing") == {:ok, [0.0, 0.0, 0.0]}
    end

    test "out-of-order answers are put back in input order" do
      stub_embedding_reply(fn _ ->
        %{
          "data" => [
            %{"index" => 1, "embedding" => [0.0, 2.0]},
            %{"index" => 0, "embedding" => [3.0, 0.0]}
          ]
        }
      end)

      assert Embeddings.embed_all(["first", "second"]) == {:ok, [[1.0, 0.0], [0.0, 1.0]]}
    end

    test "more than one batch is sent in several requests, in order" do
      texts = for i <- 1..70, do: "item #{i}"
      assert {:ok, vectors} = Embeddings.embed_all(texts)
      assert length(vectors) == 70

      assert_received {:embed_request, %{"input" => first}}
      assert_received {:embed_request, %{"input" => second}}
      assert {length(first), length(second)} == {64, 6}
      assert hd(second) == "item 65"

      assert hd(vectors) == elem(Embeddings.embed("item 1"), 1)
    end
  end

  describe "when the model lets us down" do
    setup ctx do
      card = card_fixture(ctx.column, %{"title" => "Alpha", "description" => "first"})
      {:ok, _} = Search.index_card(card.id)
      {:ok, card} = Boards.update_card(card, %{"description" => "second"})
      %{card: card, before: rows_for(card.id)}
    end

    # A failure leaves the index as it was: behind, but never half-written.
    defp assert_untouched(ctx), do: assert(rows_for(ctx.card.id) == ctx.before)

    test "an HTTP error is reported in words and nothing is written", ctx do
      AIStub.fail_with(500, "upstream exploded")

      log =
        capture_log(fn ->
          assert {:error, "The model refused the request (500): upstream exploded"} =
                   Search.index_card(ctx.card.id)
        end)

      assert log =~ "Embedding call failed with 500"
      assert_untouched(ctx)
    end

    test "a rejected key says so", ctx do
      AIStub.fail_with(401, "bad key")

      capture_log(fn ->
        assert {:error, "The OpenRouter API key was rejected."} = Search.index_card(ctx.card.id)
      end)

      assert_untouched(ctx)
    end

    test "an unreachable model is reported as such", ctx do
      Req.Test.stub(Slipdock.AI, &Req.Test.transport_error(&1, :econnrefused))

      capture_log(fn ->
        assert {:error, "Couldn't reach the embedding model" <> _} =
                 Search.index_card(ctx.card.id)
      end)

      assert_untouched(ctx)
    end

    test "a 200 with no data in it is an error, not an empty index", ctx do
      stub_embedding_reply(fn _ -> %{"object" => "list"} end)

      log =
        capture_log(fn ->
          assert {:error, "The embedding model returned nothing."} =
                   Search.index_card(ctx.card.id)
        end)

      assert log =~ "returned no data"
      assert_untouched(ctx)
    end

    test "the wrong number of vectors fails the lot", ctx do
      stub_embedding_reply(fn _ -> %{"data" => []} end)

      assert {:error, "The embedding model returned 0 vectors for 1 inputs."} =
               Search.index_card(ctx.card.id)

      assert {:error, "The embedding model returned 0 vectors for 1 inputs."} =
               Embeddings.embed("anything")

      assert_untouched(ctx)
    end

    test "a vector that is not a list fails the lot", ctx do
      stub_embedding_reply(fn _ -> %{"data" => [%{"index" => 0, "embedding" => "base64=="}]} end)

      assert {:error, "The embedding model returned 1 vectors for 1 inputs."} =
               Search.index_card(ctx.card.id)

      assert_untouched(ctx)
    end

    test "one failed batch fails the whole list rather than leaving holes" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Slipdock.AI, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
          Req.Test.json(conn, %{
            "data" =>
              Jason.decode!(body)["input"]
              |> Enum.with_index()
              |> Enum.map(fn {_, i} -> %{"index" => i, "embedding" => [1.0]} end)
          })
        else
          conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{})
        end
      end)

      capture_log(fn ->
        assert {:error, "The model is rate-limited right now; try again in a moment."} =
                 Embeddings.embed_all(for i <- 1..70, do: "item #{i}")
      end)
    end
  end

  describe "with no key and no model to talk to" do
    setup do
      put_ai_config(api_key: nil)
      refute AI.configured?()
      :ok
    end

    test "indexing fails with the reason, and search reports itself unavailable", ctx do
      card = card_fixture(ctx.column, %{"title" => "Alpha"})

      assert {:error, message} = Search.index_card(card.id)
      assert message =~ "AI features need a model to talk to"
      assert rows_for(card.id) == []

      refute Embeddings.configured?()
      refute Search.available?()
      refute_received {:embed_request, _}
    end

    test "the queue drops what it could not embed instead of retrying it forever", ctx do
      card_fixture(ctx.column, %{"title" => "Queued work"})
      assert Indexer.pending() >= 1

      log = capture_log(fn -> assert {:error, _} = Indexer.flush() end)

      assert log =~ "Search index update failed"
      assert Indexer.pending() == 0
    end
  end

  describe "the queue" do
    test "nil and missing ids are no-ops, never failures" do
      assert Indexer.enqueue(nil) == :ok
      assert Indexer.enqueue_page(nil) == :ok
      assert Indexer.forget(nil) == :ok
      assert Indexer.forget_page(nil) == :ok
      assert Indexer.pending() == 0
    end

    test "pages are queued and flushed alongside cards", ctx do
      card = card_fixture(ctx.column, %{"title" => "Runbook card"})
      page = page_fixture(ctx.board, %{"title" => "Runbook", "body" => "Restart the worker."})
      Indexer.reset()

      Indexer.enqueue_all([card.id])
      Indexer.enqueue_pages([page.id])
      assert Indexer.pending() == 2

      assert {:ok, %{embedded: n}} = Indexer.flush()
      assert n >= 2
      assert length(rows_for(card.id)) == 1
      assert page_rows(page.id) != []
    end

    test "a card or page that has gone since it was queued takes its rows with it", ctx do
      card = card_fixture(ctx.column, %{"title" => "Gone soon"})
      page = page_fixture(ctx.board, %{"title" => "Gone too", "body" => "Text."})
      {:ok, _} = Search.index_card(card.id)
      {:ok, _} = Search.index_page(page.id)
      Indexer.reset()

      Indexer.enqueue(card)
      Indexer.enqueue_page(page)
      Repo.delete_all(from(c in Boards.Card, where: c.id == ^card.id))
      Repo.delete!(page)

      assert {:ok, %{embedded: 0}} = Indexer.flush()
      assert rows_for(card.id) == []
      assert page_rows(page.id) == []
    end

    test "a timer tick flushes the queue, and stray messages are ignored", ctx do
      card = card_fixture(ctx.column, %{"title" => "Ticked"})
      assert Indexer.pending() >= 1

      send(Indexer, :something_else)
      send(Indexer, :flush)
      # A call after the sends is answered only once they have been handled.
      assert Indexer.pending() == 0
      assert length(rows_for(card.id)) == 1
    end

    test "an empty flush does nothing" do
      assert Indexer.flush() == {:ok, %{embedded: 0, unchanged: 0, removed: 0}}
      refute_received {:embed_request, _}
    end
  end
end
