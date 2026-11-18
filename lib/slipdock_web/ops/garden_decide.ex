defmodule SlipdockWeb.Ops.GardenDecide do
  @moduledoc """
  Deciding one gardener suggestion (W-1807), defined once (#3188): apply it
  (`keep` and `choice` for the ones that ask), dismiss it, or undo an
  applied one. REST's route is `POST /api/garden/suggestions/:id/:decision`,
  the decision in the path (it was three routes, `…/apply`, `…/dismiss` and
  `…/undo`, which are these paths still). A proposal, or a suggestion that
  edits a section, is a person's to decide on the Tidy-up page, not the
  API's (`Gardener.person_only?/1`).

  MCP alone asks for `confirm: true` first (`confirm/2`), because the
  decision is the person's, not the model's; REST, whose callers name the
  suggestion and the verb themselves, never did, and takes a `confirm` from
  older CLIs and does nothing with it. Before it, REST refused a field it
  didn't know on apply only: now on every decision (`strict?`), as MCP
  refuses an argument it doesn't take. A suggestion out of reach was
  MCP's "no suggestion #12": now it is not there on both (404).
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [actor: 1]

  alias Slipdock.{Boards, Gardener}
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.GardenJSON, as: G

  @impl true
  def definition do
    %{
      name: "garden_decide",
      title: "Apply or dismiss a tidy-up suggestion",
      summary:
        "Applies or dismisses one garden suggestion the person approved; never a list " <>
          "on your own judgment. A dismissal sticks unless its subject changes; undo puts " <>
          "an applied one back. keep and choice: see their fields. Needs confirm.",
      verb: :post,
      path: "/api/garden/suggestions/:id/:decision",
      permission: {:board, :write},
      writes?: true,
      strict?: true,
      params: [
        %{name: "suggestion", type: :integer, required: true, in_path: "id"},
        %{
          name: "decision",
          type: {:enum, ["apply", "dismiss", "undo"]},
          required: true,
          in_path: "decision"
        },
        %{name: "keep", type: :integer, doc: "For a duplicate: the card that stays."},
        %{name: "choice", type: :string, doc: "One of the suggestion's alternatives, by name."}
      ],
      confirm: %{type: :boolean, doc: "Must be true: the person approved this."},
      cli: %{
        command: "garden",
        positional: ["decision", "suggestion"],
        flags: %{"keep" => %{param: "keep"}, "choice" => %{param: "choice"}}
      }
    }
  end

  @impl true
  def confirm(%{"confirm" => true}, _auth), do: :ok

  def confirm(_params, _auth),
    do:
      {:error,
       "not done: garden_decide needs confirm = true, and only for a suggestion the person " <>
         "has approved. Show them the suggestion and ask first."}

  @impl true
  def run(%{"suggestion" => id, "decision" => decision} = params, auth) do
    with %{} = s <- Gardener.get_suggestion(id) || {:error, :not_found, "suggestion"},
         board = Boards.get_board_record!(s.board_id),
         :ok <- readable(auth, board),
         :ok <- Authorize.board(auth, board, :write),
         {:ok, s} <- refused(decide(s, auth, decision, params)) do
      {:ok, %{suggestion: G.suggestion(s)}}
    end
  end

  # A suggestion on a board the caller can't read is one they don't know of.
  defp readable(auth, board) do
    case Authorize.board(auth, board, :read) do
      :ok -> :ok
      _ -> {:error, :not_found, "suggestion"}
    end
  end

  defp decide(s, auth, "apply", params),
    do:
      Gardener.apply(s, auth.assigns.current_user,
        keep: params["keep"],
        choice: params["choice"],
        actor: decider(auth)
      )

  defp decide(s, auth, "dismiss", _params),
    do: Gardener.dismiss(s, auth.assigns.current_user, actor: decider(auth))

  defp decide(s, auth, "undo", _params),
    do: Gardener.undo(s, auth.assigns.current_user, actor: decider(auth))

  # Who decides: the call's actor, never the Tidy-up page's, so a
  # person-only suggestion is decided there and not over the API (#2668).
  defp decider(auth) do
    case actor(auth) do
      %{via: "web"} = actor -> %{actor | via: "api"}
      actor -> actor
    end
  end

  defp refused({:ok, _} = ok), do: ok

  defp refused({:error, :forbidden}),
    do: {:error, :forbidden, "you can't change everything this suggestion touches"}

  defp refused({:error, message}) when is_binary(message),
    do: {:error, :unprocessable_entity, message}

  defp refused(error), do: error
end
