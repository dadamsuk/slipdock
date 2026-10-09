defmodule Slipdock.Meetings do
  @moduledoc """
  Meeting capture: a meeting's audio and/or transcript turned into proposed
  decisions, actions and card changes, which a person reviews and commits in
  one undoable write. The requirements are the PRD on the board's wiki
  (W-87, "Meeting capture: PRD").

  ## Meeting mode

  Off unless an admin turns it on (`meetings_enabled`). While it is off there
  is nothing of it anywhere: no routes, no menu entries, no MCP tools, no guide
  section, and the CLI's `capture` commands say "meeting mode is off on this
  server". Turning it off deletes nothing; turning it back on shows every
  capture again.

  While it is on, `meetings_visibility` decides where it shows:

    * `:used_only` (the default) — a board's Meetings tab appears once that
      board has had a capture; until then there is one entry in the board's
      menu to start one.
    * `:every_board` — the tab is on every board.

  And `meetings_hideable` lets each person put it out of sight for themselves
  (Account › Settings › Display). That is a display preference: the API and
  the CLI answer the same either way.

  Whether a board has had a capture is a column on the board
  (`meetings_used_at`), so the board page decides from the row it already has
  and a board that never had one pays nothing for meeting mode existing.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Settings

  @off_message "meeting mode is off on this server"

  @doc "What every refusal says while meeting mode is off."
  def off_message, do: @off_message

  @doc "Whether an admin has turned meeting mode on."
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get().meetings_enabled == true

  @doc "`:used_only` or `:every_board`: where the Meetings tab shows."
  @spec visibility() :: :used_only | :every_board
  def visibility, do: Settings.get().meetings_visibility || :used_only

  @doc "Whether people may hide meeting capture for themselves."
  @spec hideable?() :: boolean()
  def hideable?, do: Settings.get().meetings_hideable != false

  @doc """
  Whether this person sees meeting capture at all: it is on, and they have
  not hidden it (or are not allowed to).
  """
  @spec available?(User.t() | nil) :: boolean()
  def available?(%User{} = user), do: enabled?() and not hidden_by?(user)
  def available?(_), do: false

  @doc "Whether this person has hidden meeting capture, and is allowed to."
  @spec hidden_by?(User.t() | nil) :: boolean()
  def hidden_by?(%User{hide_meetings: true}), do: hideable?()
  def hidden_by?(_), do: false

  @doc """
  What this person sees of meeting capture on this board:

    * `:tab` — the Meetings tab, in the view menu beside the wiki;
    * `:menu` — only an entry in the board's menu to start a first capture;
    * `:none` — nothing at all.
  """
  @spec presence(User.t() | nil, Board.t()) :: :tab | :menu | :none
  def presence(user, %Board{} = board) do
    cond do
      not available?(user) -> :none
      visibility() == :every_board -> :tab
      board.meetings_used_at != nil -> :tab
      true -> :menu
    end
  end

  @doc """
  The mode as the API reports it: whether it is on, and how it shows. What a
  client needs before it offers to send anything.
  """
  @spec mode(User.t() | nil) :: map()
  def mode(user) do
    settings = Settings.get()

    %{
      enabled: settings.meetings_enabled == true,
      visibility: settings.meetings_visibility,
      hideable: settings.meetings_hideable != false,
      hidden: hidden_by?(user)
    }
  end

  @doc """
  Stamps the board as having had a capture, which is what puts its Meetings
  tab up under `:used_only`. Only the first stamp counts.
  """
  @spec mark_used(Board.t()) :: Board.t()
  def mark_used(%Board{meetings_used_at: nil} = board) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_, _} =
      Slipdock.Repo.update_all(
        from(b in Board, where: b.id == ^board.id and is_nil(b.meetings_used_at)),
        set: [meetings_used_at: now]
      )

    %{board | meetings_used_at: now}
  end

  def mark_used(%Board{} = board), do: board
end
