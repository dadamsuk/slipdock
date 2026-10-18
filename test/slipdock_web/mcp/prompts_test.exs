defmodule SlipdockWeb.MCP.PromptsTest do
  @moduledoc """
  MCP prompts (W-1805): `prompts/list` and `prompts/get` over `/mcp`, the
  frame every rendered prompt gets (conventions, read-only notice, tools to
  use, size cap), argument checking, and the live context helpers' access
  rules. The prompts themselves are tested beside this.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Accounts
  alias SlipdockWeb.MCP.Prompts
  alias SlipdockWeb.MCP.Prompts.Context

  defmodule Echo do
    @moduledoc false
    @behaviour SlipdockWeb.MCP.Prompt

    def name, do: "echo"
    def title, do: "Echo"
    def description, do: "Says what it was given."

    def arguments,
      do: [
        %{name: "board", description: "Board id, code or name.", required: true},
        %{name: "note", description: "Anything.", required: false}
      ]

    def writes?, do: true
    def tools, do: ["get_board", "move_card"]

    def render(%{"board" => "refuse"}, _context),
      do: {:error, "no board you can see matches that"}

    def render(%{"board" => "huge"}, _context), do: {:ok, String.duplicate("x", 50_000)}
    def render(args, _context), do: {:ok, "board=#{args["board"]} note=#{inspect(args["note"])}"}
  end

  defmodule Reader do
    @moduledoc false
    @behaviour SlipdockWeb.MCP.Prompt

    def name, do: "reader"
    def title, do: "Reader"
    def description, do: "Reads only."
    def arguments, do: []
    def writes?, do: false
    def tools, do: ["list_cards"]
    def render(_args, _context), do: {:ok, "just reading"}
  end

  defp rpc(conn, method, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))
    |> json_response(200)
  end

  defp context(user, scope \\ "write"), do: %{user: user, token: %{scope: scope}, base_url: ""}

  defp text!({:ok, %{messages: [%{role: "user", content: %{type: "text", text: text}}]}}),
    do: text

  describe "over /mcp" do
    test "prompts/list lists every prompt offered, each with its arguments", %{conn: conn} do
      %{"result" => %{"prompts" => prompts}} = rpc(conn, "prompts/list", %{})
      assert length(prompts) == length(Prompts.all())

      for prompt <- prompts do
        assert is_binary(prompt["name"]) and is_binary(prompt["title"])
        assert is_binary(prompt["description"])

        for arg <- prompt["arguments"] do
          assert Map.keys(arg) |> Enum.sort() == ["description", "name", "required"]
        end
      end
    end

    test "an unknown prompt is -32602 naming it", %{conn: conn} do
      body = rpc(conn, "prompts/get", %{name: "no-such-prompt"})
      assert body["error"]["code"] == -32602
      assert body["error"]["message"] == "unknown prompt: no-such-prompt"
    end

    test "prompts/get without a name is -32602", %{conn: conn} do
      assert rpc(conn, "prompts/get", %{})["error"]["code"] == -32602
    end
  end

  describe "get/3" do
    test "answers one user message: conventions, the body, the tools last", %{user: user} do
      text = text!(Prompts.get(Echo, %{"board" => " b1 "}, context(user)))

      assert text =~ ~r/^Slipdock conventions:/
      assert text =~ "board=b1 note=nil"
      assert text |> String.split("\n\n") |> List.last() == "Tools to use: get_board, move_card."
      refute text =~ "read-only"
    end

    test "says the token is read-only when the workflow would write", %{user: user} do
      text = text!(Prompts.get(Echo, %{"board" => "b1"}, context(user, "read")))
      assert text =~ "read-only"
      assert text =~ "report what you would do"
    end

    test "a read-only workflow gets no notice on a read-only token", %{user: user} do
      refute text!(Prompts.get(Reader, %{}, context(user, "read"))) =~ "read-only"
    end

    test "a missing or blank required argument is refused, naming it", %{user: user} do
      assert {:error, msg} = Prompts.get(Echo, %{}, context(user))
      assert msg =~ "echo needs the board argument"
      assert {:error, ^msg} = Prompts.get(Echo, %{"board" => "  "}, context(user))
    end

    test "a blank optional argument is as good as absent", %{user: user} do
      assert text!(Prompts.get(Echo, %{"board" => "b", "note" => " "}, context(user))) =~
               "note=nil"
    end

    test "an unknown argument is refused, naming what it takes", %{user: user} do
      assert {:error, msg} = Prompts.get(Echo, %{"board" => "b", "bord" => "x"}, context(user))
      assert msg =~ ~s(no argument "bord")
      assert msg =~ "only board, note"

      assert {:error, msg} = Prompts.get(Reader, %{"x" => "1"}, context(user))
      assert msg =~ "no arguments"
    end

    test "an argument that is not a string is refused", %{user: user} do
      assert {:error, "argument board must be a string"} =
               Prompts.get(Echo, %{"board" => 3}, context(user))

      assert {:error, _} = Prompts.get(Echo, "nope", context(user))
    end

    test "render's refusal comes back as the error", %{user: user} do
      assert {:error, "no board you can see matches that"} =
               Prompts.get(Echo, %{"board" => "refuse"}, context(user))
    end

    test "the body is cut at the size cap; the tools line survives", %{user: user} do
      text = text!(Prompts.get(Echo, %{"board" => "huge"}, context(user)))
      assert String.length(text) <= Prompts.max_chars()
      assert text =~ "…cut at the size cap"
      assert text =~ ~r/Tools to use: get_board, move_card\.$/
    end
  end

  describe "the live context" do
    setup %{user: user} do
      mine = board_fixture(%{"name" => "Mine", "code" => "mine1"}, owner: user)
      other = board_fixture(%{"name" => "Other", "code" => "other1"}, owner: user)
      stranger = user_fixture("stranger@example.com")
      theirs = board_fixture(%{"name" => "Theirs", "code" => "theirs1pr"}, owner: stranger)
      %{mine: mine, other: other, theirs: theirs}
    end

    test "boards/1 is what the token sees: a scoped token only its boards", ctx do
      codes = ctx.user |> context() |> Context.boards() |> Enum.map(& &1.code)
      assert "mine1" in codes and "other1" in codes
      refute "theirs1pr" in codes

      {_, token} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [ctx.mine.id])
      scoped = %{user: ctx.user, token: token, base_url: ""}
      assert scoped |> Context.boards() |> Enum.map(& &1.code) == ["mine1"]
    end

    test "board/2 loads a readable board and refuses the rest", ctx do
      assert {:ok, board} = Context.board(context(ctx.user), "mine1")
      assert board.id == ctx.mine.id and is_list(hd(board.columns).cards)

      assert {:error, _} = Context.board(context(ctx.user), "theirs1pr")

      {_, token} = Accounts.create_api_token(ctx.user, "scoped", scope_boards: [ctx.mine.id])
      assert {:error, msg} = Context.board(%{user: ctx.user, token: token}, "other1")
      assert msg =~ "scope"
    end

    test "lists_line names each list's open count and part", ctx do
      {:ok, board} = Context.board(context(ctx.user), "mine1")
      [first | _] = board.columns
      card_fixture(first, %{"title" => "Open one"})
      card_fixture(first, %{"title" => "Done one", "completed" => true})
      {:ok, board} = Context.board(context(ctx.user), "mine1")

      assert Context.lists_line(board) =~ "#{first.name} (1 open"
    end

    test "card_line says what stands out", ctx do
      [col | _] = ctx.mine.columns

      card =
        card_fixture(col, %{
          "title" => "Ship it",
          "priority" => "high",
          "due_date" => "2026-10-20",
          "flags" => ["blocked"]
        })

      assert Context.card_line(card) ==
               "##{card.id} Ship it (high priority; due 2026-10-20; flagged blocked)"

      plain = card_fixture(col, %{"title" => "Plain"})
      assert Context.card_line(plain) == "##{plain.id} Plain"
    end
  end

  describe "list/3" do
    test "cuts a long list and says how many more, and which tool lists them" do
      assert Context.list(~w(a b c d), 2, "list_cards") ==
               "- a\n- b\n- …and 2 more, use list_cards"

      assert Context.list(~w(a b), 2, "list_cards") == "- a\n- b"
      assert Context.list([], 2, "list_cards") == "- none"
    end
  end
end
