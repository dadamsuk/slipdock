defmodule Slipdock.WikiFrontMatterTest do
  @moduledoc """
  Front matter kept exactly as written (W-103 R3.1–R3.3): read as blocks,
  patched only where Slipdock owns a key, and written back byte for byte —
  checked on hand-picked cases and, as properties, over generated ones.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.FrontMatterGen
  alias Slipdock.Wiki
  alias Slipdock.Wiki.{Archive, FrontMatter}

  @seeds 1..300

  describe "reading" do
    test "split takes the header — delimiters, YAML and the blank lines after — off the body" do
      assert FrontMatter.split("---\na: 1\n---\n\nBody\n") == {"---\na: 1\n---\n\n", "Body\n"}
      assert FrontMatter.split("---\r\na: 1\r\n---\r\nBody") == {"---\r\na: 1\r\n---\r\n", "Body"}
      assert FrontMatter.split("---\n---\nBody") == {"---\n---\n", "Body"}
      assert FrontMatter.split("No front matter\n---\n") == {nil, "No front matter\n---\n"}
      # The first line of the body keeps its indentation: only blank lines go.
      assert FrontMatter.split("---\na: 1\n---\n\n    code\n") ==
               {"---\na: 1\n---\n\n", "    code\n"}
    end

    test "values: scalars quoted either way, flow and block lists, comments stripped" do
      yaml = """
      # leading comment
      title: "Retry: why"
      alias: 'It''s'
      tags: [one, "two, three"]
      list:
        - a # first
        - "b"
      plain: value # trailing
      hash: "has # inside"
      nested:
        x: 1
      empty:
      block: |
        text\
      """

      assert FrontMatter.get(yaml, "title") == "Retry: why"
      assert FrontMatter.get(yaml, "alias") == "It's"
      assert FrontMatter.get(yaml, "tags") == ["one", "two, three"]
      assert FrontMatter.get(yaml, "list") == ["a", "b"]
      assert FrontMatter.get(yaml, "plain") == "value"
      assert FrontMatter.get(yaml, "hash") == "has # inside"
      assert FrontMatter.get(yaml, "nested") == nil
      assert FrontMatter.get(yaml, "empty") == nil
      assert FrontMatter.get(yaml, "block") == nil
      assert FrontMatter.get(yaml, "missing") == nil
      assert FrontMatter.get(nil, "title") == nil

      assert FrontMatter.keys(yaml) ==
               ~w(title alias tags list plain hash nested empty block)
    end

    test "a quoted key is still a key" do
      assert FrontMatter.get(~s("my key": 1\n'other': two), "other") == "two"
      assert FrontMatter.keys(~s("my key": 1\n'other': two)) == ["my key", "other"]
    end
  end

  describe "patching" do
    @yaml "# about it\ntitle: Old\nrating: 5 # stars\ntags:\n  - a\n\n# trailing note\ncreated: 2026-01-01"

    test "a key is rewritten where it stands, everything else left alone" do
      assert FrontMatter.put(@yaml, "title", "New") ==
               String.replace(@yaml, "title: Old", "title: New")
    end

    test "a value that has not changed is not rewritten, quotes and all" do
      yaml = ~s(title: "Same"\nother: 'x')
      assert FrontMatter.put(yaml, "title", "Same") == yaml
      assert FrontMatter.put("flag: true", "flag", true) == "flag: true"
    end

    test "a new key goes at the end, quoted only when YAML would misread it" do
      assert FrontMatter.put("a: 1", "title", "Plain") == "a: 1\ntitle: Plain"
      assert FrontMatter.put("a: 1", "title", "Why: this") == ~s(a: 1\ntitle: "Why: this")
      assert FrontMatter.put("a: 1", "title", "true") == ~s(a: 1\ntitle: "true")
      assert FrontMatter.put("a: 1", "template", true) == "a: 1\ntemplate: true"
      assert FrontMatter.put("a: 1", "tags", ["x", "y z"]) == "a: 1\ntags: [x, y z]"
      assert FrontMatter.put("", "title", "T") == "title: T"
      assert FrontMatter.put("a: 1\r\n", "b", "2") == "a: 1\r\nb: 2"
    end

    test "nil takes a key out, keeping the comment and blank lines after its value" do
      assert FrontMatter.put(@yaml, "tags", nil) ==
               "# about it\ntitle: Old\nrating: 5 # stars\n\n# trailing note\ncreated: 2026-01-01"

      assert FrontMatter.put(@yaml, "created", nil) ==
               "# about it\ntitle: Old\nrating: 5 # stars\ntags:\n  - a\n\n# trailing note"

      assert FrontMatter.put(@yaml, "missing", nil) == @yaml

      assert FrontMatter.drop(@yaml, ~w(title rating tags created)) ==
               "# about it\n\n# trailing note"
    end

    test "with_yaml keeps the header's own delimiters and gap" do
      header = "---\r\nold: 1\r\n---\r\n\r\n"
      assert FrontMatter.with_yaml(header, "new: 2") == "---\r\nnew: 2\r\n---\r\n\r\n"
      assert FrontMatter.with_yaml("---\n---\n", "a: 1") == "---\na: 1\n---\n"
      assert FrontMatter.with_yaml("---\na: 1\n---\n", "") == "---\n---\n"
      assert FrontMatter.with_yaml(nil, "a: 1") == "---\na: 1\n---\n\n"
      assert FrontMatter.with_yaml(nil, "") == nil
    end

    test "replace refuses YAML that would close the header early" do
      assert {:error, message} = FrontMatter.replace(nil, "a: 1\n---\nb: 2")
      assert message =~ "---"
      assert {:error, _} = FrontMatter.replace(nil, "a: 1\n...")
      assert {:error, _} = FrontMatter.replace(nil, 12)
      assert {:ok, nil} = FrontMatter.replace("---\na: 1\n---\n", "")
      assert {:ok, "---\nb: 2\n---\n"} = FrontMatter.replace("---\na: 1\n---\n", "b: 2\n")
    end
  end

  describe "properties" do
    test "split and join give the file back exactly" do
      for seed <- @seeds do
        {file, %{yaml: yaml}} = FrontMatterGen.file(seed, owned: true)
        {header, body} = FrontMatter.split(file)
        assert header <> body == file, "seed #{seed}"
        assert FrontMatter.yaml(header) == yaml, "seed #{seed}"
        assert FrontMatter.with_yaml(header, yaml) == header, "seed #{seed}"
        assert Enum.map_join(FrontMatter.blocks(yaml), & &1.text) == yaml, "seed #{seed}"
      end
    end

    test "putting a key's own value back changes nothing" do
      for seed <- @seeds do
        {_file, %{yaml: yaml}} = FrontMatterGen.file(seed, owned: true)

        for key <- FrontMatter.keys(yaml), value = FrontMatter.get(yaml, key), value != nil do
          assert FrontMatter.put(yaml, key, value) == yaml, "seed #{seed}, key #{key}"
        end
      end
    end

    test "patching one key leaves every other block byte for byte" do
      for seed <- @seeds do
        {_file, %{yaml: yaml}} = FrontMatterGen.file(seed, owned: true)
        [key | _] = FrontMatter.keys(yaml) |> Enum.shuffle()
        others = fn y -> y |> FrontMatter.blocks() |> Enum.reject(&(&1.key == key)) end

        changed = FrontMatter.put(yaml, key, "changed value")
        assert FrontMatter.get(changed, key) == "changed value", "seed #{seed}"
        assert texts(others.(changed)) == texts(others.(yaml)), "seed #{seed}"

        added = FrontMatter.put(yaml, "brand-new", "x")
        assert String.starts_with?(added, yaml), "seed #{seed}"
        assert FrontMatter.get(added, "brand-new") == "x", "seed #{seed}"

        removed = FrontMatter.put(yaml, key, nil)
        refute FrontMatter.has_key?(removed, key), "seed #{seed}"

        assert FrontMatter.keys(removed) == FrontMatter.keys(yaml) -- [key], "seed #{seed}"
      end
    end
  end

  # The last block's text may lose or gain the line break that separated it
  # from a removed neighbour; what is compared is each block's own lines.
  defp texts(blocks), do: Enum.map(blocks, &String.trim_trailing(&1.text))

  describe "through a page" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Notes", "code" => "fmnotes"}, owner: user)
      %{user: user, board: board}
    end

    defp import!(board, user, path, text) do
      %{created: [page]} = Archive.import_files(board, [{path, text}], user: user)
      Wiki.get_page!(page.id)
    end

    test "import keeps the header, maps title and summary, and drops nothing", ctx do
      text =
        "---\ntitle: \"Retry: why\"\nsummary: How retries work\nrating: 5 # stars\n---\n\nBody\n"

      page = import!(ctx.board, ctx.user, "retry.md", text)

      assert page.title == "Retry: why"
      assert page.summary == "How retries work"
      assert page.body == "Body\n"

      assert page.front_matter ==
               "---\ntitle: \"Retry: why\"\nsummary: How retries work\nrating: 5 # stars\n---\n\n"
    end

    test "a file without front matter stores none", ctx do
      page = import!(ctx.board, ctx.user, "Plain.md", "Just text\n")
      assert page.front_matter == nil
      assert Archive.sync_file(page, file_title: "Plain") == "Just text\n"
    end

    test "ordinary export patches Slipdock's keys in place and keeps the rest exactly", ctx do
      text =
        "---\n# mine\nrating: 5 # stars\ntitle: Old\nstatus: reading\ncreated: 2026-01-01\n---\n\nBody\n"

      page = import!(ctx.board, ctx.user, "Old.md", text)
      {:ok, page} = Wiki.update_page(page, %{"title" => "New"}, user: ctx.user)

      out = Archive.file(page)
      {header, body} = FrontMatter.split(out)
      yaml = FrontMatter.yaml(header)

      assert body == "Body\n"
      assert String.starts_with?(yaml, "# mine\nrating: 5 # stars\ntitle: New\n")
      # `status: reading` is the writer's own, not a page status: kept.
      assert yaml =~ "status: reading\ncreated: 2026-01-01\n"
      assert FrontMatter.get(yaml, "code") == page.code
      assert FrontMatter.get(yaml, "slug") == page.slug
      assert FrontMatter.get(yaml, "updated")
    end

    test "export writes board tags only where the file has no tags of its own", ctx do
      {:ok, tag} = Slipdock.Boards.create_tag(ctx.board, %{"name" => "ops"})
      page = import!(ctx.board, ctx.user, "A.md", "---\ntags: [mine]\n---\nx")
      {:ok, _} = Wiki.set_tags(page, [tag])

      assert FrontMatter.get(
               FrontMatter.yaml(
                 elem(FrontMatter.split(Archive.file(Wiki.get_page!(page.id))), 0)
               ),
               "tags"
             ) == ["mine"]

      other = import!(ctx.board, ctx.user, "B.md", "---\nrating: 1\n---\nx")
      {:ok, _} = Wiki.set_tags(other, [tag])
      assert Archive.file(Wiki.get_page!(other.id)) =~ "tags: ops"
    end

    test "the sync writer adds no key that changes on every save", ctx do
      page = import!(ctx.board, ctx.user, "Note.md", "---\nrating: 5\n---\n\nBody")
      {:ok, page} = Wiki.update_page(page, %{"body" => "Edited"}, user: ctx.user)

      out = Archive.sync_file(page, file_title: "Note")
      assert out == "---\nrating: 5\n---\n\nEdited"
      refute out =~ "updated"
      refute out =~ "code:"

      assert Archive.sync_file(page, file_title: "Note", code: true) =~ "code: #{page.code}"
      # A title the file name cannot say goes into the front matter.
      assert Archive.sync_file(page, file_title: "Note-renamed") =~ "title: Note"
    end

    test "the sync writer says draft, template and summary only when they are so", ctx do
      {:ok, page} =
        Wiki.create_page(
          ctx.board,
          %{
            "title" => "Fresh",
            "body" => "x",
            "status" => "draft",
            "template" => true,
            "summary" => "S"
          },
          user: ctx.user
        )

      out = Archive.sync_file(page, file_title: "Fresh")
      assert out == "---\nsummary: S\nstatus: draft\ntemplate: true\n---\n\nx"

      {:ok, page} =
        Wiki.update_page(page, %{"status" => "published", "template" => false, "summary" => ""},
          user: ctx.user
        )

      page = Wiki.get_page!(page.id)
      assert Archive.sync_file(%{page | front_matter: nil}, file_title: "Fresh") == "x"
    end

    test "property: a file imported and written back by the sync writer is the same file", ctx do
      for seed <- 1..40 do
        {file, _} = FrontMatterGen.file(seed, owned: true)
        # A board each: the generator repeats titles, and import skips a
        # title the board already has.
        board = board_fixture(%{"name" => "Seed #{seed}"}, owner: ctx.user)
        page = import!(board, ctx.user, "Note #{seed}.md", file)

        assert Archive.sync_file(page, file_title: "Note #{seed}") == file, "seed #{seed}"
      end
    end

    test "property: ordinary export keeps every key Slipdock does not own, in order", ctx do
      owned = ~w(title code slug summary status template tags updated)

      for seed <- 41..80 do
        {file, %{yaml: yaml}} = FrontMatterGen.file(seed)
        board = board_fixture(%{"name" => "Seed #{seed}"}, owner: ctx.user)
        page = import!(board, ctx.user, "Export #{seed}.md", file)
        {header, _} = page |> Archive.file() |> FrontMatter.split()
        exported = FrontMatter.yaml(header)

        theirs = fn y ->
          y |> FrontMatter.blocks() |> Enum.reject(&(&1.key in owned)) |> texts()
        end

        assert theirs.(exported) == theirs.(yaml), "seed #{seed}"
      end
    end
  end
end
