defmodule SlipdockCLI.WikiShowTreeTest do
  @moduledoc """
  `slipdock wiki show`, `wiki tree` and `wiki changes`: your wiki's boards,
  page count and synced folders, its tree, and what changed.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, WholeWiki}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-wikishow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp json(term), do: term |> :json.encode() |> IO.iodata_to_binary()

  defp show(response) do
    System.put_env("SLIPDOCK_URL", FakeServer.start([{200, response}]))
    out = capture_io(fn -> WholeWiki.wiki(["show"], []) end)
    assert_received {:request, "GET", path, _}
    assert path =~ ~r{/api/wiki$}
    out
  end

  test "prints each board, the page count and every synced folder" do
    out =
      show(
        ~s({"wiki":{"pages":202,"boards":[
        {"id":5,"code":"kb","name":"Keystone","path":"/Keystone","archived":false},
        {"id":6,"code":"jobs","name":"Journal Desk","path":"/Journal Desk","archived":false}],
        "mirrors":[{"label":"slipdock CLI on laptop","last_synced_at":"2026-10-13T10:00:00Z"}]},"boards":[]})
      )

    assert out =~ ~r{/Keystone\s+kb$}m
    assert out =~ ~r{/Journal Desk\s+jobs$}m
    assert out =~ "202 pages"
    assert out =~ "synced to slipdock CLI on laptop, last 2026-10-13T10:00:00Z"
  end

  test "with one page and no mirrors" do
    out = show(~s({"wiki":{"pages":1,"boards":[],"mirrors":[]},"boards":[]}))
    assert out =~ "1 page"
    refute out =~ "1 pages"
    refute out =~ "synced to"
  end

  describe "wiki tree" do
    @listing %{
      "cursor" => 1,
      "folders" => ["Key", "Key/Cards", "Key/Cards/Parked jobs", "Key/Cards/Plain"],
      "boards" => [%{"id" => 1, "title" => "Keystone", "path" => "Key", "archived" => true}],
      "virtual_folders" => [
        %{"title" => "Cards", "path" => "Key/Cards", "archived" => false}
      ],
      "folder_details" => %{
        "Key/Cards/Parked jobs" => %{
          "id" => 2,
          "title" => "Parked jobs must be released on timeout",
          "short_name" => "Parked jobs",
          "archived" => false
        },
        "Key/Cards/Plain" => %{
          "id" => 3,
          "title" => "Plain",
          "archived" => false
        }
      },
      "entries" => [
        %{"kind" => "page", "path" => "Key/Cards/Plain/Note.md", "title" => "My note: one"},
        %{"kind" => "file", "path" => "Key/x.pdf", "name" => "x.pdf"}
      ]
    }

    defp tree(opts) do
      System.put_env("SLIPDOCK_URL", FakeServer.start([{200, json(@listing)}]))
      out = capture_io(fn -> WholeWiki.wiki(["tree"], opts) end)
      assert_received {:request, "GET", path, _}
      assert path =~ ~r{/api/wiki/sync$}
      out
    end

    test "full titles, indented, archived marked" do
      out = tree([])

      assert out =~ "Keystone/"
      assert out =~ "archived"
      assert out =~ "    Parked jobs must be released on timeout/"
      assert out =~ "      My note: one"
      assert out =~ "  x.pdf"
    end

    test "--short-names, falling back to the title" do
      out = tree(short_names: true)

      assert out =~ "    Parked jobs/\n"
      refute out =~ "released on timeout"
      assert out =~ "    Plain/"
    end
  end

  describe "wiki changes" do
    defp changes(opts) do
      body = %{
        "cursor" => 9,
        "more" => false,
        "changes" => [
          %{
            "cursor" => 9,
            "subject" => "folder",
            "action" => "moved",
            "from_path" => "Key/Cards/Old",
            "path" => "Key/Cards/New long",
            "short_name" => "New"
          },
          %{"cursor" => 8, "subject" => "page", "action" => "changed", "path" => "Key/A.md"}
        ]
      }

      System.put_env("SLIPDOCK_URL", FakeServer.start([{200, json(body)}]))
      capture_io(fn -> WholeWiki.wiki(["changes"], opts) end)
    end

    test "a move says from where to where" do
      assert changes([]) =~ "folder moved  Key/Cards/Old → Key/Cards/New long"
    end

    test "--short-names says the name, or the path where there is none" do
      out = changes(short_names: true)

      assert out =~ "Key/Cards/Old → New"
      assert out =~ "page changed  Key/A.md"
    end
  end
end
