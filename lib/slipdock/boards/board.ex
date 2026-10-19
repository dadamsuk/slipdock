defmodule Slipdock.Boards.Board do
  use Ecto.Schema
  import Ecto.Query, only: [from: 2]
  import Ecto.Changeset

  schema "boards" do
    field :name, :string
    # A short, URL-safe handle for the board: unique, at most 10 characters,
    # generated from the name and editable. See `code_from_name/2`.
    field :code, :string
    # The key that jumps to this board from the board switcher ("b"): one or
    # two characters, unique, taken from the name and editable. Only top-level
    # boards have one — the switcher never lists sub-boards.
    field :shortcut, :string
    field :description, :string
    field :color, :string, default: "indigo"
    # Budget voting: votes per person across the tree, and the most one
    # card may take from one person.
    field :vote_budget, :integer, default: 10
    field :vote_max, :integer, default: 5
    # The counter the next wiki page's number — and so its code, "W-31" —
    # comes from. Taken in the same transaction as the page's insert.
    field :page_seq, :integer, default: 0

    # What the foot of every list offers. All three add something to the
    # list; a board that never holds documents can turn that one off rather
    # than look at the button.
    field :add_card, :boolean, default: true
    field :add_page, :boolean, default: true
    field :add_document, :boolean, default: true

    # Whether this board's wiki pages carry the card contents under their
    # prose: status, checklist, links, fields, votes and comments. One switch
    # for the whole wiki; off hides them without deleting anything.
    field :page_card_features, :boolean, default: true

    # The view that opening the board lands on, from the board index, the
    # board switcher and favourites: one of `default_views/0`. nil is the
    # board itself. The view menu still reaches every view.
    field :default_view, :string
    # How the top of the board's wiki tree orders its pages, as a folder's
    # `sort` does for the folder (see `Slipdock.Wiki.Folder.sorts/0`). By
    # name unless someone chose otherwise (#789).
    field :wiki_sort, :string, default: "name"
    # Whether the wiki's tree shows folders' and pages' icons and colours
    # (#792); the main page always does.
    field :wiki_tree_icons, :boolean, default: true

    # A simple board is a plain to-do list: the project-tracking details
    # (see `technical_facets/0`) are hidden on its cards and its tiles, and
    # the Timeline and Prioritise views drop out of its view menu. The data
    # stays, so turning it off brings everything back.
    field :simple, :boolean, default: false

    # Whether the board page shows its pulse (#1113, `Slipdock.Pulse`) as a
    # strip of plain words above the lists. Off unless the owner turns it
    # on; the numbers reach the API, MCP and the CLI either way.
    field :show_pulse, :boolean, default: false

    # Whether the board records deploys and shows delivery metrics (#1134,
    # `Slipdock.Deployments`, `Slipdock.Dora`). Off unless the owner turns it
    # on, and invisible while off: the deploy endpoint refuses posts for it.
    field :delivery_metrics, :boolean, default: false
    # The hash of the board's deploy token (`Slipdock.Deployments.issue_token/1`):
    # it records deploys for this board and does nothing else. Never set
    # through `changeset/2`.
    field :deploy_token_hash, :binary, redact: true
    # A regex finding card ids in commit messages, its first group the id;
    # nil is `#NNN` (`Slipdock.Deployments.card_refs/2`).
    field :card_ref_pattern, :string
    # The tag that marks the board's incident cards; nil is "incident". And
    # how many hours after a deploy a fix naming an incident makes that
    # deploy a failed change (`Slipdock.Deployments.Incidents`).
    field :incident_tag, :string
    field :hotfix_window_hours, :integer, default: 24

    # Whether WIP limits hold automated work (#1116, KTD11): with it on, a
    # runner job or a list_top send whose card isn't already in progress
    # waits while the board's first doing list is at its limit. People's
    # drags only ever see the badge.
    field :automation_wip, :boolean, default: false

    # What sort of board this is, when it is more than a board: "sprints"
    # makes every card a sprint and its subcards the sprint's work, and gives
    # the board New sprint and Add cards… (see `Slipdock.Sprints`). nil for an
    # ordinary board. Set by a template that carries a kind, or in settings.
    field :kind, :string
    # Where a sprint board's sprints are planned from: `[%{"board_id",
    # "column_ids"}]`, set through `Slipdock.Sprints.put_sources/3` (which
    # checks them) rather than the settings changeset.
    field :sprint_sources, {:array, :map}, default: []

    # The gardener's per-check switches and thresholds (W-1807): `%{check
    # key => %{"enabled" => bool, …}}`, written through
    # `Slipdock.Gardener.Settings.put/3`. A check not named takes its defaults.
    field :gardening, :map, default: %{}

    # Put away rather than deleted: an archived board drops off the index, the
    # switcher and quick add, but keeps everything on it. Only root boards are
    # archived — a sub-board goes away with the card it hangs off.
    field :archived_at, :utc_datetime

    # When this board had its first meeting capture (see `Slipdock.Meetings`).
    # Kept on the row so the board page can tell whether its Meetings tab is
    # due without asking the captures table: a board that never had one pays
    # nothing for meeting mode existing.
    field :meetings_used_at, :utc_datetime

    # Set when this board lives inside a card (a "sub-board").
    belongs_to :parent_card, Slipdock.Boards.Card
    # The top-level board of the tree; nil on a root board. Tags are shared
    # across the whole tree and stored against the root.
    belongs_to :root, Slipdock.Boards.Board
    belongs_to :template, Slipdock.Boards.Template
    belongs_to :owner, Slipdock.Accounts.User

    # The tree's rollup (see Slipdock.Rollup), set when loaded through Slipdock.Boards.
    field :rollup, :map, virtual: true
    # Where the reader has put this board on their own index, and nil until
    # they have placed it (see Slipdock.Boards.BoardOrder). Set by
    # `Slipdock.Access.list_boards/2`.
    field :position, :integer, virtual: true
    # When anything last happened anywhere in this board's tree, set by
    # `Slipdock.Access.list_boards/2` so the index can sort and show it.
    field :last_activity_at, :utc_datetime, virtual: true
    # Each list's usual stay in seconds, keyed by list id (see
    # `Slipdock.Pulse.usual_stays/1`), set when loaded through Slipdock.Boards.
    field :usual_stays, :map, virtual: true, default: %{}
    # Whether a rule anywhere in its tree sends cards to a runner (see
    # `Slipdock.CardState.runner_tree?/1`): the board's Agent/Human filter is
    # offered only then. Set when loaded through Slipdock.Boards.
    field :runner_tree, :boolean, virtual: true, default: false

    has_many :columns, Slipdock.Boards.Column, preload_order: [asc: :position]
    has_many :cards, Slipdock.Boards.Card
    has_many :tags, Slipdock.Boards.Tag, preload_order: [asc: :name]
    # Like tags, milestones belong to the root board and are put on every
    # board of the tree when it is loaded.
    has_many :milestones, Slipdock.Boards.Milestone, preload_order: [asc: :date]
    # Custom fields, also root-scoped and copied onto every board of the tree.
    has_many :fields, Slipdock.Boards.FieldDefinition, preload_order: [asc: :position]
    has_many :saved_views, Slipdock.Boards.SavedView, preload_order: [asc: :name]
    # The board's wiki: a tree of Markdown pages (see `Slipdock.Wiki`).
    has_many :pages, Slipdock.Wiki.Page, preload_order: [asc: :position, asc: :title]

    timestamps(type: :utc_datetime)
  end

  @doc "The id of the root board of this board's tree."
  def root_id(%__MODULE__{root_id: nil, id: id}), do: id
  def root_id(%__MODULE__{root_id: root_id}), do: root_id

  @doc """
  Who owns the top of this board's tree — a sub-board belongs to whoever owns
  its root, not to nobody. Loaded on demand because a sub-board carries only
  `root_id`.
  """
  def root_owner_id(%__MODULE__{root_id: nil, owner_id: owner_id}), do: owner_id

  def root_owner_id(%__MODULE__{root_id: root_id}) do
    Slipdock.Repo.one(from(b in __MODULE__, where: b.id == ^root_id, select: b.owner_id))
  end

  def sub_board?(%__MODULE__{parent_card_id: id}), do: not is_nil(id)

  @name_length 80

  @doc """
  The name a sub-board takes from its card. Card titles may run to 200
  characters and a board name to #{@name_length}, so a long title is cut short.
  """
  def name_for_card(title) when is_binary(title) do
    if String.length(title) <= @name_length,
      do: title,
      else: String.slice(title, 0, @name_length - 1) |> String.trim_trailing() |> Kernel.<>("…")
  end

  @doc "Whether the board has been put away."
  def archived?(%__MODULE__{archived_at: at}), do: not is_nil(at)

  @code_length 10

  @doc "The longest a board code may be."
  def code_length, do: @code_length

  @doc """
  A code for a board named `name`: lower case, words joined by hyphens and cut
  to #{@code_length} characters — "QVM V1 Remediation" becomes "qvm-v1-rem".

  `taken` says which codes are already in use, either as an enumerable of codes
  or as a function taking a code and returning true when it is taken. When the
  first choice is taken a number is appended (within the length limit), and if
  that runs out a random code is used.
  """
  def code_from_name(name, taken \\ []) do
    taken? = taken_predicate(taken)

    base =
      case cut(sanitize_code(name), @code_length) do
        "" -> "board"
        code -> code
      end

    if taken?.(base) do
      Enum.find_value(2..999, fn n ->
        suffix = Integer.to_string(n)
        candidate = cut(base, @code_length - String.length(suffix)) <> suffix
        if taken?.(candidate), do: nil, else: candidate
      end) || random_code(taken?)
    else
      base
    end
  end

  @doc """
  Turns anything into the shape a code has to take: lower case, runs of other
  characters collapsed to a single hyphen, no hyphen at either end. The result
  is not cut to length, so an over-long code from a form still fails validation
  rather than being silently trimmed.
  """
  def sanitize_code(value) do
    value
    |> to_string()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    # Accents come off their letters in NFD; drop them rather than let them
    # turn into hyphens, so "Núñez" is "nunez".
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp cut(code, length) do
    code |> String.slice(0, max(length, 1)) |> String.trim("-")
  end

  @shortcut_length 2
  # The characters a shortcut may use, in the order they are handed out: the
  # home keys first, then the rest of the letters, then the digits.
  @shortcut_chars ~w(a s d f k j l g h w e r t y u i o p v b c n m x z q
                     1 2 3 4 5 6 7 8 9 0)

  @doc "The longest a board shortcut may be."
  def shortcut_length, do: @shortcut_length

  @doc """
  The key that jumps to a board named `name` from the board switcher.

  The name gets first refusal — the initials of its words, then every other
  letter in it — so "Marketing" is `m` and "Product Launch" is `p` then `l`.
  Once those are taken the remaining characters are handed out in home-key
  order, and after that pairs of them, the way `code_from_name/2` falls back.

  `taken` says which shortcuts are already in use, either as an enumerable or
  as a function taking a shortcut and returning true when it is taken.
  """
  def shortcut_from_name(name, taken \\ []) do
    taken? = taken_predicate(taken)

    letters =
      name
      |> to_string()
      |> String.downcase()
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/\p{Mn}/u, "")

    initials = Regex.scan(~r/(?<![a-z0-9])[a-z0-9]/, letters) |> List.flatten()
    rest = Regex.scan(~r/[a-z0-9]/, letters) |> List.flatten()
    pairs = for a <- @shortcut_chars, b <- @shortcut_chars, do: a <> b

    Enum.find(initials ++ rest ++ @shortcut_chars ++ pairs, &(not taken?.(&1)))
  end

  @doc "Turns anything into the shape a shortcut has to take: lower case, letters and digits."
  def sanitize_shortcut(value) do
    value
    |> to_string()
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^a-z0-9]/u, "")
  end

  defp taken_predicate(fun) when is_function(fun, 1), do: fun

  defp taken_predicate(codes) do
    set = MapSet.new(codes)
    &MapSet.member?(set, &1)
  end

  defp random_code(taken?) do
    Stream.repeatedly(fn ->
      6
      |> :crypto.strong_rand_bytes()
      |> Base.encode32(case: :lower, padding: false)
      |> String.slice(0, @code_length)
    end)
    |> Enum.find(&(not taken?.(&1)))
  end

  @kinds ~w(sprints)

  @doc "The kinds a board may be, besides an ordinary board (nil)."
  def kinds, do: @kinds

  @doc "Whether the board is a sprint board: its cards are sprints."
  def sprints?(%__MODULE__{kind: "sprints"}), do: true
  def sprints?(_), do: false

  @doc "Whether the board is a simple one: a to-do list without the tracking details."
  def simple?(%__MODULE__{simple: true}), do: true
  def simple?(_), do: false

  # The card facets a simple board hides — the ones that only mean something
  # to somebody tracking a project. Keys of `Slipdock.Swimlanes.Config.facets/1`.
  @technical_facets ~w(start_date percent_complete time dependencies)

  @doc "The card facets a simple board hides."
  def technical_facets, do: @technical_facets

  @doc "The card facets hidden on `board`: the technical ones when it is simple, else none."
  def hidden_facets(board), do: if(simple?(board), do: @technical_facets, else: [])

  # The views that are project tooling rather than a way of looking at a list.
  @technical_views [:timeline, :prioritise]

  @doc "The view modes a simple board leaves out of its view menu."
  def hidden_views(board), do: if(simple?(board), do: @technical_views, else: [])

  # What a board can open on: its view modes, and its wiki.
  @default_views ~w(board swimlanes table timeline calendar outline narrative prioritise wiki)

  @doc "The views a board can be set to open on."
  def default_views, do: @default_views

  @doc """
  The view `board` opens on, as a string from `default_views/0`: its
  `default_view`, or "board" when that is unset or is a view the board hides
  (a simple board has no Timeline or Prioritise).
  """
  def home_view(%{default_view: view} = board) when view in @default_views do
    if String.to_existing_atom(view) in hidden_views(board), do: "board", else: view
  end

  def home_view(_board), do: "board"

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Unset and "board" mean the same, so both are stored as nil.
  defp default_view_to_nil("board"), do: nil
  defp default_view_to_nil(value), do: blank_to_nil(value)

  # Deliberately no `:owner_id`: this changeset is fed the board settings
  # form, and an owner who could set it could hand the board (and its quota)
  # to somebody else. The owner is fixed when the board is created (see
  # `Slipdock.Boards.create_board/2`) and moves only on account deletion.
  def changeset(board, attrs) do
    board
    |> cast(attrs, [
      :name,
      :code,
      :shortcut,
      :description,
      :color,
      :vote_budget,
      :vote_max,
      :add_card,
      :add_page,
      :add_document,
      :page_card_features,
      :simple,
      :show_pulse,
      :delivery_metrics,
      :card_ref_pattern,
      :incident_tag,
      :hotfix_window_hours,
      :automation_wip,
      :kind,
      :default_view
    ])
    |> update_change(:kind, &blank_to_nil/1)
    |> update_change(:default_view, &default_view_to_nil/1)
    |> validate_inclusion(:default_view, @default_views,
      message: "must be one of: #{Enum.join(@default_views, ", ")}"
    )
    |> validate_inclusion(:kind, @kinds, message: "must be one of: #{Enum.join(@kinds, ", ")}")
    |> update_change(:code, &sanitize_code/1)
    |> update_change(:shortcut, &sanitize_shortcut/1)
    |> validate_required([:name, :code])
    |> validate_length(:code, max: @code_length)
    |> validate_format(:code, ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/,
      message: "must be letters, digits and hyphens"
    )
    |> unique_constraint(:code, message: "is already used by another board")
    |> validate_length(:shortcut, min: 1, max: @shortcut_length)
    |> validate_format(:shortcut, ~r/^[a-z0-9]+$/, message: "must be letters or digits")
    |> unique_constraint(:shortcut, message: "is already used by another board")
    |> validate_number(:vote_budget, greater_than_or_equal_to: 0, less_than_or_equal_to: 1000)
    |> validate_number(:vote_max, greater_than_or_equal_to: 1, less_than_or_equal_to: 1000)
    |> validate_length(:name, min: 1, max: @name_length)
    |> validate_inclusion(:color, Slipdock.Palette.names())
    |> update_change(:card_ref_pattern, &blank_to_nil/1)
    |> update_change(:incident_tag, &(&1 |> blank_to_nil() |> incident_tag_to_nil()))
    |> validate_length(:incident_tag, max: 50)
    |> validate_number(:hotfix_window_hours,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 24 * 30
    )
    |> validate_change(:card_ref_pattern, &validate_card_ref_pattern/2)
  end

  # A pattern must compile and capture the card id in its first group.
  defp validate_card_ref_pattern(field, pattern) do
    cond do
      String.length(pattern) > 200 ->
        [{field, "must be at most 200 characters"}]

      match?({:error, _}, Regex.compile(pattern)) ->
        [{field, "is not a valid regular expression"}]

      not capturing_group?(pattern) ->
        [{field, "must capture the card id in a group, like #(\\d+)"}]

      true ->
        []
    end
  end

  # The default is stored as nil, so a later change of default reaches it.
  defp incident_tag_to_nil(nil), do: nil

  defp incident_tag_to_nil(tag),
    do: if(String.downcase(String.trim(tag)) == "incident", do: nil, else: String.trim(tag))

  # An unescaped `(` that doesn't start a non-capturing or other `(?…)` group.
  defp capturing_group?(pattern), do: Regex.match?(~r/(?<!\\)\((?!\?)/, pattern)
end
