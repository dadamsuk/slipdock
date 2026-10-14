defmodule Slipdock.Wiki.AutoOrganiseTest do
  @moduledoc "A folder's Organise… (#791): the plans each mode makes, and filing them."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Ecto.Query

  alias Slipdock.{Repo, Wiki}
  alias Slipdock.Wiki.{AutoOrganise, Files, Folders, Page}

  setup do
    board = board_fixture(%{"name" => "Brain"})
    {:ok, inbox} = Wiki.create_folder(board, %{"name" => "Inbox"})
    {:ok, meetings} = Wiki.create_folder(board, %{"name" => "Meetings"})
    %{board: board, inbox: inbox, meetings: meetings}
  end

  defp page_in(board, folder, title, attrs \\ []) do
    page = page_fixture(board, %{"title" => title})
    {:ok, page} = Wiki.file_page(page, folder)
    set = Keyword.take(attrs, [:inserted_at, :front_matter, :note_tags, :parent_id])
    if set != [], do: Repo.update_all(from(p in Page, where: p.id == ^page.id), set: set)
    Wiki.get_page!(page.id)
  end

  defp file_in(board, folder, name) do
    path = Path.join(System.tmp_dir!(), "ao-#{System.unique_integer([:positive])}")
    File.write!(path, "bytes")
    {:ok, file} = Files.create(board, %{name: name, folder_id: folder && folder.id}, path)
    File.rm(path)
    file
  end

  defp at(iso), do: iso |> DateTime.from_iso8601() |> elem(1) |> DateTime.truncate(:second)

  defp folder_at(board, path) do
    {:ok, folder} = Folders.find(board, path)
    folder
  end

  describe "by date" do
    test "a note goes into <parent>/YYYY-MM, and the folders are made", %{
      board: board,
      inbox: inbox
    } do
      page = page_in(board, inbox, "Standup", inserted_at: at("2026-10-12T09:00:00Z"))
      file = file_in(board, inbox, "slides.pdf")

      {:ok, plan} = AutoOrganise.plan(inbox, "date", parent: "Meetings")

      assert %{key: key, from: "Inbox", to: "Meetings/2026-10", title: "Standup"} =
               Enum.find(plan, &(&1.kind == :page))

      assert key == "page:#{page.id}"
      file_to = "Meetings/" <> Calendar.strftime(file.inserted_at, "%Y-%m")
      assert Enum.find(plan, &(&1.kind == :file)).to == file_to

      # Planning changes nothing.
      assert Wiki.get_page!(page.id).folder_id == inbox.id

      {:ok, result} = AutoOrganise.apply_plan(board, plan)
      assert result.moved == 2
      assert result.skipped == []
      # Meetings was there; 2026-10 was made (and the file's month, if another).
      assert result.folders == if(file_to == "Meetings/2026-10", do: 1, else: 2)

      oct = folder_at(board, "Meetings/2026-10")
      assert Wiki.get_page!(page.id).folder_id == oct.id
      assert Files.get(file.id).folder_id == folder_at(board, file_to).id
    end

    test "the parent defaults to the folder itself, and other groupings work", %{
      board: board,
      inbox: inbox
    } do
      page_in(board, inbox, "Old", inserted_at: at("2025-03-04T09:00:00Z"))

      for {granularity, to} <- [
            {"month", "Inbox/2025-03"},
            {"year", "Inbox/2025"},
            {"year_month", "Inbox/2025/03"},
            {"day", "Inbox/2025-03-04"}
          ] do
        assert {:ok, [%{to: ^to}]} = AutoOrganise.plan(inbox, "date", granularity: granularity)
      end

      # The top of the wiki as the parent.
      assert {:ok, [%{to: "2025-03"}]} = AutoOrganise.plan(inbox, "date", parent: "")

      assert {:error, _} = AutoOrganise.plan(inbox, "date", granularity: "fortnight")
      assert {:error, _} = AutoOrganise.plan(inbox, "date", parent: "Meetings/../x")
    end

    test "front matter's created: or date: wins over when it was added, unless asked not to",
         %{board: board, inbox: inbox} do
      page_in(board, inbox, "Imported",
        inserted_at: at("2026-10-14T09:00:00Z"),
        front_matter: "---\ncreated: 2019-07-21 10:30\n---\n"
      )

      page_in(board, inbox, "Dated",
        inserted_at: at("2026-10-14T09:00:00Z"),
        front_matter: "---\ndate: \"2020-01-02\"\n---\n"
      )

      page_in(board, inbox, "Junk date",
        inserted_at: at("2026-10-14T09:00:00Z"),
        front_matter: "---\ncreated: someday\n---\n"
      )

      {:ok, plan} = AutoOrganise.plan(inbox, "date", parent: "Meetings")
      to = Map.new(plan, &{&1.title, &1.to})
      assert to["Imported"] == "Meetings/2019-07"
      assert to["Dated"] == "Meetings/2020-01"
      assert to["Junk date"] == "Meetings/2026-10"

      {:ok, plan} = AutoOrganise.plan(inbox, "date", parent: "Meetings", source: "added")
      assert Enum.all?(plan, &(&1.to == "Meetings/2026-10"))
    end

    test "an item already where it would go is left out, and a page's children go with it",
         %{board: board, meetings: meetings} do
      {:ok, oct} = Wiki.create_folder(board, %{"name" => "2026-10", "parent_id" => meetings.id})
      page_in(board, oct, "Already filed", inserted_at: at("2026-10-01T09:00:00Z"))
      assert {:ok, []} = AutoOrganise.plan(oct, "date", parent: "Meetings")

      parent = page_in(board, meetings, "Parent", inserted_at: at("2026-09-01T09:00:00Z"))

      child =
        page_in(board, meetings, "Child",
          inserted_at: at("2024-01-01T09:00:00Z"),
          parent_id: parent.id
        )

      {:ok, plan} = AutoOrganise.plan(meetings, "date")
      assert [%{title: "Parent", to: "Meetings/2026-09"}] = plan

      {:ok, %{moved: 1}} = AutoOrganise.apply_plan(board, plan)
      sept = folder_at(board, "Meetings/2026-09")
      assert Wiki.get_page!(parent.id).folder_id == sept.id
      assert Wiki.get_page!(child.id).folder_id == sept.id
      assert Wiki.get_page!(child.id).parent_id == parent.id
    end
  end

  describe "by tag and flatten" do
    test "a tagged note goes into a subfolder named after its first tag", %{
      board: board,
      inbox: inbox
    } do
      a = page_in(board, inbox, "A", note_tags: ["project/acme", "urgent"])
      page_in(board, inbox, "Untagged")
      file_in(board, inbox, "loose.txt")

      {:ok, plan} = AutoOrganise.plan(inbox, "tag")
      assert [%{key: key, to: "Inbox/project/acme"}] = plan
      assert key == "page:#{a.id}"

      {:ok, %{moved: 1, folders: 2}} = AutoOrganise.apply_plan(board, plan)
      assert Wiki.get_page!(a.id).folder_id == folder_at(board, "Inbox/project/acme").id
    end

    test "flatten pulls everything up from the subfolders, however deep", %{
      board: board,
      meetings: meetings
    } do
      {:ok, deep} = Wiki.create_folder(board, %{"name" => "2026/10", "parent_id" => meetings.id})
      p = page_in(board, deep, "Deep")
      f = file_in(board, deep, "deep.png")

      {:ok, plan} = AutoOrganise.plan(meetings, "flatten")
      assert Enum.sort(Enum.map(plan, & &1.from)) == ["Meetings/2026/10", "Meetings/2026/10"]
      assert Enum.all?(plan, &(&1.to == "Meetings"))

      {:ok, %{moved: 2, folders: 0}} = AutoOrganise.apply_plan(board, plan)
      assert Wiki.get_page!(p.id).folder_id == meetings.id
      assert Files.get(f.id).folder_id == meetings.id
      # The emptied folders stay.
      assert Wiki.get_folder(deep.id)
    end
  end

  describe "applying" do
    test "skips a file whose name is taken where it would go, and anything moved since",
         %{board: board, inbox: inbox, meetings: meetings} do
      file_in(board, meetings, "notes.txt")
      clash = file_in(board, inbox, "notes.txt")
      page = page_in(board, inbox, "Moved since")

      {:ok, plan} = AutoOrganise.plan(inbox, "flatten")
      assert plan == []

      plan = [
        %{
          key: "file:#{clash.id}",
          kind: :file,
          id: clash.id,
          title: "notes.txt",
          from: "Inbox",
          to: "Meetings"
        },
        %{
          key: "page:#{page.id}",
          kind: :page,
          id: page.id,
          title: "Moved since",
          from: "Elsewhere",
          to: "Meetings"
        }
      ]

      {:ok, result} = AutoOrganise.apply_plan(board, plan)
      assert result.moved == 0

      assert [{"notes.txt", "a file of that name is already in Meetings"}, {"Moved since", _}] =
               result.skipped

      assert Files.get(clash.id).folder_id == inbox.id
      assert Wiki.get_page!(page.id).folder_id == inbox.id
    end

    test "a folder path is matched case-aside, so no near-duplicate is made", %{
      board: board,
      inbox: inbox
    } do
      page = page_in(board, inbox, "X")

      plan = [
        %{
          key: "page:#{page.id}",
          kind: :page,
          id: page.id,
          title: "X",
          from: "Inbox",
          to: "meetings/new"
        }
      ]

      {:ok, %{moved: 1, folders: 1}} = AutoOrganise.apply_plan(board, plan)
      assert length(Folders.list(board)) == 3
      assert Wiki.get_page!(page.id).folder_id == folder_at(board, "Meetings/new").id
    end
  end

  describe "AI" do
    setup %{board: board, inbox: inbox} do
      {:ok, _} = Wiki.create_folder(board, %{"name" => "Projects/Acme"})
      page_in(board, folder_at(board, "Projects/Acme"), "Acme kickoff")

      %{
        one: page_in(board, inbox, "Acme budget review"),
        two: page_in(board, inbox, "Weekly sync"),
        three: page_in(board, inbox, "Gardening ideas")
      }
    end

    test "suggestions under existing top-level folders are kept; anything else is dropped",
         %{board: board, inbox: inbox, one: one, two: two, three: three} do
      Slipdock.AIStub.reply_with(%{
        "moves" => [
          %{"id" => "p#{one.id}", "folder" => "projects/acme"},
          %{"id" => "p#{two.id}", "folder" => "Meetings/Weekly/"},
          %{"id" => "p#{three.id}", "folder" => "Garden"},
          %{"id" => "p999999", "folder" => "Projects"},
          %{"id" => "p#{one.id}", "folder" => "Meetings"},
          %{"nonsense" => true}
        ]
      })

      {:ok, plan} = AutoOrganise.plan(inbox, "ai")

      assert_received {:ai_request, request}
      assert request["model"] == "anthropic/claude-haiku-5.5"
      prompt = Enum.map_join(request["messages"], "\n", & &1["content"])
      assert prompt =~ "- Projects/Acme (e.g. \"Acme kickoff\")"
      assert prompt =~ "p#{one.id}: \"Acme budget review\""

      assert Map.new(plan, &{&1.title, &1.to}) == %{
               "Acme budget review" => "Projects/Acme",
               "Weekly sync" => "Meetings/Weekly"
             }

      {:ok, %{moved: 2, folders: 1}} = AutoOrganise.apply_plan(board, plan)
      assert Wiki.get_page!(three.id).folder_id == inbox.id
    end

    test "a person's own model is used instead of the default", %{inbox: inbox} do
      user = user_fixture("organiser-#{System.unique_integer([:positive])}@example.com")
      :ok = Slipdock.AI.Keys.put_settings(user, %{api_key: "sk-theirs", model: "someone/else"})
      on_exit(fn -> Slipdock.AI.Keys.delete(user) end)
      Slipdock.AIStub.reply_with(%{"moves" => []})

      assert {:ok, []} = AutoOrganise.plan(inbox, "ai", user: user)
      assert_received {:ai_request, %{"model" => "someone/else"}}
    end

    test "the model failing is an error", %{inbox: inbox} do
      Slipdock.AIStub.reply_with("not json at all")
      assert {:error, message} = AutoOrganise.plan(inbox, "ai")
      assert message =~ "JSON"
    end

    test "an empty folder isn't sent to the model", %{board: board} do
      {:ok, empty} = Wiki.create_folder(board, %{"name" => "Empty"})
      assert {:ok, []} = AutoOrganise.plan(empty, "ai")
      refute_received {:ai_request, _}
    end
  end

  test "an unknown mode is refused", %{inbox: inbox} do
    assert {:error, _} = AutoOrganise.plan(inbox, "shuffle")
  end
end
