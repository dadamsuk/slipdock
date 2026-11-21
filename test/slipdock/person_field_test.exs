defmodule Slipdock.PersonFieldTest do
  @moduledoc """
  A person field (#3614): who it takes (members, by email, id or `me`) and
  refuses, the order it keeps, a former member kept where held and refused
  where new, the filter that keeps a card holding any of the people picked
  (with `me` the viewer, through a saved view and the address), the axis
  with a lane per person and a drag that swaps one, the sort, and an import
  holding its people to the tree's members.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Actor, Boards, Fields, Filters, Swimlanes}
  alias Slipdock.Boards.FieldDefinition
  alias Slipdock.Swimlanes.Config

  setup do
    owner = user_fixture()
    board = board_fixture(%{"name" => "People"}, owner: owner)
    [_backlog, todo | _] = board.columns

    ann = user_fixture("ann@example.com")
    zed = user_fixture("zed@example.com")
    {:ok, ann_grant} = Access.grant(board, ann, "write", owner)
    {:ok, _} = Access.grant(board, zed, "read", owner)
    outsider = user_fixture("outsider@example.com")

    {:ok, reviewers} = Fields.create_field(board, %{"name" => "Reviewers", "kind" => "person"})

    card = card_fixture(todo, %{"title" => "Review me"})
    other = card_fixture(todo, %{"title" => "Other"})
    empty = card_fixture(todo, %{"title" => "Nobody"})

    %{
      owner: owner,
      board: board,
      todo: todo,
      ann: ann,
      ann_grant: ann_grant,
      zed: zed,
      outsider: outsider,
      field: reviewers,
      card: card,
      other: other,
      empty: empty
    }
  end

  defp card(card), do: Boards.Cards.get_card!(card.id)
  defp ids(users), do: Enum.map(users, &to_string(&1.id))
  defp titles(cards), do: Enum.map(cards, & &1.title)
  defp acting_as(user), do: Actor.put(Actor.web(user), user.email, {user, nil})

  defp leave(ctx), do: {:ok, _} = Access.revoke(ctx.ann_grant, actor: Actor.web(ctx.owner))

  defp loaded(ctx) do
    fields = Fields.list_fields(Boards.Board.root_id(ctx.board))
    Fields.decorate([card(ctx.card), card(ctx.other), card(ctx.empty)], fields)
  end

  test "is a kind, and an axis" do
    assert {"person", "Person"} in FieldDefinition.kinds()
    assert FieldDefinition.axis?(%FieldDefinition{kind: "person"})
    refute FieldDefinition.numeric?(%FieldDefinition{kind: "person"})
  end

  describe "setting it" do
    test "takes members by email, id or me, in the order given, without repeats", ctx do
      acting_as(ctx.owner)
      raw = "#{ctx.zed.email}, #{ctx.ann.id}, me, #{String.upcase(ctx.zed.email)}"
      {:ok, card} = Fields.set_value(ctx.card, ctx.field, raw)

      assert Fields.value(card, ctx.field) == ids([ctx.zed, ctx.ann, ctx.owner])

      # A list does too, and "" or [] clears.
      {:ok, card} = Fields.set_value(card, ctx.field, ["", ctx.ann.email])
      assert Fields.value(card, ctx.field) == ids([ctx.ann])
      {:ok, card} = Fields.set_value(card, ctx.field, "")
      assert Fields.value(card, ctx.field) == nil
    end

    test "me with nobody acting is refused", ctx do
      Actor.put(nil)
      assert {:error, message} = Fields.set_value(ctx.card, ctx.field, "me")
      assert message == "Reviewers: me isn't a member of this board."
    end

    test "refuses a non-member, an unknown address and a stranger's id, naming them", ctx do
      assert Fields.set_value(ctx.card, ctx.field, "#{ctx.ann.email}, #{ctx.outsider.email}") ==
               {:error, "Reviewers: #{ctx.outsider.email} isn't a member of this board."}

      assert {:error, "Reviewers: nobody@example.com isn't a member of this board."} =
               Fields.set_value(ctx.card, ctx.field, "nobody@example.com")

      assert {:error, _} = Fields.set_value(ctx.card, ctx.field, to_string(ctx.outsider.id))

      # Nothing was stored.
      assert Fields.value(card(ctx.card), ctx.field) == nil
    end

    test "a former member stays where held, and can't be picked anew", ctx do
      {:ok, _} = Fields.set_value(ctx.card, ctx.field, [ctx.ann.email, ctx.zed.email])
      leave(ctx)

      # Held: saving the card again with Ann still on it, without Zed, is fine.
      {:ok, kept} = Fields.set_value(card(ctx.card), ctx.field, [to_string(ctx.ann.id)])
      assert Fields.value(kept, ctx.field) == ids([ctx.ann])

      # Not held: another card can't take her.
      assert Fields.set_value(ctx.other, ctx.field, "#{ctx.ann.email}") ==
               {:error, "Reviewers: #{ctx.ann.email} isn't a member of this board."}

      # Nor can the first, once she is off it.
      {:ok, _} = Fields.set_value(card(ctx.card), ctx.field, ctx.zed.email)
      assert {:error, _} = Fields.set_value(card(ctx.card), ctx.field, "#{ctx.ann.email}")
    end
  end

  describe "reading it" do
    test "names its people, a former member marked", ctx do
      {:ok, card} = Fields.set_value(ctx.card, ctx.field, "#{ctx.zed.email}, #{ctx.ann.email}")

      assert Fields.format(ctx.field, Fields.value(card, ctx.field)) ==
               "#{ctx.zed.email}, #{ctx.ann.email}"

      leave(ctx)

      assert Fields.format(ctx.field, Fields.value(card, ctx.field)) ==
               "#{ctx.zed.email}, #{ctx.ann.email} (former member)"

      assert Fields.external(ctx.field, Fields.value(card, ctx.field)) == [
               %{"id" => ctx.zed.id, "name" => "#{ctx.zed.email}", "email" => "#{ctx.zed.email}"},
               %{
                 "id" => ctx.ann.id,
                 "name" => "#{ctx.ann.email}",
                 "email" => "#{ctx.ann.email}",
                 "former" => true
               }
             ]

      # As a formula input it is no number.
      assert Fields.numeric(card, ctx.field) == nil
    end
  end

  describe "filtering" do
    setup ctx do
      {:ok, _} = Fields.set_value(ctx.card, ctx.field, [ctx.ann.email, ctx.zed.email])
      {:ok, _} = Fields.set_value(ctx.other, ctx.field, [ctx.owner.email])
      :ok
    end

    test "keeps a card holding any of the people picked", ctx do
      filters =
        Filters.put_field(Filters.empty(), ctx.field, %{"person" => to_string(ctx.zed.id)})

      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, filters)) |> titles() == [
               "Review me"
             ]

      filters = Filters.put_field(filters, ctx.field, %{"person" => to_string(ctx.owner.id)})

      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, filters)) |> titles() ==
               ["Review me", "Other"]

      # The same again takes that person off.
      filters = Filters.put_field(filters, ctx.field, %{"person" => to_string(ctx.zed.id)})

      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, filters)) |> titles() == [
               "Other"
             ]
    end

    test "me is whoever is looking, through the address and a saved view", ctx do
      filters = Filters.put_field(Filters.empty(), ctx.field, %{"person" => "me"})
      kept = Filters.saved_fields(filters)
      assert kept == %{to_string(ctx.field.id) => %{"people" => ["me"]}}

      from_url = Config.from_query(%{"field_filters" => kept}, Config.defaults("table"))
      assert from_url.field_filters == kept
      restored = Filters.put_saved_fields(Filters.empty(), [ctx.field], from_url.field_filters)

      acting_as(ctx.owner)

      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, restored)) |> titles() == [
               "Other"
             ]

      assert ctx |> loaded() |> Enum.filter(&Swimlanes.matches?(&1, from_url)) |> titles() == [
               "Other"
             ]

      acting_as(ctx.ann)

      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, restored)) |> titles() == [
               "Review me"
             ]

      assert ctx |> loaded() |> Enum.filter(&Swimlanes.matches?(&1, from_url)) |> titles() ==
               ["Review me"]

      # Nobody looking: me is nobody.
      Actor.put(nil)
      assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, restored)) == []
    end
  end

  describe "as a swimlane axis" do
    test "a lane per person held, a former member marked, then No reviewers", ctx do
      {:ok, _} = Fields.set_value(ctx.card, ctx.field, [ctx.zed.email, ctx.ann.email])
      leave(ctx)

      key = "f:#{ctx.field.id}"
      board = %{Boards.get_board!(ctx.board.id) | fields: [ctx.field]}
      config = %Config{Config.defaults("swimlanes") | rows: key, cols: "none"}
      grid = Swimlanes.grid(board, config)

      assert Enum.map(grid.rows, &{&1.key, &1.label}) == [
               {to_string(ctx.zed.id), "#{ctx.zed.email}"},
               {to_string(ctx.ann.id), "#{ctx.ann.email} (former member)"},
               {"none", "No reviewers"}
             ]

      lanes = Map.new(grid.rows, &{&1.key, &1.cells |> List.flatten() |> titles()})
      assert lanes[to_string(ctx.zed.id)] == ["Review me"]
      assert lanes[to_string(ctx.ann.id)] == ["Review me"]
      assert Enum.sort(lanes["none"]) == ["Nobody", "Other"]
    end

    test "a drag swaps that one person and keeps the rest; on No it drops just them", ctx do
      {:ok, card} = Fields.set_value(ctx.card, ctx.field, [ctx.ann.email, ctx.zed.email])
      key = "f:#{ctx.field.id}"
      config = Config.defaults("swimlanes")
      [ann, zed, owner] = ids([ctx.ann, ctx.zed, ctx.owner])

      assert [{:field, id, swapped}] = Swimlanes.move_ops(key, card, ann, owner, config)
      assert id == ctx.field.id
      assert swapped == [zed, owner]
      {:ok, moved} = Fields.set_value(card, ctx.field, swapped)
      assert Fields.value(moved, ctx.field) == [zed, owner]

      assert [{:field, _, [^owner]}] = Swimlanes.move_ops(key, moved, zed, "none", config)

      # Into a former member's lane it is refused: they can't be picked anew.
      leave(ctx)
      [{:field, _, raw}] = Swimlanes.move_ops(key, moved, zed, ann, config)
      assert {:error, _} = Fields.set_value(moved, ctx.field, raw)

      # An empty card dragged into a lane gets that person.
      [{:field, _, raw}] = Swimlanes.move_ops(key, card(ctx.empty), "none", zed, config)
      {:ok, filled} = Fields.set_value(card(ctx.empty), ctx.field, raw)
      assert Fields.value(filled, ctx.field) == [zed]
    end
  end

  test "sorts by the first person's name", ctx do
    {:ok, _} = Fields.set_value(ctx.card, ctx.field, [ctx.zed.email, ctx.ann.email])
    {:ok, _} = Fields.set_value(ctx.other, ctx.field, [ctx.ann.email, ctx.zed.email])

    asc = %Config{Config.defaults("table") | sort: "f:#{ctx.field.id}", dir: "asc"}
    sorted = ctx |> loaded() |> Enum.reverse() |> Swimlanes.sort(asc) |> titles()
    assert Enum.take(sorted, 2) == ["Other", "Review me"]
  end

  test "an import keeps a member and leaves out anyone else, saying so" do
    importer = user_fixture("importer@example.com")
    stranger = user_fixture("stranger@example.com")

    document =
      Jason.encode!(%{
        slipdock_portable: 1,
        boards: [
          %{
            root: %{ref: "r", name: "Imported", code: "ppl", lists: [%{ref: "l1", name: "To Do"}]},
            boards: [],
            fields: [%{ref: "f1", name: "Owner", key: "owner", kind: "person"}],
            cards: [
              %{
                ref: "k1",
                board: "r",
                list: "l1",
                title: "Stranger",
                fields: [%{field: "f1", options: [to_string(stranger.id)]}]
              },
              %{
                ref: "k2",
                board: "r",
                list: "l1",
                title: "Mine",
                fields: [%{field: "f1", options: [to_string(importer.id)]}]
              }
            ]
          }
        ]
      })

    {:ok, report} = Slipdock.Portable.import(importer, document)
    board = Boards.get_board!(hd(report.boards).id)
    [owner_field] = Fields.list_fields(board.id)
    cards = Boards.Cards.list_cards(board, %{}) |> Map.new(&{&1.title, &1})

    assert Fields.value(cards["Mine"], owner_field) == [to_string(importer.id)]
    assert Fields.value(cards["Stranger"], owner_field) == nil

    assert Enum.any?(
             report.skipped,
             &(&1 =~
                 "A field value on “Stranger” was left out: Owner: #{stranger.id} isn't a member")
           )
  end
end
