defmodule Slipdock.ToolPackagesDocTest do
  @moduledoc """
  `docs/tool-packages.md` is what programs that build Tools are pointed at
  (#1156), so it is held to the server: its worked example must publish and
  install, its documented response must have the shape the server answers
  with, its preset table must be the presets, and every endpoint it names
  must be routed.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Automations, Boards, Tools}
  alias Slipdock.Tools.Package

  @doc_path Path.expand("../../docs/tool-packages.md", __DIR__)
  @external_resource @doc_path
  @doc_text File.read!(@doc_path)

  # The worked example's files: each `#### `path`` heading and the fenced
  # block under it.
  defp example_files do
    [_, example] = String.split(@doc_text, "## Worked example", parts: 2)

    ~r/^#### `([^`]+)`\n\n```[a-z]*\n(.*?)^```/ms
    |> Regex.scan(example, capture: :all_but_first)
    |> Map.new(fn [path, body] -> {path, body} end)
  end

  defp documented_response do
    [_, after_heading] = String.split(@doc_text, "#### Response", parts: 2)
    [_, json | _] = String.split(after_heading, ~r/```json\n|```\n/, parts: 3)
    Jason.decode!(json)
  end

  defp tarball(files) do
    entries = for {path, body} <- files, do: {String.to_charlist("reply-drafts/" <> path), body}
    path = Path.join(System.tmp_dir!(), "doc-tool-#{System.unique_integer([:positive])}.tgz")

    try do
      :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed, :write])
      File.read!(path)
    after
      File.rm(path)
    end
  end

  # A map's keys all the way down, lists by their first item: the shape.
  defp shape(%{} = map), do: Map.new(map, fn {k, v} -> {k, shape(v)} end)
  defp shape([first | _]), do: [shape(first)]
  defp shape(_), do: :value

  test "the worked example is a package the server reads" do
    files = example_files()

    assert Map.keys(files) |> Enum.sort() == [
             "README.md",
             "board.json",
             "files/build.py",
             "skills/reply-drafts/SKILL.md",
             "skills/reply-drafts/references/procedure.md",
             "tool.json"
           ]

    assert {:ok, package} = Package.read(tarball(files))
    assert package.manifest["name"] == "reply-drafts"
    assert [%{name: "reply-drafts"}] = package.skills
  end

  test "publishing it answers with the documented shape and values" do
    user = user_fixture()
    {:ok, version} = Tools.publish(user, tarball(example_files()))

    actual =
      %{"tool" => SlipdockWeb.API.ToolJSON.show(version.tool, version, user)}
      |> Jason.encode!()
      |> Jason.decode!()

    documented = documented_response()

    assert shape(documented) == shape(actual)

    # What doesn't vary from server to server is exactly as documented.
    for key <- ~w(name title summary version mine kind installed author requires versions
                  skills_archive package files listing) do
      assert documented["tool"][key] == actual["tool"][key], "tool.#{key}"
    end

    assert documented["tool"]["board"]["lists"] == actual["tool"]["board"]["lists"]
    assert documented["tool"]["board"]["automations"] == actual["tool"]["board"]["automations"]

    [doc_skill] = documented["tool"]["skills"]
    [skill] = actual["tool"]["skills"]

    for key <- ~w(name files version skill_md claude_zip chatgpt_zip),
        do: assert(doc_skill[key] == skill[key], "skills[0].#{key}")
  end

  test "installing it makes what the page says, Found as the ready list" do
    Slipdock.TestConfig.own_uploads_dir()
    user = user_fixture()
    {:ok, version} = Tools.publish(user, tarball(example_files()))

    {:ok, result} = Tools.install_board(user, version.tool)

    assert result.report.added["lists"] == ["Found", "Generate", "Ready", "Sent", "Closed"]
    assert result.report.added["pages"] == ["Criteria"]
    assert result.report.added["automations"] == ["Draft a reply"]
    assert result.report.added["files"] == []

    board = Boards.get_board!(result.board.id)
    roles = SlipdockWeb.APIGuide.list_roles(board.columns)
    assert roles.ready.name == "Found"
    assert roles.doing.name == "Generate"
    assert roles.done.name == "Closed"

    [rule] = Automations.list_rules(board.id)
    assert rule.spec["trigger"] == %{"type" => "card_entered", "column" => "Generate"}

    assert [%{"pool" => "generate", "kind" => "claude", "prompt" => prompt}] =
             rule.spec["actions"]

    assert prompt =~ "Use the reply-drafts skill"
  end

  test "the preset table is every preset, with its fields, required marks and defaults" do
    [_, table] = String.split(@doc_text, "<!-- presets:start -->\n", parts: 2)
    [table, _] = String.split(table, "\n<!-- presets:end -->", parts: 2)
    [_header, _rule | rows] = String.split(table, "\n", trim: true)

    expected =
      for p <- Automations.Presets.all() do
        fields =
          Enum.map_join(p.fields, ", ", fn f ->
            "`#{f.name}`" <>
              if(f.required, do: "*", else: "") <>
              if(Map.has_key?(f, :default), do: " (#{f.default})", else: "")
          end)

        "| `#{p.key}` | #{p.title} | #{fields} |"
      end

    assert rows == expected
  end

  test "every endpoint the page names is routed" do
    routes =
      SlipdockWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(
        &{&1.verb |> Atom.to_string() |> String.upcase(), String.split(&1.path, "/", trim: true)}
      )

    named =
      ~r/`(GET|POST|PATCH|PUT|DELETE) (\/api\/[^`?\s\[]+)/
      |> Regex.scan(@doc_text, capture: :all_but_first)
      |> Enum.uniq()

    assert length(named) >= 8

    for [verb, path] <- named do
      segments = String.split(path, "/", trim: true)

      assert Enum.any?(routes, fn {v, route} -> v == verb and matches?(route, segments) end),
             "#{verb} #{path} is not a route"
    end
  end

  # A route's `:param` takes one segment and `*glob` the rest; the page's
  # `<placeholder>` may only stand where the route has a parameter.
  defp matches?([], []), do: true
  defp matches?(["*" <> _], [_ | _]), do: true
  defp matches?([":" <> _ | route], [_ | path]), do: matches?(route, path)

  defp matches?([seg | route], [seg | path]) when binary_part(seg, 0, 1) != "<",
    do: matches?(route, path)

  defp matches?(_, _), do: false
end
