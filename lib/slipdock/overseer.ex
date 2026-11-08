defmodule Slipdock.Overseer do
  @moduledoc """
  The overseer (#2068): an eye on outcomes, not on the runners' line-by-line
  work, that says "a person should look now" rarely and accurately. Off
  until the root board's owner turns it on (`put_settings/3`).

  Two layers:

    1. **The watch** (`Slipdock.Overseer.Watch`), on the server, costing no
       tokens: checks over what the server already holds — looping, waiting
       while idle, slow, idle capacity, no way forward — run every minute
       by the automation scheduler (`tick/1`). Each condition fires once
       (a warning alert on the root board, an email to the owner), clears
       itself when it ends, and says why and what to do. Open ones head the
       owner's *Waiting on you* (`Slipdock.Work.waiting_on_me/2`).
    2. **The pass** (`Slipdock.Overseer.Pass`): a runner job of kind
       `overseer` on the owner's own machine, reading only the watch's
       conditions and the pulse, answering with a digest kept as a status
       update on the overseer's card. Paced by `Slipdock.Overseer.Pacing`:
       every `min_minutes` (10) while cards are active, longer when little
       or nothing is in flight.

  The overseer's card is a completed card titled *Overseer* in the root
  board's done list, made when it is first turned on: runner jobs hang off
  a card, and its status updates are the digests.
  """

  import Ecto.Query

  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Overseer.{Pass, Settings, Watch}
  alias Slipdock.Repo

  require Logger

  @kind "overseer"

  @doc "The runner job kind of a pass."
  def kind, do: @kind

  @doc "The root board of `board`'s tree."
  def root(%Board{root_id: nil} = board), do: board
  def root(%Board{root_id: id}), do: Repo.get!(Board, id)

  @doc "The settings of `board`'s tree: the root's row, or the defaults (unsaved)."
  def settings(%Board{} = board) do
    root = root(board)
    Repo.get_by(Settings, board_id: root.id) || %Settings{board_id: root.id}
  end

  @doc """
  Changes the settings of `board`'s tree (on its root): `enabled`, `pool`,
  `min_minutes`, `max_minutes`, `idle_minutes`, `email`. Turning it on makes
  its card and brings the next pass to now. `{:ok, settings}` or
  `{:error, changeset}`.
  """
  def put_settings(%Board{} = board, attrs) do
    root = root(board)
    before = settings(root)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    before
    |> Settings.changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, %Settings{enabled: true} = settings} when before.enabled != true ->
        with {:ok, card} <- ensure_card(root, settings) do
          settings
          |> Ecto.Changeset.change(card_id: card.id, next_run_at: DateTime.utc_now(:second))
          |> Repo.update()
        end

      other ->
        other
    end
  end

  @doc """
  The overseer's card on `root`: the one the settings name if it is still
  there, else a new completed card titled *Overseer* in the root's done
  list (or its last list).
  """
  def ensure_card(%Board{} = root, %Settings{} = settings) do
    case settings.card_id && Repo.get(Card, settings.card_id) do
      %Card{archived_at: nil} = card ->
        {:ok, card}

      _ ->
        root |> make_card() |> tap(&remember_card(&1, settings))
    end
  end

  defp remember_card({:ok, card}, %Settings{id: id}) when is_integer(id),
    do: Repo.update_all(from(s in Settings, where: s.id == ^id), set: [card_id: card.id])

  defp remember_card(_result, _settings), do: :ok

  defp make_card(root) do
    root = Boards.get_board!(root.id)
    column = Enum.find(root.columns, &(&1.category == "done")) || List.last(root.columns)

    Boards.create_card(
      column,
      %{
        "title" => "Overseer",
        "description" =>
          "The overseer's card (#2068): its runner jobs hang off it, and its status " <>
            "updates are the overseer's digests. Its settings and conditions are under " <>
            "Automations → Overseer, `slipdock overseer` and `GET /api/boards/:board/overseer`.",
        "completed" => true
      },
      actor: Slipdock.Actor.automation()
    )
  end

  @doc """
  Where the overseer of `board`'s tree stands: its settings, the open
  conditions, those cleared in the last day, the last digest, the next
  pass and the open one.
  """
  def state(%Board{} = board, now \\ DateTime.utc_now()) do
    root = root(board)
    settings = settings(root)

    %{
      board: root,
      settings: settings,
      conditions: root.id |> Watch.open_conditions() |> Repo.preload(:card),
      cleared: Watch.cleared_since(root.id, DateTime.add(now, -86_400, :second)),
      open_job: Pass.open_job(root.id)
    }
  end

  @doc "The open conditions on the trees of `root_ids`, for *Waiting on you*."
  def open_conditions(root_ids), do: Watch.open_conditions(root_ids)

  @doc """
  The minute's work, from the automation scheduler: for every root board
  with the overseer on, the watch, then a pass if one is due. One board's
  failure doesn't stop the rest.
  """
  def tick(now \\ DateTime.utc_now()) do
    from(s in Settings, where: s.enabled, preload: :board)
    |> Repo.all()
    |> Enum.each(fn settings ->
      try do
        Watch.run(settings.board, settings, now)
        Pass.maybe_queue(settings.board, Repo.reload!(settings), now)
      rescue
        error ->
          Logger.error(
            "Overseer on board #{settings.board_id} failed: " <> Exception.message(error)
          )
      end
    end)
  end

  @doc "After a runner job ends: a pass's digest (`Slipdock.Overseer.Pass.finished/1`)."
  def job_finished(%{kind: @kind} = job), do: Pass.finished(job)
  def job_finished(_job), do: :ok
end
