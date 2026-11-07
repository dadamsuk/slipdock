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

  ## The human tier (#1952)

  Each profile has a human tier, saying what an agent's acceptance does on
  a board that ships by pull request (`tier/1`):

    * `none` (`docs`, `fix`): acceptance merges, as without profiles;
    * `ledger` (`feature`): acceptance merges, and the card's line on the
      ledger (`Slipdock.Ledger`) is the person's look at it; it behaves as
      `none`, and exists so a board can raise it;
    * `before_merge` (`schema`, `security`, `spike`): acceptance opens a
      wait routed `release` (Merge / Send back) instead of queueing the
      merge, and the card is `held` until a person answers
      (`Slipdock.Verified`).

  A board's root holds any changes to the defaults (`Board.profile_tiers`,
  only the ones that differ); with profiles off on the card's board every
  tier is `none`. The verifier's spend (#1953) is still to come.

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

  @tiers ~w(none ledger before_merge)

  # The strict defaults (#1952).
  @default_tiers %{
    "docs" => "none",
    "fix" => "none",
    "feature" => "ledger",
    "schema" => "before_merge",
    "security" => "before_merge",
    "spike" => "before_merge"
  }

  @doc "The profiles, strictest first."
  def names, do: ~w(security schema feature fix docs spike)

  @doc "Whether `name` is one of the profiles."
  def name?(name), do: Enum.member?(@names, name)

  @doc "The number of changed lines over which a `fix` or `docs` card is a `feature`."
  def size_limit, do: @size_limit

  @doc "The human tiers, least checking first."
  def tiers, do: @tiers

  @doc "Each profile's default human tier: the strict ones."
  def default_tiers, do: @default_tiers

  @doc """
  Each profile's tier on a board whose root has `overrides`
  (`Board.profile_tiers`): the defaults with the overrides on top.
  """
  def tiers_with(overrides) when is_map(overrides), do: Map.merge(@default_tiers, overrides)
  def tiers_with(_overrides), do: @default_tiers

  @doc """
  The changes a board keeps: only the profiles whose tier differs from the
  default. Unknown keys are kept, for the changeset to refuse.
  """
  def overrides(tiers) when is_map(tiers) do
    for {profile, tier} <- tiers,
        profile = to_string(profile),
        tier = tier |> to_string() |> String.trim(),
        not Enum.member?(["", "default"], tier),
        Map.get(@default_tiers, profile) != tier,
        into: %{},
        do: {profile, tier}
  end

  def overrides(tiers), do: tiers

  @doc """
  `changes` (profile => tier, `"default"` or blank putting a profile back to
  its default) applied to a board's `current` overrides: `{:ok, overrides}`
  or `{:error, message}`, naming what is wrong.
  """
  def merge_tiers(current, changes) when is_map(changes) do
    current = current || %{}

    Enum.reduce_while(changes, {:ok, current}, fn {profile, tier}, {:ok, acc} ->
      profile = to_string(profile)
      tier = if is_nil(tier), do: "", else: tier |> to_string() |> String.trim()

      cond do
        not name?(profile) ->
          {:halt, {:error, "profile_tiers: #{inspect(profile)} #{unknown_message()}"}}

        Enum.member?(["", "default"], tier) ->
          {:cont, {:ok, Map.delete(acc, profile)}}

        Enum.member?(@tiers, tier) ->
          {:cont, {:ok, Map.put(acc, profile, tier)}}

        true ->
          {:halt, {:error, "profile_tiers: #{profile}'s tier #{tier_message()}"}}
      end
    end)
    |> case do
      {:ok, map} -> {:ok, overrides(map)}
      error -> error
    end
  end

  def merge_tiers(_current, _changes),
    do: {:error, "profile_tiers is an object of profile => tier (#{Enum.join(@tiers, ", ")})"}

  @doc "The message an unknown tier is refused with."
  def tier_message,
    do: "must be one of #{Enum.join(@tiers, ", ")}, or default"

  @doc "An error for each wrong entry of a board's `profile_tiers`, as `[{field, message}]`."
  def tier_errors(tiers) when is_map(tiers) do
    Enum.flat_map(tiers, fn {profile, tier} ->
      cond do
        not name?(profile) -> [profile_tiers: "#{inspect(profile)} #{unknown_message()}"]
        not Enum.member?(@tiers, tier) -> [profile_tiers: "#{profile}'s tier #{tier_message()}"]
        true -> []
      end
    end)
  end

  def tier_errors(_tiers), do: [profile_tiers: "must be an object of profile => tier"]

  @doc """
  What a board's tiers say loudly (#1952): `security` set to `none`, so an
  agent's acceptance merges a security change with no person looking.
  """
  def tier_warnings(overrides) do
    if tiers_with(overrides)["security"] == "none",
      do: [
        "security is set to none: an agent's acceptance merges a security change " <>
          "with no person looking at it first"
      ],
      else: []
  end

  @doc """
  A card's human tier (#1952): `none` when its board has profiles off,
  else its profile's tier on its tree (the root board's `profile_tiers`
  over the defaults). A card with no profile is judged by the one its paths
  and tags infer, so an unprofiled schema change still waits. `card` needs
  its board; its tags are loaded if they aren't.
  """
  def tier(%{board: %{profiles: true} = board} = card) do
    tiers_with(root_overrides(board))[profile_of(card)] || "none"
  end

  def tier(%{board: %Ecto.Association.NotLoaded{}} = card),
    do: card |> Slipdock.Repo.preload(:board) |> tier()

  def tier(_card), do: "none"

  @doc "The card's profile, or the one its paths and tags infer when it has none."
  def profile_of(%{profile: profile}) when is_binary(profile), do: profile

  def profile_of(card), do: card |> Slipdock.Repo.preload(:tags) |> infer_card()

  @doc """
  Each profile's tier on `board`'s tree (#1952), the root's changes over the
  defaults; the doors show this, and `tier_warnings/1` reads it.
  """
  def board_tiers(board), do: tiers_with(root_overrides(board))

  @doc """
  A board write's `profile_tiers` (`params`, string keys) applied to the
  root's (`board`'s tree's) current ones, for `Boards.update_board/2`: the
  params with the merged map, or `{:error, message}`. Params without it
  pass through. Only a root board keeps tiers: a sub-board's write is
  refused, naming the root.
  """
  def put_tiers(board, %{"profile_tiers" => changes} = params) do
    if board.root_id do
      {:error,
       "profile_tiers are kept on the tree's root board (##{board.root_id}): set them there"}
    else
      with {:ok, merged} <- merge_tiers(board.profile_tiers, changes),
           do: {:ok, Map.put(params, "profile_tiers", merged)}
    end
  end

  def put_tiers(_board, params), do: {:ok, params}

  defp root_overrides(%{root_id: nil, profile_tiers: tiers}), do: tiers

  defp root_overrides(%{root_id: root_id}) do
    case Slipdock.Repo.get(Slipdock.Boards.Board, root_id) do
      nil -> %{}
      root -> root.profile_tiers
    end
  end

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

  @doc """
  What `infer_card/1` would give `card` now, and why, for a person to see
  before an agent starts it (#2018): `{profile, reason}`, the reason one
  short phrase ("from priv/repo/migrations/…", "from the bug tag").
  """
  def explain_card(%{paths: paths, tags: tags}) do
    paths = Enum.reject(paths || [], &(is_nil(&1) or &1 == ""))
    tags = Enum.map(tag_names(tags), &String.downcase/1)
    profile = by_rules(paths, tags)
    {profile, reason(profile, paths, tags)}
  end

  defp reason("security", paths, tags) do
    if Enum.member?(tags, "security"),
      do: "from the security tag",
      else: "from " <> Enum.find(paths, &security_path?/1)
  end

  defp reason("schema", paths, _tags), do: "from " <> Enum.find(paths, &schema_path?/1)
  defp reason("spike", _paths, _tags), do: "from the spike tag"
  defp reason("fix", _paths, _tags), do: "from the bug tag"
  defp reason("docs", _paths, _tags), do: "from its paths, all docs"
  defp reason(_feature, [], _tags), do: "the default: it has no paths yet"
  defp reason(_feature, _paths, _tags), do: "the default for its paths"

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
