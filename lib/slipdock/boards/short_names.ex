defmodule Slipdock.Boards.ShortNames do
  @moduledoc """
  A card's short name (W-2201 §Names): about 30 characters, a human label for
  when space is tight, and what its folder is called on disk.

  A title over 40 characters gets one the moment it is saved, made
  systematically (`systematic/1`), so a card always has one and nothing waits
  on a model. The cheapest configured model then improves it in the
  background (`refine/1`). No key, no quota, a failed call or an unusable
  reply all leave the systematic name standing. A name a person typed
  (`short_name_edited`) is never touched; clearing it hands it back.

  Uniqueness is not the short name's job: clashes are numbered at the folder
  level (`Slipdock.Wiki.DiskName.assign/2`).
  """

  import Ecto.Query, warn: false

  alias Slipdock.{AI, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Wiki.{CardFolders, DiskName}

  require Logger

  @long 40
  @target 30

  @prompt """
  You shorten kanban card titles for a file tree. Reply with the short name
  alone: at most 30 characters, no quotes, no trailing punctuation.

  Keep whatever tells this card from its siblings: a sequence number becomes
  one number, and the specific noun stays.

  Title: Agent supervision 5/9: Parked jobs must be released on timeout
  Short name: Agent supervision 5: Parked jobs
  """

  @doc "The longest a title can be with no short name."
  def long, do: @long

  @doc "The longest a short name can be."
  def max_length, do: @long

  @doc "Whether a title wants a short name of its own."
  def long?(title), do: String.length(String.trim(to_string(title))) > @long

  @doc """
  The short name made with no model: cleaned, cut to 30 characters at a word,
  marked with `…`. Deterministic, and nil for a title that isn't long.
  """
  def systematic(title) do
    if long?(title), do: title |> DiskName.clean() |> DiskName.shorten(@target)
  end

  @doc """
  The short name of a recurring card's occurrence on `date`: the card's own,
  or its title, then the date, so a series' folders tell themselves apart. An
  earlier occurrence's date is not carried on. Saved as a person's would be,
  so `refine/1` leaves it alone.
  """
  def occurrence(%Card{} = card, %Date{} = date) do
    stamp = " " <> Date.to_iso8601(date)

    (card.short_name || card.title)
    |> String.replace(~r/\s+\d{4}-\d{2}-\d{2}\z/u, "")
    |> String.trim()
    |> DiskName.shorten(@long - String.length(stamp))
    |> Kernel.<>(stamp)
  end

  @doc """
  What a card's new values do to its short name, in the changeset that saves
  them: one typed marks it edited, one cleared hands it back, and a changed
  title makes a new one unless a person's stands.
  """
  def put(%Ecto.Changeset{} = changeset) do
    import Ecto.Changeset

    cond do
      changed?(changeset, :short_name) and is_binary(get_change(changeset, :short_name)) ->
        typed = get_change(changeset, :short_name)
        # A form left open sends back the name it was shown, which a model
        # may have replaced since: that's nobody typing anything.
        edited? = typed != systematic(get_field(changeset, :title))
        put_change(changeset, :short_name_edited, edited?)

      changed?(changeset, :short_name) ->
        changeset
        |> put_change(:short_name_edited, false)
        |> put_change(:short_name, systematic(get_field(changeset, :title)))

      get_field(changeset, :short_name_edited) ->
        changeset

      changed?(changeset, :title) ->
        put_change(changeset, :short_name, systematic(get_field(changeset, :title)))

      true ->
        changeset
    end
  end

  @doc """
  Whether saving `before` as `card` calls for a model's attempt: the card has
  a long title, nobody typed its short name, and the title or the short name
  just changed.
  """
  def stale?(before, %Card{} = card) do
    long?(card.title) and not card.short_name_edited and
      (is_nil(before) or before.title != card.title or before.short_name_edited)
  end

  @doc """
  Sets `refine/1` going, off to the side, so the caller never waits on it.
  `config :slipdock, :short_names, refine: :off | :inline` for the tests.
  """
  def refine_later(%Card{} = card) do
    case Slipdock.Config.get(:short_names, [])[:refine] do
      :off ->
        :ok

      :inline ->
        refine(card)
        :ok

      _ ->
        Slipdock.Deferred.defer(fn ->
          Task.Supervisor.start_child(Slipdock.TaskSupervisor, fn -> refine(card) end)
        end)

        :ok
    end
  end

  @doc """
  Asks the cheapest model for a better short name and saves a usable answer.
  `{:ok, name}`, or `:kept` when the card keeps what it has. Never raises.
  """
  def refine(%Card{} = card) do
    with true <- not card.short_name_edited and long?(card.title),
         user = owner(card),
         true <- AI.configured?(user) or (is_nil(user) and AI.configured?()),
         {:ok, reply} <- ask(card.title, user),
         {:ok, name} <- usable(reply) do
      save(card, name)
    else
      _ -> :kept
    end
  rescue
    error ->
      Logger.warning("short name for card #{card.id}: #{Exception.message(error)}")
      :kept
  end

  defp ask(title, user) do
    messages = [
      %{role: "system", content: @prompt},
      %{role: "user", content: "Title: " <> title <> "\nShort name:"}
    ]

    AI.complete(messages, max_tokens: 30, temperature: 0, quick: true, user: user)
  end

  @doc "A model's reply as a short name, or `:error` when it can't be one."
  def usable(reply) do
    name =
      reply
      |> to_string()
      |> String.replace(~r/[[:cntrl:]]/u, " ")
      |> String.trim()
      |> String.trim("\"")
      |> String.replace(~r/[\s.,;:!?\-]+$/u, "")

    # Asked for 30, taken up to what the column holds: this is a label, and
    # the path it makes is cleaned and bounded on its way to disk.
    if name != "" and String.length(name) <= @long, do: {:ok, name}, else: :error
  end

  # Only over the systematic name: a person may have typed one meanwhile, or
  # changed the title, and neither is the model's to undo.
  defp save(card, name) do
    query =
      from(c in Card,
        where: c.id == ^card.id and not c.short_name_edited and c.title == ^card.title
      )

    if rename(card, query, name) == 1, do: {:ok, name}, else: :kept
  end

  # The name is what the card's folder is called on disk, so saving it can
  # move everything under that folder.
  defp rename(card, query, name) do
    {count, _} =
      CardFolders.tracking(card, fn -> Repo.update_all(query, set: [short_name: name]) end)

    if count == 1, do: CardFolders.renamed(%{card | short_name: name})
    count
  end

  defp owner(%Card{board_id: board_id}) do
    with %Board{} = board <- Repo.get(Board, board_id),
         id when not is_nil(id) <- Board.root_owner_id(board) do
      Repo.get(User, id)
    else
      _ -> nil
    end
  end

  @doc """
  Asks the model again for every card still on its systematic name: what a
  run with no model left behind. Run it in the live app, where the AI calls
  work (`bin/slipdock rpc`), not from a bare `eval`. Oldest first, one at a
  time, and safe to stop and run again; a card it couldn't improve just stays.

      %{tried: 12, by_model: 9}
  """
  def improve_systematic do
    cards =
      Repo.all(
        from(c in Card,
          where: not is_nil(c.short_name) and not c.short_name_edited,
          where: fragment("char_length(trim(?)) > ?", c.title, ^@long),
          order_by: [asc: c.id]
        )
      )
      |> Enum.filter(&(&1.short_name == systematic(&1.title)))

    %{tried: length(cards), by_model: Enum.count(cards, &match?({:ok, _}, refine(&1)))}
  end

  @doc """
  Gives every long-titled card with no short name one, oldest first. Safe to
  run again and with no key: a card already named is left alone. `:ids`
  limits it to those cards, `:model` false skips the model.

      %{named: 12, by_model: 9}
  """
  def backfill(opts \\ []) do
    query =
      from(c in Card,
        where: is_nil(c.short_name) and not c.short_name_edited,
        where: fragment("char_length(trim(?)) > ?", c.title, ^@long),
        order_by: [asc: c.id]
      )

    query = if ids = opts[:ids], do: where(query, [c], c.id in ^ids), else: query
    cards = Repo.all(query)

    by_model =
      Enum.count(cards, fn card ->
        name = systematic(card.title)
        rename(card, from(c in Card, where: c.id == ^card.id), name)

        opts[:model] != false and match?({:ok, _}, refine(%{card | short_name: name}))
      end)

    %{named: length(cards), by_model: by_model}
  end
end
