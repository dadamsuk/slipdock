defmodule SlipdockWeb.MCP.Tools.ResolveCaptureQuestion do
  @moduledoc """
  Answers a meeting capture's question with the answer the person gave in
  the conversation. Recorded as theirs, via agent (G4).
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Meetings.{Question, Review}
  alias SlipdockWeb.MCP.Args
  alias SlipdockWeb.MCP.Tools.GetCapture

  @impl true
  def name, do: "resolve_capture_question"

  @impl true
  def title, do: "Answer a meeting question"

  @impl true
  def description,
    do:
      "Answers one question on a meeting capture with the answer THE PERSON gave you in this " <>
        "conversation — never your own guess. It is recorded as theirs, via agent. The answer is the " <>
        "option's number or label (see get_capture)."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        capture: %{type: "integer"},
        question: %{type: "integer"},
        answer: %{
          type: "string",
          description: "The person's answer: the option's number or label."
        }
      },
      required: ["capture", "question", "answer"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    with {:ok, capture} <- GetCapture.fetch(args, context, :write),
         {:ok, qid} <- Args.required(args, "question"),
         {:ok, given} <- Args.required(args, "answer"),
         %Question{} = q <-
           Slipdock.Repo.get_by(Question,
             id: SlipdockWeb.Params.id(qid) || 0,
             capture_id: capture.id
           ) || {:error, "no question #{qid} on this capture"},
         value when is_binary(value) <-
           Review.option_value(q, given) ||
             {:error,
              "#{inspect(given)} is not one of the answers: " <>
                Enum.map_join(Enum.with_index(q.options, 1), ", ", fn {o, i} ->
                  "#{i}. #{o["label"]}"
                end)},
         {:ok, _} <- Review.answer(q, value, context.user, via: "agent") do
      {:ok, GetCapture.summary(Slipdock.Meetings.get_capture!(capture.id), context)}
    end
  end
end
