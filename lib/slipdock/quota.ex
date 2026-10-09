defmodule Slipdock.Quota do
  @moduledoc """
  What one person's own boards may hold: how many boards, how many things on
  them, and how many bytes of uploaded files behind them.

  ## Two layers, one answer

  **The free tier's allowance** (`free_card_limit`) is blank on a self-hosted
  install, which is the default, and then that layer is inert. It exists for
  running Slipdock for other people: a free account gets a limited number of
  things and pays for more. Admins are exempt from it — somebody has to be able
  to fix a server that has filled up — and so is anybody an admin has marked
  **unlimited**: a named person who should never meet the free tier, without
  pretending they paid.

  **The guardrails** (`board_limit`, `item_limit`, `storage_limit_mb`) are on
  everywhere, on every kind of install, paid or not, with defaults of 1,000
  boards / 250,000 items / 10 GB. Each has its own switch, so an operator can
  turn any of them off without losing the number. They are not a billing lever
  but a safety rail — a runaway script or an import gone wrong should hit
  something — so **admins are not exempt from these**. An admin who means to go
  past one raises it, which takes a moment and is a record of the decision.

  Where both layers apply, the lower of the two wins.

  ## The trial

  A third, separate thing: `trial_days` gives a free account a month (or
  whatever the operator says) to add things in, counted from the day it was
  made. It is off by default and stands alongside the counts rather than
  inside them — an account can have no card limit at all and still run out of
  trial, or have both and hit whichever comes first.

  What makes an account **not free** is `users.paid_until` in the future.
  Nothing here charges anybody; an operator sets that date when somebody pays,
  and until then a free account is any account without it. Admins are free
  accounts that nothing expires. So is an account an admin has marked
  `unlimited`, which is the same exemption without a date to fake.

  An expired trial is a wall of the same shape as a full quota: nothing new can
  be added, everything already there stays readable and editable. Locking
  somebody out of their own work to make a point about a subscription is how
  you get a support queue instead of a customer.

  ## Whose things

  **The board owner's.** Not the creator. Per-creator is simpler to explain,
  but it means an invited colleague hits a wall while working on *your* paid
  board, which reads as broken software. Per-owner means the person who would
  be billed is the person who is counted, and sharing a board with somebody
  never hands them a bill.

  Sub-boards belong to their root board's owner, so a tree counts once, against
  whoever owns the top of it.

  ## What counts

  An **item** is a card, a wiki page or an uploaded file. All three are things
  the server stores and has to serve, and a limit that counted only cards would
  be escaped by writing the work up as pages instead.

  Cards and pages count while they are not archived: archiving frees quota,
  which is gameable in principle — but a limit you can only escape by
  permanently deleting work generates support mail, and the point is a nudge
  towards subscribing, not a vault. **Files count until they are deleted**,
  archived or not, because the bytes are still on the disk either way.

  **Storage** is the sum of those files' sizes. **Boards** counts root boards
  only: a sub-board exists because a card has subcards, so counting them would
  turn "1,000 boards" into a limit on subcards, which is not what it says.
  """
  # `limit/2` is ours: a person's limit in a dimension, not a query clause.
  import Ecto.Query, warn: false, except: [limit: 2]

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Attachment, Board, Card, Column}
  alias Slipdock.Repo
  alias Slipdock.Settings
  alias Slipdock.Wiki.Page

  @type dimension :: :items | :boards | :storage
  @type reason ::
          :card_limit_reached | :board_limit_reached | :storage_limit_reached | :trial_expired

  @dimensions [:items, :boards, :storage]

  # Which refusal each dimension answers with. `:items` keeps the name
  # `card_limit_reached` because the JSON API, the CLI and the agent guide all
  # match on that string, and renaming it would break callers for no gain.
  @reasons %{
    items: :card_limit_reached,
    boards: :board_limit_reached,
    storage: :storage_limit_reached,
    trial: :trial_expired
  }

  # The changeset validation key each dimension marks its error with, so a
  # caller can tell a limit from a typo without reading the wording.
  @validations %{
    items: :card_limit,
    boards: :board_limit,
    storage: :storage_limit,
    trial: :trial_expired
  }

  @doc "The dimensions, in the order a report should show them."
  def dimensions, do: @dimensions

  @doc """
  How much of a dimension this person is using. `used/1` is the item count,
  which is what most callers mean.

  One query per dimension, the item count included: it runs on every card,
  page and upload, so the three things an item can be are counted as a union
  rather than as three round trips.
  """
  @spec used(User.t() | integer() | nil) :: non_neg_integer()
  def used(user), do: used(user, :items)

  @spec used(User.t() | integer() | nil, dimension() | :cards | :pages | :files) ::
          non_neg_integer()
  def used(nil, _dimension), do: 0
  def used(%User{id: id}, dimension), do: used(id, dimension)

  def used(user_id, :items) when is_integer(user_id) do
    # One query, not three: this is on the write path for every card, page and
    # upload, so the three parts are a union rather than three round trips.
    cards =
      from(c in Card,
        join: b in subquery(owned_boards(user_id)),
        on: b.id == c.board_id,
        # A stand-in is not one more thing: the card it stands for counts.
        where: is_nil(c.archived_at) and is_nil(c.stand_in_for_id),
        select: %{id: c.id}
      )

    pages =
      from(p in Page,
        join: b in subquery(owned_boards(user_id)),
        on: b.id == p.board_id,
        where: is_nil(p.archived_at),
        select: %{id: p.id}
      )

    files = from(a in owned_attachments(user_id), select: %{id: a.id})

    Repo.aggregate(subquery(union_all(union_all(cards, ^pages), ^files)), :count)
  end

  def used(user_id, :cards) when is_integer(user_id) do
    Repo.aggregate(
      from(c in Card,
        join: b in subquery(owned_boards(user_id)),
        on: b.id == c.board_id,
        where: is_nil(c.archived_at) and is_nil(c.stand_in_for_id)
      ),
      :count
    )
  end

  def used(user_id, :pages) when is_integer(user_id) do
    Repo.aggregate(
      from(p in Page,
        join: b in subquery(owned_boards(user_id)),
        on: b.id == p.board_id,
        where: is_nil(p.archived_at)
      ),
      :count
    )
  end

  def used(user_id, :files) when is_integer(user_id) do
    Repo.aggregate(owned_attachments(user_id), :count)
  end

  def used(user_id, :storage) when is_integer(user_id) do
    (Repo.aggregate(owned_attachments(user_id), :sum, :size) || 0) +
      (Repo.one(from(c in owned_audio(user_id), select: type(sum(c.audio_size), :integer))) || 0)
  end

  def used(user_id, :boards) when is_integer(user_id) do
    Repo.aggregate(
      from(b in Board,
        where: b.owner_id == ^user_id and is_nil(b.root_id) and is_nil(b.archived_at)
      ),
      :count
    )
  end

  @doc """
  What this person's item count is made of. Useful when telling somebody why
  they are full, and the only honest way to report "cards" now that the number
  is not only cards.
  """
  @spec breakdown(User.t() | integer() | nil) :: %{
          cards: non_neg_integer(),
          pages: non_neg_integer(),
          files: non_neg_integer()
        }
  def breakdown(user) do
    %{cards: used(user, :cards), pages: used(user, :pages), files: used(user, :files)}
  end

  @doc """
  This person's limit in a dimension, or nil for no limit.

  For items that is the lower of their free-tier allowance (their own override
  if an admin set one, else the instance's `free_card_limit`, and neither for
  an admin) and the instance's item guardrail. For boards and storage it is the
  guardrail alone, which applies to everybody.
  """
  @spec limit(User.t() | nil) :: pos_integer() | nil
  def limit(user), do: limit(user, :items)

  @spec limit(User.t() | nil, dimension()) :: pos_integer() | nil
  def limit(nil, _dimension), do: nil

  def limit(%User{} = user, :items) do
    [free_tier_limit(user), Settings.item_limit()]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  def limit(%User{}, :boards), do: Settings.board_limit()
  def limit(%User{}, :storage), do: Settings.storage_limit_bytes()

  defp free_tier_limit(%User{} = user) do
    cond do
      not free?(user) -> nil
      is_integer(user.card_limit_override) -> user.card_limit_override
      true -> Settings.free_card_limit()
    end
  end

  @doc """
  Whether this is a free account: no payment recorded, not an admin, and not
  marked unlimited. Only
  free accounts have the free tier's allowance or a trial; the guardrails apply
  to everybody.
  """
  @spec free?(User.t() | nil) :: boolean()
  def free?(nil), do: false
  def free?(%User{admin: true}), do: false
  def free?(%User{unlimited: true}), do: false

  def free?(%User{paid_until: nil}), do: true

  def free?(%User{paid_until: paid_until}),
    do: DateTime.compare(paid_until, DateTime.utc_now()) != :gt

  @doc """
  Where this person stands on their free trial.

  `applies?` is false when the trial is switched off or the account is not a
  free one, and then nothing else here matters. `ends_at` is `trial_days` after
  the account was made.
  """
  @spec trial(User.t() | nil) :: %{
          applies?: boolean(),
          days: pos_integer() | nil,
          started_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          days_left: integer() | nil,
          expired?: boolean()
        }
  def trial(nil), do: no_trial(Settings.trial_days())

  def trial(%User{} = user) do
    days = Settings.trial_days()

    if is_nil(days) or not free?(user) or is_nil(user.inserted_at) do
      no_trial(days)
    else
      started_at = user.inserted_at
      ends_at = DateTime.add(started_at, days * 24 * 60 * 60, :second)
      seconds_left = DateTime.diff(ends_at, DateTime.utc_now())

      %{
        applies?: true,
        days: days,
        started_at: started_at,
        ends_at: ends_at,
        # Rounded up, so the last part-day still reads as "1 day left" rather
        # than as nothing left while things can still be added.
        days_left: max(ceil(seconds_left / (24 * 60 * 60)), 0),
        expired?: seconds_left <= 0
      }
    end
  end

  defp no_trial(days) do
    %{applies?: false, days: days, started_at: nil, ends_at: nil, days_left: nil, expired?: false}
  end

  @doc "Whether this person's free trial has run out."
  @spec trial_expired?(User.t() | nil) :: boolean()
  def trial_expired?(user), do: trial(user).expired?

  @doc """
  Whether somebody is close enough to the end of their trial to be told. A
  week, or a fifth of a short trial, whichever is less.
  """
  @spec trial_warning?(User.t() | nil) :: boolean()
  def trial_warning?(user) do
    case trial(user) do
      %{applies?: false} -> false
      %{expired?: true} -> true
      %{days: days, days_left: left} -> left <= min(7, max(div(days, 5), 1))
    end
  end

  @doc "Whether this person may make another item."
  @spec allows?(User.t() | nil) :: boolean()
  def allows?(user), do: check(user) == :ok

  @doc """
  `:ok`, or `{:error, reason}` with no further explanation — the caller phrases
  it, because the board, the CLI, the API and an automation rule each need to
  say it differently.

  `want` is how much more is being asked for: one item, one board, or the size
  in bytes of the file about to be stored. Zero is a real answer — importing a
  board with nothing on it asks for no items — and still runs the trial check,
  because an expired account may not add even an empty thing.
  """
  @spec check(User.t() | nil) :: :ok | {:error, reason()}
  def check(user), do: check(user, :items)

  @spec check(User.t() | nil, dimension(), non_neg_integer()) :: :ok | {:error, reason()}
  def check(user, dimension, want \\ 1) do
    # The trial first: when it has run out, which limit had room is beside the
    # point, and saying "you have 998 boards left" would be a lie about what is
    # going to happen next.
    if trial_expired?(user) do
      {:error, @reasons[:trial]}
    else
      case limit(user, dimension) do
        nil ->
          :ok

        limit ->
          if used(user, dimension) + want <= limit,
            do: :ok,
            else: {:error, @reasons[dimension]}
      end
    end
  end

  @doc """
  The same question for a board rather than a person: whoever owns the root of
  this tree is the one being counted. This is the form the card-creation path
  wants, since a card knows its column and its column knows its board.
  """
  @spec check_board(Board.t() | Column.t() | integer() | nil, dimension(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def check_board(scope, dimension \\ :items, want \\ 1)
  def check_board(nil, _dimension, _want), do: :ok

  def check_board(%Column{board_id: board_id}, dimension, want),
    do: check_board(board_id, dimension, want)

  def check_board(%Board{} = board, dimension, want),
    do: check_board(Board.root_id(board), dimension, want)

  def check_board(board_id, dimension, want) when is_integer(board_id) do
    # Nothing to count against on an unowned board — and nothing to fear from
    # one either, since `Slipdock.Access` lets nobody at all into it.
    case owner_of(board_id) do
      nil -> :ok
      owner -> check(owner, dimension, want)
    end
  end

  @doc "Where somebody stands in one dimension: used, their limit, and what is left."
  @spec status(User.t() | nil, dimension()) :: %{
          used: non_neg_integer(),
          limit: pos_integer() | nil,
          remaining: non_neg_integer() | nil,
          limited?: boolean()
        }
  def status(user, dimension \\ :items), do: status_of(user, dimension, used(user, dimension))

  defp status_of(user, dimension, used) do
    case limit(user, dimension) do
      nil -> %{used: used, limit: nil, remaining: nil, limited?: false}
      limit -> %{used: used, limit: limit, remaining: max(limit - used, 0), limited?: true}
    end
  end

  @doc """
  Every dimension at once, with the item count broken down. What the account
  page, `GET /api/me` and the agent guide all show.
  """
  @spec report(User.t() | nil) :: %{
          items: map(),
          boards: map(),
          storage: map(),
          breakdown: map()
        }
  def report(user) do
    @dimensions
    |> Map.new(&{&1, status(user, &1)})
    |> Map.put(:breakdown, breakdown(user))
    |> Map.put(:trial, trial(user))
    |> Map.put(:free, free?(user))
  end

  @doc """
  `report/1` from counts already gathered by `usage/1`, for a list of people
  that would otherwise cost a handful of queries each.
  """
  @spec report(User.t(), map()) :: map()
  def report(%User{} = user, usage) do
    @dimensions
    |> Map.new(&{&1, status_of(user, &1, usage[&1])})
    |> Map.put(:breakdown, Map.take(usage, [:cards, :pages, :files]))
    |> Map.put(:trial, trial(user))
    |> Map.put(:free, free?(user))
  end

  @doc """
  What each of these people uses, in a fixed number of queries however many
  there are: `%{user_id => %{items, cards, pages, files, boards, storage}}`,
  counted exactly as `used/2` counts them. Everyone asked about is in the map.
  """
  @spec usage([integer()]) :: %{integer() => map()}
  def usage(user_ids) do
    cards =
      from(c in Card,
        join: b in subquery(owners_of_boards(user_ids)),
        on: b.id == c.board_id,
        where: is_nil(c.archived_at),
        group_by: b.owner_id,
        select: {b.owner_id, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    pages =
      from(p in Page,
        join: b in subquery(owners_of_boards(user_ids)),
        on: b.id == p.board_id,
        where: is_nil(p.archived_at),
        group_by: b.owner_id,
        select: {b.owner_id, count(p.id)}
      )
      |> Repo.all()
      |> Map.new()

    files =
      from(a in Attachment,
        left_join: c in Card,
        on: c.id == a.card_id,
        left_join: p in Page,
        on: p.id == a.page_id,
        join: b in subquery(owners_of_boards(user_ids)),
        on: b.id == coalesce(c.board_id, p.board_id),
        group_by: b.owner_id,
        select: {b.owner_id, {count(a.id), type(sum(a.size), :integer)}}
      )
      |> Repo.all()
      |> Map.new()

    # Meeting recordings are bytes on the disk too (see `Slipdock.Meetings`).
    audio =
      from(c in Slipdock.Meetings.Capture,
        join: b in subquery(owners_of_boards(user_ids)),
        on: b.id == c.board_id,
        where: not is_nil(c.audio_key),
        group_by: b.owner_id,
        select: {b.owner_id, type(sum(c.audio_size), :integer)}
      )
      |> Repo.all()
      |> Map.new()

    boards =
      from(b in Board,
        where: b.owner_id in ^user_ids and is_nil(b.root_id) and is_nil(b.archived_at),
        group_by: b.owner_id,
        select: {b.owner_id, count(b.id)}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(user_ids, fn id ->
      {file_count, bytes} = Map.get(files, id, {0, 0})
      card_count = Map.get(cards, id, 0)
      page_count = Map.get(pages, id, 0)

      {id,
       %{
         items: card_count + page_count + file_count,
         cards: card_count,
         pages: page_count,
         files: file_count,
         boards: Map.get(boards, id, 0),
         storage: (bytes || 0) + (Map.get(audio, id) || 0)
       }}
    end)
  end

  @doc """
  Whether somebody is close enough to a limit to be warned. Being told at the
  wall is being told too late.
  """
  @spec warning?(User.t() | nil, dimension()) :: boolean()
  def warning?(user, dimension \\ :items) do
    case status(user, dimension) do
      %{limited?: false} -> false
      %{limit: limit, remaining: remaining} -> remaining <= max(div(limit, 5), 1)
    end
  end

  @doc "Which dimensions are close enough to warn about, if any."
  @spec warnings(User.t() | nil) :: [dimension()]
  def warnings(user), do: Enum.filter(@dimensions, &warning?(user, &1))

  @doc "A sentence for somebody who has hit, or is near, a limit."
  def message(user, dimension \\ :items)

  def message(user, :trial) do
    case trial(user) do
      %{applies?: false} -> nil
      %{expired?: true, days: days} -> trial_over_message(days)
      %{days_left: 1} -> "1 day left of your free trial."
      %{days_left: left} -> "#{left} days left of your free trial."
    end
  end

  def message(user, dimension) do
    case status(user, dimension) do
      %{limited?: false} ->
        nil

      %{limit: limit, remaining: 0} ->
        full_message(dimension, limit)

      %{limit: limit, remaining: remaining} ->
        "#{noun(dimension, remaining)} left of #{amount(dimension, limit)}."
    end
  end

  defp full_message(:boards, limit),
    do:
      "You own all #{limit} boards this server allows one person. Archive a board " <>
        "you have finished with, or ask an admin to raise the limit."

  defp full_message(:storage, limit),
    do:
      "The boards you own hold all #{amount(:storage, limit)} of files this server " <>
        "allows one person. Delete some attachments, or ask an admin to raise the limit."

  defp full_message(:items, limit),
    do:
      "You have used all #{limit} cards, pages and files on the boards you own. " <>
        "Archive something you have finished with, or subscribe for more."

  defp trial_over_message(days),
    do:
      "Your #{days}-day free trial has ended. Everything you have made is still " <>
        "here and still editable; subscribe to go on adding to it."

  @doc """
  Adds a limit to a changeset, so every creation path refuses the same way
  whatever it is.

  The error is a **changeset** rather than a bare `{:error, :card_limit}`
  because a dozen callers already handle `{:error, %Ecto.Changeset{}}` and
  would have treated an atom as one. It is still machine-readable:
  `limit_reached?/1` matches on the validation key rather than on the wording,
  so the API, the CLI and the UI can each say it their own way.
  """
  @spec enforce(
          Ecto.Changeset.t(),
          Column.t() | Board.t() | integer() | nil,
          dimension(),
          keyword()
        ) ::
          Ecto.Changeset.t()
  def enforce(changeset, scope, dimension \\ :items, opts \\ []) do
    want = opts[:want] || 1

    case check_board(scope, dimension, want) do
      :ok ->
        changeset

      {:error, reason} ->
        # The reason, not the dimension asked about: a trial that has run out
        # refuses a card creation, and saying "you have used all your cards"
        # would send the person to archive things that would not help.
        refused = dimension_for(reason)

        Ecto.Changeset.add_error(
          changeset,
          :base,
          limit_message(scope, refused),
          validation: @validations[refused]
        )
    end
  end

  @doc """
  `check_board/3` for a path that has no changeset of its own — a restore that
  is an `update_all`, a move that carries a whole subtree. `:ok`, or
  `{:error, changeset}` refusing the same way `enforce/4` does, so the API
  answers it with the same 402 and a caller can show `refusal_message/1`.

  `wants` is a keyword of dimension to amount, checked in order; dimensions
  asking for nothing are skipped, unless every one is, when the trial still
  is.
  """
  @spec refusal(Column.t() | Board.t() | integer() | nil, keyword(non_neg_integer())) ::
          :ok | {:error, Ecto.Changeset.t()}
  def refusal(scope, wants) do
    wants =
      case Enum.reject(wants, fn {_dimension, want} -> want == 0 end) do
        [] -> [items: 0]
        wants -> wants
      end

    changeset =
      Enum.reduce_while(wants, Ecto.Changeset.change({%{}, %{}}), fn {dimension, want}, cs ->
        cs = enforce(cs, scope, dimension, want: want)
        if cs.valid?, do: {:cont, cs}, else: {:halt, cs}
      end)

    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  @doc "The sentence a limit refusal carries, for a caller that shows it."
  @spec refusal_message(Ecto.Changeset.t()) :: String.t() | nil
  def refusal_message(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :base) do
      {message, _opts} -> message
      nil -> nil
    end
  end

  @doc """
  The board guardrail, for a changeset that has an owner rather than a board —
  which is every board being created, since it has no board above it yet.
  """
  @spec enforce_owner(Ecto.Changeset.t(), User.t() | integer() | nil, dimension()) ::
          Ecto.Changeset.t()
  def enforce_owner(changeset, owner, dimension \\ :boards)
  def enforce_owner(changeset, nil, _dimension), do: changeset

  def enforce_owner(changeset, owner_id, dimension) when is_integer(owner_id) do
    case Repo.get(User, owner_id) do
      nil -> changeset
      user -> enforce_owner(changeset, user, dimension)
    end
  end

  def enforce_owner(changeset, %User{} = user, dimension) do
    case check(user, dimension) do
      :ok ->
        changeset

      {:error, reason} ->
        refused = dimension_for(reason)

        Ecto.Changeset.add_error(changeset, :base, message(user, refused),
          validation: @validations[refused]
        )
    end
  end

  # Which limit a refusal came from.
  defp dimension_for(reason) do
    Enum.find_value(@reasons, fn {dimension, named} -> if named == reason, do: dimension end)
  end

  @doc "Whether this changeset failed because of a limit, rather than wording."
  @spec limit_reached?(Ecto.Changeset.t() | term()) :: boolean()
  def limit_reached?(changeset), do: limit_kind(changeset) != nil

  @doc """
  Which limit a changeset failed on — `:items`, `:boards`, `:storage`, or nil.
  The API turns it into an error code the caller can match on.
  """
  @spec limit_kind(Ecto.Changeset.t() | term()) :: dimension() | nil
  def limit_kind(%Ecto.Changeset{errors: errors}) do
    kinds = Map.new(@validations, fn {dimension, validation} -> {validation, dimension} end)

    Enum.find_value(errors, fn
      {_field, {_message, opts}} -> kinds[opts[:validation]]
      _ -> nil
    end)
  end

  def limit_kind(_), do: nil

  @doc """
  The refusal a dimension answers with: `:card_limit_reached`,
  `:board_limit_reached`, `:storage_limit_reached` or `:trial_expired`.
  """
  @spec limit_name(dimension() | :trial) :: reason()
  def limit_name(dimension), do: @reasons[dimension]

  @doc "The error code the JSON API answers a limit refusal with."
  @spec error_code(dimension()) :: String.t()
  def error_code(dimension), do: Atom.to_string(@reasons[dimension])

  @doc "A short name for a limit, for a sentence that has to say which one."
  @spec label(dimension() | :trial) :: String.t()
  def label(:items), do: "cards, pages and files"
  def label(:boards), do: "boards"
  def label(:storage), do: "file storage"
  def label(:trial), do: "free trial"

  @doc """
  Bytes as a person would write them. Used in every limit message, so a 10 GB
  limit never appears as 10737418240.
  """
  @spec humanise_bytes(number()) :: String.t()
  def humanise_bytes(bytes) when bytes >= 1024 * 1024 * 1024,
    do: "#{trim_float(bytes / (1024 * 1024 * 1024))} GB"

  def humanise_bytes(bytes) when bytes >= 1024 * 1024,
    do: "#{trim_float(bytes / (1024 * 1024))} MB"

  def humanise_bytes(bytes) when bytes >= 1024, do: "#{trim_float(bytes / 1024)} KB"
  def humanise_bytes(bytes), do: "#{round(bytes)} bytes"

  defp trim_float(value) do
    rounded = Float.round(value, 1)
    if rounded == Float.round(rounded, 0), do: round(rounded), else: rounded
  end

  defp amount(:storage, n), do: humanise_bytes(n)
  defp amount(_dimension, n), do: Integer.to_string(n)

  defp noun(:storage, n), do: humanise_bytes(n)
  defp noun(:boards, 1), do: "1 board"
  defp noun(:boards, n), do: "#{n} boards"
  defp noun(:items, 1), do: "1 item"
  defp noun(:items, n), do: "#{n} items"

  defp limit_message(scope, :trial) do
    case trial(owner_for(scope)) do
      %{applies?: false} ->
        "This board's owner cannot add anything more."

      %{days: days} ->
        "This board's owner's #{days}-day free trial has ended. Everything here " <>
          "is still readable and editable; they can subscribe to go on adding."
    end
  end

  defp limit_message(scope, dimension) do
    owner = owner_for(scope)

    case limit(owner, dimension) do
      nil ->
        "This board has reached its limit."

      limit ->
        owner_message(dimension, limit)
    end
  end

  defp owner_message(:items, limit),
    do:
      "This board's owner has used all #{limit} of their cards, pages and files. " <>
        "They can archive something finished with, or subscribe for more."

  defp owner_message(:storage, limit),
    do:
      "This board's owner has used all #{humanise_bytes(limit)} of their file storage. " <>
        "They can delete some attachments, or ask an admin to raise the limit."

  defp owner_message(:boards, limit),
    do: "This board's owner already owns all #{limit} boards they are allowed."

  defp owner_for(%Column{board_id: board_id}), do: owner_of(board_id)
  defp owner_for(%Board{} = board), do: owner_of(Board.root_id(board))
  defp owner_for(board_id) when is_integer(board_id), do: owner_of(board_id)
  defp owner_for(_), do: nil

  @doc "The id of whoever owns the root of this board's tree, or nil."
  @spec owner_id_of(integer()) :: integer() | nil
  def owner_id_of(board_id) do
    Repo.one(
      from(b in Board,
        join: root in Board,
        on: root.id == coalesce(b.root_id, b.id),
        where: b.id == ^board_id,
        select: root.owner_id
      )
    )
  end

  defp owner_of(board_id) do
    Repo.one(
      from(b in Board,
        join: root in Board,
        on: root.id == coalesce(b.root_id, b.id),
        join: u in User,
        on: u.id == root.owner_id,
        where: b.id == ^board_id,
        select: u
      )
    )
  end

  # Every board in every tree this person owns the top of.
  defp owned_boards(user_id) do
    from(b in Board,
      join: root in Board,
      on: root.id == coalesce(b.root_id, b.id),
      where: root.owner_id == ^user_id,
      select: %{id: b.id}
    )
  end

  # owned_boards/1 for several owners at once, each board tagged with its owner.
  defp owners_of_boards(user_ids) do
    from(b in Board,
      join: root in Board,
      on: root.id == coalesce(b.root_id, b.id),
      where: root.owner_id in ^user_ids,
      select: %{id: b.id, owner_id: root.owner_id}
    )
  end

  # Every uploaded file hanging off a card or a page on one of those boards.
  # Archived or not: the bytes are on the disk either way.
  defp owned_attachments(user_id) do
    from(a in Attachment,
      left_join: c in Card,
      on: c.id == a.card_id,
      left_join: p in Page,
      on: p.id == a.page_id,
      join: b in subquery(owned_boards(user_id)),
      on: b.id == coalesce(c.board_id, p.board_id)
    )
  end

  # Every meeting recording still on the disk on one of those boards.
  defp owned_audio(user_id) do
    from(c in Slipdock.Meetings.Capture,
      join: b in subquery(owned_boards(user_id)),
      on: b.id == c.board_id,
      where: not is_nil(c.audio_key)
    )
  end
end
