defmodule SlipdockWeb.WikiLive.Format do
  @moduledoc """
  Small helpers `WikiLive.Index` and its templates share: paths, dates,
  excerpts, counts, breadcrumbs and the labels the tree's dialogs use. Pure
  functions of what they are given, and the function components they need.
  """
  use SlipdockWeb, :html

  alias SlipdockWeb.Dates
  alias Slipdock.Wiki
  alias Slipdock.Vaults.Names
  alias Slipdock.Wiki.{CardFolders, AutoOrganise, Folder, Icons, Page}
  alias SlipdockWeb.Wiki.Renderer

  # Folders with what to call them: a card's folder has its card's title and
  # short name, and any other just its name.
  def crumbs(folders) do
    labels = folders |> Enum.map(& &1.id) |> CardFolders.labels()

    Enum.map(folders, fn folder ->
      {folder, labels[folder.id] || %{title: folder.name, short_name: nil}}
    end)
  end

  # The folders a page is filed under, outermost first.
  def folder_crumbs(%Page{} = page) do
    case page.folder_id && Wiki.get_folder(page.folder_id) do
      nil -> []
      folder -> Wiki.folder_ancestors(folder) ++ [folder]
    end
  end

  def filed_in(%Page{} = page) do
    case folder_crumbs(page) do
      [] -> ""
      crumbs -> Enum.map_join(crumbs, "/", & &1.name)
    end
  end

  # A page always reaches the view with everything it draws loaded: its
  # assignee, and the card contents it carries (see `Slipdock.Boards.Owned`).
  # An unloaded association here is a crash in a component, not a blank.
  def recording_problem({:error, reason}), do: reason
  def recording_problem(_), do: nil

  def as_datetime(%DateTime{} = dt), do: dt
  def as_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")

  # The vault view's breadcrumbs: the vault, then each directory down to
  # what is shown, each a link to its place in the view.
  def vault_crumbs(vault, addresses, page, folder, choice) do
    path =
      case {page, folder} do
        {%Page{id: id}, _} -> addresses.pages[id]
        {_, %Folder{id: id}} -> addresses.folders[id]
        _ -> nil
      end

    segments = if path, do: String.split(path, "/"), else: []

    segments
    |> Enum.with_index(1)
    |> Enum.map(fn {name, n} ->
      at = segments |> Enum.take(n) |> Enum.join("/")
      {shown, full} = Names.label(addresses.names, at, choice) || {name, name}

      %{name: shown, full: full, url: SlipdockWeb.VaultUrls.url(vault, at)}
    end)
  end

  def item_name(%Page{title: title}), do: title
  def item_name(%Folder{name: name}), do: name

  # What a move to another board leaves behind, one line each.
  def cross_losses(report) do
    [
      report.tags.dropped != [] && "Tags: " <> Enum.join(report.tags.dropped, ", "),
      report.fields.dropped != [] && "Field values: " <> Enum.join(report.fields.dropped, ", "),
      report.pins.dropped != [] &&
        "Pinned cards (they stay linked, unpinned): " <> Enum.join(report.pins.dropped, ", "),
      report.assignees != [] && "Assigned to: " <> Enum.join(report.assignees, ", "),
      report.lists != [] && "A place in the list: " <> Enum.join(report.lists, ", "),
      report.parents != [] && "Its parent page: " <> Enum.join(report.parents, ", "),
      report.left_behind != [] &&
        "Pages filed there under a page that isn't moving: " <>
          Enum.join(report.left_behind, ", "),
      report.filing_dropped > 0 &&
        "#{count(report.filing_dropped, "filing")} in folders on boards outside your wiki"
    ]
    |> Enum.filter(& &1)
  end

  def visible_targets(%{targets: targets, q: q}) do
    case String.downcase(String.trim(q || "")) do
      "" -> targets
      term -> Enum.filter(targets, &String.contains?(String.downcase(&1.label), term))
    end
  end

  # An icon or colour name as the form holds it, blank as none. Not
  # `blank_to_nil/1`, which reads strings as ids: every name came out nil, so
  # picking a colour unpicked the icon (#1203).
  def dress_value(value) when value in [nil, ""], do: nil
  def dress_value(value), do: value

  def wiki_path(board), do: ~p"/boards/#{board}/wiki"
  def page_path(board, %Page{} = page), do: ~p"/boards/#{board}/wiki/#{page.slug}"

  def summary_of(%Page{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  def summary_of(%Page{body: body}), do: Renderer.excerpt(body, 140)

  # A listing's line under a title, from what `Slipdock.Wiki.Tree.excerpts/1`
  # read of the page: the summary, or the start of the body.
  def excerpt_of(excerpts, id) do
    case excerpts[id] do
      %{summary: summary} when is_binary(summary) and summary != "" -> summary
      %{body: body} -> Renderer.excerpt(body, 140)
      _ -> ""
    end
  end

  # What a page says about where it stands, for the places that only show it.
  def facets(page) do
    [
      page.priority != "none" && {page.priority, "Priority"},
      page.completed && {"written", "Marked written"},
      assignee_facet(page.assignee),
      page.start_date && {"starts #{Dates.short(page.start_date)}", "Start date"},
      page.due_date && {"due #{Dates.short(page.due_date)}", "Due date"},
      page.percent_complete && {"#{page.percent_complete}%", "Per cent complete"}
    ]
    |> Enum.filter(&is_tuple/1)
    |> Enum.concat(Enum.map(page.flags, &{&1, "Flag"}))
  end

  # An unloaded association is truthy, so the match has to be on the struct.
  defp assignee_facet(%Slipdock.Accounts.User{} = user),
    do: {"@" <> Slipdock.Accounts.User.display_name(user), "Assignee"}

  defp assignee_facet(_), do: nil

  def column_name(columns, column_id) do
    case Enum.find(columns, &(&1.id == column_id)) do
      nil -> "a list"
      column -> column.name
    end
  end

  def iso(nil), do: nil
  def iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  def stamp(nil), do: ""
  def stamp(%DateTime{} = at), do: Dates.datetime(at)

  # Short, for the tree's Recent view: the time today, the day otherwise.
  def recent_stamp(nil), do: ""

  def recent_stamp(%DateTime{} = at) do
    if Dates.long(at) == Dates.long(DateTime.utc_now()),
      do: Dates.time(at),
      else: Dates.short(at)
  end

  def via_label("web"), do: "in the app"
  def via_label("api"), do: "over the API"
  def via_label("cli"), do: "from the CLI"
  def via_label("assistant"), do: "by the assistant"
  def via_label("automation"), do: "by an automation"
  def via_label("mcp"), do: "over MCP"
  def via_label("gardener"), do: "by the gardener"
  def via_label("email"), do: "by email"
  def via_label(_), do: ""

  def author_label(revision) do
    case revision.author do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} -> email
      _ -> "someone"
    end
  end

  # The plan for the organise dialog's choices; the AI's waits for its button.
  def organise_plan(%{mode: "ai"} = prompt), do: %{prompt | plan: nil, error: nil}

  def organise_plan(prompt) do
    opts =
      if prompt.mode == "date",
        do: [parent: prompt.parent, granularity: prompt.granularity, source: prompt.source],
        else: []

    case AutoOrganise.plan(prompt.folder, prompt.mode, opts) do
      {:ok, plan} -> %{prompt | plan: plan, error: nil}
      {:error, message} -> %{prompt | plan: nil, error: message}
    end
  end

  def organise_choice(value, allowed, current),
    do: if(Enum.member?(allowed, value), do: value, else: current)

  def count(1, noun), do: "1 #{noun}"
  def count(n, noun), do: "#{n} #{noun}s"

  # What is about to be lost, said plainly. A page's children are not deleted
  # with it, so the warning says where they will end up instead.
  def delete_warning(%Page{} = page, children) do
    base = "Delete “#{page.title}” and its whole history for good? This cannot be undone."

    case length(children) do
      0 -> base
      n -> base <> " The #{count(n, "page")} under it will be kept, at the top of the tree."
    end
  end

  attr :kind, :atom, required: true, values: [:folder, :page]
  attr :icon, :string, default: nil
  attr :color, :string, default: nil
  attr :class, :string, default: "size-4"
  attr :plain, :string, default: "text-base-content/50", doc: "the tint when it has no colour"

  # A folder's or page's icon in its colour (#792), or the plain one of its
  # kind. `data-icon` and `data-color` say which, for whoever reads the page
  # rather than looks at it.
  def wiki_icon(assigns) do
    ~H"""
    <span
      class={[Icons.class(@icon, @kind), "shrink-0", @class, Icons.tint(@color) || @plain]}
      data-icon={@icon}
      data-color={@color}
      aria-hidden="true"
    ></span>
    """
  end

  # Whether a page wears anything of its own: a page row shows no icon at
  # all unless it does, so a listing of plain pages reads as it always has.
  def dressed?(row), do: not is_nil(row[:icon]) or not is_nil(row[:color])
end
