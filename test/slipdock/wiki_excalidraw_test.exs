defmodule Slipdock.WikiExcalidrawTest do
  @moduledoc """
  Excalidraw drawings on the server (W-103 R5.1): lz-string as the plugin
  uses it, both file formats read and written back, the SVG preview, and
  finding the drawing an embed names. The compressed fixture and vectors
  were made by the lz-string npm package (see the `.cjs` beside them).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki.{Drawings, Excalidraw, Files}
  alias Slipdock.Wiki.Excalidraw.{LZString, SVG}

  @vectors "test/support/fixtures/lz_string_vectors.json" |> File.read!() |> Jason.decode!()
  @sketch File.read!("test/support/fixtures/excalidraw/Sketch.excalidraw.md")
  @sketch_json File.read!("test/support/fixtures/excalidraw/sketch.json")

  describe "LZString" do
    test "compresses to exactly what lz-string writes, and reads it back" do
      for %{"plain" => plain, "compressed" => compressed} <- @vectors["vectors"] do
        assert LZString.compress_to_base64(plain) == compressed, plain
        assert LZString.decompress_from_base64(compressed) == {:ok, plain}
      end
    end

    test "ignores the line breaks the plugin cuts its base64 into" do
      [%{"plain" => plain, "compressed" => compressed} | _] = Enum.reverse(@vectors["vectors"])
      broken = compressed |> String.graphemes() |> Enum.chunk_every(7) |> Enum.join("\n\n")
      assert LZString.decompress_from_base64(broken) == {:ok, plain}
    end

    test "an empty string compresses to nothing; nothing and garbage don't decompress" do
      assert LZString.compress_to_base64("") == ""
      assert LZString.decompress_from_base64("") == :error
      assert LZString.decompress_from_base64("////////") == :error
      assert LZString.decompress_from_base64("A") == :error
    end
  end

  describe "reading a drawing" do
    test "the plugin's compressed note: the scene, its encoding and its linked files" do
      assert {:ok, %{scene: scene, format: :compressed, links: links}} =
               Excalidraw.parse_markdown(@sketch)

      assert scene == Jason.decode!(@sketch_json)
      assert links == %{"f00d" => "cat.png"}
    end

    test "an uncompressed ```json note, and a .excalidraw file's JSON" do
      body = "# Excalidraw Data\n\n## Drawing\n```json\n#{@sketch_json}\n```\n"
      assert {:ok, %{format: :json, scene: scene, links: %{}}} = Excalidraw.parse_markdown(body)
      assert length(scene["elements"]) == 7
      assert {:ok, ^scene} = Excalidraw.parse_json(@sketch_json)
    end

    test "anything without a scene is not a drawing" do
      assert Excalidraw.parse_markdown("just prose") == :error
      assert Excalidraw.parse_markdown("## Drawing\n```json\n{not json\n```\n") == :error
      assert Excalidraw.parse_markdown("## Drawing\n```json\n{\"a\": 1}\n```\n") == :error

      assert Excalidraw.parse_markdown("## Drawing\n```compressed-json\n!!!!\n```\n") ==
               :error

      assert Excalidraw.parse_markdown(nil) == :error
      assert Excalidraw.parse_json("[]") == :error
    end

    test "texts: each live text element, as written before wrapping" do
      {:ok, scene} = Excalidraw.parse_json(@sketch_json)

      assert Excalidraw.texts(scene) == [
               {"txtA1b2c", "Ship it"},
               {"txtZ9y8x", "Second line of notes ✓"}
             ]

      assert Excalidraw.plain_text(scene) == "Ship it\nSecond line of notes ✓"
      assert Excalidraw.texts(%{}) == []
    end

    test "readable: a note's prose and its drawing's words, without the plugin's wrapping" do
      assert Excalidraw.readable(@sketch) == "Ship it\nSecond line of notes ✓"

      assert Excalidraw.readable("A caption.\n\n%%\n" <> @sketch) ==
               "A caption.\n\nShip it\nSecond line of notes ✓"

      # The plugin's older layout, with no "# Excalidraw Data" heading.
      old = "Intro\n\n# Text Elements\nHi ^a\n\n# Drawing\n```json\n#{@sketch_json}\n```\n"
      assert Excalidraw.readable(old) == "Intro\n\nShip it\nSecond line of notes ✓"

      empty = "# Excalidraw Data\n## Drawing\n```json\n{\"elements\":[]}\n```\n"
      assert Excalidraw.readable(empty) == ""

      assert Excalidraw.readable("plain *prose*") == "plain *prose*"
      assert Excalidraw.readable(nil) == nil
    end

    test "names and pages that are drawings" do
      assert Excalidraw.name?("Plan.excalidraw")
      assert Excalidraw.name?("Plan.Excalidraw.md")
      refute Excalidraw.name?("Plan.md")
      refute Excalidraw.name?("excalidraw.png")
      refute Excalidraw.name?(nil)

      assert Excalidraw.page?(%Slipdock.Wiki.Page{file_name: "Plan.excalidraw"})

      assert Excalidraw.page?(%Slipdock.Wiki.Page{
               front_matter: "---\nexcalidraw-plugin: parsed\n---\n"
             })

      refute Excalidraw.page?(%Slipdock.Wiki.Page{
               title: "Plan",
               front_matter: "---\na: 1\n---\n"
             })
    end
  end

  describe "writing a drawing back" do
    test "a compressed note stays compressed, in the plugin's lines, its prose and files kept" do
      scene = Jason.decode!(@sketch_json)

      changed =
        update_in(scene, ["elements"], fn elements ->
          Enum.map(elements, fn
            %{"id" => "txtA1b2c"} = el -> %{el | "text" => "Shipped", "originalText" => "Shipped"}
            el -> el
          end)
        end)

      json = Jason.encode!(changed)
      assert {:ok, body} = Excalidraw.write_markdown(@sketch, json)

      assert body =~ "## Text Elements\nShipped ^txtA1b2c\n\nSecond line of notes ✓ ^txtZ9y8x\n\n"
      refute body =~ "Ship it ^"
      assert body =~ "## Embedded Files\nf00d: [[cat.png]]"
      assert String.starts_with?(body, "==⚠  Switch to EXCALIDRAW VIEW")
      assert body =~ "```compressed-json\n"

      [_, data] = Regex.run(~r/```compressed-json\n(.*?)\n```/s, body)
      lines = String.split(data, "\n\n")
      assert Enum.all?(Enum.drop(lines, -1), &(String.length(&1) == 256))
      assert LZString.decompress_from_base64(data) == {:ok, json}

      assert {:ok, %{scene: ^changed, format: :compressed}} = Excalidraw.parse_markdown(body)
    end

    test "a ```json note stays JSON, and a note with no texts gets an empty section" do
      body = "## Text Elements\nold ^x\n\n%%\n## Drawing\n```json\n{\"elements\":[]}\n```\n%%\n"
      json = ~s({"type":"excalidraw","elements":[]})

      assert {:ok, written} = Excalidraw.write_markdown(body, json)
      assert written == "## Text Elements\n%%\n## Drawing\n```json\n#{json}\n```\n%%\n"
    end

    test "text with a backslash or \\\\1 in it is written as it is" do
      body = "## Text Elements\n%%\n## Drawing\n```json\n{\"elements\":[]}\n```\n"

      json =
        Jason.encode!(%{
          "elements" => [%{"id" => "t", "type" => "text", "text" => ~S(a\1 b \0)}]
        })

      assert {:ok, written} = Excalidraw.write_markdown(body, json)
      assert written =~ ~S(a\1 b \0 ^t)

      assert {:ok, %{scene: %{"elements" => [%{"text" => ~S(a\1 b \0)}]}}} =
               Excalidraw.parse_markdown(written)
    end

    test "refuses what is not a scene, and a body with nowhere to put one" do
      assert Excalidraw.write_markdown(@sketch, "{nope") == :error
      assert Excalidraw.write_markdown(@sketch, ~s({"a":1})) == :error
      assert Excalidraw.write_markdown("no drawing here", @sketch_json) == :error
      assert Excalidraw.write_json(@sketch_json) == {:ok, @sketch_json}
      assert Excalidraw.write_json("[1]") == :error
    end
  end

  describe "the SVG preview" do
    setup do
      {:ok, scene} = Excalidraw.parse_json(@sketch_json)
      %{scene: scene}
    end

    test "draws each kind of element where the scene puts it", %{scene: scene} do
      svg = SVG.render(scene)

      assert svg =~ ~r/^<svg xmlns="http:\/\/www.w3.org\/2000\/svg" viewBox="-11 -11 /
      assert svg =~ ~s(<rect x="0" y="0" width="200" height="100" rx="25" fill="#a5d8ff")
      assert svg =~ ~s|<ellipse cx="360" cy="40" rx="60" ry="40" fill="url(#hatch-0)"|
      assert svg =~ ~s(<pattern id="hatch-0")
      assert svg =~ ~s(<path d="M200 50 L300 40")
      assert svg =~ ">Ship it</tspan>"
      assert svg =~ ">of notes ✓</tspan>"
      refute svg =~ "deleted words"
      # The image the plugin keeps as a separate file, not given: a placeholder.
      assert svg =~ ~s(stroke-dasharray="6 4")
      refute svg =~ "filter: invert"
    end

    test "an image it is given is drawn, but only a raster data: URL", %{scene: scene} do
      png = "data:image/png;base64,iVBORw0KGgo="
      assert SVG.render(scene, %{"f00d" => png}) =~ ~s(<image href="#{png}")

      for bad <- ["javascript:alert(1)", "data:image/svg+xml;base64,PHN2Zz4=", "https://x/y.png"] do
        refute SVG.render(scene, %{"f00d" => bad}) =~ "<image"
      end
    end

    test "nothing in the scene reaches the markup unescaped or unchecked" do
      scene = %{
        "appState" => %{"viewBackgroundColor" => "red\" onload=\"x", "theme" => "dark"},
        "elements" => [
          %{
            "type" => "text",
            "x" => 0,
            "y" => 0,
            "width" => 10,
            "height" => 10,
            "text" => "<script>alert(1)</script>",
            "strokeColor" => "#000\"/><script>"
          },
          %{"type" => "frame", "x" => 0, "y" => 0, "width" => 5, "height" => 5, "name" => "<b>"},
          %{"type" => "rectangle", "x" => "1", "y" => nil, "angle" => 0.5, "opacity" => 50}
        ]
      }

      svg = SVG.render(scene)
      refute svg =~ "<script"
      refute svg =~ "onload"
      refute svg =~ "<b>"
      assert svg =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert svg =~ ~s(fill="#ffffff")
      assert svg =~ ~s(fill="#1e1e1e")
      assert svg =~ "filter: invert(93%) hue-rotate(180deg)"
      assert svg =~ ~s|transform="rotate(28.65 0 0)"|
      assert svg =~ ~s(opacity="0.5")
    end

    test "arrowheads, curves, freehand and an empty scene" do
      line = fn extra ->
        Map.merge(
          %{"type" => "arrow", "x" => 0, "y" => 0, "points" => [[0, 0], [50, 50], [100, 0]]},
          extra
        )
      end

      svg =
        SVG.render(%{
          "elements" => [
            line.(%{"endArrowhead" => "triangle", "startArrowhead" => "dot"}),
            line.(%{"endArrowhead" => "bar", "roundness" => %{"type" => 2}}),
            line.(%{"type" => "line", "points" => [[0, 0], [10, 0], [10, 10], [0, 0]]}),
            %{"type" => "freedraw", "x" => 5, "y" => 5, "points" => [[0, 0], [1, 2], [3, 1]]},
            %{"type" => "arrow", "x" => 0, "y" => 0, "points" => [[0, 0]]}
          ]
        })

      assert svg =~ "<polygon"
      assert svg =~ "<circle"
      assert svg =~ " C"
      assert svg =~ ~s( Z")
      assert svg =~ ~s(<path d="M5 5 L6 7 L8 6")

      assert SVG.render(%{"elements" => []}) =~ ~s(viewBox="-10 -10 120 120")
      assert SVG.render(%{}) =~ "<svg"
    end
  end

  describe "finding the drawing an embed names" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Sketches"}, owner: user)
      %{user: user, board: board}
    end

    test "a page by its file name, with or without .md, and its preview", %{
      board: board,
      user: user
    } do
      page =
        page_fixture(
          board,
          %{
            "title" => "Roadmap",
            "file_name" => "Roadmap sketch.excalidraw",
            "front_matter" => "---\nexcalidraw-plugin: parsed\n---\n",
            "body" => @sketch
          },
          user: user
        )

      assert {:page, found} = Drawings.resolve(board, "Roadmap sketch.excalidraw", user)
      assert found.id == page.id
      assert {:page, _} = Drawings.resolve(board, "Roadmap sketch.excalidraw.md", user)
      assert Drawings.resolve(board, "Nothing.excalidraw", user) == nil

      assert {:ok, svg} = Drawings.svg(page, user)
      assert svg =~ ">Ship it</tspan>"

      assert Drawings.preview_url(page) ==
               "/wiki-drawings/page/#{page.id}?v=#{String.slice(page.content_hash, 0, 12)}"
    end

    test "a page not readable, or not a drawing, is not found", %{board: board, user: user} do
      page_fixture(board, %{"title" => "Plain.excalidraw", "body" => "words"}, user: user)
      assert Drawings.resolve(board, "Plain.excalidraw", user) == nil

      page_fixture(
        board,
        %{"title" => "Secret", "file_name" => "Secret.excalidraw", "body" => @sketch},
        user: user
      )

      stranger = user_fixture("stranger-#{System.unique_integer([:positive])}@example.com")
      assert Drawings.resolve(board, "Secret.excalidraw", stranger) == nil
      assert {:page, _} = Drawings.resolve(board, "Secret.excalidraw", user)
    end

    test "a .excalidraw file, with the images the note links put in", %{board: board, user: user} do
      path = Path.join(System.tmp_dir!(), "ex-#{System.unique_integer([:positive])}")
      File.write!(path, @sketch_json)
      {:ok, file} = Files.create(board, %{name: "Flow.excalidraw"}, path)
      File.write!(path, "PNGBYTES")
      {:ok, _cat} = Files.create(board, %{name: "cat.png"}, path)

      assert {:file, found} = Drawings.resolve(board, "Flow.excalidraw", user)
      assert found.id == file.id
      assert {:ok, svg} = Drawings.svg(file, user)
      assert svg =~ ">Ship it</tspan>"
      assert Drawings.preview_url(file) =~ "/wiki-drawings/file/#{file.id}?v="

      page =
        page_fixture(
          board,
          %{"title" => "Linked", "file_name" => "Linked.excalidraw", "body" => @sketch},
          user: user
        )

      assert {:ok, svg} = Drawings.svg(page, user)
      assert svg =~ ~s(<image href="data:image/png;base64,#{Base.encode64("PNGBYTES")}")

      File.write!(Files.disk_path(file), "{broken")
      assert Drawings.svg(file, user) == :error
    end
  end
end
