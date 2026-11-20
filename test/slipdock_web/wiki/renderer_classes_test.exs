defmodule SlipdockWeb.Wiki.RendererClassesTest do
  @moduledoc """
  The classes a page's HTML may carry (#3504): the ones the renderer, comrak
  and the transcript view write, and a code block's `language-…`. Any other
  class written in raw HTML is taken off, token by token.
  """
  use ExUnit.Case, async: true

  alias SlipdockWeb.Wiki.Renderer

  defp classes(html) do
    ~r/ class="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  describe "classes written in raw HTML" do
    test "layout classes are taken off, and the attribute with them" do
      html = Renderer.to_html(~s|<div class="fixed inset-0 z-50">Cover</div>|)

      assert html =~ "<div>Cover</div>"
      refute html =~ "class="
      refute html =~ "fixed"
      refute html =~ "z-50"
    end

    test "on any tag, inline or block" do
      html =
        Renderer.to_html("""
        <p class="absolute top-0">para</p>

        A <a href="/x" class="fixed">link</a>, <span class="z-[9999]">span</span>,
        <img src="/i.png" alt="i" class="inset-0"> and <b class="sr-only">bold</b>.

        <ul class="hidden"><li class="w-screen h-screen">item</li></ul>
        """)

      assert classes(html) == []
      assert html =~ "<p>para</p>"
      assert html =~ "<span>span</span>"
      assert html =~ "<li>item</li>"
    end

    test "a mixed list keeps the allowed classes and loses the rest" do
      html = Renderer.to_html(~s|<span class="fixed wiki-inline inset-0 wiki-link z-50">x</span>|)

      assert classes(html) == ["wiki-inline wiki-link"]
    end

    test "an allowed class is kept once, however often it is written" do
      html = Renderer.to_html(~s|<span class="wiki-inline  wiki-inline">x</span>|)
      assert classes(html) == ["wiki-inline"]
    end

    test "a class is matched exactly, not by its case or a part of it" do
      html =
        Renderer.to_html(
          ~s|<span class="Wiki-Inline wiki-inline-x xwiki-inline wiki anchorx">x</span>|
        )

      assert classes(html) == []
    end

    test "an empty class attribute goes" do
      html = Renderer.to_html(~s|<span class="">x</span> <span class="  ">y</span>|)
      refute html =~ "class="
    end

    test "a language class needs a language after its prefix" do
      html =
        Renderer.to_html(
          ~s|<code class="language-">a</code> <code class="language-a&amp;b">b</code> | <>
            ~s|<code class="language-a/b">c</code>|
        )

      assert classes(html) == []
    end

    test "a ` class=` inside another attribute's value is left as it is" do
      html = Renderer.to_html(~s|<span title="x class=" data-tag="fixed">t</span>|)

      assert html =~ ~s|<span title="x class=" data-tag="fixed">t</span>|
    end

    test "a page's other attributes come through as they were" do
      html = Renderer.to_html(~s|<a href="/x" class="fixed" title="T">l</a>|)
      assert html =~ ~s|<a href="/x" title="T" rel="noopener noreferrer">l</a>|
    end
  end

  describe "the classes the renderer writes" do
    test "comrak's are kept: code languages, heading anchors and footnotes" do
      html =
        Renderer.to_html("""
        ## Heading

        ```elixir
        x = 1
        ```

        ```c++
        y
        ```

        Text[^a]

        [^a]: note
        """)

      for class <- ~w(anchor language-elixir language-c++ footnote-ref footnote-backref) do
        assert class in classes(html), "#{class} kept"
      end
    end

    test "a transcript's are kept, every speaker's colour and the tag chips" do
      speakers = ~w(Ann Ben Cat Dan Eve Fay Gus)

      cues =
        speakers
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {name, i} ->
          "00:00:0#{i}.000 --> 00:00:0#{i}.900\n<v #{name}>words from #{name}\n"
        end)

      vtt = "WEBVTT\n\n" <> cues
      tags = Slipdock.Wiki.TranscriptTags.parse("Tags: #important (0:02)\n")
      written = SlipdockWeb.TranscriptView.block_html(vtt, tags)

      html = Renderer.to_html("Tags: #important (0:02)\n\n```vtt\n" <> vtt <> "```\n")

      assert written =~ "wiki-transcript-tag "

      assert Enum.sort(classes(html) -- ["wiki-transcript-tags", "wiki-transcript-tag-link"]) ==
               Enum.sort(classes(written))

      assert "wiki-transcript-tags" in classes(html)
      assert "wiki-transcript-tag-link" in classes(html)
    end

    test "a transcript block with nothing in it keeps its note's classes" do
      vtt = "WEBVTT\n\nNOTE No speech detected.\n"
      written = SlipdockWeb.TranscriptView.block_html(vtt)
      html = Renderer.to_html("```vtt\n" <> vtt <> "```\n")

      assert [_] = classes(written)
      assert classes(html) == classes(written)
    end

    # The second time a class is written and not allowed, the page loses it
    # silently; this is the check that fails first.
    test "every class written in the renderer's sources is allowed" do
      sources = [
        "lib/slipdock_web/wiki/renderer.ex",
        "lib/slipdock/wiki/transcript_tags.ex",
        "lib/slipdock_web/components/transcript_view.ex"
      ]

      written =
        for path <- sources,
            [value] <- Regex.scan(~r/class="([^"]*)"/, File.read!(path), capture: :all_but_first),
            not String.contains?(value, "\#{"),
            class <- String.split(value),
            uniq: true,
            do: class

      assert length(written) > 40
      assert Enum.reject(written, &Renderer.allowed_class?/1) == []

      # The ones put together in code rather than written out.
      for class <-
            ~w(wiki-chip wiki-chip-done wiki-query-card wiki-transcript-block my-4) ++
              Enum.map(1..6, &"wiki-toc-#{&1}") do
        assert Renderer.allowed_class?(class), class
      end
    end
  end
end
