defmodule Slipdock.Profiles do
  @moduledoc """
  A card's profile (#1951): one word saying what kind of change it is, so
  that the change, not its author, can say how much checking it gets.

  There are six, fixed here rather than in a board setting: `docs`, `fix`,
  `feature`, `schema`, `security` and `spike`. A board turns them on with
  `Board.profiles` (off by default). With it on, a card an agent claims or
  starts with no profile gets one inferred from its paths, tags and (when
  one is known) diff size, stored on the card (`Card.profile`); anyone can
  set or clear it at every door.

  **Nothing acts on the profile yet.** It is shown, not read: the human tier
  (#1952) and the verifier's spend (#1953) are the cards that will.

  ## Inference

  Strict first: the first rule that matches wins, so a card that touches a
  migration and a docs file is `schema`.

    1. `security`: tagged `security`, or any path in an auth, access, token,
       OAuth or egress module (`security_path?/1`).
    2. `schema`: any path a migration or schema file (`schema_path?/1`).
    3. `spike`: tagged `spike` (only ever by tag).
    4. `fix`: tagged `bug`.
    5. `docs`: it has paths, and every one is under `docs/`, `README.md` or
       a `.md` file.
    6. `feature`: anything else, a card with no paths included.

  A `fix` or `docs` card whose diff changes more than `size_limit/0` lines
  is a `feature`: a big change is not a small one whatever it is tagged.
  """

  @names ~w(docs fix feature schema security spike)

  # Words that make a path a security one: a segment of it (split on `/`,
  # `.`, `_` and `-`) that is one of these, as in `lib/slipdock/access.ex`,
  # `lib/slipdock_web/user_auth.ex` or `lib/slipdock/accounts/user_token.ex`.
  @security_words ~w(access auth oauth token tokens egress)

  # A diff over this many changed lines (added plus removed) bumps a `fix`
  # or `docs` card to `feature`.
  @size_limit 400

  @doc "The profiles, strictest first."
  def names, do: ~w(security schema feature fix docs spike)

  @doc "Whether `name` is one of the profiles."
  def name?(name), do: Enum.member?(@names, name)

  @doc "The number of changed lines over which a `fix` or `docs` card is a `feature`."
  def size_limit, do: @size_limit

  @doc "The message an unknown profile is refused with."
  def unknown_message,
    do: "must be one of #{Enum.join(names(), ", ")}, or blank for none"

  @doc """
  The profile for a card with `paths` and `tags` (names, any case).
  `opts`: `:diff_lines`, the changed lines of its diff when one is known.
  """
  def infer(paths, tags, opts \\ []) do
    paths = Enum.reject(paths || [], &(is_nil(&1) or &1 == ""))
    tags = Enum.map(tags || [], &(&1 |> to_string() |> String.downcase()))

    paths
    |> by_rules(tags)
    |> bump(opts[:diff_lines])
  end

  @doc "The profile for `card`, from its paths and its (loaded) tags."
  def infer_card(%{paths: paths, tags: tags}, opts \\ []) do
    infer(paths, tag_names(tags), opts)
  end

  defp tag_names(%Ecto.Association.NotLoaded{}), do: []
  defp tag_names(tags), do: Enum.map(tags || [], & &1.name)

  defp by_rules(paths, tags) do
    cond do
      Enum.member?(tags, "security") or Enum.any?(paths, &security_path?/1) -> "security"
      Enum.any?(paths, &schema_path?/1) -> "schema"
      Enum.member?(tags, "spike") -> "spike"
      Enum.member?(tags, "bug") -> "fix"
      paths != [] and Enum.all?(paths, &docs_path?/1) -> "docs"
      true -> "feature"
    end
  end

  defp bump(profile, lines) when profile in ["fix", "docs"] and is_integer(lines) do
    if lines > @size_limit, do: "feature", else: profile
  end

  defp bump(profile, _lines), do: profile

  @doc "Whether `path` (a path or glob) is in an auth, access, token, OAuth or egress module."
  def security_path?(path) do
    path
    |> String.downcase()
    |> String.split(["/", ".", "_", "-"], trim: true)
    |> Enum.any?(&Enum.member?(@security_words, &1))
  end

  @doc "Whether `path` is a migration or a schema file."
  def schema_path?(path) do
    path = String.downcase(path)

    String.contains?(path, "migrations/") or
      String.ends_with?(path, ["structure.sql", "schema.ex", "schema.rb", "schema.prisma"]) or
      Path.basename(path) == "schema.sql"
  end

  @doc "Whether `path` is documentation: under `docs/`, `README.md` or any `.md` file."
  def docs_path?(path) do
    String.starts_with?(path, "docs/") or Path.basename(path) == "README.md" or
      String.ends_with?(String.downcase(path), ".md")
  end
end
