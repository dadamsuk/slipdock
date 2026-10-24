defmodule Slipdock.BlueprintTest do
  @moduledoc """
  The board blueprint (#959): one applier that templates and Tools both build
  boards with — lists with roles, folders, tags, page skeletons and preset
  rules — additive, so applying it again adds nothing.
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
  import Slipdock.Fixtures

  alias Slipdock.{Automations, Blueprint, Boards, Repo, Wiki}
  alias Slipdock.Wiki.Folders

  @blueprint %{
    "lists" => [
      %{"name" => "Found", "role" => "ready"},
      %{"name" => "Interested"},
      %{"name" => "Working", "role" => "doing", "wip_limit" => 2, "color" => "amber"},
      %{"name" => "Closed", "role" => "done"}
    ],
    "folders" => ["Config", "Runs/Archive"],
    "tags" => ["interim", %{"name" => "urgent", "color" => "red"}],
    "pages" => [
      %{"title" => "Setup", "folder" => "Config", "body" => "# {{board.name}}", "summary" => "s"},
      %{"title" => "Loose", "body" => "no folder"}
    ],
    "automations" => [
      %{"preset" => "feed_runner", "params" => %{"column" => "Interested", "pool" => "default"}}
    ]
  }

  defp bare_board(user) do
    board = board_fixture(%{}, owner: user)
    # A board with no lists of its own, as a Tool's install starts from.
    Enum.each(board.columns, &Boards.delete_column/1)
    Boards.get_board!(board.id)
  end

  describe "validate/2" do
    test "a page may carry front matter, which must be YAML text (#1262)" do
      page = %{"title" => "P", "front_matter" => "handbook: ux\ncovers: []"}

      assert {:ok, %{"pages" => [clean]}} =
               Blueprint.validate(%{"lists" => [], "pages" => [page]}, lists: :optional)

      assert clean["front_matter"] == "handbook: ux\ncovers: []"

      assert {:error, message} =
               Blueprint.validate(
                 %{"pages" => [%{page | "front_matter" => "a: 1\n---\nb: 2"}]},
                 lists: :optional
               )

      assert message =~ "front_matter is a string of YAML"

      assert {:error, _} =
               Blueprint.validate(%{"pages" => [%{page | "front_matter" => 7}]}, lists: :optional)
    end

    test "a page's front matter lands on the page it makes", %{} do
      user = user_fixture()
      board = bare_board(user)

      {:ok, _} =
        Blueprint.apply(board, %{"pages" => [%{"title" => "FM", "front_matter" => "kind: x"}]},
          user: user
        )

      page = Repo.get_by!(Wiki.Page, board_id: board.id, title: "FM")
      assert page.front_matter == "---\nkind: x\n---\n\n"
    end

    test "cleans a good blueprint up and sets categories from roles (or guesses from names)" do
      assert {:ok, bp} = Blueprint.validate(@blueprint)

      assert Enum.map(bp["lists"], &{&1["name"], &1["category"]}) == [
               {"Found", "todo"},
               {"Interested", nil},
               {"Working", "doing"},
               {"Closed", "done"}
             ]

      assert Enum.at(bp["lists"], 2)["wip_limit"] == 2

      assert bp["tags"] == [
               %{"name" => "interim", "color" => nil},
               %{"name" => "urgent", "color" => "red"}
             ]

      assert bp["folders"] == ["Config", "Runs/Archive"]
      assert hd(bp["pages"])["folder"] == "Config"
    end

    test "a role the server would read differently is refused, naming the list that wins" do
      lists = [%{"name" => "To Do"}, %{"name" => "Found", "role" => "ready"}, "Done"]

      assert {:error, message} = Blueprint.validate(%{"lists" => lists})
      assert message =~ "“Found” is meant to be the ready list"
      assert message =~ "“To Do”"
    end

    test "each kind of mistake gets its own message" do
      cases = [
        {%{}, "a board needs at least one list"},
        {%{"lists" => ["A"], "colour" => 1}, "unknown key “colour”"},
        {%{"lists" => ["A", "a"]}, "“A” appears twice"},
        {%{"lists" => [%{"name" => "A", "role" => "boss"}]}, "role must be one of"},
        {%{"lists" => [%{"name" => "A", "category" => "later"}]}, "category must be one of"},
        {%{"lists" => [%{"name" => "A", "role" => "done", "category" => "todo"}]},
         "role done means category done"},
        {%{"lists" => ["A"], "folders" => [""]}, "a folder needs a name"},
        {%{"lists" => ["A"], "tags" => [String.duplicate("x", 31)]}, "at most 30 characters"},
        {%{"lists" => ["A"], "tags" => [%{"name" => "t", "color" => "plaid"}]}, "unknown colour"},
        {%{"lists" => ["A"], "pages" => [%{"title" => "P", "folder" => "Nope"}]},
         "folder “Nope” is not in folders"},
        {%{"lists" => ["A"], "pages" => [%{"body" => "x"}]}, "a page needs a title"},
        {%{"lists" => ["A"], "automations" => [%{"preset" => "make_coffee"}]},
         "unknown preset “make_coffee”"},
        {%{
           "lists" => ["A"],
           "automations" => [%{"preset" => "follow_list", "params" => %{"column" => "B"}}]
         }, "no list called “B”"},
        {%{"lists" => ["A"], "automations" => [%{"preset" => "follow_list", "params" => %{}}]},
         "needs List"},
        {"lists", "a blueprint is a JSON object"}
      ]

      for {bp, expected} <- cases do
        assert {:error, message} = Blueprint.validate(bp), "expected an error for #{inspect(bp)}"
        assert message =~ expected
      end
    end
  end

  describe "apply/3" do
    test "creates every element on the board" do
      user = user_fixture()
      board = bare_board(user)

      assert {:ok, report} = Blueprint.apply(board, @blueprint, user: user, message: "set up")

      assert report.added["lists"] == ["Found", "Interested", "Working", "Closed"]
      assert report.added["folders"] == ["Config", "Runs/Archive"]
      assert report.added["tags"] == ["interim", "urgent"]
      assert report.added["pages"] == ["Setup", "Loose"]
      assert [_rule] = report.added["automations"]

      board = Boards.get_board!(board.id)
      assert Enum.map(board.columns, & &1.name) == ["Found", "Interested", "Working", "Closed"]
      roles = SlipdockWeb.APIGuide.list_roles(board.columns)
      assert roles.ready.name == "Found"
      assert roles.doing.name == "Working"
      assert roles.done.name == "Closed"
      assert Enum.find(board.columns, &(&1.name == "Working")).wip_limit == 2

      assert {:ok, archive} = Folders.find(board, "Runs/Archive")
      assert archive.parent_id

      assert board.id |> Boards.list_tags() |> Enum.map(& &1.name) |> Enum.sort() ==
               ["interim", "urgent"]

      {:ok, config} = Folders.find(board, "Config")
      setup = Enum.find(Wiki.list_pages(board), &(&1.title == "Setup"))
      assert setup.folder_id == config.id
      assert setup.body == "# #{board.name}"

      assert [rule] = Automations.list_rules(board.id)
      assert rule.spec["trigger"]["column"] == "Interested"
      assert rule.created_by_id == user.id
    end

    test "a runner rule's prompt in the blueprint is the prompt its jobs are sent (#1156)" do
      user = user_fixture()
      board = bare_board(user)

      blueprint =
        Map.put(@blueprint, "automations", [
          %{
            "preset" => "send_to_runner",
            "name" => "Draft it",
            "params" => %{
              "column" => "Working",
              "pool" => "generate",
              "prompt" => "Draft a reply to {{card.title}}, using the Setup page."
            }
          }
        ])

      assert {:ok, _} = Blueprint.apply(board, blueprint, user: user)

      assert [rule] = Automations.list_rules(board.id)
      assert rule.name == "Draft it"
      assert rule.spec["trigger"] == %{"type" => "card_entered", "column" => "Working"}

      assert [%{"type" => "runner", "pool" => "generate", "prompt" => prompt}] =
               rule.spec["actions"]

      assert prompt == "Draft a reply to {{card.title}}, using the Setup page."

      working =
        board.id
        |> Boards.get_board!()
        |> Map.fetch!(:columns)
        |> Enum.find(&(&1.name == "Working"))

      card = card_fixture(working, %{"title" => "Acme enquiry"})

      Slipdock.Automations.Runner.run(rule, %{
        type: "card_entered",
        card: card,
        board_id: board.id
      })

      [job] = Repo.all(from(j in Slipdock.Runners.Job, where: j.rule_id == ^rule.id))
      assert job.pool == "generate"
      assert job.prompt =~ "Draft a reply to Acme enquiry, using the Setup page."
    end

    test "is idempotent: a second apply adds nothing and reports it all skipped" do
      user = user_fixture()
      board = bare_board(user)
      {:ok, _} = Blueprint.apply(board, @blueprint, user: user)

      counts = fn ->
        b = Boards.get_board!(board.id)

        {length(b.columns), length(Folders.list(b)), length(Boards.list_tags(b.id)),
         length(Wiki.list_pages(b)), length(Automations.list_rules(b.id))}
      end

      before = counts.()
      assert {:ok, report} = Blueprint.apply(Boards.get_board!(board.id), @blueprint, user: user)
      assert counts.() == before

      assert Enum.all?(Map.values(report.added), &(&1 == []))
      assert report.skipped["lists"] == ["Found", "Interested", "Working", "Closed"]
      assert report.skipped["pages"] == ["Setup", "Loose"]
      assert length(report.skipped["automations"]) == 1
    end

    test "an invalid blueprint changes nothing" do
      user = user_fixture()
      board = bare_board(user)
      bad = Map.put(@blueprint, "pages", [%{"title" => "P", "folder" => "Missing"}])

      assert {:error, message} = Blueprint.apply(board, bad, user: user)
      assert message =~ "Missing"
      assert Boards.get_board!(board.id).columns == []
    end

    test "a rule naming a list the board does not have is refused, and rolls the rest back" do
      user = user_fixture()
      board = board_fixture(%{}, owner: user)

      extras = %{
        "tags" => ["fresh"],
        "automations" => [%{"preset" => "follow_list", "params" => %{"column" => "Nowhere"}}]
      }

      assert {:error, message} = Blueprint.apply(board, extras, user: user)
      assert message =~ "the board has no list called “Nowhere”"
      assert Boards.list_tags(board.id) == []
    end

    test "only replaces a page nobody edited, and only when asked to" do
      user = user_fixture()
      board = bare_board(user)
      {:ok, _} = Blueprint.apply(board, @blueprint, user: user)

      loose = Enum.find(Wiki.list_pages(board), &(&1.title == "Setup"))
      {:ok, _} = Wiki.update_page(loose, %{"body" => "mine now"}, user: user)

      newer =
        Map.put(@blueprint, "pages", [
          %{"title" => "Setup", "folder" => "Config", "body" => "v2"},
          %{"title" => "Loose", "body" => "v2"}
        ])

      refresh = Map.new(@blueprint["pages"], &{&1["title"], &1})
      assert {:ok, report} = Blueprint.apply(board, newer, user: user, refresh_pages: refresh)
      assert report.added["pages"] == ["Loose (updated)"]
      assert report.skipped["pages"] == ["Setup"]

      pages = Map.new(Wiki.list_pages(board), &{&1.title, Repo.reload(&1).body})
      assert pages["Setup"] == "mine now"
      assert pages["Loose"] == "v2"
    end
  end

  describe "templates" do
    test "a template's folders, tags and rules build with the board" do
      user = user_fixture()

      {:ok, template} =
        Boards.create_template(user, %{
          "name" => "Blueprinted #{System.unique_integer([:positive])}",
          "columns" => ["To Do", "Doing", "Done"],
          "folders" => ["Notes"],
          "tags" => ["bug"],
          "pages" => [%{"title" => "Read me", "folder" => "Notes", "body" => "hi"}],
          "automations" => [%{"preset" => "follow_list", "params" => %{"column" => "Done"}}]
        })

      board = board_fixture(%{}, owner: user, template: template)

      assert Enum.map(board.columns, & &1.name) == ["To Do", "Doing", "Done"]
      assert {:ok, notes} = Folders.find(board, "Notes")
      assert [%{title: "Read me", folder_id: folder_id}] = Wiki.list_pages(board)
      assert folder_id == notes.id
      assert [%{name: "bug"}] = Boards.list_tags(board.id)
      assert [%{name: "Followed: Done"}] = Automations.list_rules(board.id)
    end

    test "a built-in template still builds the same board" do
      {:ok, template} = Boards.find_template(nil, "Checklist")
      board = board_fixture(%{}, template: template)

      assert Enum.map(board.columns, & &1.name) ==
               Enum.map(template.columns, & &1["name"])

      assert length(Wiki.list_pages(board)) == length(template.pages || [])
      assert Boards.list_tags(board.id) == []
      assert Automations.list_rules(board.id) == []
    end

    test "invalid extras are refused when the template is saved" do
      user = user_fixture()

      assert {:error, cs} =
               Boards.create_template(user, %{
                 "name" => "Bad extras",
                 "columns" => ["A"],
                 "automations" => [%{"preset" => "nope"}]
               })

      assert {message, _} = cs.errors[:blueprint]
      assert message =~ "unknown preset"
    end
  end
end
