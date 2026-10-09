defmodule Slipdock.AccountExport do
  @moduledoc """
  Everything one person has here, as a zip they can take away.

  The test of an export is whether somebody could leave with it and still have
  their work, so this is deliberately more than a gesture: the boards they own
  as JSON with every card, their wiki pages as the same Markdown files the
  per-board export writes, and the status updates and wiki revisions they wrote
  on *other people's* boards — theirs too, and invisible to every other export
  because those boards are not.

  Comments are deliberately absent: this app's comments carry no author at all
  (see `Slipdock.Boards.Comment`), so there is nothing to attribute.

  JSON rather than CSV for the structure, because cards have subcards, and a
  flat file loses the shape of the thing being exported.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.{Board, Card, StatusUpdate}
  alias Slipdock.Wiki.{Page, Revision}
  alias Slipdock.Repo
  alias Slipdock.Wiki.Archive

  @doc """
  Returns `{filename, zip_binary}`. `audio: true` puts the recordings of the
  meetings they sent in as well (see `Slipdock.Meetings`); without it each
  capture names its recording and leaves the bytes out, since a few meetings'
  audio can outweigh everything else in the file many times over.
  """
  @spec zip(User.t(), keyword()) :: {String.t(), binary()}
  def zip(%User{} = user, opts \\ []) do
    entries =
      [{"account.json", Jason.encode_to_iodata!(account(user), pretty: true)}] ++
        board_entries(user) ++
        page_entries(user) ++
        elsewhere_entries(user) ++
        capture_entries(user, opts) ++
        voiceprint_entries(user)

    entries = for {path, contents} <- entries, do: {String.to_charlist(path), to_binary(contents)}

    name = "slipdock-#{slug(user.email)}-#{Date.utc_today()}.zip"
    {:ok, {_, binary}} = :zip.create(String.to_charlist(name), entries, [:memory])
    {name, binary}
  end

  @doc "What the export says about the person themselves."
  def account(%User{} = user) do
    %{
      exported_at: DateTime.utc_now(),
      email: user.email,
      name: user.name,
      joined: user.inserted_at,
      last_signed_in_at: user.last_signed_in_at,
      invited: user.invited_at != nil,
      boards_owned: Enum.map(owned_boards(user), &%{id: &1.id, name: &1.name, code: &1.code}),
      note:
        "Boards are under boards/, wiki pages under pages/, anything you wrote on " <>
          "other people's boards under elsewhere/, and the meetings you sent under captures/."
    }
  end

  ## Internals

  defp owned_boards(%User{} = user) do
    Repo.all(from(b in Board, where: b.owner_id == ^user.id, order_by: [asc: b.id]))
  end

  defp board_entries(user) do
    for board <- owned_boards(user) do
      {"boards/#{slug(board.code || board.name)}-#{board.id}.json",
       Jason.encode_to_iodata!(board_json(board), pretty: true)}
    end
  end

  defp board_json(%Board{} = board) do
    board = Boards.get_board!(board.id)

    %{
      id: board.id,
      name: board.name,
      code: board.code,
      description: board.description,
      archived: board.archived_at != nil,
      lists:
        Enum.map(board.columns, fn column ->
          %{
            name: column.name,
            wip_limit: column.wip_limit,
            cards: Enum.map(column.cards, &card_json/1)
          }
        end)
    }
  end

  defp card_json(%Card{} = card) do
    %{
      id: card.id,
      title: card.title,
      description: card.description,
      priority: card.priority,
      flags: card.flags,
      start_date: card.start_date,
      due_date: card.due_date,
      completed: card.completed,
      percent_complete: card.percent_complete,
      time_spent_minutes: card.time_spent,
      time_estimate_minutes: card.time_estimate,
      time_unit: card.time_unit,
      archived: card.archived_at != nil,
      created: card.inserted_at
    }
  end

  # The same bytes the per-board wiki export writes, so one import path reads
  # both rather than two nearly-identical formats drifting apart.
  defp page_entries(user) do
    for board <- owned_boards(user),
        {path, contents} <- Archive.files(board, archived: :all) do
      {"pages/#{slug(board.code || board.name)}/#{path}", contents}
    end
  end

  # What they wrote that is attributed to them on boards they do not own —
  # invisible to every other export, because those boards belong to somebody
  # else.
  #
  # Comments are **not** here, and that is not an omission: this app's comments
  # carry no author at all (see `Slipdock.Boards.Comment`), so there is nothing
  # to attribute, nothing to export and nothing to anonymise on deletion.
  defp elsewhere_entries(user) do
    updates =
      Repo.all(
        from(s in StatusUpdate,
          where: s.user_id == ^user.id,
          order_by: [asc: s.inserted_at],
          select: %{
            card_id: s.card_id,
            page_id: s.page_id,
            health: s.health,
            body: s.body,
            written: s.inserted_at
          }
        )
      )

    revisions =
      Repo.all(
        from(r in Revision,
          join: p in Page,
          on: p.id == r.page_id,
          where: r.author_id == ^user.id,
          order_by: [asc: r.inserted_at],
          select: %{page: p.title, title: r.title, summary: r.summary, written: r.inserted_at}
        )
      )

    case {updates, revisions} do
      {[], []} ->
        []

      _ ->
        [
          {"elsewhere/written-by-you.json",
           Jason.encode_to_iodata!(%{status_updates: updates, wiki_revisions: revisions},
             pretty: true
           )}
        ]
    end
  end

  # The meetings they sent, wherever they were sent: the transcript, what
  # was found, every question and how it was settled, the record. With
  # `audio: true`, the recording beside each one that still has it.
  defp capture_entries(user, opts) do
    for capture <- Slipdock.Meetings.Export.sent_by(user),
        base = "captures/#{slug(capture.board.code || capture.board.name)}-#{capture.id}",
        entry <- capture_files(capture, base, opts) do
      entry
    end
  end

  defp capture_files(capture, base, opts) do
    json =
      {base <> ".json",
       Jason.encode_to_iodata!(
         Map.put(Slipdock.Meetings.Export.capture_json(capture), :board, capture.board.name),
         pretty: true
       )}

    audio = opts[:audio] && Slipdock.Meetings.audio_path(capture)

    if audio && File.exists?(audio),
      do: [json, {base <> Path.extname(capture.audio_key), File.read!(audio)}],
      else: [json]
  end

  # Their voiceprint (the embedding, never audio) and every consent given or
  # withdrawn, whenever there is either — whether or not voiceprints are on now.
  defp voiceprint_entries(user) do
    case Slipdock.Meetings.Voiceprints.export(user) do
      %{voiceprint: nil, consent: []} -> []
      data -> [{"voiceprint.json", Jason.encode_to_iodata!(data, pretty: true)}]
    end
  end

  defp to_binary(iodata) when is_binary(iodata), do: iodata
  defp to_binary(iodata), do: IO.iodata_to_binary(iodata)

  defp slug(value) do
    value |> to_string() |> String.downcase() |> String.replace(~r/[^\w-]+/u, "-")
  end
end
