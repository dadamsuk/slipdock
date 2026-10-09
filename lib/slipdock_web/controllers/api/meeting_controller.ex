defmodule SlipdockWeb.API.MeetingController do
  @moduledoc """
  Meeting capture over the JSON API (see `Slipdock.Meetings`). Every route is
  behind the `:meetings` pipeline, so none of them exists while meeting mode
  is off.
  """
  use SlipdockWeb, :controller

  alias Slipdock.Meetings
  alias Slipdock.Meetings.Ingest
  alias SlipdockWeb.API.{Authorize, MeetingJSON}

  action_fallback SlipdockWeb.API.FallbackController

  @doc "Whether meeting mode is on, and how it shows: what a client asks first."
  def mode(conn, _params) do
    json(conn, %{meetings: Meetings.mode(conn.assigns.current_user)})
  end

  @doc "The findings format an agent sends with a capture, as JSON Schema."
  def schema(conn, _params), do: json(conn, Slipdock.Meetings.Schema.json_schema())

  @doc """
  Sends a meeting to a board: multipart with any of `audio`, `transcript`,
  `findings` and `ics` as files, or JSON with `transcript`, `findings` and
  `ics` as text; plus `title`, `when`, `attendees`, `format`, `parent`,
  `retention`. 201 with the capture, or 200 and `existing: true` when this
  board already has a capture of the same meeting.
  """
  def create(conn, %{"board" => ref} = params) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :write) do
      result =
        Ingest.ingest(board, conn.assigns.current_user, %{
          transcript: file(params["transcript"]),
          audio: audio(params["audio"]),
          findings: file(params["findings"]),
          ics: file(params["ics"]),
          title: params["title"],
          started_at: params["when"] || params["started_at"],
          attendees: params["attendees"],
          format: blank(params["format"]),
          context: %{parent: params["parent"]},
          retention: blank(params["retention"]),
          source:
            if(params["source"] in ["agent", "connector"], do: params["source"], else: "upload"),
          via: "api"
        })

      case result do
        {:ok, capture} ->
          conn
          |> put_status(:created)
          |> json(%{capture: show_json(conn, capture), existing: false})

        {:existing, capture} ->
          json(conn, %{capture: show_json(conn, capture), existing: true})

        {:error, {:invalid, message}} ->
          {:error, :unprocessable_entity, message}

        {:error, other} ->
          {:error, other}
      end
    end
  end

  @doc "A capture: its state, lines, findings, questions and record."
  def show(conn, %{"id" => id}) do
    with {:ok, capture} <- fetch(conn, id, :read) do
      json(conn, %{capture: show_json(conn, capture)})
    end
  end

  @doc "Carries a failed capture on from where it stopped."
  def retry(conn, %{"id" => id}) do
    with {:ok, capture} <- fetch(conn, id, :write) do
      case Slipdock.Meetings.Pipeline.retry(capture, conn.assigns.current_user, via: "api") do
        {:error, message} -> {:error, :conflict, message}
        capture -> json(conn, %{capture: show_json(conn, capture)})
      end
    end
  end

  @doc """
  What committing would write: the change set, its digest (send it back with
  the commit to be sure the same thing is written), and what has moved since
  the review read it.
  """
  def preview(conn, %{"id" => id}) do
    with {:ok, capture} <- fetch(conn, id, :read) do
      set = Slipdock.Meetings.Commit.build(capture)
      json(conn, %{preview: set, stale: Slipdock.Meetings.Commit.stale(set)})
    end
  end

  @doc """
  Commits a capture: one write, all or nothing. `preview` (optional) is the
  digest of the preview the caller saw; if the change set is no longer that
  one, nothing is written and the answer is 409.
  """
  def commit(conn, %{"id" => id} = params) do
    with {:ok, capture} <- fetch(conn, id, :write) do
      case Slipdock.Meetings.Commit.commit(capture, conn.assigns.current_user,
             digest: blank(params["preview"]),
             via: if(params["via"] == "agent", do: "agent", else: "api")
           ) do
        {:ok, capture} ->
          json(conn, %{capture: show_json(conn, capture)})

        {:error, :stale, targets} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error:
              "conflict: changed since the review read them — " <>
                Enum.map_join(targets, "; ", &"#{&1["ref"] || &1["title"]} (#{&1["why"]})"),
            stale: targets
          })

        {:error, :conflict, message} ->
          {:error, :conflict, message}

        {:error, :forbidden, message} ->
          {:error, :forbidden, message}

        {:error, message} ->
          {:error, :unprocessable_entity, message}
      end
    end
  end

  @doc """
  Undoes a committed capture as a whole. When something it wrote has been
  edited since, nothing is undone and the answer is 409 listing them;
  `rest: true` undoes everything else and leaves those as they are.
  """
  def undo(conn, %{"id" => id} = params) do
    with {:ok, capture} <- fetch(conn, id, :write) do
      case Slipdock.Meetings.Undo.undo(capture, conn.assigns.current_user,
             rest: params["rest"] in [true, "true", "1"],
             via: "api"
           ) do
        {:ok, capture} ->
          json(conn, %{capture: show_json(conn, capture)})

        {:error, :conflicts, conflicts} ->
          conn
          |> put_status(:conflict)
          |> json(%{
            error:
              "conflict: edited since the commit — " <>
                Enum.map_join(conflicts, "; ", &"#{&1["ref"] || &1["title"]} (#{&1["why"]})") <>
                ". Send rest: true to undo everything else.",
            edited: conflicts
          })

        {:error, :conflict, message} ->
          {:error, :conflict, message}

        {:error, message} ->
          {:error, :unprocessable_entity, message}
      end
    end
  end

  @doc "Decides against a capture: nothing from it is written; the record stays."
  def discard(conn, %{"id" => id}) do
    with {:ok, capture} <- fetch(conn, id, :write) do
      case Meetings.discard(capture, conn.assigns.current_user, via: "api") do
        {:ok, capture} -> json(conn, %{capture: show_json(conn, capture)})
        {:error, :conflict, message} -> {:error, :conflict, message}
        {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      end
    end
  end

  @doc """
  Answers one of a capture's questions: `question` (its id), `answer` (an
  option's value, its number, or its label), and optionally `replayed`
  (what was listened to first, e.g. "07:38–07:44"). `via: "agent"` marks an
  answer an agent relayed from the person. `answer: null` takes it back.
  """
  def resolve(conn, %{"id" => id} = params) do
    with {:ok, capture} <- fetch(conn, id, :write),
         %Slipdock.Meetings.Question{} = q <- question(capture, params["question"]) do
      user = conn.assigns.current_user
      via = if params["via"] == "agent", do: "agent", else: "api"

      result =
        case params["answer"] do
          nil ->
            Slipdock.Meetings.Review.unanswer(q, user)

          given ->
            case Slipdock.Meetings.Review.option_value(q, given) do
              nil ->
                {:error,
                 "#{inspect(given)} is not an answer to this question; the answers are " <>
                   Enum.map_join(Enum.with_index(q.options, 1), ", ", fn {o, i} ->
                     "#{i}. #{o["label"]}"
                   end)}

              value ->
                context = if params["replayed"], do: %{replayed: params["replayed"]}, else: %{}
                Slipdock.Meetings.Review.answer(q, value, user, via: via, context: context)
            end
        end

      reply(conn, capture, result)
    else
      nil -> {:error, :not_found, "question"}
      other -> other
    end
  end

  @doc """
  Includes, leaves out or edits a finding: `included` (true/false), or any of
  `title`, `body`, `list`, `due_date`, `topic`.
  """
  def finding(conn, %{"id" => id, "fid" => fid} = params) do
    with {:ok, capture} <- fetch(conn, id, :write),
         %Slipdock.Meetings.Finding{} = f <- finding_of(capture, fid) do
      user = conn.assigns.current_user

      result =
        case params["included"] do
          included when included in [true, false, "true", "false"] ->
            Slipdock.Meetings.Review.include(f, included in [true, "true"], user)

          _ ->
            Slipdock.Meetings.Review.edit(
              f,
              Map.take(params, ~w(title body list due_date topic)),
              user
            )
        end

      reply(conn, capture, result)
    else
      nil -> {:error, :not_found, "finding"}
      other -> other
    end
  end

  defp question(capture, id) do
    case SlipdockWeb.Params.id(id) do
      nil -> nil
      id -> Slipdock.Repo.get_by(Slipdock.Meetings.Question, id: id, capture_id: capture.id)
    end
  end

  defp finding_of(capture, id) do
    case SlipdockWeb.Params.id(id) do
      nil -> nil
      id -> Slipdock.Repo.get_by(Slipdock.Meetings.Finding, id: id, capture_id: capture.id)
    end
  end

  defp reply(conn, capture, {:ok, _}),
    do: json(conn, %{capture: show_json(conn, Meetings.get_capture!(capture.id))})

  defp reply(_conn, _capture, {:error, %Ecto.Changeset{} = cs}), do: {:error, cs}

  defp reply(_conn, capture, {:error, message}) when is_binary(message) do
    if Slipdock.Meetings.Review.reviewable?(Meetings.get_capture!(capture.id)),
      do: {:error, :unprocessable_entity, message},
      else: {:error, :conflict, message}
  end

  @doc "A board's captures, newest first."
  def index(conn, %{"board" => ref}) do
    with {:ok, board} <- Authorize.fetch_board(conn, ref, :read) do
      base = SlipdockWeb.BaseURL.from_conn(conn)

      json(conn, %{
        captures: Enum.map(Meetings.list_captures(board), &MeetingJSON.summary(&1, base))
      })
    end
  end

  @doc false
  # A capture the caller can read (`:read`) or write (`:write`) through its
  # board; one they cannot read is a 404, the same as one that is not there.
  def fetch(conn, id, need) do
    with %Meetings.Capture{} = capture <- id |> SlipdockWeb.Params.id() |> get(),
         board = Slipdock.Boards.get_board!(capture.board_id),
         :ok <- readable(conn, board),
         :ok <- Authorize.board(conn, board, need) do
      {:ok, capture}
    else
      nil -> {:error, :not_found, "capture"}
      {:error, :not_found, _} -> {:error, :not_found, "capture"}
      other -> other
    end
  end

  defp get(nil), do: nil
  defp get(id), do: Meetings.get_capture(id)

  defp readable(conn, board) do
    if Slipdock.Access.can_read?(
         Slipdock.Access.board_permission(conn.assigns.current_user, board)
       ),
       do: :ok,
       else: {:error, :not_found, "capture"}
  end

  defp show_json(conn, capture),
    do: MeetingJSON.capture(Meetings.load(capture), SlipdockWeb.BaseURL.from_conn(conn))

  # A file upload, or the text itself.
  defp file(%Plug.Upload{path: path, filename: name}),
    do: %{content: File.read!(path), filename: name}

  defp file(text) when is_binary(text) and text != "", do: %{content: text, filename: nil}
  defp file(_), do: nil

  defp audio(%Plug.Upload{path: path, filename: name, content_type: type}),
    do: %{path: path, filename: name, content_type: type}

  defp audio(_), do: nil

  defp blank(""), do: nil
  defp blank(value), do: value
end
