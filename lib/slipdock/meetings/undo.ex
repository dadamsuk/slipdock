defmodule Slipdock.Meetings.Undo do
  @moduledoc """
  Undoing a committed capture as a whole (G9): the cards it made archived,
  the fields it changed put back, the comments it added removed, and the
  decisions pages it wrote returned to how they were (a page it made is
  archived).

  It looks first. Each change kept the version of its target right after
  the commit (`version_after`); anything that has moved since was edited by
  somebody, and undoing it would quietly throw their edit away. So
  `conflicts/1` lists those, and `undo/3` refuses while there are any —
  unless told to undo the rest (`rest: true`), which leaves the edited ones
  as they are and says so.

  One transaction, like the commit. The capture stays committed (it is never
  written again) and is stamped undone.
  """
  import Ecto.Query, warn: false

  alias Slipdock.{Boards, Meetings, Repo, Wiki}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Card, Comment}
  alias Slipdock.Meetings.{Capture, Version}
  alias Slipdock.Wiki.Page

  @doc """
  The changes whose targets were edited after the commit, as
  `%{"id", "ref", "title", "why"}`.
  """
  def conflicts(%Capture{change_set: %{"changes" => changes}}) do
    changes
    |> Enum.flat_map(fn c ->
      case moved(c) do
        nil ->
          []

        why ->
          [
            %{
              "id" => c["id"],
              "ref" => c["ref"] || c["page_code"],
              "title" => c["title"] || c["page_title"],
              "why" => why
            }
          ]
      end
    end)
  end

  def conflicts(_capture), do: []

  defp moved(%{"op" => "comment", "comment_id" => id}) do
    if Repo.exists?(from(c in Comment, where: c.id == ^id)),
      do: nil,
      else: "the comment was deleted since"
  end

  defp moved(%{"op" => "decision_entry", "page_id" => id, "version_after" => after_}) do
    case Version.current("page", id) do
      nil -> "the page was deleted since"
      ^after_ -> nil
      _ -> "the page was edited since"
    end
  end

  defp moved(%{"card_id" => id, "version_after" => after_}) when is_integer(id) do
    case Version.current("card", id) do
      nil -> "the card was deleted since"
      ^after_ -> nil
      _ -> "the card was edited since"
    end
  end

  defp moved(_), do: nil

  @doc """
  Undoes a committed capture. Options: `:rest` — undo what nobody has edited
  since and leave the rest; `:via`.

  `{:ok, capture}`, `{:error, :conflicts, [conflict]}` when something was
  edited since and `:rest` was not given, `{:error, :conflict, message}`
  when it is not committed or was undone already, or `{:error, message}`.
  """
  def undo(%Capture{} = capture, %User{} = user, opts \\ []) do
    capture = Repo.get!(Capture, capture.id)

    with :ok <- undoable(capture),
         conflicts = conflicts(capture),
         :ok <- proceed(conflicts, opts[:rest]) do
      skip = MapSet.new(conflicts, & &1["id"])
      do_undo(capture, user, skip, conflicts, opts)
    end
  end

  defp undoable(%Capture{state: "committed", undone_at: nil}), do: :ok

  defp undoable(%Capture{state: "committed"}),
    do: {:error, :conflict, "this capture was undone already"}

  defp undoable(%Capture{state: state}),
    do: {:error, :conflict, "this capture is #{state}: only a commit can be undone"}

  defp proceed([], _rest), do: :ok
  defp proceed(_conflicts, true), do: :ok
  defp proceed(conflicts, _), do: {:error, :conflicts, conflicts}

  defp do_undo(capture, user, skip, conflicts, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changes =
      capture.change_set["changes"]
      |> Enum.reject(&MapSet.member?(skip, &1["id"]))
      |> Enum.reverse()

    result =
      Repo.transaction(fn ->
        Enum.each(changes, fn change ->
          case reverse(change, capture, user) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback({change, reason})
            other -> Repo.rollback({change, other})
          end
        end)

        set =
          Map.put(capture.change_set, "undone", %{
            "at" => DateTime.to_iso8601(now),
            "by" => user.email,
            "kept" => Enum.map(conflicts, & &1["id"])
          })

        capture =
          capture
          |> Ecto.Changeset.change(undone_at: now, undone_by_id: user.id, change_set: set)
          |> Repo.update!()

        kept =
          case conflicts do
            [] ->
              ""

            list ->
              "; left #{length(list)} edited since as they are (#{Enum.map_join(list, ", ", &(&1["ref"] || &1["title"]))})"
          end

        Meetings.record(
          capture,
          "undone",
          "Undid #{length(changes)} #{if length(changes) == 1, do: "change", else: "changes"}#{kept}.",
          user: user,
          via: opts[:via]
        )

        capture
      end)

    case result do
      {:ok, capture} ->
        Meetings.broadcast(capture)
        {:ok, capture}

      {:error, {change, reason}} ->
        {:error,
         "nothing was undone: putting back #{change["ref"] || change["page_title"] || change["title"]} failed (#{inspect(reason)})"}
    end
  end

  # The opposite of each change, through the ordinary functions.
  defp reverse(%{"op" => "create_card", "card_id" => id}, capture, user) do
    case Repo.get(Card, id) do
      nil ->
        :ok

      card ->
        with {:ok, card} <- Boards.archive_card(card) do
          log(card.board_id, card.id, "archived “#{card.title}”", capture, user)
        end
    end
  end

  defp reverse(%{"op" => "update_card", "card_id" => id, "fields" => fields}, capture, user) do
    case Repo.get(Card, id) do
      nil ->
        :ok

      card ->
        attrs =
          Enum.reduce(fields, %{}, fn
            {"list", _}, acc -> acc
            {"assignee_ids", %{"from" => from}}, acc -> Map.put(acc, "assignee_ids", from)
            {field, %{"from" => from}}, acc -> Map.put(acc, field, from)
          end)

        Slipdock.Meetings.Provenance.forget(card.id, capture.id)

        with {:ok, card} <- Boards.update_card(card, attrs, by: user) do
          log(
            card.board_id,
            card.id,
            "put back #{Enum.join(Map.keys(fields) -- ["list"], ", ")} on “#{card.title}”",
            capture,
            user
          )
        end
    end
  end

  defp reverse(%{"op" => "comment", "comment_id" => id, "card_id" => card_id}, capture, user) do
    case Repo.get(Comment, id) do
      nil ->
        :ok

      comment ->
        with {:ok, _} <- Boards.delete_comment(comment) do
          card = Repo.get(Card, card_id)

          if card,
            do:
              log(card.board_id, card.id, "removed its comment on “#{card.title}”", capture, user),
            else: :ok
        end
    end
  end

  defp reverse(%{"op" => "decision_entry", "page_id" => id} = c, capture, user) do
    before = c["body_before"]

    case Repo.get(Page, id) do
      nil ->
        :ok

      page when is_nil(before) ->
        with {:ok, page} <- Wiki.archive_page(page) do
          log(page.board_id, nil, "archived “#{page.title}”", capture, user)
        end

      page ->
        with {:ok, page} <-
               Wiki.update_page(page, %{"body" => before},
                 user: user,
                 via: "meeting",
                 message: "Undoing the meeting “#{capture.title}”",
                 new_revision: true
               ) do
          log(page.board_id, nil, "put “#{page.title}” back as it was", capture, user)
        end
    end
  end

  defp reverse(_change, _capture, _user), do: :ok

  defp log(board_id, card_id, what, capture, user) do
    Boards.log_activity(
      board_id,
      card_id,
      "meeting",
      "#{what}: undoing meeting capture “#{capture.title}”, by #{user.name || user.email}"
    )

    :ok
  end
end
