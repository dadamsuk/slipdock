defmodule SlipdockWeb.APIGuideSectionsTest do
  @moduledoc """
  How the agent guide is cut into sections (`APIGuide.sections/1`, which
  `short/1`, `section/2`, `get_guide` and `GET /api/guide?section=` all go
  through): on `## ` headings outside fenced code only, so an example page in
  the guide with headings of its own stays whole.
  """
  use Slipdock.DataCase, async: true

  alias SlipdockWeb.APIGuide

  defp keys(markdown), do: [markdown: markdown] |> APIGuide.sections() |> Enum.map(&elem(&1, 0))

  describe "sections/1 on a given guide" do
    test "a heading inside a three- or four-backtick fence is not a section" do
      guide = """
      Opening.

      ## Alpha

      ```markdown
      ## Not a section
      ```

      ## Beta

      ````markdown
      # A page

      ## Recording

      ```slipdock
      ## Still inside
      ```

      ## Transcript
      ````

      ## Gamma
      """

      sections = APIGuide.sections(markdown: guide)

      assert keys(guide) == ["intro", "alpha", "beta", "gamma"]
      assert Enum.map_join(sections, &elem(&1, 2)) == guide

      {_, "Beta", beta} = Enum.find(sections, &(elem(&1, 0) == "beta"))
      assert beta =~ "## Recording"
      assert beta =~ "## Transcript\n````\n"
      refute beta =~ "## Gamma"
    end

    test "a longer run closes a fence, a shorter one or one with text after it doesn't" do
      guide = """
      ## One

      ```
      ## Inside
      `````

      ## Two

      ~~~~
      ```
      ## Inside tildes
      ~~~ not a close
      ~~~~
      ## Three
      """

      assert keys(guide) == ["intro", "one", "two", "three"]
    end

    test "a fence never closed runs to the end, and nothing after it is cut" do
      guide = """
      Opening.

      ## Alpha

      ````
      ## Inside

      ## Also inside
      """

      assert [{"intro", nil, "Opening.\n\n"}, {"alpha", "Alpha", alpha}] =
               APIGuide.sections(markdown: guide)

      assert alpha =~ "## Also inside"
    end

    test "a guide that starts at a heading has an empty opening" do
      assert [{"intro", nil, ""}, {"only", "Only", "## Only\ntext\n"}] =
               APIGuide.sections(markdown: "## Only\ntext\n")
    end

    test "### Over MCP is cut at the next heading outside a fence" do
      guide = """
      ## Getting in

      ### Over HTTP

      ### Over MCP

      ```
      ### Inside
      ```

      ### After
      """

      assert {"mcp", "Over MCP", mcp} =
               [markdown: guide] |> APIGuide.sections() |> List.last()

      assert mcp == "## Over MCP\n\n```\n### Inside\n```\n\n"
    end
  end

  describe "the live guide" do
    test "no example heading becomes a section, and wiki is the whole wiki section" do
      keys = APIGuide.sections() |> Enum.map(&elem(&1, 0))

      refute "recording" in keys
      refute "transcript" in keys

      {:ok, wiki} = APIGuide.section("wiki", [])
      assert wiki =~ "recordings_folder"
      assert wiki =~ "## Transcript"

      short = APIGuide.short()
      rest = short |> String.split("## The rest of the guide") |> List.last()
      refute rest =~ "`recording`"
      refute rest =~ "`transcript`"
      assert rest =~ "`wiki`"
    end

    test "the sections join back into the whole guide" do
      text =
        APIGuide.sections()
        |> Enum.reject(&(elem(&1, 0) == "mcp"))
        |> Enum.map_join(&elem(&1, 2))

      assert text == APIGuide.markdown()
    end

    # The short guide is what an agent reads at the start of every session
    # (get_guide, `slipdock guide`, `?section=short`), before it has read a
    # card: about 3,500 words today, 5k to 6k tokens. The whole guide is
    # 27,000 words, a quarter of a 200k context. 4,500 words leaves room to
    # grow while catching the slide back towards that: past it, move a part
    # out into a section of its own rather than raise the number.
    @short_budget 4_500

    test "the short guide stays under its word budget" do
      words = APIGuide.short() |> String.split() |> length()

      assert words < @short_budget,
             "the short guide is #{words} words, over its budget of #{@short_budget}"
    end
  end
end
