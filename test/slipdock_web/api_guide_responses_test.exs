defmodule SlipdockWeb.APIGuideResponsesTest do
  @moduledoc """
  The guide's "What comes back" samples, held to what the server returns.
  A client (FirstMate) once had to guess these shapes and guessed wrong, so
  every field a sample shows must be in the live response, at the same
  place, and the facts a client relies on must be said in words (#664).
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Search}

  setup %{user: user} do
    Slipdock.AIStub.stub_embeddings()

    board = board_fixture(%{"name" => "Delivery", "code" => "delivery"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Refund rounding"})
    {:ok, _} = Boards.add_comment(card, "Rollback was blocked on approvals", by: user)
    {:ok, _} = Boards.add_checklist_item(card, "Write the test")
    {:ok, _} = Search.index_cards(Search.load_cards(Search.all_card_ids()))
    {:ok, _} = Boards.create_tag(board, %{"name" => "api", "color" => "sky"})

    markdown = SlipdockWeb.APIGuide.markdown()
    [_, section] = String.split(markdown, "### What comes back", parts: 2)
    [section | _] = String.split(section, "\nAn **archived board**", parts: 2)

    samples =
      ~r/```json\n(.*?)```/s
      |> Regex.scan(section, capture: :all_but_first)
      |> Enum.map(fn [json] -> Jason.decode!(json) end)

    %{board: board, card: card, section: section, samples: samples}
  end

  # Every key in `sample` is in `real`, recursively; a list is checked by its
  # first element, which is all a sample shows.
  defp assert_shape(sample, real, path \\ "$")

  defp assert_shape(sample, real, path) when is_map(sample) do
    assert is_map(real), "#{path}: the guide shows an object, the server sent #{inspect(real)}"

    for {key, value} <- sample do
      assert Map.has_key?(real, key),
             "#{path}.#{key}: the guide shows it, the server does not send it"

      assert_shape(value, real[key], "#{path}.#{key}")
    end
  end

  defp assert_shape([first | _], real, path) do
    assert match?([_ | _], real),
           "#{path}: the guide shows a list with items, the server sent #{inspect(real)}"

    assert_shape(first, hd(real), "#{path}[0]")
  end

  defp assert_shape(_scalar, _real, _path), do: :ok

  test "there is a sample for each of the eight responses", %{samples: samples} do
    assert length(samples) == 8
  end

  test "every sample's fields are in the real response", ctx do
    [board_s, card_s, status_s, invalid_s, handoff_s, recurrence_s, search_s, ask_s] =
      ctx.samples

    conn = ctx.conn

    status =
      conn
      |> post(~p"/api/cards/#{ctx.card.id}/status", %{
        health: "at_risk",
        body: "Waiting on finance"
      })
      |> json_response(201)

    assert_shape(status_s, status)
    assert status["card"]["stated_health"] == "at_risk"

    assert_shape(board_s, conn |> get(~p"/api/boards/delivery") |> json_response(200))
    assert_shape(card_s, conn |> get(~p"/api/cards/#{ctx.card.id}") |> json_response(200))

    invalid =
      conn |> post(~p"/api/cards/#{ctx.card.id}/status", %{health: "meh"}) |> json_response(422)

    assert invalid == invalid_s

    handoff =
      conn
      |> post(~p"/api/cards/#{ctx.card.id}/handoff", %{
        next_step: "Write the rounding test",
        body: "State: fix is in, untested"
      })
      |> json_response(201)

    assert_shape(handoff_s, handoff)
    assert handoff["handoff"]["via"] == "api"

    recurrence =
      conn
      |> put(~p"/api/cards/#{ctx.card.id}/recurrence", %{rule: "every mon", at: "08:00"})
      |> json_response(200)

    assert_shape(recurrence_s, recurrence)
    assert recurrence["recurrence"]["rule"] == "FREQ=WEEKLY;BYDAY=MO"
    assert length(recurrence["recurrence"]["upcoming"]) == 3

    search =
      conn
      |> get(~p"/api/search", %{q: "rollback blocked approvals", board: "delivery", limit: 5})
      |> json_response(200)

    assert_shape(search_s, search)

    Slipdock.AIStub.reply_sequence([
      {:tool_calls, [{"search_cards", %{"query" => "refund rounding"}}]},
      "Finance are waiting on the refund rounding card."
    ])

    ask =
      conn
      |> post(~p"/api/ask", %{q: "What is happening with refunds?", board: "delivery"})
      |> json_response(200)

    assert_shape(ask_s, ask)
  end

  test "a sample that invents a field is caught" do
    assert_raise ExUnit.AssertionError, ~r/\$\.card\.author/, fn ->
      assert_shape(%{"card" => %{"author" => "x"}}, %{"card" => %{"id" => 1}})
    end

    assert_raise ExUnit.AssertionError, ~r/\$\.cards: the guide shows a list/, fn ->
      assert_shape(%{"cards" => [%{"id" => 1}]}, %{"cards" => []})
    end
  end

  test "the facts a client needs are said in words", %{section: section} do
    text = section |> String.split() |> Enum.join(" ")

    # Board: cards come inside each list.
    assert text =~ "Each list carries its own `cards`"
    # Card: what a comment is, and who wrote it.
    assert text =~ "A comment is `id`, `body`, `author` and `inserted_at`"
    assert text =~ "`null` on comments written before authors were kept"
    # Status: the body and its values.
    assert text =~
             "takes `health` — `on_track`, `at_risk` or `off_track` — and an optional `body`"

    # Handoff: what it takes, and where the current one is.
    assert text =~ "takes `next_step` (one line, at most 280, required)"
    assert text =~ "`GET` gives it with every earlier one as `history`"

    # Recurrence: the phrases it takes, and what a missed one does.
    assert text =~ "`rule` is a phrase (`every mon`"
    assert text =~ "`on_missed` (`bump`, the default"

    # Search: where the title is.
    assert text =~ "Read the title from `subject`"
    # Ask: synchronous, GET is not a poll, both spellings, board.
    assert text =~ "It answers **synchronously**"
    assert text =~ "`GET /api/ask?q=…` is the same call, not a poll"
    assert text =~ "takes the question as `q` or `question`, an optional `board`"
  end
end
