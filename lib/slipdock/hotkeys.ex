defmodule Slipdock.Hotkeys do
  @moduledoc """
  Board hotkeys (#1101): Ctrl+Shift+a digit opens a board — or a vault
  (#1204) — from any page.

  The digit is set in the board's (or vault's) settings, but it belongs to
  the person who set it, not the board — there are only ten, and two people
  sharing a board each keep their own. Giving a digit to one board takes it
  off whichever of your boards or vaults had it, and a board has at most one
  of yours.

  Only top-level boards take one, as only they are in the switcher, and only
  your own vaults, as nobody else's are. Access is checked when a digit is
  set and again when it is followed, since a share can be revoked long after
  the row was written; an archived board is not opened by its digit either,
  though it keeps it for when it comes back.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Hotkeys.Hotkey
  alias Slipdock.Vaults.Vault
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

  @doc "`user`'s digit for `board` or `vault`, or nil."
  def get(%User{id: user_id}, target) when is_struct(target, Board) or is_struct(target, Vault) do
    Repo.one(from(h in Hotkey, where: h.user_id == ^user_id, select: h.digit) |> on(target))
  end

  def get(_user, _target), do: nil

  defp on(query, %Board{id: id}), do: from(h in query, where: h.board_id == ^id)
  defp on(query, %Vault{id: id}), do: from(h in query, where: h.vault_id == ^id)

  @doc """
  Every hotkey `user` has on a board they can still open or a vault of
  theirs, as `[{digit, board_or_vault}]` in digit order (1–9, then 0, as on
  the keyboard).
  """
  def list(%User{} = user) do
    from(h in Hotkey,
      left_join: b in Board,
      on: b.id == h.board_id,
      left_join: v in Vault,
      on: v.id == h.vault_id,
      where: h.user_id == ^user.id,
      select: {h.digit, b, v}
    )
    |> Repo.all()
    |> Enum.map(fn {digit, board, vault} -> {digit, board || vault} end)
    |> Enum.filter(fn {_digit, target} -> visible?(user, target) end)
    |> Enum.sort_by(fn {digit, _} -> if digit == 0, do: 10, else: digit end)
  end

  def list(_), do: []

  @doc """
  The options for a Hotkey select on `target`'s settings, from `hotkeys` (as
  `list/1` gives them): None, then each digit, naming the board or vault that
  has it now when that is not `target`.
  """
  def choices(hotkeys, target) do
    taken = Map.new(hotkeys)

    [{"None", ""}] ++
      for digit <- Enum.to_list(1..9) ++ [0] do
        case taken[digit] do
          %{__struct__: kind, id: id, name: name}
          when kind != target.__struct__ or id != target.id ->
            {"Ctrl+Shift+#{digit} (now #{name})", to_string(digit)}

          _ ->
            {"Ctrl+Shift+#{digit}", to_string(digit)}
        end
      end
  end

  @doc "Just the boards of `list/1`, as `[{digit, board}]`."
  def boards(user), do: for({digit, %Board{} = board} <- list(user), do: {digit, board})

  @doc """
  Gives `board` (or a vault) the digit `value` for `user` (anything `parse/1`
  reads), or takes its digit away with nil. The digit leaves whichever other
  board or vault of theirs had it.
  """
  def put(%User{} = user, target, value)
      when is_struct(target, Board) or is_struct(target, Vault) do
    with {:ok, digit} <- parse(value),
         :ok <- allowed(user, target) do
      Repo.transaction(fn ->
        Repo.delete_all(
          from(h in Hotkey,
            where: h.user_id == ^user.id and h.digit == ^(digit || -1)
          )
        )

        Repo.delete_all(from(h in Hotkey, where: h.user_id == ^user.id) |> on(target))

        if digit do
          Repo.insert!(
            case target do
              %Board{id: id} -> %Hotkey{user_id: user.id, board_id: id, digit: digit}
              %Vault{id: id} -> %Hotkey{user_id: user.id, vault_id: id, digit: digit}
            end
          )
        end

        digit
      end)
    end
  end

  defp allowed(user, %Vault{} = vault) do
    if visible?(user, vault), do: :ok, else: {:error, "vault not found"}
  end

  defp allowed(user, board) do
    cond do
      not is_nil(board.parent_card_id) -> {:error, "only a top-level board takes a hotkey"}
      visible?(user, board) -> :ok
      true -> {:error, "board not found"}
    end
  end

  @doc """
  The board or vault `user`'s `digit` opens, or nil: nothing on that digit, a
  board they can no longer read, or one that is archived.
  """
  def target(%User{} = user, value) do
    with {:ok, digit} when not is_nil(digit) <- parse(value),
         {board, vault} <-
           Repo.one(
             from(h in Hotkey,
               left_join: b in Board,
               on: b.id == h.board_id,
               left_join: v in Vault,
               on: v.id == h.vault_id,
               where: h.user_id == ^user.id and h.digit == ^digit,
               select: {b, v}
             )
           ),
         target when not is_nil(target) <- board || vault,
         true <- openable?(target),
         true <- visible?(user, target) do
      target
    else
      _ -> nil
    end
  end

  def target(_user, _value), do: nil

  defp openable?(%Board{archived_at: archived_at}), do: is_nil(archived_at)
  defp openable?(%Vault{}), do: true

  # Anything that lists the board in the switcher — a grant on one of its
  # views included — can be reached by its digit. A vault is its owner's.
  defp visible?(user, %Vault{user_id: owner}), do: owner == user.id
  defp visible?(user, board), do: Access.board_permission(user, board) != :none
end
