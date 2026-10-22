defmodule Slipdock.CardColoursAITest do
  @moduledoc """
  A card's cover and its four edges (#1209) set by the AI (#1210): the
  assistant's edit mode, the context it reads, and the `set_colours`
  automation action.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias Slipdock.AI.{Actions, Context}
  alias Slipdock.Automations.{Runner, Spec}
  alias Slipdock.Boards.Card

  setup do
    user = user_fixture()
    board = board_fixture(%{"name" => "Paint"}, owner: user)
    card = card_fixture(hd(board.columns), %{"title" => "Canvas"})
    %{user: user, board: board, card: Boards.get_card!(card.id)}
  end

  defp edges(card), do: Enum.map(Card.borders(), &Map.get(Repo.reload!(card), &1))

  defp propose(ctx, changes, card \\ nil) do
    card = card || ctx.card

    Actions.prepare(
      [%{"type" => "update", "card_id" => card.id, "changes" => changes}],
      %{board: ctx.board, cards: [card], user: ctx.user, users: [ctx.user]}
    )
  end

  defp apply!(steps) do
    applied = Actions.apply(steps)
    assert Enum.all?(applied, &(&1.result == :ok)), inspect(applied)
    applied
  end

  describe "assistant edit mode" do
    test "sets the cover colour, and null takes it off", ctx do
      assert [step] = propose(ctx, %{"cover" => "Teal"})
      assert step.label == "Set the cover colour of “Canvas” to teal"
      apply!([step])
      card = Boards.get_card!(ctx.card.id)
      assert card.color == "teal"

      assert [step] = propose(ctx, %{"cover" => nil}, card)
      assert step.label == "Take the cover colour off “Canvas”"
      apply!([step])
      assert Repo.reload!(card).color == nil
    end

    test "border sets every edge in one step", ctx do
      assert [step] = propose(ctx, %{"border" => "rose"})
      assert step.label == "Set every edge of “Canvas” to rose"
      apply!([step])
      assert edges(ctx.card) == ~w(rose rose rose rose)
    end

    test "a named edge wins over border", ctx do
      assert [step] = propose(ctx, %{"border" => "sky", "border_top" => "red"})
      assert step.label == "Set the edges of “Canvas”: top red, right sky, bottom sky, left sky"
      apply!([step])
      assert edges(ctx.card) == ~w(red sky sky sky)
    end

    test "only edges that change are in the step, and none at all is no step", ctx do
      {:ok, card} = Boards.update_card(ctx.card, %{"border_top" => "red", "color" => "lime"})
      card = Boards.get_card!(card.id)

      assert propose(ctx, %{"border_top" => "red", "cover" => "lime"}, card) == []

      assert [step] = propose(ctx, %{"border_top" => "red", "border_left" => "teal"}, card)
      assert step.label == "Set the edges of “Canvas”: left teal"

      assert [step] = propose(ctx, %{"border" => nil}, card)
      apply!([step])
      assert edges(card) == [nil, nil, nil, nil]
    end

    test "clearing every edge that has one says so", ctx do
      {:ok, card} =
        Boards.update_card(ctx.card, Map.new(Card.borders(), &{to_string(&1), "amber"}))

      assert [step] = propose(ctx, %{"borders" => nil}, Boards.get_card!(card.id))
      assert step.label == "Take the edge colours off “Canvas”"
    end

    test "a colour outside the palette fails its step and changes nothing", ctx do
      assert [cover] = propose(ctx, %{"cover" => "chartreuse"})
      assert cover.error =~ "“chartreuse” isn't a colour"

      assert [edge] = propose(ctx, %{"border" => "red", "border_left" => "mauve"})
      assert edge.error =~ "“mauve” isn't a colour"

      Actions.apply([cover, edge])
      card = Repo.reload!(ctx.card)
      assert card.color == nil
      assert edges(card) == [nil, nil, nil, nil]
    end

    test "colours sit beside the card's other changes", ctx do
      steps = propose(ctx, %{"priority" => "high", "colour" => "violet"})

      assert Enum.map(steps, & &1.label) == [
               "Set priority of “Canvas” to high",
               "Set the cover colour of “Canvas” to violet"
             ]

      apply!(steps)
      card = Repo.reload!(ctx.card)
      assert {card.priority, card.color} == {"high", "violet"}
    end

    test "the edit prompt tells the model about cover and edges" do
      Slipdock.AIStub.reply_with(%{"reply" => "Painted.", "actions" => []})
      Slipdock.AI.Assistant.propose("# Board: Paint", [], "make it red all round")

      assert_receive {:ai_request,
                      %{"messages" => [%{"role" => "system", "content" => system} | _]}}

      assert system =~ ~S["cover" (the card's cover colour)]
      assert system =~ ~S["border" (all four edges]
      assert system =~ "one of slate, red, orange"
    end
  end

  describe "context" do
    test "a card's line and its full text name the cover and edges", ctx do
      {:ok, _} =
        Boards.update_card(ctx.card, %{
          "color" => "indigo",
          "border_top" => "red",
          "border_left" => "sky"
        })

      card = Boards.get_card!(ctx.card.id)
      board = Boards.get_board!(ctx.board.id)

      assert Context.card_line(card, board) =~ "cover: indigo; edges: top red, left sky"
      text = Context.card_text(card, board)
      assert text =~ "Cover colour: indigo"
      assert text =~ "Edge colours: top red, left sky"
    end

    test "a card with no colours says none in full and nothing on its line", ctx do
      board = Boards.get_board!(ctx.board.id)
      refute Context.card_line(ctx.card, board) =~ "cover"
      refute Context.card_line(ctx.card, board) =~ "edges"
      assert Context.card_text(ctx.card, board) =~ "Edge colours: none"
    end
  end

  describe "set_colours automation action" do
    defp action(a) do
      Spec.validate(%{
        "trigger" => %{"type" => "card_created"},
        "actions" => [Map.put(a, "type", "set_colours")]
      })
    end

    test "keeps the colours, lower-cased, and reads back" do
      assert {:ok, spec} = action(%{"cover" => "Red", "border" => "none", "border_top" => "sky"})
      assert [%{"cover" => "red", "border" => "none", "border_top" => "sky"}] = spec["actions"]

      assert Spec.summary(spec) =~
               "colour it cover red, every edge none, top edge sky"
    end

    test "set_colors is the same action" do
      assert {:ok, spec} =
               Spec.validate(%{
                 "trigger" => %{"type" => "card_created"},
                 "actions" => [%{"type" => "set_colors", "cover" => "teal"}]
               })

      assert [%{"type" => "set_colours"}] = spec["actions"]
    end

    test "refuses no colours, and a colour outside the palette" do
      assert {:error, msg} = action(%{})
      assert msg =~ "needs cover, border"

      assert {:error, msg} = action(%{"border_left" => "mauve"})
      assert msg =~ "border_left “mauve” isn't a colour"
    end

    test "is in the catalogue the AI writes rules from" do
      assert Spec.catalogue() =~ "set_colours"
    end

    test "colours the card; a named edge wins and none takes one off", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"color" => "lime", "border_right" => "amber"})

      {:ok, spec} =
        action(%{"cover" => "none", "border" => "emerald", "border_bottom" => "rose"})

      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "schedule", "at" => "23:59"},
          "actions" => spec["actions"]
        })

      card = Boards.get_card!(ctx.card.id)

      assert Runner.run(rule, %{type: "card_updated", card: card, board_id: ctx.board.id}) ==
               [{:ok, "coloured it"}]

      card = Repo.reload!(card)
      assert card.color == nil
      assert edges(card) == ~w(emerald emerald rose emerald)
    end

    test "only the colours it names change", ctx do
      {:ok, _} = Boards.update_card(ctx.card, %{"color" => "lime", "border_right" => "amber"})
      {:ok, spec} = action(%{"border_top" => "red"})

      rule =
        rule_fixture(ctx.board, %{
          "trigger" => %{"type" => "schedule", "at" => "23:59"},
          "actions" => spec["actions"]
        })

      Runner.run(rule, %{type: "card_updated", card: ctx.card, board_id: ctx.board.id})
      card = Repo.reload!(ctx.card)
      assert card.color == "lime"
      assert edges(card) == ["red", "amber", nil, nil]
    end
  end
end
