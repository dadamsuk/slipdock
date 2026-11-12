defmodule SlipdockWeb.FlagAttentionLiveTest do
  @moduledoc """
  A flag says who clears it (#2624): filled, with a solid icon, when a
  person has to act; outline only when the board's own processes clear it.
  On the card face, the card panel, the API and MCP.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Repo}
  alias SlipdockWeb.MCP.Tools

  setup %{user: user} do
    board = board_fixture(%{"name" => "Flags", "code" => "flg2624"}, owner: user)
    [todo, doing | _] = board.columns
    %{board: board, todo: todo, doing: doing}
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp flag(html, card, name),
    do:
      html
      |> doc()
      |> LazyHTML.query("#card-#{card.id} [data-role=card-meta] [data-flag=#{name}]")

  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  defp classes(node), do: node |> attr("class") |> String.split()

  defp pool!(board),
    do: board |> Ecto.Changeset.change(verify_work: true, verify_pool: "verify") |> Repo.update!()

  defp pending!(card),
    do:
      card |> Ecto.Changeset.change(verify_state: "pending", flags: ["review"]) |> Repo.update!()

  describe "the card face" do
    test "a person's flag is filled with a solid icon, and says so", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Asked", "flags" => ["waiting"]})
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      node = flag(html, card, "waiting")

      assert attr(node, "data-attention") == "person"
      assert "chip-tint" in classes(node)
      refute "chip-auto" in classes(node)
      assert attr(node, "title") == "Waiting · Needs a person: Waits on a person's answer."
      assert node |> LazyHTML.query(".hero-clock-solid") |> Enum.count() == 1
      assert node |> LazyHTML.query(".sr-only") |> LazyHTML.text() =~ "Needs a person"
    end

    test "blocked by an open card is outline only, naming the blocker", ctx do
      blocker = card_fixture(ctx.todo, %{"title" => "First"})
      card = card_fixture(ctx.todo, %{"title" => "Second", "flags" => ["blocked"]})
      {:ok, _} = Boards.Dependencies.add_dependency(card, blocker)

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      node = flag(html, card, "blocked")

      assert attr(node, "data-attention") == "auto"
      assert "chip-auto" in classes(node)
      refute "chip-tint" in classes(node)

      assert attr(node, "title") ==
               "Blocked · Clears itself: Clears itself when ##{blocker.id} is done."

      assert node |> LazyHTML.query(".hero-no-symbol") |> Enum.count() == 1
    end

    test "blocked by nothing on the board is a person's", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Waiting on a supplier", "flags" => ["blocked"]})
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert flag(html, card, "blocked") |> attr("data-attention") == "person"
    end

    test "review clears itself on a board with a verify pool, and is a person's without", ctx do
      card = card_fixture(ctx.doing, %{"title" => "Submitted"}) |> pending!()

      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      assert flag(html, card, "review") |> attr("data-attention") == "person"

      pool!(ctx.board)
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      node = flag(html, card, "review")
      assert attr(node, "data-attention") == "auto"
      assert attr(node, "title") =~ "A verifier agent checks it"
    end

    test "starred is plain: neither filled for a person nor outlined", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Kept", "flags" => ["starred"]})
      {:ok, _view, html} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      node = flag(html, card, "starred")
      assert attr(node, "data-attention") == "none"
      refute "chip-auto" in classes(node)
    end
  end

  describe "the card panel" do
    test "a person's chip has the hand; one that clears itself says so", ctx do
      blocker = card_fixture(ctx.todo, %{"title" => "First"})
      card = card_fixture(ctx.todo, %{"title" => "Second", "flags" => ["blocked", "waiting"]})
      {:ok, _} = Boards.Dependencies.add_dependency(card, blocker)

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{card.id}")

      assert has_element?(view, "#card-flag-waiting[data-attention=person] .hero-hand-raised")
      refute has_element?(view, "#card-flag-waiting", "clears itself")
      assert has_element?(view, "#card-flag-blocked[data-attention=auto]", "clears itself")
      refute has_element?(view, "#card-flag-blocked .hero-hand-raised")

      assert has_element?(
               view,
               ~s(#card-flag-blocked[title="Blocked · Clears itself: Clears itself when ##{blocker.id} is done."])
             )
    end
  end

  describe "the API and MCP" do
    test "the card carries flag_attention per flag", ctx do
      pool!(ctx.board)
      card = card_fixture(ctx.doing, %{"title" => "Submitted"}) |> pending!()
      Boards.Cards.update_card(card, %{"flags" => ["review", "starred"]})

      body =
        ctx.conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/cards/#{card.id}")
        |> json_response(200)

      assert %{
               "review" => %{
                 "attention" => "auto",
                 "why" => "A verifier agent checks it and decides."
               },
               "starred" => %{"attention" => "none"}
             } = body["flag_attention"] || body["card"]["flag_attention"]

      line = Tools.card_line(Boards.with_state(Boards.Cards.get_card!(card.id)))
      assert line.flag_attention["review"]["attention"] == "auto"
    end

    test "MCP's card line leaves it out when the card has no flags", ctx do
      card = card_fixture(ctx.todo, %{"title" => "Plain"})

      refute Map.has_key?(
               Tools.card_line(Boards.with_state(Boards.Cards.get_card!(card.id))),
               :flag_attention
             )
    end
  end
end
