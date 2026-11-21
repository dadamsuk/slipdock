defmodule Slipdock.UrlFieldTest do
  @moduledoc """
  URL fields (#3613): one http(s) link, refused otherwise (so nothing else
  ever becomes an `href`), shown as its host, filtered on the text it
  contains and sorted; not a swimlane axis.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Fields, Filters, Swimlanes}
  alias Slipdock.Boards.FieldDefinition
  alias Slipdock.Swimlanes.Config

  setup do
    board = board_fixture(%{"name" => "Reading list"})
    [col | _] = board.columns
    {:ok, link} = Fields.create_field(board, %{"name" => "Link", "kind" => "url"})
    card = card_fixture(col, %{"title" => "An article"})
    %{board: board, col: col, link: link, card: card}
  end

  test "takes an http or https link, trimmed", %{link: link, card: card} do
    {:ok, card} = Fields.set_value(card, link, "  https://example.com/a?b=1  ")
    assert Fields.value(card, link) == "https://example.com/a?b=1"

    {:ok, card} = Fields.set_value(card, link, "http://example.com")
    assert Fields.value(card, link) == "http://example.com"
  end

  test "refuses anything else, and keeps the value it had", %{link: link, card: card} do
    {:ok, card} = Fields.set_value(card, link, "https://example.com/kept")

    for bad <- [
          "javascript:alert(1)",
          "JavaScript:alert(1)",
          "ftp://example.com/file",
          "mailto:someone@example.com",
          "data:text/html,hi",
          "example.com",
          "https://",
          "not a link at all"
        ] do
      assert {:error, "Link needs an http or https link, like https://example.com."} =
               Fields.set_value(Boards.Cards.get_card!(card.id), link, bad),
             bad
    end

    assert Fields.value(Boards.Cards.get_card!(card.id), link) == "https://example.com/kept"
  end

  test "an empty value clears it", %{link: link, card: card} do
    {:ok, card} = Fields.set_value(card, link, "https://example.com")
    {:ok, card} = Fields.set_value(card, link, "")
    assert Fields.value(card, link) == nil
  end

  test "is shown as its host, without www.", %{link: link} do
    assert Fields.format(link, "https://www.example.com/a/b?c=d") == "example.com"
    assert Fields.format(link, "http://docs.example.com:8080/x") == "docs.example.com"
  end

  test "web_link? is http(s) with a host and nothing else" do
    assert Fields.web_link?("https://example.com")
    assert Fields.web_link?("http://example.com/x")
    refute Fields.web_link?("javascript:alert(1)")
    refute Fields.web_link?("//example.com")
    refute Fields.web_link?("https://")
    refute Fields.web_link?(nil)
  end

  test "filters on the text the whole link contains, and sorts", %{col: col, link: link} = ctx do
    a = card_fixture(col, %{"title" => "Alpha"})
    b = card_fixture(col, %{"title" => "Beta"})
    {:ok, _} = Fields.set_value(a, link, "https://example.com/zebra")
    {:ok, _} = Fields.set_value(b, link, "https://another.example.com/apple")

    cards =
      Fields.decorate(
        [Boards.Cards.get_card!(a.id), Boards.Cards.get_card!(b.id)],
        Fields.list_fields(ctx.board.id)
      )

    filters = Filters.put_field(Filters.empty(), link, %{"text" => "ZEBRA"})

    assert cards |> Enum.filter(&Filters.matches?(&1, filters)) |> Enum.map(& &1.title) == [
             "Alpha"
           ]

    asc = %Config{Config.defaults("table") | sort: "f:#{link.id}", dir: "asc"}
    assert cards |> Swimlanes.sort(asc) |> Enum.map(& &1.title) == ["Beta", "Alpha"]
  end

  test "is not a swimlane axis", %{link: link, board: board} do
    refute FieldDefinition.axis?(link)
    refute {"f:#{link.id}", "Link"} in Config.axes(%{board | fields: [link]})
  end

  test "an import holds a URL field's value to http(s) too" do
    importer = user_fixture("importer@example.com")

    document =
      Jason.encode!(%{
        slipdock_portable: 1,
        boards: [
          %{
            root: %{ref: "r", name: "Imported", code: "imp", lists: [%{ref: "l1", name: "To Do"}]},
            boards: [],
            fields: [%{ref: "f1", name: "Link", key: "link", kind: "url"}],
            cards: [
              %{
                ref: "k1",
                board: "r",
                list: "l1",
                title: "Bad",
                fields: [%{field: "f1", text: "javascript:alert(1)"}]
              },
              %{ref: "k3", board: "r", list: "l1", title: "Empty", fields: [%{field: "f1"}]},
              %{
                ref: "k2",
                board: "r",
                list: "l1",
                title: "Good",
                fields: [%{field: "f1", text: "https://example.com/a"}]
              }
            ]
          }
        ]
      })

    {:ok, report} = Slipdock.Portable.import(importer, document)
    board = Boards.get_board!(hd(report.boards).id)
    [link] = Fields.list_fields(board.id)
    cards = Boards.Cards.list_cards(board, %{}) |> Map.new(&{&1.title, &1})

    assert Fields.value(cards["Good"], link) == "https://example.com/a"
    assert Fields.value(cards["Bad"], link) == nil

    assert Enum.any?(
             report.skipped,
             &(&1 =~ "A field value on “Bad” was left out: Link needs an http or https link")
           )

    # A row with no link says nothing wrong, so it isn't reported.
    refute Enum.any?(report.skipped, &(&1 =~ "“Empty”"))
  end
end
