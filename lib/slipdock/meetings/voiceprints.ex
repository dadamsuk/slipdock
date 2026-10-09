defmodule Slipdock.Meetings.Voiceprints do
  @moduledoc """
  Voiceprints, by consent: one more piece of evidence for who a voice in a
  meeting is (`Slipdock.Meetings.Speakers`), from people who chose to have one.

  A voiceprint is biometric data, so:

    * **Off unless an admin turns it on** (Configuration › Meetings), and only
      with an endpoint to make embeddings. While off there is no voiceprint
      page, API route or processing at all.
    * **Each person's own decision.** Every function here takes the person it
      is about as the one acting: there is no way to name somebody else, so
      nobody can enrol, read or delete another person's voiceprint.
    * **Consent recorded**: who, when, and the wording they were shown
      (`wording/0`, versioned by `wording_version/0`). Enrolling without the
      current wording's version is refused.
    * **The embedding only.** The audio it is made from is sent to the
      endpoint and never stored: a recording of their own is read from the
      upload and left there; a meeting's is the recording the capture
      already holds, under its own retention.
    * **Deleted whenever they like**, at once: later captures stop using it,
      and the consent record notes the withdrawal.
    * **In their own export** (`export/1`).

  ## The endpoint

  `POST` multipart: `file` (the recording) and, for a stretch of a meeting,
  `segments` (JSON, `[[start, end], …]` in seconds). It answers
  `{"embedding": [numbers]}`. A SpeechBrain ECAPA or pyannote embedding
  server fits.

  ## As evidence

  For a capture with its recording, each voice's own lines are embedded and
  compared (cosine similarity) with the voiceprints of the people the voice
  could be. The closest, if close enough, is evidence like any other —
  shown, weighed with the rest, and confirmable.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Slipdock.{Meetings, Repo, Settings}
  alias Slipdock.Accounts.User
  alias Slipdock.Meetings.{Capture, Utterance, Voice, Voiceprint, VoiceprintConsent}

  @wording_version "2026-10-09"
  @wording """
  I agree to Slipdock keeping a voiceprint of mine: a set of numbers made from \
  a recording of my voice, used only to suggest that it was me speaking in \
  meetings sent to boards on this server. The recording itself is not kept. \
  Anything it suggests is shown as evidence and can be corrected. I can delete \
  the voiceprint at any time, and from then on it is not used.\
  """

  # Cosine similarity: at or above `@strong` is strong evidence, at or above
  # `@medium` is medium; below that, nothing is said.
  @strong 0.75
  @medium 0.6

  @doc "The consent wording a person agrees to, word for word."
  def wording, do: @wording

  @doc "The version of `wording/0` an enrolment must quote."
  def wording_version, do: @wording_version

  @doc "Whether voiceprints are on: meeting mode on, the switch on, an endpoint set."
  def enabled? do
    s = Settings.get()

    Meetings.enabled?() and s.meetings_voiceprints == true and
      s.meetings_voiceprint_url not in [nil, ""]
  end

  @doc "The person's own voiceprint, or nil."
  def get(%User{id: id}), do: Repo.get_by(Voiceprint, user_id: id)

  @doc "Their consent record, oldest first."
  def consents(%User{id: id}) do
    Repo.all(from(c in VoiceprintConsent, where: c.user_id == ^id, order_by: [asc: c.id]))
  end

  @doc """
  Enrols the person from their own recording (`{:recording, path, filename}`)
  or from a meeting where their voice was confirmed (`{:capture, id}`).
  `consent:` must be `wording_version/0`. Replaces a voiceprint they had.
  """
  def enrol(user, source, opts \\ [])

  def enrol(%User{} = user, source, opts) do
    cond do
      not enabled?() ->
        {:error, :off}

      opts[:consent] != @wording_version ->
        {:error, :consent}

      true ->
        with {:ok, audio, segments, attrs} <- audio_for(user, source),
             {:ok, embedding} <- embed(audio, segments, opts) do
          store(user, embedding, attrs)
        end
    end
  end

  defp audio_for(_user, {:recording, path, filename}) do
    if is_binary(path) and File.regular?(path),
      do: {:ok, {path, filename || "recording"}, nil, %{source: "recording"}},
      else: {:error, "send a recording of your voice"}
  end

  defp audio_for(user, {:capture, id}) do
    with %{capture: capture, voice: voice} <- offer(user, id) do
      segments =
        Repo.all(
          from(u in Utterance,
            where: u.voice_id == ^voice.id and not is_nil(u.start_ms),
            order_by: u.position
          )
        )
        |> Enum.map(&[&1.start_ms / 1000, (&1.end_ms || &1.start_ms + 1000) / 1000])

      {:ok, {Meetings.audio_path(capture), capture.audio_filename || "recording"}, segments,
       %{source: "meeting", source_capture_id: capture.id}}
    else
      nil -> {:error, "that meeting has no confirmed voice of yours to enrol from"}
    end
  end

  defp store(user, embedding, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      Repo.delete_all(from(v in Voiceprint, where: v.user_id == ^user.id))

      Repo.insert!(%VoiceprintConsent{
        user_id: user.id,
        event: "given",
        wording_version: @wording_version,
        wording: @wording
      })

      Repo.insert!(
        struct(
          %Voiceprint{
            user_id: user.id,
            embedding: embedding,
            consent_version: @wording_version,
            consented_at: now
          },
          attrs
        )
      )
    end)
  end

  @doc """
  Deletes the person's voiceprint, at once, and records the withdrawal.
  `{:error, :none}` when they had none.
  """
  def delete(%User{} = user) do
    Repo.transaction(fn ->
      case Repo.delete_all(from(v in Voiceprint, where: v.user_id == ^user.id)) do
        {0, _} ->
          Repo.rollback(:none)

        _ ->
          Repo.insert!(%VoiceprintConsent{
            user_id: user.id,
            event: "withdrawn",
            wording_version: @wording_version,
            wording: @wording
          })

          :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  @doc """
  The meetings the person could enrol from: their voice confirmed there, the
  recording still kept, a timed line of theirs, a board they can read. None
  while they have a voiceprint, or voiceprints are off.
  """
  def offers(%User{} = user) do
    if enabled?() and is_nil(get(user)) do
      user |> offer_query() |> Repo.all() |> Enum.filter(&readable?(user, &1.capture))
    else
      []
    end
  end

  defp offer(user, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %{} = o <- user |> offer_query() |> where([c], c.id == ^id) |> limit(1) |> Repo.one(),
         true <- readable?(user, o.capture) do
      o
    else
      _ -> nil
    end
  end

  defp offer_query(user) do
    from(c in Capture,
      join: v in Voice,
      as: :voice,
      on: v.capture_id == c.id,
      where:
        v.user_id == ^user.id and v.confidence == "confirmed" and is_nil(v.merged_into_id) and
          not is_nil(c.audio_key) and c.state != "discarded",
      where:
        exists(
          from(u in Utterance,
            where: u.voice_id == parent_as(:voice).id and not is_nil(u.start_ms)
          )
        ),
      order_by: [desc: c.id],
      select: %{capture: c, voice: v}
    )
  end

  defp readable?(user, capture) do
    board = Repo.get(Slipdock.Boards.Board, capture.board_id)
    board != nil and Slipdock.Access.can_read?(Slipdock.Access.board_permission(user, board))
  end

  @doc """
  Evidence for `Slipdock.Meetings.Speakers.attribute/2`: `[{voice_id,
  item}]`, the closest voiceprint to each voice among `people` (those with
  a `user_id`), if close enough. Nothing while off, without a recording, or
  when the endpoint fails (logged: it is one signal of several).
  """
  def evidence(%Capture{} = capture, voices, people, opts \\ []) do
    ids = people |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1)
    path = Meetings.audio_path(capture)

    prints =
      if (enabled?() and ids != [] and path) && File.regular?(path),
        do: Repo.all(from(v in Voiceprint, where: v.user_id in ^ids)),
        else: []

    if prints == [] do
      []
    else
      names = Map.new(people, &{&1.user_id, &1.name})
      audio = {path, capture.audio_filename || "recording"}

      Enum.flat_map(voices, fn voice ->
        with [_ | _] = segments <- voice_segments(voice),
             {:ok, embedding} <- embed(audio, segments, opts),
             {print, score} <- closest(embedding, prints),
             strength when strength != nil <- strength(score) do
          name = names[print.user_id]

          [
            {voice.id,
             %{
               "kind" => "voiceprint",
               "person" => "user:#{print.user_id}",
               "name" => name,
               "strength" => strength,
               "score" => Float.round(score, 2),
               "detail" =>
                 "sounds like #{name}'s voiceprint (similarity #{:erlang.float_to_binary(score, decimals: 2)})"
             }}
          ]
        else
          {:error, reason} ->
            Logger.warning("voiceprint evidence for capture #{capture.id}: #{reason}")
            []

          _ ->
            []
        end
      end)
    end
  end

  defp voice_segments(voice) do
    Repo.all(
      from(u in Utterance,
        where: u.voice_id == ^voice.id and not is_nil(u.start_ms),
        order_by: u.position
      )
    )
    |> Enum.map(&[&1.start_ms / 1000, (&1.end_ms || &1.start_ms + 1000) / 1000])
  end

  defp closest(embedding, prints) do
    prints
    |> Enum.map(&{&1, cosine(embedding, &1.embedding)})
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
  end

  defp strength(score) when score >= @strong, do: "strong"
  defp strength(score) when score >= @medium, do: "medium"
  defp strength(_), do: nil

  @doc false
  def cosine(a, b) when length(a) == length(b) and a != [] do
    dot = Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)

    norm =
      :math.sqrt(Enum.reduce(a, 0.0, &(&1 * &1 + &2))) *
        :math.sqrt(Enum.reduce(b, 0.0, &(&1 * &1 + &2)))

    if norm == 0.0, do: 0.0, else: dot / norm
  end

  def cosine(_, _), do: 0.0

  defp embed({path, filename}, segments, opts) do
    s = Settings.get()

    req =
      Req.new(
        [base_url: s.meetings_voiceprint_url, receive_timeout: 300_000, retry: false] ++
          Keyword.get(Slipdock.Config.get(:meetings, []), :voiceprint_req_options, []) ++
          (opts[:req] || [])
      )

    form =
      [file: {File.read!(path), filename: filename}] ++
        if(segments, do: [segments: Jason.encode!(segments)], else: [])

    case Req.post(req, form_multipart: form) do
      {:ok, %Req.Response{status: 200, body: %{"embedding" => [_ | _] = e}}} ->
        if Enum.all?(e, &is_number/1),
          do: {:ok, Enum.map(e, &(&1 * 1.0))},
          else: {:error, "the voiceprint endpoint answered something that isn't an embedding"}

      {:ok, %Req.Response{status: 200}} ->
        {:error, "the voiceprint endpoint answered something that isn't an embedding"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "the voiceprint endpoint said #{status}"}

      {:error, e} ->
        {:error, "couldn't reach the voiceprint endpoint (#{Exception.message(e)})"}
    end
  end

  @doc "What the person's export says about their voiceprint and consent."
  def export(%User{} = user) do
    print = get(user)

    %{
      voiceprint:
        print &&
          %{
            source: print.source,
            source_capture_id: print.source_capture_id,
            consent_version: print.consent_version,
            consented_at: print.consented_at,
            embedding: print.embedding
          },
      consent:
        Enum.map(consents(user), fn c ->
          %{
            event: c.event,
            at: c.inserted_at,
            wording_version: c.wording_version,
            wording: c.wording
          }
        end)
    }
  end
end
