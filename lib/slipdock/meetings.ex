defmodule Slipdock.Meetings do
  @moduledoc """
  Meeting capture: a meeting's audio and/or transcript turned into proposed
  decisions, actions and card changes, which a person reviews and commits in
  one undoable write. The requirements are the PRD on the board's wiki
  (W-87, "Meeting capture: PRD").

  ## Meeting mode

  Off unless an admin turns it on (`meetings_enabled`). While it is off there
  is nothing of it anywhere: no routes, no menu entries, no MCP tools, no guide
  section, and the CLI's `capture` commands say "meeting mode is off on this
  server". Turning it off deletes nothing; turning it back on shows every
  capture again.

  While it is on, `meetings_visibility` decides where it shows:

    * `:used_only` (the default) — a board's Meetings tab appears once that
      board has had a capture; until then there is one entry in the board's
      menu to start one.
    * `:every_board` — the tab is on every board.

  And `meetings_hideable` lets each person put it out of sight for themselves
  (Account › Settings › Display). That is a display preference: the API and
  the CLI answer the same either way.

  Whether a board has had a capture is a column on the board
  (`meetings_used_at`), so the board page decides from the row it already has
  and a board that never had one pays nothing for meeting mode existing.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards
  alias Slipdock.Boards.Board
  alias Slipdock.Meetings.{Capture, Event, Finding, Question, Utterance}
  alias Slipdock.{Quota, Repo, Settings}

  @off_message "meeting mode is off on this server"

  @doc "What every refusal says while meeting mode is off."
  def off_message, do: @off_message

  @doc "Whether an admin has turned meeting mode on."
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get().meetings_enabled == true

  @doc "`:used_only` or `:every_board`: where the Meetings tab shows."
  @spec visibility() :: :used_only | :every_board
  def visibility, do: Settings.get().meetings_visibility || :used_only

  @doc "Whether people may hide meeting capture for themselves."
  @spec hideable?() :: boolean()
  def hideable?, do: Settings.get().meetings_hideable != false

  @doc """
  Whether this person sees meeting capture at all: it is on, and they have
  not hidden it (or are not allowed to).
  """
  @spec available?(User.t() | nil) :: boolean()
  def available?(%User{} = user), do: enabled?() and not hidden_by?(user)
  def available?(_), do: false

  @doc "Whether this person has hidden meeting capture, and is allowed to."
  @spec hidden_by?(User.t() | nil) :: boolean()
  def hidden_by?(%User{hide_meetings: true}), do: hideable?()
  def hidden_by?(_), do: false

  @doc """
  What this person sees of meeting capture on this board:

    * `:tab` — the Meetings tab, in the view menu beside the wiki;
    * `:menu` — only an entry in the board's menu to start a first capture;
    * `:none` — nothing at all.
  """
  @spec presence(User.t() | nil, Board.t()) :: :tab | :menu | :none
  def presence(user, %Board{} = board) do
    cond do
      not available?(user) -> :none
      visibility() == :every_board -> :tab
      board.meetings_used_at != nil -> :tab
      true -> :menu
    end
  end

  @doc """
  The mode as the API reports it: whether it is on, and how it shows. What a
  client needs before it offers to send anything.
  """
  @spec mode(User.t() | nil) :: map()
  def mode(user) do
    settings = Settings.get()

    %{
      enabled: settings.meetings_enabled == true,
      visibility: settings.meetings_visibility,
      hideable: settings.meetings_hideable != false,
      hidden: hidden_by?(user),
      accepts: %{
        transcripts: settings.meetings_accept_transcripts,
        audio: settings.meetings_accept_audio,
        findings: settings.meetings_accept_findings
      },
      # Whether a person may enrol a voiceprint of their own
      # (see `Slipdock.Meetings.Voiceprints`).
      voiceprints: Slipdock.Meetings.Voiceprints.enabled?()
    }
  end

  @doc """
  Stamps the board as having had a capture, which is what puts its Meetings
  tab up under `:used_only`. Only the first stamp counts.
  """
  @spec mark_used(Board.t()) :: Board.t()
  def mark_used(%Board{meetings_used_at: nil} = board) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_, _} =
      Slipdock.Repo.update_all(
        from(b in Board, where: b.id == ^board.id and is_nil(b.meetings_used_at)),
        set: [meetings_used_at: now]
      )

    %{board | meetings_used_at: now}
  end

  def mark_used(%Board{} = board), do: board

  @doc """
  Where a capture sent by this person goes before anyone reviews it — shown
  before anything is sent (the disclosure on the New capture page):

    * `:reading` — `%{host:, model:, own?:}`, the model that reads the
      transcript, on the person's own AI settings (or the server's shared
      key), or nil when they have none and nothing can be read;
    * `:transcription` — the same for recordings, or nil when this server
      transcribes nothing (the recording is then stored for replay only).
  """
  def destinations(%User{} = user) do
    reading =
      case Slipdock.AI.provider(user: user) do
        {:ok, p} -> %{host: host(p.base_url), model: p.model, own?: Slipdock.AI.Keys.own?(user)}
        {:error, _} -> nil
      end

    transcription =
      case Slipdock.Meetings.Transcriber.target(user) do
        {:ok, t} -> %{host: host(t.base_url), model: t.model, own?: t.own?}
        _ -> nil
      end

    %{reading: reading, transcription: transcription}
  end

  defp host(url) do
    case URI.parse(url || "") do
      %URI{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  ## Captures -----------------------------------------------------------------

  @doc """
  The fingerprint a meeting is known by on a board (G10): SHA-256 of the
  transcript's text, normalised so that the same words with different line
  endings, a byte-order mark or trailing spaces are the same meeting, and/or
  of the audio's bytes. Sending the same transcript or recording to a board
  again finds the first capture rather than making a second.

  Takes `transcript:` (text) and `audio:` (a path to the bytes); at least one.
  """
  @spec fingerprint(keyword()) :: String.t()
  def fingerprint(parts) do
    pieces =
      [
        parts[:transcript] && "t:" <> sha256(normalise_transcript(parts[:transcript])),
        parts[:audio] && "a:" <> sha256_file(parts[:audio])
      ]
      |> Enum.reject(&is_nil/1)

    case pieces do
      [] -> raise ArgumentError, "a fingerprint needs a transcript or audio"
      pieces -> Enum.join(pieces, "+")
    end
  end

  @doc """
  A transcript's text, reduced to what makes it the same meeting: Unicode
  NFC, no byte-order mark, `\n` line endings, each line's surrounding blanks
  and the blank lines gone. Only for the fingerprint — the stored transcript
  is always the bytes as received.
  """
  def normalise_transcript(text) when is_binary(text) do
    text
    |> String.replace_prefix("\uFEFF", "")
    |> :unicode.characters_to_nfc_binary()
    |> String.replace(~r/\r\n?/, "\n")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp sha256_file(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "The capture on this board with this fingerprint, or nil."
  def find_by_fingerprint(%Board{id: board_id}, fingerprint),
    do: Repo.get_by(Capture, board_id: board_id, fingerprint: fingerprint)

  @doc """
  Records a meeting sent to a board.

  `attrs` holds the capture's own fields (`title`, `started_at`, `attendees`,
  `fingerprint`, `source`, `sources`, `transcript`, …). Options:

    * `:utterances` — the transcript's lines, as maps (`text`, `speaker`,
      `start_ms`, `end_ms`, `words`), in order; they get positions and line
      ids `L1`, `L2`, …
    * `:audio` — `%{path:, filename:, content_type:}`: the recording, copied
      into the uploads directory and counted against the board owner's file
      storage before a byte is copied.

  Returns `{:ok, capture}`, or `{:existing, capture}` when this board already
  has a capture with the same fingerprint (G10) — nothing new is stored then.
  The board is stamped as having had a capture (`mark_used/1`).
  """
  @spec create_capture(Board.t(), User.t(), map(), keyword()) ::
          {:ok, Capture.t()} | {:existing, Capture.t()} | {:error, term()}
  def create_capture(%Board{} = board, %User{} = owner, attrs, opts \\ []) do
    fingerprint = attrs[:fingerprint] || attrs["fingerprint"]

    case fingerprint && find_by_fingerprint(board, fingerprint) do
      %Capture{} = existing ->
        {:existing, existing}

      nil ->
        insert_capture(board, owner, attrs, opts)
    end
  end

  defp insert_capture(board, owner, attrs, opts) do
    audio = opts[:audio]

    changeset =
      %Capture{board_id: board.id, owner_id: owner.id}
      |> Capture.create_changeset(attrs)
      |> put_audio_fields(audio)
      |> Quota.enforce(board, :storage, want: (audio && audio_size(audio)) || 0)

    result =
      with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
           :ok <- store_audio(changeset, audio) do
        Repo.transaction(fn ->
          case Repo.insert(changeset) do
            {:ok, capture} ->
              :ok = insert_utterances(capture, opts[:utterances] || [])
              record(capture, "received", received_message(capture), user: owner)

              # Stored audio is on the ledger from the moment it is kept.
              if capture.audio_key do
                Slipdock.Meetings.Usage.record(capture, %{
                  kind: :storage,
                  step: "ingest",
                  bytes: capture.audio_size
                })
              end

              capture

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
      end

    case result do
      {:ok, capture} ->
        mark_used(board)
        {:ok, capture}

      {:error, %Ecto.Changeset{} = cs} ->
        # The file went down before the row: take it back up.
        remove_audio_file(Ecto.Changeset.get_field(changeset, :audio_key))

        # Two uploads of the same meeting at once: the second finds the first.
        fingerprint = Ecto.Changeset.get_field(changeset, :fingerprint)

        case fingerprint && cs.errors[:board_id] && find_by_fingerprint(board, fingerprint) do
          %Capture{} = existing -> {:existing, existing}
          _ -> {:error, cs}
        end

      {:error, reason} ->
        remove_audio_file(Ecto.Changeset.get_field(changeset, :audio_key))
        {:error, reason}
    end
  end

  defp received_message(%Capture{} = capture) do
    parts =
      [
        capture.transcript && "a transcript",
        capture.audio_key && "a recording",
        get_in(capture.sources, ["findings", "count"]) && "findings from an agent"
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    "Received #{Enum.join(parts, " and ")} for “#{capture.title}”."
  end

  defp audio_size(%{size: size}) when is_integer(size), do: size
  defp audio_size(%{path: path}), do: File.stat!(path).size

  defp put_audio_fields(changeset, nil), do: changeset

  defp put_audio_fields(changeset, %{path: _} = audio) do
    ext = audio |> Map.get(:filename, "") |> Path.extname() |> String.downcase()
    ext = if Regex.match?(~r/^\.[a-z0-9]{1,8}$/, ext), do: ext, else: ""

    Ecto.Changeset.change(changeset,
      audio_key: Path.join("captures", Ecto.UUID.generate() <> ext),
      audio_filename: audio[:filename],
      audio_content_type: audio[:content_type],
      audio_size: audio_size(audio),
      audio_duration_ms: audio[:duration_ms]
    )
  end

  defp store_audio(_changeset, nil), do: :ok

  defp store_audio(changeset, %{path: source}) do
    dest = Path.join(Boards.uploads_dir(), Ecto.Changeset.get_field(changeset, :audio_key))

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _} <- File.copy(source, dest) do
      :ok
    else
      {:error, reason} ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :audio_key,
           "could not be stored: #{inspect(reason)}"
         )}
    end
  end

  @doc "Where a capture's audio is on disk, or nil when it has none (or no longer has it)."
  def audio_path(%Capture{audio_key: nil}), do: nil
  def audio_path(%Capture{audio_key: key}), do: Path.join(Boards.uploads_dir(), key)

  defp remove_audio_file(nil), do: :ok
  defp remove_audio_file(key), do: Boards.remove_files([key])

  @doc """
  Replaces a capture's transcript lines: what ingest parsed, or what
  transcription produced. Each line gets its position and an `L<n>` id.
  """
  def put_utterances(%Capture{} = capture, lines) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Repo.delete_all(from(u in Utterance, where: u.capture_id == ^capture.id))
        insert_utterances(capture, lines)
      end)

    :ok
  end

  defp insert_utterances(_capture, []), do: :ok

  defp insert_utterances(%Capture{id: id}, lines) do
    rows =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, n} ->
        %{
          capture_id: id,
          position: n,
          line_id: "L#{n}",
          text: line[:text] || line["text"] || "",
          speaker: line[:speaker] || line["speaker"],
          start_ms: line[:start_ms] || line["start_ms"],
          end_ms: line[:end_ms] || line["end_ms"],
          words: line[:words] || line["words"],
          voice_unsure: false
        }
      end)

    rows
    |> Enum.chunk_every(1000)
    |> Enum.each(&Repo.insert_all(Utterance, &1))

    :ok
  end

  @doc "A board's lists, in order: where a new card from a meeting can go."
  def lists(board_id) do
    Repo.all(
      from(c in Slipdock.Boards.Column,
        where: c.board_id == ^board_id,
        order_by: [asc: c.position]
      )
    )
  end

  @doc "A capture, or nil."
  def get_capture(id), do: Repo.get(Capture, id)

  @doc "A capture, or raises."
  def get_capture!(id), do: Repo.get!(Capture, id)

  @doc """
  A capture with everything a review shows: its lines, voices, findings
  (with their evidence) and questions, and its record.
  """
  def load(%Capture{} = capture) do
    Repo.preload(
      capture,
      [
        :owner,
        :committed_by,
        :discarded_by,
        :utterances,
        :voices,
        questions: [:answered_by],
        findings: [:evidence, :edited_by, :added_by],
        events: [:user]
      ],
      force: true
    )
  end

  @doc "A board's captures, newest first."
  def list_captures(%Board{id: board_id}, opts \\ []) do
    from(c in Capture,
      where: c.board_id == ^board_id,
      order_by: [desc: c.inserted_at, desc: c.id],
      preload: [:owner, :committed_by, :discarded_by]
    )
    |> then(fn q -> if opts[:limit], do: limit(q, ^opts[:limit]), else: q end)
    |> Repo.all()
  end

  @doc """
  Moves a capture to another state (see `Slipdock.Meetings.Capture` for the
  ones it may go to), writing a line on its record. Options: `:reason`
  (stored as `state_reason`, and the record's message when no `:message` is
  given), `:message`, `:user`, `:via`, `:changes` (more fields to set in the
  same write).
  """
  def transition(%Capture{} = capture, to, opts \\ []) do
    extra =
      Map.merge(
        %{state_reason: opts[:reason]},
        Map.new(opts[:changes] || %{})
      )

    with {:ok, updated} <- capture |> Capture.transition(to, extra) |> Repo.update() do
      record(updated, "state", opts[:message] || state_message(to, opts[:reason]),
        user: opts[:user],
        via: opts[:via],
        data: %{"from" => capture.state, "to" => to}
      )

      broadcast(updated)
      {:ok, updated}
    end
  end

  defp state_message("reading", _), do: "Reading the meeting."
  defp state_message("needs_review", _), do: "Read. Some things need a person to settle."
  defp state_message("ready", _), do: "Ready to commit."
  defp state_message("committed", _), do: "Committed."
  defp state_message("discarded", _), do: "Discarded: nothing was written."
  defp state_message("failed", reason), do: "Failed: #{reason || "no reason given"}."
  defp state_message(to, _), do: "Now #{to}."

  @doc """
  Writes a line on a capture's record. Options: `:user`, `:via` (`web`,
  `api`, `agent`), `:data`.
  """
  def record(%Capture{id: id}, kind, message, opts \\ []) do
    Repo.insert!(%Event{
      capture_id: id,
      kind: kind,
      message: message,
      user_id: opts[:user] && opts[:user].id,
      via: opts[:via] && to_string(opts[:via]),
      data: opts[:data] || %{},
      inserted_at: DateTime.utc_now()
    })
  end

  @doc """
  Deletes a capture and everything hanging off it, then its audio file, which
  frees the storage it was counted against. What it committed stays on the
  board, provenance and all (G11).
  """
  def delete_capture(%Capture{} = capture) do
    with {:ok, deleted} <- Repo.delete(capture) do
      remove_audio_file(capture.audio_key)
      broadcast(deleted)
      {:ok, deleted}
    end
  end

  @doc """
  The audio keys of every capture on the boards `boards` selects, for
  `Slipdock.Boards.file_keys/1`: the cascade takes the rows, nothing takes
  the bytes.
  """
  def audio_keys(%Ecto.Query{} = boards) do
    ids = from(b in subquery(boards), select: b.id)

    Repo.all(
      from(c in Capture,
        where: c.board_id in subquery(ids) and not is_nil(c.audio_key),
        select: c.audio_key
      )
    )
  end

  @doc "The audio keys of the captures this person sent, on any board."
  def audio_keys_of_owner(%User{id: user_id}) do
    Repo.all(
      from(c in Capture,
        where: c.owner_id == ^user_id and not is_nil(c.audio_key),
        select: c.audio_key
      )
    )
  end

  @doc """
  Gathers what the board already knows about the meeting
  (`Slipdock.Meetings.Context`) and keeps it on the capture, with the
  candidate count and what the search cost in `stats["context"]`.
  """
  def gather_context(%Capture{} = capture) do
    context = Slipdock.Meetings.Context.gather(capture)

    capture
    |> Ecto.Changeset.change(
      context: context,
      stats: Map.put(capture.stats || %{}, "context", context["stats"])
    )
    |> Repo.update()
  end

  @doc """
  Reads the meeting (`Slipdock.Meetings.Reader`): two readings and any agent
  findings, kept on the capture as they came back, before verification.
  """
  def read_meeting(%Capture{} = capture, opts \\ []) do
    with {:ok, readings} <- Slipdock.Meetings.Reader.read(capture, opts) do
      capture |> Ecto.Changeset.change(readings: readings) |> Repo.update()
    end
  end

  @doc """
  Verifies the readings (`Slipdock.Meetings.Verify`): findings, evidence and
  questions as a person will review them.
  """
  def verify(%Capture{} = capture), do: Slipdock.Meetings.Verify.verify(capture)

  @doc """
  Decides against a capture: nothing from it is written, ever, and the
  record stays (who discarded it, and when). A committed capture cannot be
  discarded — undo it instead.
  """
  def discard(%Capture{} = capture, %User{} = user, opts \\ []) do
    # Held, so a discard and a commit arriving together can't both win.
    Repo.transaction(fn ->
      capture = Repo.one!(from(c in Capture, where: c.id == ^capture.id, lock: "FOR UPDATE"))

      if capture.state in ~w(committed discarded) do
        Repo.rollback({:conflict, "this capture is #{capture.state} already"})
      else
        case transition(capture, "discarded",
               user: user,
               via: opts[:via],
               changes: %{
                 discarded_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 discarded_by_id: user.id
               }
             ) do
          {:ok, capture} -> capture
          {:error, cs} -> Repo.rollback(cs)
        end
      end
    end)
    |> case do
      {:ok, capture} -> {:ok, capture}
      {:error, {:conflict, message}} -> {:error, :conflict, message}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  For a board's inbox: each capture's kept findings and open questions,
  counted in two queries for the lot, as `%{id => %{findings:, open:}}`.
  """
  def counts(captures) do
    ids = Enum.map(captures, & &1.id)

    findings =
      Repo.all(
        from(f in Finding,
          where: f.capture_id in ^ids and f.status == "kept",
          group_by: f.capture_id,
          select: {f.capture_id, count(f.id)}
        )
      )
      |> Map.new()

    open =
      Repo.all(
        from(q in Question,
          where: q.capture_id in ^ids and q.status == "open" and q.blocking,
          group_by: q.capture_id,
          select: {q.capture_id, count(q.id)}
        )
      )
      |> Map.new()

    Map.new(ids, &{&1, %{findings: Map.get(findings, &1, 0), open: Map.get(open, &1, 0)}})
  end

  @doc "The open blocking questions on a capture."
  def open_questions(%Capture{id: id}) do
    Repo.all(
      from(q in Question,
        where: q.capture_id == ^id and q.status == "open" and q.blocking,
        order_by: [asc: q.id]
      )
    )
  end

  @doc "A capture's kept findings, in order."
  def kept_findings(%Capture{id: id}) do
    Repo.all(
      from(f in Finding,
        where: f.capture_id == ^id and f.status == "kept",
        order_by: [asc: f.position, asc: f.id],
        preload: [:evidence]
      )
    )
  end

  ## PubSub -------------------------------------------------------------------

  @doc "Subscribes to one capture's changes: `{:capture_changed, id}`."
  def subscribe(%Capture{id: id}), do: subscribe_capture(id)

  def subscribe_capture(id),
    do: Phoenix.PubSub.subscribe(Slipdock.PubSub, "capture:#{id}")

  @doc "Subscribes to a board's captures: `{:captures_changed, board_id}`."
  def subscribe_board(board_id),
    do: Phoenix.PubSub.subscribe(Slipdock.PubSub, "captures:#{board_id}")

  @doc "Tells whoever is watching that a capture changed."
  def broadcast(%Capture{id: id, board_id: board_id}) do
    Phoenix.PubSub.broadcast(Slipdock.PubSub, "capture:#{id}", {:capture_changed, id})

    Phoenix.PubSub.broadcast(
      Slipdock.PubSub,
      "captures:#{board_id}",
      {:captures_changed, board_id}
    )
  end
end
