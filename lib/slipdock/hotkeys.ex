defmodule Slipdock.Hotkeys do
  @moduledoc """
  Board hotkeys (#1101): Ctrl+Shift+a digit opens a board from any page.

  The digit is set in the board's settings, but it belongs to the person who
  set it, not the board — there are only ten, and two people sharing a board
  each keep their own. Giving a digit to one board takes it off whichever of
  your boards had it, and a board has at most one of yours.

  Only top-level boards take one, as only they are in the switcher. Access is
  checked when a digit is set and again when it is followed, since a share
  can be revoked long after the row was written; an archived board is not
  opened by its digit either, though it keeps it for when it comes back.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Hotkeys.Hotkey
  alias Slipdock.{Access, Repo}

  @digits Enum.to_list(0..9)

  @doc "The digits a hotkey can be."
  def digits, do: @digits

  @doc """
  Reads a digit from what a form, a client or the keyboard sent: an integer
  or a string of one digit. `{:ok, nil}` for none ("", "none", nil).
  """
  def parse(value) when value in [nil, "", "none", "off"], do: {:ok, nil}
  def parse(value) when value in @digits, do: {:ok, value}

  def parse(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n in @digits -> {:ok, n}
      _ -> {:error, "must be a single digit, 0–9, or none"}
    end
  end

  def parse(_), do: {:error, "must be a single digit, 0–9, or none"}

  @doc "`user`'s digit for `board`, or nil."
  def get(%User{id: user_id}, %Board{id: board_id}) do
    Repo.one(
      from(h in Hotkey,
        where: h.user_id == ^user_id and h.board_id == ^board_id,
        select: h.digit
      )
    )
  end

  def get(_user, _board), do: nil

  @doc """
  Every hotkey `user` has on a board they can still open, as
  `[{digit, board}]` in digit order (1–9, then 0, as on the keyboard).
  """
  def list(%User{} = user) do
    from(h in Hotkey,
      join: b in Board,
      on: b.id == h.board_id,
      where: h.user_id == ^user.id,
      select: {h.digit, b}
    )
    |> Repo.all()
    |> Enum.filter(fn {_digit, board} -> visible?(user, board) end)
    |> Enum.sort_by(fn {digit, _} -> if digit == 0, do: 10, else: digit end)
  end

  def list(_), do: []

  @doc """
  Gives `board` the digit `value` for `user` (anything `parse/1` reads), or
  takes its digit away with nil. The digit leaves whichever other board of
  theirs had it.
  """
  def put(%User{} = user, %Board{} = board, value) do
    with {:ok, digit} <- parse(value),
         :ok <- allowed(user, board) do
      Repo.transaction(fn ->
        Repo.delete_all(
          from(h in Hotkey,
            where:
              h.user_id == ^user.id and (h.board_id == ^board.id or h.digit == ^(digit || -1))
          )
        )

        if digit do
          Repo.insert!(%Hotkey{user_id: user.id, board_id: board.id, digit: digit})
        end

        digit
      end)
    end
  end

  defp allowed(user, board) do
    cond do
      not is_nil(board.parent_card_id) -> {:error, "only a top-level board takes a hotkey"}
      visible?(user, board) -> :ok
      true -> {:error, "board not found"}
    end
  end

  @doc """
  The board `user`'s `digit` opens, or nil: nothing on that digit, a board
  they can no longer read, or one that is archived.
  """
  def target(%User{} = user, value) do
    with {:ok, digit} when not is_nil(digit) <- parse(value),
         %Board{archived_at: nil} = board <-
           Repo.one(
             from(b in Board,
               join: h in Hotkey,
               on: h.board_id == b.id,
               where: h.user_id == ^user.id and h.digit == ^digit
             )
           ),
         true <- visible?(user, board) do
      board
    else
      _ -> nil
    end
  end

  def target(_user, _value), do: nil

  # Anything that lists the board in the switcher — a grant on one of its
  # views included — can be reached by its digit.
  defp visible?(user, board), do: Access.board_permission(user, board) != :none
end
