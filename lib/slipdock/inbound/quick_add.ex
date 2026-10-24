defmodule Slipdock.Inbound.QuickAdd do
  @moduledoc """
  Mail to a personal `add-…` address (#1248): the subject goes through
  `Slipdock.QuickAdd.Capture`, the same path as the header's Quick Add, so
  `#high`, `due: friday`, `@dan`, a list name (and the model, when it is
  configured and turned on) all work. The body becomes the description and
  the attachments are uploaded, as for a board's card address
  (`Slipdock.Inbound.Cards`).

  The board is the user's Quick Add default unless the subject names one:
  `[Board] Title` (by name or code, as a mail filter would write it), or in
  prose to the model. A named board that can't be found bounces, with the
  boards the user can reach.
  """

  alias Slipdock.{Access, Actor}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.Board
  alias Slipdock.Inbound.{Cards, Message}
  alias Slipdock.QuickAdd.Capture

  @listed 25

  @doc "A card from `message` for `user`: `{:ok, %{card_id:, user_id:}}` or `{:reject, reason}`."
  @spec capture(User.t(), Message.t(), keyword()) :: {:ok, map()} | {:reject, String.t()}
  def capture(%User{} = user, %Message{} = message, opts \\ []) do
    {bracket, line} = split_board(Cards.title(message.subject))

    with {:ok, board} <- named_board(user, bracket) do
      description = Cards.description(message, fn _ -> nil end)

      opts =
        [
          board: board,
          strict_board: true,
          attrs: %{"description" => description},
          create_opts: [by: user, actor: Actor.email(user)]
        ] ++ opts

      case Capture.capture(user, line, opts) do
        {:ok, %{card: card}} ->
          Cards.attach(card, user, message, nil)
          {:ok, %{card_id: card.id, user_id: user.id}}

        {:error, {:unknown_board, name}} ->
          {:reject, no_board(user, name)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:reject, Cards.refusal(changeset)}

        {:error, "You don't have a board to add to yet."} ->
          {:reject, "You don't have a board to add cards to yet."}

        {:error, message} ->
          {:reject, message}
      end
    end
  end

  @doc """
  A subject's leading `[Board]`, and the rest: `{"Ops", "Renew the cert"}`,
  or `{nil, subject}`.
  """
  @spec split_board(String.t()) :: {String.t() | nil, String.t()}
  def split_board(subject) do
    case Regex.run(~r/^\s*\[([^\]]{1,100})\]\s*(.*)$/s, subject) do
      [_, board, rest] -> {String.trim(board), title_or_default(rest)}
      nil -> {nil, subject}
    end
  end

  defp title_or_default(rest) do
    case String.trim(rest) do
      "" -> "(no subject)"
      rest -> rest
    end
  end

  defp named_board(_user, nil), do: {:ok, nil}

  defp named_board(user, name) do
    wanted = norm(name)
    boards = writable(user)

    found =
      Enum.find(boards, &(norm(&1.name) == wanted or norm(&1.code) == wanted)) ||
        case Enum.filter(boards, &String.starts_with?(norm(&1.name), wanted)) do
          [one] -> one
          _ -> nil
        end

    if found, do: {:ok, found}, else: {:reject, no_board(user, name)}
  end

  defp no_board(user, name) do
    names = user |> writable() |> Enum.map(& &1.name)

    listed =
      case names do
        [] ->
          "You can't add cards to any board yet."

        names ->
          more = if length(names) > @listed, do: ", and #{length(names) - @listed} more", else: ""
          "Boards you can add to: " <> Enum.join(Enum.take(names, @listed), ", ") <> more <> "."
      end

    "There's no board called “#{name}” that you can add to. " <> listed
  end

  defp writable(user) do
    user
    |> Access.list_boards()
    |> Enum.filter(&Access.can_write?(Access.board_permission(user, &1)))
    |> Enum.reject(&Board.archived?/1)
  end

  defp norm(nil), do: ""
  defp norm(s), do: s |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]/u, "")
end
