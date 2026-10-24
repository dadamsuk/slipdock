defmodule Slipdock.Inbound.Tokens do
  @moduledoc """
  Who an inbound address belongs to, and where its mail goes (#1244, W-1933).

  Every person has one token per board they can write to, behind two
  addresses, `card-<token>@…` (a new card) and `page-<token>@…` (a new wiki
  page), and one personal token behind `add-<token>@…` (Quick Add, any
  board). A token names both the sender it accepts and the destination, so an
  address is no use to anybody but its owner.

  Tokens are 26 random base32 characters (128 bits), made the first time the
  address is asked for. They are looked up by SHA-256 hash, and kept
  encrypted with a key derived from the endpoint's `secret_key_base` too, so
  the address can be shown again: a copy of the database alone gives none of
  them away. (Changing `secret_key_base` replaces each address the next time
  it is shown, since the old one can no longer be read.)

  Rotating revokes the old token, so mail to the old address bounces, and
  makes a new one. A deleted board takes its tokens with it; losing write
  access to a board revokes that person's token for it, whether the share is
  taken back (`prune_board/1`) or found to be gone when mail arrives.
  """

  import Ecto.Query

  alias Slipdock.{Access, Inbound, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Inbound.Token

  @encryption_salt "inbound address token"
  @token_bytes 16

  @type kind :: :card | :page | :add
  @type resolve_error :: :malformed | :unknown | :wrong_kind | :inactive | :archived | :forbidden

  @doc """
  `user`'s address of `kind` for `board` (`:card` or `:page`), or their
  personal address (`nil` and `:add`), making the token if there is none yet.

  `{:error, :disabled}` while inbound mail is off, `{:error, :forbidden}` when
  `user` can't write to `board`, and `{:error, :wrong_kind}` for a kind the
  target doesn't have (no `:add` for a board, no `:card` without one).
  """
  @spec address(User.t(), Board.t() | nil, kind()) ::
          {:ok, String.t()} | {:error, :disabled | :forbidden | :wrong_kind}
  def address(%User{} = user, board, kind) do
    with :ok <- kind_fits(board, kind),
         :ok <- enabled(),
         :ok <- may_write(user, board),
         {:ok, token} <- live_token(user, board) do
      {:ok, format(kind, token)}
    end
  end

  @doc """
  Every address `user` has for `board` (or, for `nil`, the personal one), as
  a map of kind to address. Same errors as `address/3`.
  """
  @spec addresses(User.t(), Board.t() | nil) :: {:ok, map()} | {:error, atom()}
  def addresses(%User{} = user, nil) do
    with {:ok, add} <- address(user, nil, :add), do: {:ok, %{add: add}}
  end

  def addresses(%User{} = user, %Board{} = board) do
    with {:ok, card} <- address(user, board, :card),
         {:ok, page} <- address(user, board, :page) do
      {:ok, %{card: card, page: page}}
    end
  end

  @doc """
  Replaces `user`'s token for `board` (or their personal one, for `nil`) with
  a new one; mail to the old address bounces from now on. Answers the new
  addresses, as `addresses/2` does.
  """
  @spec rotate(User.t(), Board.t() | nil) :: {:ok, map()} | {:error, atom()}
  def rotate(%User{} = user, board) do
    with :ok <- enabled(),
         :ok <- may_write(user, board) do
      now = DateTime.utc_now(:second)

      Repo.transaction(fn ->
        live(user, board) |> Repo.update_all(set: [revoked_at: now, rotated_at: now])
        {:ok, _} = insert(user, board)
      end)

      addresses(user, board)
    end
  end

  @doc """
  Turns `user`'s token for `board` (or their personal one) off, without a
  replacement. Asking for the address again makes a new one.
  """
  @spec revoke(User.t(), Board.t() | nil) :: :ok
  def revoke(%User{} = user, board) do
    live(user, board) |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])
    :ok
  end

  @doc """
  Revokes the board's tokens held by people who can no longer write to it:
  run when a share of it is taken back.
  """
  @spec prune_board(Board.t()) :: :ok
  def prune_board(%Board{id: board_id} = board) do
    from(t in Token, where: t.board_id == ^board_id and is_nil(t.revoked_at), preload: :user)
    |> Repo.all()
    |> Enum.reject(&writer?(&1.user, board))
    |> Enum.each(&revoke_row/1)
  end

  @doc """
  What an address's local part (`card-<token>`, or the whole address) points
  at: `{:ok, {kind, user, board}}`, `board` nil for a personal address. Or
  why not:

    * `:malformed` — not an inbound address at all
    * `:unknown` — no such token, or it was rotated or revoked
    * `:wrong_kind` — `add-` with a board token, or `card-`/`page-` with a
      personal one
    * `:inactive` — the account is disabled
    * `:archived` — the board is archived
    * `:forbidden` — its owner can no longer write to the board; the token is
      revoked on the spot
  """
  @spec resolve(String.t()) ::
          {:ok, {kind(), User.t(), Board.t() | nil}} | {:error, resolve_error()}
  def resolve(local_part) when is_binary(local_part) do
    with {kind, token} when kind in ["card", "page", "add"] <-
           Inbound.address(String.downcase(String.trim(local_part))),
         %Token{} = row <- find(token) do
      check(String.to_existing_atom(kind), row)
    else
      {_kind, _token} -> {:error, :malformed}
      nil -> {:error, :unknown}
    end
  end

  defp check(kind, %Token{board: nil}) when kind != :add, do: {:error, :wrong_kind}
  defp check(:add, %Token{board: %Board{}}), do: {:error, :wrong_kind}

  defp check(_kind, %Token{user: %User{disabled_at: at}}) when not is_nil(at),
    do: {:error, :inactive}

  defp check(kind, %Token{user: user, board: nil}), do: {:ok, {kind, user, nil}}

  defp check(kind, %Token{user: user, board: board} = row) do
    cond do
      Board.archived?(board) ->
        {:error, :archived}

      not writer?(user, board) ->
        revoke_row(row)
        {:error, :forbidden}

      true ->
        {:ok, {kind, user, board}}
    end
  end

  defp find(token) do
    from(t in Token,
      where: t.token_hash == ^hash(token) and is_nil(t.revoked_at),
      preload: [:user, :board]
    )
    |> Repo.one()
  end

  ## Plumbing -----------------------------------------------------------------

  defp kind_fits(nil, :add), do: :ok
  defp kind_fits(%Board{}, kind) when kind in [:card, :page], do: :ok
  defp kind_fits(_board, _kind), do: {:error, :wrong_kind}

  defp enabled, do: if(Inbound.enabled?(), do: :ok, else: {:error, :disabled})

  defp may_write(_user, nil), do: :ok
  defp may_write(user, board), do: if(writer?(user, board), do: :ok, else: {:error, :forbidden})

  defp writer?(user, board), do: user |> Access.board_permission(board) |> Access.can_write?()

  defp live(%User{id: user_id}, nil),
    do:
      from(t in Token,
        where: t.user_id == ^user_id and is_nil(t.board_id) and is_nil(t.revoked_at)
      )

  defp live(%User{id: user_id}, %Board{id: board_id}),
    do:
      from(t in Token,
        where: t.user_id == ^user_id and t.board_id == ^board_id and is_nil(t.revoked_at)
      )

  defp revoke_row(%Token{id: id}) do
    from(t in Token, where: t.id == ^id)
    |> Repo.update_all(set: [revoked_at: DateTime.utc_now(:second)])
  end

  # The live token in plain text, made if there is none. Two requests can
  # race to make it; the loser reads the winner's.
  defp live_token(user, board) do
    case Repo.one(live(user, board)) do
      nil ->
        case insert(user, board) do
          {:ok, token} -> {:ok, token}
          {:error, _} -> live_token(user, board)
        end

      row ->
        decrypt(row)
    end
  end

  defp insert(user, board) do
    token = new_token()

    %Token{
      user_id: user.id,
      board_id: board && board.id,
      token_hash: hash(token),
      token_encrypted: Plug.Crypto.encrypt(secret(), @encryption_salt, token)
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:user_id, :board_id],
      name: :inbound_tokens_live_board_index
    )
    |> Ecto.Changeset.unique_constraint([:user_id], name: :inbound_tokens_live_personal_index)
    |> Repo.insert()
    |> case do
      {:ok, _row} -> {:ok, token}
      error -> error
    end
  end

  # A token whose key has gone (secret_key_base changed) can't be shown: it
  # is replaced, as a rotation would.
  defp decrypt(%Token{} = row) do
    case Plug.Crypto.decrypt(secret(), @encryption_salt, row.token_encrypted, max_age: :infinity) do
      {:ok, token} ->
        {:ok, token}

      {:error, _} ->
        revoke_row(row)
        row = Repo.preload(row, [:user, :board])
        live_token(row.user, row.board)
    end
  end

  defp new_token,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp format(kind, token), do: "#{kind}-#{token}@#{Inbound.domain()}"

  defp secret, do: SlipdockWeb.Endpoint.config(:secret_key_base)
end
