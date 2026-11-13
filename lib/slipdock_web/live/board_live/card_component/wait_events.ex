defmodule SlipdockWeb.BoardLive.CardComponent.WaitEvents do
  @moduledoc """
  The card panel's events on what a card waits for: answering, skipping or
  withdrawing its open questions, a suggested answer, the Ask questions
  form, and accepting or rejecting finished work.

  `BoardLive.CardComponent.handle_event/3` hands these over once it has
  decided the reader may do them. The clauses run in the component's own
  process, with its socket, as they did when they were its own.
  """
  use SlipdockWeb.WikiLive.Events

  import SlipdockWeb.BoardLive.Helpers

  alias Slipdock.Boards
  alias Slipdock.Boards.Card
  alias SlipdockWeb.BoardLive.CardComponent.State

  # Waiting on a person (#1114): answered by a choice's button or in words,
  # one box per question (#1220), skipped, or withdrawn. All need write, as
  # over the API.
  def handle_event("answer_wait", params, socket) do
    answers =
      case get_in(params, ["wait", "answers"]) do
        %{} = by_number -> by_number
        _ -> nil
      end

    attrs = %{
      "choice" => params["choice"],
      "answers" => if(params["choice"], do: nil, else: answers),
      "answer" => get_in(params, ["wait", "answer"]) || params["answer"]
    }

    socket.assigns.card |> Boards.Waits.answer_wait(State.me(socket), attrs) |> waited(socket)
  end

  def handle_event("skip_wait", _, socket),
    do:
      socket.assigns.card
      |> Boards.Waits.answer_wait(State.me(socket), %{"skip" => true})
      |> waited(socket)

  # Accepting or rejecting an agent's completion (#1633), as a person.
  def handle_event("verify_work", %{"decision" => decision} = params, socket) do
    user = socket.assigns.current_user

    with {:ok, card} <- State.writable(socket),
         {:ok, _} <-
           Slipdock.Verified.decide(
             card,
             decision,
             Map.take(params, ["reason", "commit"]),
             Slipdock.Actor.web(user),
             user
           ) do
      {:noreply, assign(socket, card: State.fresh(socket, card.id))}
    else
      {:error, _status, message} ->
        {:noreply, notice(socket, :error, String.capitalize(message) <> ".")}

      _ ->
        {:noreply, notice(socket, :error, "You have read-only access to that card.")}
    end
  end

  def handle_event("withdraw_wait", _, socket),
    do: socket.assigns.card |> Boards.Waits.withdraw_wait(State.me(socket)) |> waited(socket)

  # What is typed into the answer boxes, kept so a suggestion can fill one
  # without losing the rest.
  def handle_event("wait_change", params, socket) do
    answers =
      for {n, text} <- get_in(params, ["wait", "answers"]) || %{},
          {n, ""} <- [Integer.parse(n)],
          into: %{},
          do: {n, text}

    {:noreply, assign(socket, wait_answers: answers)}
  end

  # A suggested answer (#1220): the reader's model answers question `n`
  # from the card, into its box. Nothing is sent until they answer.
  def handle_event("suggest_answer", %{"n" => n}, socket) do
    %{card: card, board: board, current_user: user, wait_answers: typed} = socket.assigns
    wait = Card.open_wait(card)

    with %Slipdock.Boards.Wait{} <- wait,
         {n, ""} <- Integer.parse(to_string(n)) do
      if Slipdock.AI.configured?(user) do
        {:noreply,
         socket
         |> assign(wait_suggest: Map.put(socket.assigns.wait_suggest, n, :running))
         |> start_async({:wait_suggest, n}, fn ->
           Slipdock.AI.WaitAnswerer.suggest(card, board, wait, n, typed, user: user)
         end)}
      else
        {:noreply,
         assign(socket,
           wait_suggest:
             Map.put(
               socket.assigns.wait_suggest,
               n,
               {:error, "Suggesting needs an AI model: set one under Account → AI model."}
             )
         )}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Asking questions (#1220): a box per question, and who they are on.
  def handle_event("ask_questions", _, socket),
    do: {:noreply, assign(socket, asking: %{questions: [""], on: ""})}

  def handle_event("ask_cancel", _, socket), do: {:noreply, assign(socket, asking: nil)}

  def handle_event("ask_change", %{"ask" => params}, socket),
    do: {:noreply, assign(socket, asking: asked(params))}

  def handle_event("ask_add", _, socket) do
    asking = socket.assigns.asking || %{questions: [], on: ""}

    if length(asking.questions) < Slipdock.Boards.Wait.max_questions(),
      do: {:noreply, assign(socket, asking: %{asking | questions: asking.questions ++ [""]})},
      else: {:noreply, socket}
  end

  def handle_event("ask_remove", %{"n" => n}, socket) do
    with %{questions: questions} = asking <- socket.assigns.asking,
         {n, ""} <- Integer.parse(to_string(n)) do
      {:noreply, assign(socket, asking: %{asking | questions: List.delete_at(questions, n - 1)})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("ask_save", %{"ask" => params}, socket) do
    asking = asked(params)

    attrs = %{
      "questions" => asking.questions,
      "on_user_id" => ask_on(socket, asking.on)
    }

    case Boards.Waits.open_wait(socket.assigns.card, State.me(socket), attrs) do
      {:ok, _} ->
        {:noreply, socket |> assign(asking: nil) |> State.reload() |> State.assign_pages()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket |> assign(asking: asking) |> notice(:error, changeset_message(changeset))}

      {:error, message} ->
        {:noreply, socket |> assign(asking: asking) |> notice(:error, message)}
    end
  end

  # A wait answered, skipped or withdrawn: the panel shows it closed.
  defp waited({:ok, _}, socket),
    do:
      {:noreply,
       socket
       |> assign(wait_answers: %{}, wait_suggest: %{})
       |> State.reload()
       |> State.assign_pages()}

  defp waited({:error, %Ecto.Changeset{} = changeset}, socket),
    do: {:noreply, notice(socket, :error, changeset_message(changeset))}

  defp waited({:error, message}, socket), do: {:noreply, notice(socket, :error, message)}

  # The ask form's questions, in order, as typed.
  defp asked(params) do
    questions =
      (params["questions"] || %{})
      |> Enum.flat_map(fn {n, text} ->
        case Integer.parse(to_string(n)) do
          {n, ""} -> [{n, text}]
          _ -> []
        end
      end)
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))

    %{questions: if(questions == [], do: [""], else: questions), on: params["on"] || ""}
  end

  # Who the questions are on: one of the people who may see the card, or
  # anyone.
  defp ask_on(socket, on) do
    Enum.find_value(socket.assigns.users, fn u -> if to_string(u.id) == on, do: u.id end)
  end
end
