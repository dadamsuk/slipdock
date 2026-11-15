defmodule Slipdock.Policy do
  @moduledoc """
  Where a write asks who is writing (#3162, #3167; W-1945 §Permissions,
  *Where authorisation lives*).

  A context function that writes calls `authorize/2` before it writes and
  answers `{:error, %Slipdock.Policy.Refused{}}` when it is refused. Nothing
  above the context can skip it, so a door that forgets its own check is
  refused anyway.

  It reads who the process is acting for (`Slipdock.Actor.current/0`, and
  the user and API token kept beside it, `Slipdock.Actor.principal/0`),
  looks the action up in one table (`rules/0`: `action => {scope, level}`),
  reads that person's level on the scope from the database now, so a level
  lowered while a page is open counts, and narrows it by the token (ARCH-8).
  The refusal says which of the two was short.

  Who passes without a level:

    * a rule's write, as the board's own (`:automation_depth`);
    * the server's own write, when it says so: `as_system/2`, with why.

  Nobody acting (no actor on the process, as in a `Task` nobody told) is
  refused. A test's own process may write as nobody (`allow_nobody/0`, which
  `Slipdock.DataCase` sets): those writes are its fixtures.

  Contexts not yet migrated are listed in `test/support/unchecked_writes.txt`;
  `test/slipdock/unchecked_writes_test.exs` holds the rest to asking.
  """

  alias Slipdock.Access
  alias Slipdock.Accounts
  alias Slipdock.Accounts.User
  alias Slipdock.Actor
  alias Slipdock.Boards.Board
  alias Slipdock.Boards.Card
  alias Slipdock.Boards.Column
  alias Slipdock.Repo
  alias Slipdock.Wiki.Page

  defmodule Refused do
    @moduledoc """
    Why a write was refused. `by` is who was short: `:user` (the person's
    level), `:token` (the API token's scope narrowed it, ARCH-8) or `:nobody`
    (no actor was set). `need` is the level the action needs on `scope`.
    """
    defexception [:action, :scope, :need, :by, :message]
  end

  # {action, whose level counts, the level it needs, what it is, for the
  # refusal}. A new write adds its row here (W-1945 §Permissions).
  #
  # Scopes: `:tree_root` is the root of the subject's board tree (tags,
  # fields and milestones are the tree's, DATA-9); `:board` is the board
  # itself (a column's, a card's); `:card` is the card itself, raised by a
  # grant on it; `:owner` is the card or the wiki page a row hangs off
  # (`Boards.Owned`), a page's share counting.
  @table [
    # Tags (#3168)
    {:create_tag, :tree_root, :write, "Making a tag"},
    {:update_tag, :tree_root, :write, "Changing a tag"},
    {:delete_tag, :tree_root, :write, "Deleting a tag"},
    {:toggle_card_tag, :card, :write, "Tagging a card"},
    # Cards and what hangs from one (#3169)
    {:create_card, :board, :write, "Adding a card"},
    {:update_card, :card, :write, "Changing a card"},
    {:archive_card, :card, :write, "Archiving a card"},
    {:delete_card, :card, :write, "Deleting a card"},
    {:move_card, :card, :write, "Moving a card"},
    {:move_card_in, :board, :write, "Moving a card onto a board"},
    {:time_card, :card, :write, "The card's timer"},
    {:add_comment, :owner, :comment, "Commenting"},
    {:delete_comment, :owner, :write, "Deleting somebody else's comment"},
    {:delete_own_comment, :owner, :comment, "Deleting your comment"},
    {:edit_checklist, :owner, :write, "Changing a checklist"},
    {:tick_checklist, :owner, :write, "Ticking a checklist"},
    {:attach_file, :owner, :write, "Attaching a file"},
    {:remove_file, :owner, :write, "Removing a file"},
    {:hide_file, :owner, :write, "Keeping an image off the card's front"},
    {:edit_card_urls, :owner, :write, "Changing the web links"},
    {:edit_dependency, :card, :write, "Changing what blocks a card"},
    {:link_to_card, :card, :read, "Pointing at a card"},
    {:edit_link, :card, :write, "Linking cards"},
    {:leave_handoff, :card, :comment, "Leaving a handoff"},
    {:delete_handoff, :card, :write, "Deleting somebody else's handoff"},
    {:delete_own_handoff, :card, :comment, "Deleting your handoff"},
    {:edit_milestone, :tree_root, :write, "Changing a milestone"},
    {:add_status_update, :owner, :comment, "Posting a status update"},
    {:delete_status_update, :owner, :write, "Deleting a status update"},
    {:open_wait, :card, :write, "Opening a wait"},
    {:answer_wait, :card, :write, "Answering a wait"},
    {:answer_own_wait, :card, :comment, "Answering a wait on you"},
    {:withdraw_wait, :card, :write, "Withdrawing a wait"},
    {:withdraw_own_wait, :card, :read, "Withdrawing your wait"},
    {:edit_field, :tree_root, :write, "Changing a custom field"},
    {:set_field_value, :owner, :write, "Setting a custom field"},
    {:edit_recurrence, :card, :write, "Changing how a card repeats"},
    {:snooze_card, :card, :write, "Snoozing a card"},
    {:vote, :owner, :read, "Voting"},
    # Boards, lists, views, sprints and grants (#3170)
    {:create_board, :account, :owner, "Making a board"},
    {:update_board, :board, :write, "Changing a board's settings"},
    {:delete_board, :board, :owner, "Deleting a board"},
    {:archive_board, :board, :owner, "Archiving a board"},
    {:edit_sub_board, :card, :write, "Changing a card's subcards board"},
    {:edit_list, :board, :write, "Changing the board's lists"},
    {:place_in_list, :board, :write, "Placing something in a list"},
    {:edit_view, :board, :write, "Changing a saved view"},
    {:publish_view, :board, :owner, "Publishing a saved view"},
    {:edit_sprint, :board, :write, "Changing a sprint"},
    {:add_to_sprint, :card, :write, "Adding cards to a sprint"},
    {:arrange_own, :self, :owner, "Your own board list"},
    {:own_template, :self, :owner, "Your own templates"},
    {:share_board, :board, :owner, "Sharing a board"},
    {:share_view, :board, :owner, "Sharing a saved view"},
    {:share_card, :card, :write, "Sharing a card"},
    {:share_page, :page, :write, "Sharing a page"},
    {:share_folder, :folder, :write, "Sharing a folder"},
    {:share_tool, :tool, :owner, "Sharing a tool"}
  ]

  @rules Map.new(@table, fn {action, scope, level, _} -> {action, {scope, level}} end)
  @what Map.new(@table, fn {action, _, _, what} -> {action, what} end)

  @where %{
    tree_root: "the top board of its tree",
    board: "the board",
    card: "the card",
    owner: "the card or page",
    page: "the page",
    folder: "the folder",
    tool: "the tool",
    account: "your account",
    self: "the person's own rows"
  }

  @system {__MODULE__, :system}
  @nobody_ok {__MODULE__, :nobody_ok}
  @refusal {__MODULE__, :refusal}

  @doc "The table: what each action needs, and on what."
  def rules, do: @rules

  @doc """
  `:ok` if this process's actor may do `action` to `subject`, else
  `{:error, %Refused{}}`. `opts[:actor]` asks for that actor instead.
  """
  def authorize(action, subject, opts \\ []) when is_map_key(@rules, action) do
    with {:error, %Refused{} = refused} = result <- check(action, subject, opts) do
      Process.put(@refusal, refused)
      result
    end
  end

  # What `authorize/3` decides, without noting a refusal (`can?/3` asks it).
  defp check(action, subject, opts) do
    {scope, need} = Map.fetch!(@rules, action)
    actor = actor(opts)

    cond do
      Process.get(@system) -> :ok
      actor.kind == "automation" -> :ok
      true -> decide(action, scope, need, subject, actor)
    end
  end

  # Who the `opts` name (`opts[:actor]`, or `:via` and `:by`, as
  # `Actor.resolve/1` reads a context's own `opts`, passed straight through)
  # when that is a person or a rule, else the process's actor.
  defp actor(opts) when is_list(opts) do
    case Actor.resolve(opts) do
      %{kind: "automation"} = actor -> actor
      %{user_id: id} = actor when not is_nil(id) -> actor
      _ -> Actor.current()
    end
  end

  defp actor(_opts), do: Actor.current()

  @doc """
  The id of the person this process (or `opts[:actor]`) acts for, or nil:
  for a rule that turns on authorship (a commenter deletes only their own
  comment).
  """
  def user_id(opts \\ []), do: actor(opts)[:user_id]

  @doc """
  Whether this process's actor may do `action` to `subject`: what a door
  draws a button from, asked of the same table as the write, so the two
  can't disagree.
  """
  def can?(action, subject, opts \\ []) when is_map_key(@rules, action),
    do: check(action, subject, opts) == :ok

  @doc """
  The last refusal `authorize/3` answered in this process, taken (so it is
  answered once), or nil. A door that runs a write and may not look at its
  answer (a handler that ignores it, or crashes matching `{:ok, _}`) says
  this one instead (`SlipdockWeb.Refusals`, #3169). `can?/3` notes none:
  it only asks.
  """
  def take_refusal, do: Process.delete(@refusal)

  @doc """
  Runs `fun` as the server itself, saying why: a write no person or token is
  behind (setup, the demo, a carrier whose own gate has decided). Nested
  calls keep the outer reason.
  """
  def as_system(reason, fun) when is_binary(reason) and reason != "" and is_function(fun, 0) do
    previous = Process.get(@system)
    Process.put(@system, previous || reason)

    try do
      fun.()
    after
      if previous, do: Process.put(@system, previous), else: Process.delete(@system)
    end
  end

  @doc "Why this process is writing as the server, or nil (see `as_system/2`)."
  def system_reason, do: Process.get(@system)

  @doc """
  For a test's own process: a write made with no actor set is a fixture, and
  passes. A request the test makes sets its actor and is checked as itself.
  `Slipdock.DataCase` calls it for every test; a test of the refusal itself
  calls `forbid_nobody/0`.
  """
  def allow_nobody, do: Process.put(@nobody_ok, true)

  @doc """
  The strict form of `allow_nobody/0`, for a test run that looks for a
  server path writing with nobody behind it (`SLIPDOCK_POLICY_STRICT=1`,
  `Slipdock.DataCase`; W-1950 §Tests): nobody passes only inside
  `Slipdock.Fixtures`. Each other refusal of nobody is appended to `log`,
  with the call's stack, so a run can be read for the server paths.
  """
  def allow_nobody_in_fixtures(log), do: Process.put(@nobody_ok, {:fixtures, log})

  @doc "Undoes `allow_nobody/0`: nobody acting is refused again, as outside a test."
  def forbid_nobody, do: Process.delete(@nobody_ok)

  ## Deciding ------------------------------------------------------------------

  defp decide(action, scope, need, subject, actor) do
    case user_for(actor) do
      nil ->
        if nobody_ok?(action), do: :ok, else: refuse(action, scope, need, :nobody)

      %User{} = user ->
        token = token_for(user)
        {level, board_id} = level(scope, user, subject)
        {narrowed, reason} = narrow(level, token, board_id)

        cond do
          rank(narrowed) >= rank(need) -> :ok
          reason == :scope -> refuse(action, scope, need, :token)
          true -> refuse(action, scope, need, :user)
        end
    end
  end

  defp nobody_ok?(action) do
    case Process.get(@nobody_ok) do
      true -> true
      {:fixtures, log} -> in_fixtures?() or note_nobody(log, action)
      _ -> false
    end
  end

  defp in_fixtures? do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
    Enum.any?(stack, fn {mod, _f, _a, _loc} -> mod == Slipdock.Fixtures end)
  end

  defp note_nobody(log, action) do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    frames =
      for {mod, fun, arity, loc} <- Enum.drop(stack, 2),
          do: "#{inspect(mod)}.#{fun}/#{arity}:#{loc[:line]}"

    File.write!(log, "#{action} #{Enum.join(frames, " < ")}\n", [:append])
    false
  end

  # A write on no board (`:account`) is narrowed by the token's read scope
  # alone (ARCH-8).
  defp narrow(level, token, :account) when is_map(token),
    do: Access.narrow(level, Map.put(token, :scope_boards, []), nil)

  defp narrow(level, token, :account), do: Access.narrow(level, token, nil)
  defp narrow(level, token, board_id), do: Access.narrow(level, token, board_id)

  @ranks ~w(none view read comment write owner)a
  defp rank(level), do: Enum.find_index(@ranks, &(&1 == level)) || 0

  # The person behind the actor: the one the door kept beside it, else the
  # actor's own user id (a door that set only the actor, or `opts[:actor]`).
  defp user_for(%{user_id: nil}), do: nil

  defp user_for(%{user_id: id}) do
    case Actor.principal() do
      {%User{id: ^id} = user, _token} -> user
      _ -> Accounts.get_user(id)
    end
  end

  defp user_for(_), do: nil

  # The token narrows only the user it was issued to.
  defp token_for(%User{id: id}) do
    case Actor.principal() do
      {%User{id: ^id}, token} -> token
      _ -> nil
    end
  end

  # {the level, the board the token's scope is checked against}. Every level
  # is read from the database now, not from the struct the caller holds.
  defp level(:tree_root, user, subject) do
    case root_board(subject) do
      nil -> {:none, nil}
      root -> {Access.board_permission(user, root), root.id}
    end
  end

  defp level(:board, user, subject) do
    case board_of(subject) do
      nil -> {:none, nil}
      board -> {Access.board_permission(user, board), board.id}
    end
  end

  # A saved view granted to someone with view-only access to the board
  # reaches the cards it shows, at the view's grant (`Access.view_card_level/2`).
  defp level(:card, user, subject) do
    case card_of(subject) do
      nil -> {:none, nil}
      card -> {card_level(user, card), card.board_id}
    end
  end

  # What hangs off a card or a wiki page (`Boards.Owned`): the card's level,
  # or the page's (a share on the page counts).
  defp level(:owner, user, subject) do
    case page_of(subject) do
      %Page{} = page -> {Access.page_permission(user, page), page.board_id}
      nil -> level(:card, user, subject)
    end
  end

  defp level(:page, user, subject) do
    case page_of(subject) do
      nil -> {:none, nil}
      page -> {Access.page_permission(user, page), page.board_id}
    end
  end

  defp level(:folder, user, %Slipdock.Wiki.Folder{id: id}) do
    case Repo.get(Slipdock.Wiki.Folder, id) do
      nil -> {:none, nil}
      folder -> {Access.folder_permission(user, folder), folder.board_id}
    end
  end

  defp level(:tool, user, %Slipdock.Tools.Tool{id: id}) do
    case Repo.get(Slipdock.Tools.Tool, id) do
      %{owner_id: owner_id} when owner_id == user.id -> {:owner, nil}
      _ -> {:none, nil}
    end
  end

  # Anybody signed in may make a board of their own. It is in no tree yet,
  # so a token's list of boards doesn't narrow it; its read scope does.
  defp level(:account, _user, _subject), do: {:owner, :account}

  # A person's own rows (their board order, their templates, a board off
  # their list): theirs to change, nobody else's.
  defp level(:self, user, %Slipdock.Accounts.User{id: id}),
    do: {if(id == user.id, do: :owner, else: :none), :account}

  defp level(:self, user, %{user_id: id}),
    do: {if(id == user.id, do: :owner, else: :none), :account}

  defp card_level(user, card) do
    case Access.card_permission(user, card) do
      :none -> Access.view_card_level(user, card)
      level -> level
    end
  end

  defp card_of(%Card{id: id}), do: Repo.get(Card, id)
  defp card_of(%{card_id: id}) when is_integer(id), do: Repo.get(Card, id)
  defp card_of(_), do: nil

  defp page_of(%Page{id: id}), do: Repo.get(Page, id)
  defp page_of(%{page_id: id}) when is_integer(id), do: Repo.get(Page, id)
  defp page_of(_), do: nil

  defp board_of(%{board_id: nil}), do: nil
  defp board_of(%Board{id: nil}), do: nil
  defp board_of(%Board{id: id}), do: Repo.get(Board, id)
  defp board_of(%Column{board_id: id}), do: Repo.get(Board, id)
  defp board_of(%Slipdock.Boards.SavedView{board_id: id}), do: Repo.get(Board, id)

  defp board_of(%Card{} = card),
    do: with(%Card{board_id: id} <- card_of(card), do: Repo.get(Board, id))

  defp board_of(_), do: nil

  # Read again: the root a struct names can have moved (a board moved into
  # another tree) or gone. Tags, fields and milestones are kept on the root.
  defp root_board(%Board{} = board) do
    case board_of(board) do
      nil -> nil
      %Board{root_id: nil} = board -> board
      %Board{root_id: root_id} -> Repo.get(Board, root_id)
    end
  end

  defp root_board(%Card{} = card),
    do: with(%Card{board_id: id} <- card_of(card), do: root_board(%Board{id: id}))

  defp root_board(%{board_id: id}) when is_integer(id), do: root_board(%Board{id: id})
  defp root_board(subject), do: with(%Board{} = board <- board_of(subject), do: root_board(board))

  defp refuse(action, scope, need, by) do
    what = Map.fetch!(@what, action)
    where = Map.fetch!(@where, scope)

    message =
      case by do
        :user ->
          "#{what} needs #{need} access to #{where}, and you don't have it."

        :token ->
          "#{what} needs #{need} access to #{where}, and this API token's scope doesn't allow it."

        :nobody ->
          "#{what} was asked with nobody acting: no person, token or rule is behind it."
      end

    {:error, %Refused{action: action, scope: scope, need: need, by: by, message: message}}
  end
end
