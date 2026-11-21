defmodule Slipdock.ViewFieldFiltersTest do
  @moduledoc """
  Custom-field filters kept with a view (#3608): `Config`'s `field_filters`
  survive the URL and a saved view's stored map, `Swimlanes.matches?/3`
  applies them in every view, a filter on a field since deleted is dropped,
  and a view shared with someone grants only the cards its field filters
  select (`Access.view_shows_card?/2`).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Access, Boards, Fields, Filters, Swimlanes}
  alias Slipdock.Swimlanes.Config

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{"name" => "Contacts"}, owner: owner)
    [col | _] = board.columns

    {:ok, stage} =
      Fields.create_field(board, %{
        "name" => "Stage",
        "kind" => "select",
        "options" => ["Lead", "Won"]
      })

    {:ok, size} = Fields.create_field(board, %{"name" => "Size", "kind" => "number"})
    {:ok, met} = Fields.create_field(board, %{"name" => "Met", "kind" => "date"})
    {:ok, note} = Fields.create_field(board, %{"name" => "Note", "kind" => "text"})

    won = card_fixture(col, %{"title" => "Acme"})
    lead = card_fixture(col, %{"title" => "Globex"})
    card_fixture(col, %{"title" => "Unknown"})

    {:ok, _} = Fields.set_value(won, stage, "won")
    {:ok, _} = Fields.set_value(won, size, "40")
    {:ok, _} = Fields.set_value(won, met, "2027-02-01")
    {:ok, _} = Fields.set_value(won, note, "Met at the fair")
    {:ok, _} = Fields.set_value(lead, stage, "lead")
    {:ok, _} = Fields.set_value(lead, size, "5")

    %{owner: owner, board: board, stage: stage, size: size, met: met, note: note}
  end

  defp passing(board, config) do
    board
    |> Map.fetch!(:id)
    |> Boards.get_board!()
    |> Map.fetch!(:columns)
    |> Enum.flat_map(& &1.cards)
    |> Enum.filter(&Swimlanes.matches?(&1, config))
    |> Enum.map(& &1.title)
    |> Enum.sort()
  end

  describe "a view's field filters" do
    test "select every view's cards by each condition's shape", ctx do
      id = &to_string(&1.id)
      config = fn ff -> Config.from_query(%{"field_filters" => ff}, Config.defaults("table")) end

      assert passing(ctx.board, config.(%{id.(ctx.stage) => %{"options" => ["won"]}})) == ["Acme"]

      assert passing(ctx.board, config.(%{id.(ctx.stage) => %{"options" => ["won", "lead"]}})) ==
               ["Acme", "Globex"]

      assert passing(ctx.board, config.(%{id.(ctx.size) => %{"min" => "10"}})) == ["Acme"]
      assert passing(ctx.board, config.(%{id.(ctx.size) => %{"max" => "10"}})) == ["Globex"]
      assert passing(ctx.board, config.(%{id.(ctx.met) => %{"from" => "2027-01-01"}})) == ["Acme"]
      assert passing(ctx.board, config.(%{id.(ctx.note) => %{"text" => "FAIR"}})) == ["Acme"]

      # Two at once: both must hold.
      both = %{id.(ctx.stage) => %{"options" => ["lead"]}, id.(ctx.size) => %{"min" => "10"}}
      assert passing(ctx.board, config.(both)) == []

      # None set: every card.
      assert passing(ctx.board, config.(%{})) == ["Acme", "Globex", "Unknown"]
    end

    test "go through the URL and back", ctx do
      ff = %{
        to_string(ctx.stage.id) => %{"options" => ["won"]},
        to_string(ctx.size.id) => %{"min" => "10"}
      }

      base = Config.defaults("table")
      config = Config.from_query(%{"field_filters" => ff}, base)

      query = Config.to_query(config, base)
      assert {:field_filters, %{} = encoded} = List.keyfind(query, :field_filters, 0)

      # As a browser sends it back: the nested params Plug parses.
      parsed = query |> Plug.Conn.Query.encode() |> Plug.Conn.Query.decode()
      assert Config.from_query(parsed, base).field_filters == config.field_filters
      assert encoded[to_string(ctx.size.id)] == %{"min" => 10}

      # Cleared on a view that had some: the URL says so with "".
      cleared = %{config | field_filters: %{}}

      assert List.keyfind(Config.to_query(cleared, config), :field_filters, 0) ==
               {:field_filters, ""}

      assert Config.from_query(%{"field_filters" => ""}, config).field_filters == %{}
    end

    test "are kept by a saved view", ctx do
      ff = %{to_string(ctx.stage.id) => %{"options" => ["won"]}}
      config = Config.from_query(%{"field_filters" => ff}, Config.defaults("table"))

      {:ok, view} =
        Boards.SavedViews.create_saved_view(ctx.board, %{
          "name" => "Won",
          "config" => Config.to_map(config)
        })

      view = Repo.reload!(view)

      reopened =
        view.config |> Config.from_map() |> Config.sanitize(Boards.get_board!(ctx.board.id))

      assert reopened.field_filters == ff
      assert passing(ctx.board, reopened) == ["Acme"]
      assert Config.active_filter_count(reopened) == 1
      assert Config.clear_filters(reopened).field_filters == %{}
    end

    test "on a field since deleted are dropped quietly", ctx do
      ff = %{to_string(ctx.stage.id) => %{"options" => ["won"]}}
      config = Config.from_query(%{"field_filters" => ff}, Config.defaults("table"))

      {:ok, _} = Fields.delete_field(ctx.stage)
      board = Boards.get_board!(ctx.board.id)

      sanitized = Config.sanitize(config, board)
      assert sanitized.field_filters == %{}
      assert passing(ctx.board, sanitized) == ["Acme", "Globex", "Unknown"]

      # And the toolbar's filters take nothing from it.
      assert Filters.put_saved_fields(Filters.empty(), board.fields, ff).fields == %{}
    end

    test "junk in the URL is dropped, never raised on", ctx do
      base = Config.defaults("table")
      stage = to_string(ctx.stage.id)

      for junk <- [
            "nonsense",
            %{"abc" => %{"min" => "1"}},
            %{stage => "won"},
            %{stage => %{"min" => "lots", "colour" => "red"}},
            %{stage => %{"from" => "not a date"}}
          ] do
        assert Config.from_query(%{"field_filters" => junk}, base).field_filters == %{}
      end
    end
  end

  describe "the toolbar's filters and a view's" do
    test "turn into each other", ctx do
      board = Boards.get_board!(ctx.board.id)

      filters =
        Filters.empty()
        |> Filters.put_field(ctx.stage, %{"option" => "won"})
        |> Filters.put_field(ctx.met, %{"from" => "2027-01-01"})

      kept = Filters.saved_fields(filters)

      assert kept == %{
               to_string(ctx.stage.id) => %{"options" => ["won"]},
               to_string(ctx.met.id) => %{"from" => "2027-01-01"}
             }

      restored = Filters.put_saved_fields(Filters.empty(), board.fields, kept)
      assert restored.fields == filters.fields
    end
  end

  describe "a shared view" do
    test "grants only the cards its field filters select", ctx do
      other = user_fixture("viewer@example.com")
      board = Boards.get_board!(ctx.board.id)
      [won, lead, unknown] = Enum.sort_by(Enum.flat_map(board.columns, & &1.cards), & &1.title)

      config =
        Config.from_query(
          %{"field_filters" => %{to_string(ctx.stage.id) => %{"options" => ["won"]}}},
          Config.defaults("table")
        )

      {:ok, view} =
        Boards.SavedViews.create_saved_view(board, %{
          "name" => "Won",
          "config" => Config.to_map(config)
        })

      {:ok, _} = Access.grant(view, other, "read", ctx.owner)

      assert Access.view_shows_card?(other, won)
      refute Access.view_shows_card?(other, lead)
      refute Access.view_shows_card?(other, unknown)
      assert Access.view_card_level(other, lead) == :none

      # Its field deleted, access fails closed, as a deleted tag's filter
      # does: the stored view still names the field, and no card holds it.
      {:ok, _} = Fields.delete_field(ctx.stage)
      refute Access.view_shows_card?(other, lead)
      refute Access.view_shows_card?(other, won)
    end
  end
end
