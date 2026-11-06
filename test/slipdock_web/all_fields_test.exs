defmodule SlipdockWeb.AllFieldsTest do
  @moduledoc """
  Every box a person types into or picks from, on every page, is one field
  (#1723): the `field` class (or `field-bare` for text edited in place), and
  never a daisyUI size modifier or a text size of its own. #1672 made the
  card back so, and `card_fields_test.exs` guards it there; this renders
  every signed-in, admin and help LiveView route in the router and checks
  them all, so a new page, or a new field on an old one, can't slip back to
  34px boxes with 16px text, or 12px.

  A date field is its box (`[data-date-field]`, #1720): the native input in
  it is hidden. Hidden, checkbox, radio, file and range inputs aren't boxes.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures
  import Slipdock.ToolPackages

  alias Slipdock.{Access, Accounts, Multiboard, Settings, Tools, Wiki}
  alias Slipdock.Wiki.Files

  @sizes ~w(input-xs input-sm input-md input-lg input-xl select-xs select-sm select-md select-lg
            select-xl textarea-xs textarea-sm textarea-md textarea-lg textarea-xl
            textarea-bordered select-bordered input-bordered select-ghost input-ghost
            text-xs text-sm text-base text-lg text-2xs rounded-full font-mono)

  @fields "input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=file])" <>
            ":not([type=range]):not([type=color]):not(.date-field-input), textarea, select, [data-date-field]"

  # The live sessions whose pages this covers: everything behind sign-in,
  # the admin pages and help. (Setup, login and published views have their
  # own forms and their own tests.)
  @sessions [:authenticated, :admin, :help]

  @sketch File.read!("test/support/fixtures/excalidraw/Sketch.excalidraw.md")

  @doc false
  def fields(html) do
    doc = LazyHTML.from_document(html)
    # A box drawn by its wrapper (`<label class="input field">` around a bare
    # input and an icon) is the wrapper: the input inside it isn't checked.
    inside = doc |> LazyHTML.query(".field input, .field-bare input") |> Enum.map(&key/1)

    doc
    |> LazyHTML.query(@fields)
    |> Enum.reject(&(key(&1) in inside))
    |> Enum.map(fn node ->
      first = fn attr, default ->
        case LazyHTML.attribute(node, attr) do
          [v | _] -> v
          [] -> default
        end
      end

      what = first.("id", nil) || first.("name", nil) || first.("aria-label", "a field")
      {what, String.split(first.("class", ""))}
    end)
  end

  # A label's words, where the label wraps a field: `field-label` (or
  # `section-label` on the card back's properties), never a style of its own.
  @doc false
  def label_offences(html) do
    doc = LazyHTML.from_document(html)

    for label <- LazyHTML.query(doc, "label"),
        Enum.count(LazyHTML.query(label, @fields)) > 0,
        span <-
          label
          |> LazyHTML.child_nodes()
          |> Enum.filter(&(LazyHTML.tag(&1) == ["span"]))
          |> Enum.take(1),
        text = span |> LazyHTML.text() |> String.trim(),
        text != "",
        classes = span |> LazyHTML.attribute("class") |> Enum.join(" ") |> String.split(),
        not Enum.any?(~w(field-label section-label sr-only), &(&1 in classes)),
        do: "label “#{text}”: not a field-label (#{Enum.join(classes, " ")})"
  end

  defp key(node),
    do: {LazyHTML.attribute(node, "id"), LazyHTML.attribute(node, "name"), LazyHTML.to_html(node)}

  @doc false
  def offences(fields) do
    for {what, classes} <- fields,
        reason = offence(classes),
        do: "#{what}: #{reason} (#{Enum.join(classes, " ")})"
  end

  defp offence(classes) do
    cond do
      "field" not in classes and "field-bare" not in classes ->
        "not a field"

      (sized = Enum.filter(classes, &(&1 in @sizes))) != [] ->
        "sized by #{Enum.join(sized, ", ")}"

      true ->
        nil
    end
  end

  # The routes, in groups that run side by side: by their first two fixed
  # segments ("boards table", "account", "config"…).
  @groups for(
            r <- SlipdockWeb.Router.__routes__(),
            r.plug == Phoenix.LiveView.Plug,
            {_, _, _, %{name: session}} = r.metadata.phoenix_live_view,
            session in @sessions,
            uniq: true,
            do: r.path
          )
          |> Enum.group_by(fn path ->
            path
            |> String.split("/", trim: true)
            |> Enum.reject(&String.starts_with?(&1, [":", "*"]))
            |> Enum.take(2)
            |> Enum.join(" ")
            |> then(&if &1 == "", do: "home", else: &1)
          end)

  setup %{conn: conn} do
    Slipdock.TestConfig.own_uploads_dir()
    # Inbound mail on, for the Email log tab.
    Slipdock.TestConfig.put(:inbound, domain: "example.com", secrets: ["s"])

    {:ok, _} =
      Settings.complete_setup(%{"admin_email" => "admin@example.com", "signup_mode" => :closed})

    {:ok, admin} = Accounts.promote(user_fixture("admin@example.com"))
    board = board_fixture(%{"name" => "Every field"}, owner: admin)
    [todo | _] = board.columns
    card = card_fixture(todo, %{"title" => "A card", "due_date" => "2030-01-15"})
    page = page_fixture(board, %{"title" => "A page", "body" => "Words."}, user: admin)
    {:ok, page} = Wiki.update_page(page, %{"body" => "More words."}, user: admin)
    [rev | _] = Wiki.list_revisions(page)

    drawing =
      page_fixture(
        board,
        %{
          "title" => "Sketch",
          "file_name" => "Sketch.excalidraw",
          "front_matter" => "---\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n---\n",
          "body" => @sketch
        },
        user: admin
      )

    path = Path.join(System.tmp_dir!(), "af-#{System.unique_integer([:positive])}")
    File.write!(path, "PNG")
    {:ok, file} = Files.create(board, %{name: "cat.png"}, path)
    File.rm(path)

    name = unique_name()
    {:ok, _} = Tools.publish(admin, package(name))

    {:ok, mb} =
      Multiboard.create_saved(admin, %{"name" => "Mine", "color" => "teal"}, %{
        lists: [todo.id],
        top: 5,
        by: "board"
      })

    # Something shared with the admin, for Shared with me.
    owner = user_fixture("af.owner@example.com")
    theirs = board_fixture(%{"name" => "Theirs"}, owner: owner)
    {:ok, folder} = Wiki.create_folder(theirs, %{"name" => "Shared folder"})

    shared =
      page_fixture(theirs, %{"title" => "Shared page", "folder_id" => folder.id}, user: owner)

    {:ok, _} = Access.grant(folder, admin, "write", owner)
    # And a board shared with them: its Shared page is a member's.
    {:ok, _} = Access.grant(theirs, admin, "write", owner)

    params = %{
      "id" => board.id,
      "card_id" => card.id,
      "slug" => page.slug,
      "rev" => rev.id,
      "topic" => SlipdockWeb.HelpLive.Agents.topics() |> hd() |> topic_key(),
      "section" => SlipdockWeb.HelpLive.Guides.sections() |> hd() |> topic_key()
    }

    # The paths whose `:id` isn't the board's.
    special = %{
      "/files/:id" => "/files/#{file.id}",
      "/drawings/:kind/:id" => "/drawings/page/#{drawing.id}",
      "/multiboard/:id" => "/multiboard/#{mb.id}",
      "/tools/:slug" => "/tools/#{name}",
      "/shared/folders/:id" => "/shared/folders/#{folder.id}",
      "/shared/pages/:id" => "/shared/pages/#{shared.id}",
      "/shared/pages/:id/edit" => "/shared/pages/#{shared.id}/edit",
      "/wiki/*path" => "/wiki/Every field",
      "/boards/:id/shared" => "/boards/#{theirs.id}/shared"
    }

    %{conn: log_in_user(conn, admin), params: params, special: special}
  end

  defp topic_key(%{slug: slug}), do: slug

  defp try_live(conn, url) do
    live(conn, url)
  rescue
    e -> {:raised, Exception.message(e)}
  end

  defp fill(path, params, special) do
    Map.get_lazy(special, path, fn ->
      Regex.replace(~r/:(\w+)/, path, fn _, key -> to_string(Map.fetch!(params, key)) end)
    end)
  end

  test "the routes are all here" do
    paths = @groups |> Map.values() |> List.flatten()
    assert length(paths) > 100
    assert "/boards/:id/settings" in paths
    assert "/users" in paths
    assert "/help" in paths
  end

  for {group, paths} <- @groups do
    @tag timeout: 300_000
    test "every field on the #{group} pages is a field, at the one size", ctx do
      {offences, unrendered} =
        Enum.reduce(unquote(paths), {[], []}, fn path, {off, un} ->
          url = fill(path, ctx.params, ctx.special)

          case try_live(ctx.conn, url) do
            {:ok, view, _} ->
              html = render(view)
              found = (html |> fields() |> offences()) ++ label_offences(html)
              {off ++ Enum.map(found, &"#{url} #{&1}"), un}

            other ->
              {off, [{url, other} | un]}
          end
        end)

      assert unrendered == [], "These pages didn't render:\n#{inspect(unrendered, pretty: true)}"

      assert offences == [],
             "Draw these as `field` (or `field-bare`), with no size of their own, and label " <>
               "them with `field-label` (W-1946 §Rules):\n" <>
               Enum.join(Enum.uniq(offences), "\n")
    end
  end

  # What isn't open when a page first renders (a modal's second step, a
  # popover) is checked in the source: no daisyUI size on any field.
  test "no field in the source carries a daisyUI size" do
    hits =
      for path <- Path.wildcard("lib/slipdock_web/**/*.{ex,heex}"),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/\b(input|select|textarea)-(xs|sm|md|lg|xl|bordered|ghost)\b/,
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert hits == [], "Use `field` or `field-bare` (W-1946 §Rules):\n" <> Enum.join(hits, "\n")
  end

  describe "the check itself" do
    test "finds a box that isn't a field, and one with a size" do
      html = """
      <input type="text" id="a" class="input input-sm" />
      <input type="text" id="b" class="input field" />
      <select id="c" class="select field select-xs"></select>
      <textarea id="d" class="textarea field-bare"></textarea>
      <input type="checkbox" id="e" class="checkbox" />
      <input type="hidden" id="f" />
      <div data-date-field id="g" class="date-field field"><input type="date" class="date-field-input" /></div>
      <div data-date-field id="h" class="date-field"></div>
      <label class="input field"><input type="search" id="i" /></label>
      """

      assert [
               "a: not a field" <> _,
               "c: sized by select-xs" <> _,
               "h: not a field" <> _
             ] = html |> fields() |> offences()
    end

    test "finds a field's label in a style of its own" do
      html = """
      <label><span class="field-label">Name</span><input class="input field" name="a" /></label>
      <label><span class="section-label">Due</span><input class="input field" name="b" /></label>
      <label><span class="text-xs text-base-content/60">Code</span><input class="input field" name="c" /></label>
      <label><span class="font-medium">Just words</span></label>
      """

      assert [~s(label “Code”: not a field-label (text-xs text-base-content/60\))] =
               label_offences(html)
    end
  end
end
