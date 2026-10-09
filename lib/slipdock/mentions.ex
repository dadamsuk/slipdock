defmodule Slipdock.Mentions do
  @moduledoc """
  `@someone` in a card's description or in a comment on it.

  A mention names a person who can see the board — by the part of their
  email before the "@" (`@david`), or by their name when it is one word
  (`@David`), case-insensitively. That is the same rule the wiki uses (see
  `Slipdock.Wiki.Links`), so `@stranger` stays plain text rather than
  reaching somebody the board was never shared with.

  Whoever is mentioned gets an email: for a comment, every time; for a
  description, only when the edit is what put them there, so re-saving a
  description does not mention everybody in it again. The person writing is
  never told about their own mention.
  """

  alias Slipdock.Access
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.{Notifier, Runner}
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Repo
  alias Slipdock.Wiki.Links

  # The wiki's own pattern (`Slipdock.Wiki.Markup`): not after a word
  # character, so an email address in the text is not a mention.
  @pattern ~r/(?<![\w@\/])@([a-zA-Z][\w.\-]{0,62})/

  @doc """
  The names mentioned in `text`, lowercased, in order and without repeats.
  A sentence ending in `@david.` mentions `david`.
  """
  @spec names(String.t() | nil) :: [String.t()]
  def names(nil), do: []

  def names(text) when is_binary(text) do
    # An "@" inside a URL is part of the address, not a person.
    text = Regex.replace(~r{https?://\S+}, text, "")

    @pattern
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [name] -> name |> String.trim_trailing(".") |> String.trim_trailing("-") end)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  @doc "The people `text` mentions who can see `board`."
  @spec people(Board.t() | nil, String.t() | nil) :: [User.t()]
  def people(nil, _text), do: []

  def people(%Board{} = board, text) do
    case names(text) do
      [] -> []
      names -> resolve(Links.members(board), names)
    end
  end

  @doc """
  The member of `members` that `name` (without its "@") refers to, or nil.
  An email-handle match wins over a name match, so two people called David
  can still be told apart by `@dave` and `@david`.
  """
  def find(members, name) do
    wanted = name |> String.trim_trailing(".") |> String.trim_trailing("-") |> String.downcase()

    Enum.find(members, &(Links.handle(&1) == wanted)) ||
      Enum.find(members, &(String.downcase(to_string(&1.name)) == wanted))
  end

  defp resolve(members, names),
    do: names |> Enum.map(&find(members, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.id)

  @doc """
  Tells the people a new comment on `card` mentions. `by` is who wrote it,
  when known.
  """
  def comment_added(%Card{} = card, body, by \\ nil) do
    board = Repo.get(Board, card.board_id)
    notify(card, board, people(board, body), by, "a comment", body)
  end

  @doc """
  Tells the people a description edit newly mentions: in `new`, and not
  in `old`.
  """
  def description_changed(%Card{} = card, old, new, by \\ nil) do
    case names(new) -- names(old) do
      [] ->
        :ok

      _ ->
        board = Repo.get(Board, card.board_id)
        already = board |> people(old) |> MapSet.new(& &1.id)
        fresh = board |> people(new) |> Enum.reject(&MapSet.member?(already, &1.id))
        notify(card, board, fresh, by, "the description", new)
    end
  end

  # Members of the board can still be shut out of one card on it — a card
  # reached only through a saved view, say — and the email quotes the card,
  # so whoever is told has to be able to open it.
  defp notify(card, board, people, by, where, text) do
    people
    |> Enum.reject(&(by && &1.id == by.id))
    |> Enum.filter(&Access.can_read?(Access.card_permission(&1, card)))
    |> Enum.each(fn person ->
      # Held back inside a write that may yet roll back (`Slipdock.Deferred`).
      Slipdock.Deferred.defer(fn ->
        Notifier.deliver([person.email], subject(card, board, by), body(card, by, where, text))
      end)
    end)
  end

  defp subject(card, board, by),
    do: "#{who(by)} mentioned you on “#{card.title}” (#{board.name})"

  defp body(card, by, where, text) do
    """
    #{who(by)} mentioned you in #{where} of card ##{card.id}, “#{card.title}”:

    #{text |> String.trim() |> quote_lines()}

    #{Runner.base_url()}/boards/#{card.board_id}/cards/#{card.id}
    """
  end

  defp who(nil), do: "Somebody"
  defp who(%User{name: name}) when is_binary(name) and name != "", do: name
  defp who(%User{email: email}), do: email

  defp quote_lines(text),
    do: text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
end
