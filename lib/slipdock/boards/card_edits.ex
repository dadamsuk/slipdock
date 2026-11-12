defmodule Slipdock.Boards.CardEdits do
  @moduledoc """
  Several changes to one card as one write (#2790): its own fields, whether
  it repeats, its snooze, what blocks it and its checklist. All of it lands
  or none of it does, so a change that fails part way (a dependency that
  would make a loop, a recurrence rule that doesn't parse) leaves the card
  as it was.

  The doors decide who may make the change and turn their arguments into an
  edit; this decides what the edit does. MCP's `update_card` is the door
  that sends them together. Over REST each part has an endpoint of its own,
  which calls its context directly.

  The card's own fields are written by the door's field write, handed in as
  `:fields`: `SlipdockWeb.API.CardWrites.update/3`, which `PATCH
  /api/cards/:id` uses as well, resolves tags and assignees and checks an
  incident's cause through the caller's token, and a context can't call the
  web layer (ARCH-1). It runs first, inside the transaction.
  """

  alias Slipdock.{Boards, Recurrence, Repo, Snooze}
  alias Slipdock.Boards.Card

  @typedoc """
  What to change; every key is optional and a missing one changes nothing.

    * `:fields`: `fn card -> {:ok, card} | error end`, the field write.
    * `:recurrence`: `:stop`, or the series' attributes as a map (string
      keys, as `Recurrence.set/3` takes them), with `"skip" => true` to let
      the next occurrence go.
    * `:snooze`: `:wake`; `{:until, until, note}` (`until` as
      `Snooze.snooze/4` takes it); or `{:note, note}` to change the note on
      the snooze the card already has.
    * `:add_blockers`, `:remove_blockers`: cards.
    * `:add_checklist`: the new items' texts, in order.
    * `:check`, `:uncheck`: the card's own checklist items.
  """
  @type edit :: %{
          optional(:fields) => (struct() -> {:ok, struct()} | tuple()) | nil,
          optional(:recurrence) => :untouched | :stop | map(),
          optional(:snooze) =>
            :untouched | :wake | {:note, String.t()} | {:until, term(), String.t() | nil},
          optional(:add_blockers) => [struct()],
          optional(:remove_blockers) => [struct()],
          optional(:add_checklist) => [String.t()],
          optional(:check) => [struct()],
          optional(:uncheck) => [struct()]
        }

  @doc """
  Applies `edit` to `card` in one transaction, in this order: the fields,
  the recurrence, the snooze, the blockers added and removed, then the
  checklist (added, ticked, unticked), logged as one activity line.

  What is already so is not a mistake: a blocker the card already has, an
  item already ticked (or unticked), waking a card that is awake.

  `opts`: `by:` the user making the change (required).

  `{:ok, card}` reloaded, or the first failing step's error as it gave it
  (`{:error, message}`, `{:error, changeset}`, or whatever `:fields` gave),
  with nothing written.
  """
  @spec edit(struct(), edit(), keyword()) :: {:ok, struct()} | tuple()
  def edit(%Card{} = card, edit, opts) do
    by = Keyword.fetch!(opts, :by)

    Repo.transaction(fn ->
      case steps(card, edit, by) do
        {:ok, card} -> Boards.Cards.get_card!(card.id)
        error -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, card} -> {:ok, card}
      {:error, error} -> error
    end
  end

  defp steps(card, edit, by) do
    with {:ok, card} <- fields(card, Map.get(edit, :fields)),
         :ok <- recurrence(card, Map.get(edit, :recurrence, :untouched), by),
         :ok <- snooze(card, Map.get(edit, :snooze, :untouched), by),
         :ok <- blockers(card, edit),
         :ok <- checklist(card, edit) do
      {:ok, card}
    end
  end

  defp fields(card, nil), do: {:ok, card}
  defp fields(card, write) when is_function(write, 1), do: write.(card)

  ## Recurrence

  defp recurrence(_card, :untouched, _by), do: :ok

  defp recurrence(card, :stop, _by) do
    Recurrence.stop(card)
    :ok
  end

  defp recurrence(card, %{} = attrs, by) do
    {skip?, attrs} = Map.pop(attrs, "skip")

    with :ok <- set_recurrence(card, attrs, by) do
      if skip? == true, do: skip_recurrence(card), else: :ok
    end
  end

  # Only `skip` given changes nothing else about the series.
  defp set_recurrence(_card, attrs, _by) when map_size(attrs) == 0, do: :ok

  defp set_recurrence(card, attrs, by) do
    case Recurrence.set(card, attrs, by) do
      {:ok, _} -> :ok
      {:error, message} when is_binary(message) -> {:error, "recurrence " <> message}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  defp skip_recurrence(card) do
    case Recurrence.skip(card) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        {:error, "card ##{card.id} doesn't repeat, so there is nothing to skip"}

      {:error, _} = error ->
        error
    end
  end

  ## Snooze

  defp snooze(_card, :untouched, _by), do: :ok

  # Waking a card that is already awake is what was asked for.
  defp snooze(card, :wake, by) do
    case Snooze.wake(Repo.reload!(card), by: by) do
      {:ok, _} -> :ok
      {:error, :not_snoozed} -> :ok
    end
  end

  # A note alone changes the note on the snooze the card already has.
  defp snooze(card, {:note, note}, by) do
    card = Repo.reload!(card)

    if Card.snoozed?(card),
      do: snooze_until(card, card.snoozed_until, note, by),
      else: {:error, "card ##{card.id} isn't snoozed: pass snoozed_until with the note"}
  end

  defp snooze(card, {:until, until, note}, by),
    do: snooze_until(Repo.reload!(card), until, note, by)

  # The snooze's other settings stay as the card has them.
  defp snooze_until(card, until, note, by) do
    opts = [
      note: note,
      notify: card.snooze_notify,
      wake_on_activity: card.snooze_wake_on_activity
    ]

    case Snooze.snooze(card, by, until, opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "snooze: " <> Snooze.error_message(reason)}
    end
  end

  ## Blockers and the checklist

  defp blockers(card, edit) do
    with :ok <- each(Map.get(edit, :add_blockers, []), &add_blocker(card, &1)),
         do:
           each(
             Map.get(edit, :remove_blockers, []),
             &Boards.Dependencies.remove_dependency(card, &1)
           )
  end

  # Ticking what is ticked (or unticking what isn't) is no change, and the
  # changes made are logged as one line.
  defp checklist(card, edit) do
    added = Map.get(edit, :add_checklist, [])
    ticked = edit |> Map.get(:check, []) |> Enum.reject(& &1.done)
    unticked = edit |> Map.get(:uncheck, []) |> Enum.filter(& &1.done)

    with :ok <- each(added, &Boards.Checklists.add_checklist_item(card, &1, log: false)),
         :ok <- each(ticked ++ unticked, &Boards.Checklists.toggle_checklist_item(&1, log: false)) do
      Boards.Checklists.log_checklist(card,
        added: length(added),
        ticked: length(ticked),
        unticked: length(unticked)
      )
    end
  end

  # Already blocked by it is what was asked for, not a mistake.
  defp add_blocker(card, blocker) do
    card = Repo.preload(card, :blocked_by)

    if Enum.any?(card.blocked_by, &(&1.id == blocker.id)),
      do: {:ok, card},
      else: Boards.Dependencies.add_dependency(card, blocker)
  end

  defp each(things, fun) do
    Enum.reduce_while(things, :ok, fn thing, :ok ->
      case fun.(thing) do
        {:error, _} = error -> {:halt, error}
        _ -> {:cont, :ok}
      end
    end)
  end
end
