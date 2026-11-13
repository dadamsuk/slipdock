defmodule SlipdockWeb.RecordingAPIDocsTest do
  @moduledoc """
  Playing a recording with a token (#1562) as the docs describe it: the guide,
  the manual, docs/wiki.md and the README, with the route they name real.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2]

  @root Path.expand("../..", __DIR__)
  @route "/api/pages/:id/recording"
  @reasons ~w(not_connected revoked no_folder no_vault outside_folder not_audio not_found
              no_recording unavailable)

  defp read(path), do: Slipdock.DocsText.read!(Path.join(@root, path))

  test "the route the docs name exists, and takes a GET" do
    assert Enum.any?(
             SlipdockWeb.Router.__routes__(),
             &(&1.path == @route and &1.verb == :get and
                 &1.plug == SlipdockWeb.API.RecordingController)
           )
  end

  test "the guide names the route, the 406 and every reason" do
    guide = SlipdockWeb.APIGuide.markdown()
    assert guide =~ "`GET #{@route}`"
    assert guide =~ "A strict\n`Accept: audio/mp4` is a 406"
    assert guide =~ "a page shared alone answers 404"
    for reason <- @reasons, do: assert(guide =~ "`#{reason}`")
  end

  test "the manual says how to call it and what it refuses" do
    manual = read("docs/manual.md")
    assert manual =~ "**Playing it outside the browser.**"
    assert manual =~ "`GET #{@route}`"
    assert manual =~ "A strict `Accept: audio/mp4` gets a `406`"
    assert manual =~ "**read on the board**"
    for reason <- @reasons, do: assert(manual =~ "`#{reason}`")
  end

  test "the route lists and the Google Drive page name it" do
    assert read("docs/manual.md") =~ "GET    #{@route}"
    assert read("docs/wiki.md") =~ "GET    #{@route}"
    assert read("docs/manual/google-drive-for-meeting-recordings.md") =~ "`GET #{@route}`"
  end

  test "a draft page's recording is a writer's, in each place that says who may play (#2975)" do
    drive = read("docs/manual/google-drive-for-meeting-recordings.md")
    assert_states(drive, "A draft page's recording is its writers' only, like the draft itself")

    assert read("docs/wiki.md") =~
             "GET    #{@route}            a meeting page's audio, with Range (read on the board; a draft's, write)"

    # The rule is quoted so it is a fact, held exactly: with no facts the claim
    # wants only most of its key words near each other, which the paragraph
    # meets without the draft clause, or with it saying read (#2983).
    assert_states(
      SlipdockWeb.APIGuide.markdown(),
      ~s(It takes read on the board, as in the browser, and a "draft page's takes write", like the draft itself)
    )

    assert_states(
      read("docs/manual.md"),
      "A page shared with someone outside the board answers 404, as does a draft, unless they can edit the board"
    )
  end

  test "there is no MCP tool for it" do
    refute Enum.any?(SlipdockWeb.MCP.Tools.all(), &(&1.name() =~ "recording"))
  end
end
