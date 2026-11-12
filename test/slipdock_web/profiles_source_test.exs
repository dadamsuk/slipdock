defmodule SlipdockWeb.ProfilesSourceTest do
  @moduledoc """
  Where a card's profile came from (#2018): recorded as "inferred" when an
  agent starting the card gets one, else as who set it (a person, an agent
  or a rule), cleared with it, and kept by a write that leaves the profile
  alone. It shows in the card's JSON (REST), MCP's get_card and list_cards,
  the card panel (beside the select, which sits with the bar and paths now)
  and the card's front. On a board with profiles on, a card with none shows
  what inference would give it and why, and a person can take it.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Boards, Profiles, Repo}
  alias Slipdock.Boards.Card

  setup %{user: user} do
    board = board_fixture(%{"name" => "Sourced", "code" => unique_code()}, owner: user)
    [_backlog, todo, doing, _done] = board.columns
    card = card_fixture(todo, %{"title" => "Work"})
    {token, _} = Accounts.create_api_token(user, "bot")

    agent =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)

    %{board: board, todo: todo, doing: doing, card: card, agent: agent}
  end

  defp mcp_json(conn, tool, args) do
    result =
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

    assert result["isError"] == false, inspect(result)
    [%{"text" => text}] = result["content"]
    Jason.decode!(text)
  end

  defp source(card), do: Repo.get!(Card, card.id).profile_source

  defp profiles_on(ctx), do: {:ok, _} = Boards.update_board(ctx.board, %{"profiles" => true})

  describe "recording it" do
    test "an agent starting the card on a profiles board records it as inferred", ctx do
      profiles_on(ctx)
      {:ok, _} = Boards.Cards.update_card(ctx.card, %{"paths" => "priv/repo/migrations/**"})

      ctx.agent
      |> post(~p"/api/cards/#{ctx.card.id}/move", %{"column" => ctx.doing.name})
      |> json_response(200)

      assert %Card{profile: "schema", profile_source: "inferred"} = Repo.get!(Card, ctx.card.id)
    end

    test "a token over REST sets it as an agent; clearing the profile clears it", ctx do
      resp = ctx.agent |> patch(~p"/api/cards/#{ctx.card.id}", %{"profile" => "fix"})
      assert json_response(resp, 200)["card"]["profile_source"] == "agent"

      resp = ctx.agent |> patch(~p"/api/cards/#{ctx.card.id}", %{"profile" => ""})
      card = json_response(resp, 200)["card"]
      assert card["profile"] == nil
      assert card["profile_source"] == nil
    end

    test "a write that leaves the profile alone keeps where it came from", ctx do
      {:ok, card} =
        Boards.Cards.update_card(ctx.card, %{"profile" => "docs"},
          actor: Slipdock.Actor.web(ctx.user)
        )

      assert card.profile_source == "person"
      {:ok, card} = Boards.Cards.update_card(card, %{"title" => "Renamed"})
      assert card.profile_source == "person"
    end

    test "a rule setting it is a rule; nobody known records nothing", ctx do
      Process.put(:automation_depth, 1)
      {:ok, card} = Boards.Cards.update_card(ctx.card, %{"profile" => "spike"})
      Process.delete(:automation_depth)
      assert card.profile_source == "rule"

      Slipdock.Actor.put(nil)
      {:ok, card} = Boards.Cards.update_card(card, %{"profile" => "feature"})
      assert card.profile_source == nil
    end

    test "a card created with a profile records who made it", ctx do
      {:ok, card} =
        Boards.Cards.create_card(ctx.todo, %{"title" => "Made", "profile" => "docs"},
          actor: Slipdock.Actor.mcp(%{user: ctx.user})
        )

      assert card.profile_source == "agent"
    end
  end

  describe "MCP" do
    test "update_card sets it as an agent; get_card and list_cards show it", ctx do
      mcp_json(ctx.agent, "update_card", %{card: ctx.card.id, profile: "security"})
      assert source(ctx.card) == "agent"

      card = mcp_json(ctx.agent, "get_card", %{card: ctx.card.id})
      assert (card["card"] || card)["profile_source"] == "agent"

      lines = mcp_json(ctx.agent, "list_cards", %{board: ctx.board.code})["cards"]
      assert Enum.find(lines, &(&1["id"] == ctx.card.id))["profile_source"] == "agent"
    end

    test "list_cards leaves the source out of a card with no profile", ctx do
      lines = mcp_json(ctx.agent, "list_cards", %{board: ctx.board.code})["cards"]
      refute Map.has_key?(Enum.find(lines, &(&1["id"] == ctx.card.id)), "profile_source")
    end
  end

  describe "the preview" do
    test "explain_card names the path, the tag or the default it went on", ctx do
      tagged = fn names ->
        %{paths: [], tags: Enum.map(names, &%{name: &1})}
      end

      assert Profiles.explain_card(%{paths: ["priv/repo/migrations/1_x.exs"], tags: []}) ==
               {"schema", "from priv/repo/migrations/1_x.exs"}

      assert Profiles.explain_card(%{paths: ["lib/x/auth.ex"], tags: []}) ==
               {"security", "from lib/x/auth.ex"}

      assert Profiles.explain_card(tagged.(["Security"])) == {"security", "from the security tag"}
      assert Profiles.explain_card(tagged.(["bug"])) == {"fix", "from the bug tag"}
      assert Profiles.explain_card(tagged.(["spike"])) == {"spike", "from the spike tag"}

      assert Profiles.explain_card(%{paths: ["docs/a.md"], tags: []}) ==
               {"docs", "from its paths, all docs"}

      assert Profiles.explain_card(%{paths: ["lib/x.ex"], tags: []}) ==
               {"feature", "the default for its paths"}

      # A card with no paths: the default, and why.
      assert Profiles.explain_card(ctx.card) == {"feature", "the default: it has no paths yet"}
      assert Profiles.explain_card(%{paths: nil, tags: []}) == Profiles.explain_card(ctx.card)
    end

    test "it agrees with what an agent starting the card would be given", ctx do
      for paths <- [[], ["priv/repo/migrations/x.exs"], ["docs/a.md"], ["lib/token.ex"]] do
        card = %{paths: paths, tags: []}
        assert elem(Profiles.explain_card(card), 0) == Profiles.infer_card(card)
      end

      assert ctx.card.paths == []
    end
  end

  describe "the card panel" do
    test "the profile sits with the agent work, not among the general fields", ctx do
      profiles_on(ctx)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      assert has_element?(view, "#card-profile-form #card-profile")
      refute has_element?(view, "#card-meta-form #card-profile")
    end

    test "with profiles off and no profile, there is no section and no preview", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      refute has_element?(view, "#card-profile-form")
      refute has_element?(view, "#card-profile-preview")
    end

    test "a card with no paths previews the default, and taking it sets it as a person", ctx do
      profiles_on(ctx)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      preview = view |> element("#card-profile-preview") |> render()
      assert preview =~ "would be inferred"
      assert preview =~ "feature"
      assert preview =~ "the default: it has no paths yet"

      view |> element("#card-profile-accept") |> render_click()

      assert %Card{profile: "feature", profile_source: "person"} = Repo.get!(Card, ctx.card.id)
      refute has_element?(view, "#card-profile-preview")
      assert view |> element("#card-profile-source") |> render() =~ "set by person"
    end

    test "a card with a migration path previews schema and names the path", ctx do
      profiles_on(ctx)

      {:ok, _} =
        Boards.Cards.update_card(ctx.card, %{"paths" => "priv/repo/migrations/20261107_x.exs"})

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      preview = view |> element("#card-profile-preview") |> render()
      assert preview =~ "schema"
      assert preview =~ "from priv/repo/migrations/20261107_x.exs"
    end

    test "choosing another profile in the select overrides the guess, as a person", ctx do
      profiles_on(ctx)
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      view |> form("#card-profile-form", card: %{"profile" => "docs"}) |> render_change()

      assert %Card{profile: "docs", profile_source: "person"} = Repo.get!(Card, ctx.card.id)
    end

    test "an inferred profile says so beside the select, and shows no preview", ctx do
      profiles_on(ctx)

      {:ok, _} =
        ctx.card
        |> Ecto.Changeset.change(profile: "schema", profile_source: "inferred")
        |> Repo.update()

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")
      assert view |> element("#card-profile-source") |> render() =~ "inferred"
      refute has_element?(view, "#card-profile-preview")
    end

    test "a profile with no recorded source shows the profile alone", ctx do
      {:ok, _} = ctx.card |> Ecto.Changeset.change(profile: "fix") |> Repo.update()
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card}")

      assert has_element?(view, "#card-profile option[value=fix][selected]")
      refute has_element?(view, "#card-profile-source")
    end
  end

  describe "the card's front" do
    test "an inferred profile's chip is lighter and says so; a set one isn't", ctx do
      {:ok, _} =
        ctx.card
        |> Ecto.Changeset.change(profile: "schema", profile_source: "inferred")
        |> Repo.update()

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      chip = view |> element("#card-#{ctx.card.id} [data-role=profile]") |> render()
      assert chip =~ ~s(data-source="inferred")
      assert chip =~ "border-dashed"
      assert chip =~ "Profile: schema, inferred"

      {:ok, _} =
        Boards.Cards.update_card(Repo.get!(Card, ctx.card.id), %{"profile" => "fix"},
          actor: Slipdock.Actor.web(ctx.user)
        )

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}")
      chip = view |> element("#card-#{ctx.card.id} [data-role=profile]") |> render()
      refute chip =~ "border-dashed"
      assert chip =~ "Profile: fix, set by person"
    end
  end
end
