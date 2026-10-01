defmodule Slipdock.Boards.Board do
  use Ecto.Schema
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

    # Put away rather than deleted: an archived board drops off the index, the
    # switcher and quick add, but keeps everything on it. Only root boards are
    # archived — a sub-board goes away with the card it hangs off.
    field :archived_at, :utc_datetime

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

  def sub_board?(%__MODULE__{parent_card_id: id}), do: not is_nil(id)

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

  def changeset(board, attrs) do
    board
    |> cast(attrs, [
      :name,
      :code,
      :shortcut,
      :description,
      :color,
      :owner_id,
      :vote_budget,
      :vote_max,
      :add_card,
      :add_page,
      :add_document
    ])
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
    |> validate_length(:name, min: 1, max: 80)
    |> validate_inclusion(:color, Slipdock.Palette.names())
  end
end
