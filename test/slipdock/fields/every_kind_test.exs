defmodule Slipdock.Fields.EveryKindTest do
  @moduledoc """
  The rule every custom-field kind must pass (#3607, spec W-2951 §The rule
  every type must pass): it can be filtered, sorted, shown as a table
  column, edited in the card, set and read through the API (which the CLI's
  `set` sends), MCP and a wiki page, and is either a swimlane axis or
  explicitly not one.

  The tests are generated from `FieldDefinition.kinds/0`, so a new kind gets
  its own failing tests until it has an entry in `@samples` below and passes
  every one of them. An entry says how to exercise the kind: two values
  (`low` sorts before `high`), a filter that keeps `high` and drops `low`,
  the editor the card panel draws, the value the API gives back, and
  whether it is an axis.

  Beside the kinds, `@variants` are a kind set up another way that must
  pass the same rule: a choice field that allows several (#3611).
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields, Filters, Swimlanes, Wiki}
  alias Slipdock.Boards.FieldDefinition
  alias Slipdock.Swimlanes.Config
  alias SlipdockWeb.ItemComponents

  # Every kind's field is made on one board, keyed by its kind, so the
  # formula can read the number field.
  @samples %{
    "number" => %{
      attrs: %{"config" => %{"unit" => "km"}},
      low: "2",
      high: "9",
      shown: "9 km",
      json: 9.0,
      filter: %{"min" => "5"},
      editor: ~s|input[type="number"][name="value"]|,
      axis: false
    },
    "rating" => %{
      attrs: %{"config" => %{"max" => 5}},
      low: "1",
      high: "4",
      shown: "★★★★",
      json: 4.0,
      filter: %{"min" => "3"},
      editor: ~s|button[value="4"]|,
      axis: true
    },
    "select" => %{
      attrs: %{"options" => ["Cold", "Warm"]},
      low: "cold",
      high: "warm",
      shown: "Warm",
      json: "warm",
      filter: %{"option" => "warm"},
      editor: ~s|select[name="value"] option[value="warm"]|,
      axis: true
    },
    "date" => %{
      attrs: %{},
      low: "2027-01-05",
      high: "2027-03-01",
      shown: "1 Mar 2027",
      json: "2027-03-01",
      filter: %{"from" => "2027-02-01"},
      editor: ~s|input[name="value"]|,
      # By the view's unit, as due dates (#3615).
      axis: true
    },
    "text" => %{
      attrs: %{},
      low: "apple",
      high: "pear",
      shown: "pear",
      json: "pear",
      filter: %{"text" => "PEA"},
      editor: ~s|input[type="text"][name="value"]|,
      axis: false
    },
    # One http(s) link, shown as its host (#3613); not an axis.
    "url" => %{
      attrs: %{},
      low: "https://alpha.example.com/a",
      high: "https://www.beta.example.com/b?x=1",
      shown: "beta.example.com",
      json: "https://www.beta.example.com/b?x=1",
      filter: %{"text" => "BETA"},
      editor: ~s|input[type="url"][name="value"]|,
      axis: false
    },
    # Off clears the value, so the low card is empty: empty counts as off.
    "checkbox" => %{
      attrs: %{},
      low: "false",
      high: "true",
      shown: "Yes",
      json: true,
      filter: %{"checked" => "true"},
      editor: ~s|input[type="checkbox"][name="value"]|,
      axis: true
    },
    # A choice that allows several (#3611): the high card holds two options,
    # sorts after the low one by its first, and is in each of their lanes.
    "select_several" => %{
      kind: "select",
      attrs: %{"options" => ["Cold", "Warm", "Hot"], "config" => %{"several" => true}},
      low: "cold",
      high: "Warm, Hot",
      shown: "Hot",
      json: ["warm", "hot"],
      filter: %{"option" => "hot"},
      editor: ~s|input[type="checkbox"][name="value[]"][value="hot"]|,
      axis: true
    },
    # Computed from the number field: 2 → 20, 9 → 90. Set by nobody.
    "formula" => %{
      attrs: %{"config" => %{"mode" => "expression", "expression" => "{number} * 10"}},
      computed: true,
      shown: "90",
      json: 90.0,
      filter: %{"min" => "50"},
      editor: nil,
      axis: false
    }
  }

  # A kind set up another way, tested as one of the kinds: `{name, label}`,
  # the name its entry in @samples and its field's key.
  @variants [{"select_several", "Choice (allow several)"}]

  defp sample!(kind) do
    Map.get(@samples, kind) ||
      flunk("""
      The field kind #{inspect(kind)} has no entry in @samples (#{Path.relative_to_cwd(__ENV__.file)}).
      Every kind is filtered, sorted, shown in the table, edited in the card,
      set and read through the API, MCP and a wiki page, and is a swimlane
      axis or explicitly not one: add its entry and make each test pass.
      """)
  end

  setup %{user: user} do
    board = board_fixture(%{"name" => "Every kind", "code" => "evk"}, owner: user)
    [_backlog, todo | _] = board.columns

    # The number field first: the formula reads it.
    kinds =
      ["number" | FieldDefinition.kind_keys() -- ["number"]] ++ Enum.map(@variants, &elem(&1, 0))

    fields =
      for kind <- kinds, sample = Map.get(@samples, kind), into: %{} do
        attrs =
          Map.merge(
            %{"name" => "F #{kind}", "key" => kind, "kind" => sample[:kind] || kind},
            sample.attrs
          )

        {:ok, field} = Fields.create_field(board, attrs)
        {kind, field}
      end

    low = card_fixture(todo, %{"title" => "Low card"})
    high = card_fixture(todo, %{"title" => "High card"})

    for {kind, field} <- fields, not Map.get(@samples[kind], :computed, false) do
      {:ok, _} = Fields.set_value(Boards.Cards.get_card!(low.id), field, @samples[kind].low)
      {:ok, _} = Fields.set_value(Boards.Cards.get_card!(high.id), field, @samples[kind].high)
    end

    %{board: board, fields: fields, low: low, high: high, todo: todo}
  end

  # The two cards as a board view has them: values loaded, formulas computed.
  defp loaded(ctx) do
    fields = Fields.list_fields(Boards.Board.root_id(ctx.board))

    Fields.decorate(
      [Boards.Cards.get_card!(ctx.low.id), Boards.Cards.get_card!(ctx.high.id)],
      fields
    )
  end

  defp titles(cards), do: Enum.map(cards, & &1.title)

  defp mcp(conn, tool, args) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/mcp",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: tool, arguments: args}
      })
    )
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp api_conn(user) do
    {token, _} = Slipdock.Accounts.create_api_token(user, "every-kind", scope: "write")

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  for {kind, _label} <- FieldDefinition.kinds() ++ @variants do
    describe "a #{kind} field" do
      @describetag kind: kind

      test "is filtered by the toolbar", %{kind: kind, conn: conn} = ctx do
        sample = sample!(kind)
        field = ctx.fields[kind]

        {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}")

        assert has_element?(view, ~s|[data-field-filter="#{field.key}"]|),
               "the Filter menu has no control for a #{kind} field"

        filters = Filters.put_field(Filters.empty(), field, sample.filter)
        assert Filters.field_condition(filters, field), "#{inspect(sample.filter)} set no filter"

        assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, filters)) |> titles() ==
                 ["High card"]

        # Every view's Filter menu has it, and a view keeps it (#3608).
        {:ok, table, _} = live(conn, ~p"/boards/#{ctx.board}/table")

        assert has_element?(table, ~s|#swim-config [data-field-filter="#{field.key}"]|),
               "a view's Filter menu has no control for a #{kind} field"

        kept = %{Config.defaults("table") | field_filters: Filters.saved_fields(filters)}

        assert ctx |> loaded() |> Enum.filter(&Swimlanes.matches?(&1, kept)) |> titles() ==
                 ["High card"]

        # The kept condition comes back from the address and a saved view
        # as the same filter (#3613): a kind without a restore is dropped.
        from_url =
          Config.from_query(
            %{"field_filters" => Filters.saved_fields(filters)},
            Config.defaults("table")
          )

        assert from_url.field_filters == kept.field_filters,
               "a #{kind} filter isn't kept in the address"

        restored =
          Filters.put_saved_fields(
            Filters.empty(),
            Map.values(ctx.fields),
            from_url.field_filters
          )

        assert Filters.field_condition(restored, field),
               "a #{kind} filter is dropped when a saved view is opened again"

        assert ctx |> loaded() |> Enum.filter(&Filters.matches?(&1, restored)) |> titles() ==
                 ["High card"]
      end

      test "sorts the cards by its value", %{kind: kind} = ctx do
        sample!(kind)
        field = ctx.fields[kind]
        key = "f:#{field.id}"

        assert {key, field.name} in Config.sorts(%{fields: [field]})

        cards = Enum.reverse(loaded(ctx))
        asc = %Config{Config.defaults("table") | sort: key, dir: "asc"}
        assert cards |> Swimlanes.sort(asc) |> titles() == ["Low card", "High card"]

        assert cards |> Swimlanes.sort(%{asc | dir: "desc"}) |> titles() == [
                 "High card",
                 "Low card"
               ]
      end

      test "is a table column, edited in place by a writer and shown to a reader",
           %{kind: kind, conn: conn, user: user} = ctx do
        sample = sample!(kind)
        field = ctx.fields[kind]
        path = ~p"/boards/#{ctx.board}/table?fields=title,f:#{field.id}"

        {:ok, view, _} = live(conn, path)
        assert has_element?(view, "#card-table th", field.name)
        row = "#row-all-#{ctx.high.id}"

        case sample.editor do
          # A formula is computed: its value, no editor.
          nil ->
            assert has_element?(view, row, sample.shown)

          selector ->
            assert has_element?(view, "#{row} [data-field-cell=#{field.key}] #{selector}"),
                   "a #{kind} column has no editor (#{selector}) for a writer (#3610)"
        end

        reader = user_fixture("reader-#{kind}@example.com")
        {:ok, _} = Slipdock.Access.grant(ctx.board, reader, "read", user)
        {:ok, read_view, _} = live(log_in_user(build_conn(), reader), path)
        assert has_element?(read_view, row, sample.shown)
        refute has_element?(read_view, "#{row} [data-field-cell]")
      end

      test "is edited in the card", %{kind: kind} = ctx do
        sample = sample!(kind)
        field = ctx.fields[kind]
        [_low, high] = loaded(ctx)

        html =
          render_component(&ItemComponents.field_input/1,
            field: field,
            item: high,
            can_write: true,
            id: "fi"
          )

        doc = Floki.parse_fragment!(html)

        case sample.editor do
          nil ->
            # A formula is computed: it shows its value and offers no input.
            assert Floki.find(doc, "input, select, button") == []
            assert html =~ sample.shown

          selector ->
            assert Floki.find(doc, selector) != [],
                   "the card editor for a #{kind} field has no #{selector}"
        end
      end

      test "is set and read through the API, MCP and a wiki page",
           %{kind: kind, user: user} = ctx do
        sample = sample!(kind)
        field = ctx.fields[kind]
        card = card_fixture(ctx.todo, %{"title" => "Through the doors"})
        api = api_conn(user)
        value = sample[:high] || "1"

        rest =
          api |> patch("/api/cards/#{card.id}", %{fields: %{field.key => value}})

        mcp_write = mcp(api, "update_card", %{card: card.id, fields: %{field.key => value}})

        if sample[:computed] do
          # A formula is never set: each door refuses, and it is read as a score.
          assert %{"error" => error} = json_response(rest, 422)
          assert error =~ "computed"
          assert mcp_write["isError"] == true

          read = api |> get("/api/cards/#{ctx.high.id}") |> json_response(200)
          assert read["card"]["scores"][field.key] == sample.json
        else
          json_response(rest, 200)
          assert mcp_write["isError"] == false, inspect(mcp_write["content"])

          read = api |> get("/api/cards/#{card.id}") |> json_response(200)
          assert read["card"]["fields"][field.key] == sample.json

          got = mcp(api, "get_card", %{card: card.id})
          assert got["isError"] == false
          assert mcp_data(got)["fields"][field.key] == sample.json

          # Cleared by "" through the MCP tool.
          assert mcp(api, "update_card", %{card: card.id, fields: %{field.key => ""}})["isError"] ==
                   false

          assert Fields.value(Boards.Cards.get_card!(card.id), field) == nil

          # A wiki page on the board holds the same fields.
          {:ok, page} = Wiki.create_page(ctx.board, %{"title" => "A #{kind} page"}, by: user)

          page_json =
            api
            |> patch("/api/pages/#{page.id}", %{fields: %{field.key => value}})
            |> json_response(200)

          assert page_json["page"]["fields"][field.key] == sample.json
        end
      end

      test "is a swimlane axis, or explicitly not one", %{kind: kind} = ctx do
        sample = sample!(kind)
        field = ctx.fields[kind]
        key = "f:#{field.id}"
        board = %{fields: [field]}

        assert FieldDefinition.axis?(field) == sample.axis
        assert {key, field.name} in Config.axes(board) == sample.axis

        if sample.axis do
          [low, high] = loaded(ctx)
          buckets = Swimlanes.buckets(key, board, [low, high], Config.defaults("board"))
          bucket_keys = Enum.map(buckets, & &1.key)

          # A card holding several options has a lane for each (#3611).
          for card <- [low, high], card_key <- Swimlanes.card_keys(card, key, nil) do
            assert card_key in bucket_keys, "#{card.title} has no lane on a #{kind} axis"
          end

          refute Swimlanes.card_keys(low, key, nil) == Swimlanes.card_keys(high, key, nil)
        end
      end
    end
  end
end
