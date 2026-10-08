defmodule Slipdock.Automations.Parser do
  @moduledoc """
  Turns "when a card lands in Done, email ops@example.com" into a rule spec.

  The model is given the vocabulary (`Slipdock.Automations.Spec.catalogue/0`)
  and this board's own lists, tags and people, and must answer with one JSON
  object. Whatever comes back is put through `Spec.validate/1` before it is
  allowed near a rule, so a hallucinated trigger or action is a friendly
  error rather than a rule that quietly never runs.
  """

  alias Slipdock.AI
  alias Slipdock.Access
  alias Slipdock.Accounts.User
  alias Slipdock.Automations.Spec
  alias Slipdock.Boards.Board

  @prompt """
  You write automation rules for a kanban / project-planning app. The user describes a rule in plain English; you answer with ONE JSON object and nothing else:

  {"name": "a short name for the rule, 2-6 words", "scope": "board" or "tree", "spec": {"trigger": {...}, "conditions": [...], "actions": [...]}}

  If the request can't be expressed with the vocabulary below, answer {"error": "one sentence saying what you can't do and suggesting the nearest rule you could write"} instead.

  Rules:
  - Use only the trigger types, condition fields/ops and action types listed. Never invent keys.
  - Use only list names, tag names and people that appear in the board description. If the user names a list that doesn't exist, return an error saying so.
  - "scope" is "board" for the board's own cards; use "tree" only when the user says the rule should cover subcards / everything beneath / the whole tree.
  - Relative times become numbers: "a week" is 7 days, "a day" is 24 hours.
  - Text in an action (subject, body, comment, alert title) may use these placeholders: {{card.title}}, {{card.url}}, {{card.due_date}}, {{card.priority}}, {{card.column}}, {{card.assignee}}, {{card.tags}}, {{card.status}}, {{board.name}}, {{board.url}}, {{today}}, {{rule.name}}. Prefer including {{card.title}} and {{card.url}} in emails and alerts so the reader knows what it is about.
  - Prefer the simplest trigger that does the job, and put anything else in "conditions" rather than inventing a trigger for it.
  - Set a trigger's optional keys only when the user actually named them: "when a card moves to Done" is {"type": "card_moved", "to": "Done"} with no "from".
  - "Show/raise an alert", "warn me", "remind me on screen" means the "alert" action, not email.
  - "Call", "ping", "hit", "callback", "webhook", "POST to" or "GET" a URL means the "webhook" action. Set "method" to "get" only when the user asked for a GET; leave it out for a POST. The card's title, link, dates, flags and status are always sent, so there is nothing extra to configure.
  - "Send to a runner", "hand it to Claude/Codex/an agent", "have my machine work on it" means the "runner" action. "pool" is the name of the group of runners (use what the user said, else "default"); "kind" is what the runner should run ("claude" unless the user named another, e.g. "codex"). Leave "prompt" out unless the user dictated one: the card's title, link and description are sent by default. Never put a shell command in it.
  - Give every email a subject and a body unless the user dictated them.

  VOCABULARY
  #{Spec.catalogue()}
  """

  @doc """
  Parses `text` into `{:ok, %{"name" => …, "scope" => …, "spec" => …}}`, or
  `{:error, message}`.
  """
  def parse(%Board{} = board, text, opts \\ []) do
    text = String.trim(to_string(text))

    cond do
      text == "" ->
        {:error, "Describe the rule first."}

      match?({:error, _}, AI.provider(opts)) ->
        {:error,
         "Automation rules are written by the AI: set up a model under Account → AI model."}

      true ->
        messages = [
          %{role: "system", content: @prompt <> "\n\n---\n\n" <> context(board)},
          %{role: "user", content: text}
        ]

        with {:ok, json} <-
               AI.complete_json(
                 messages,
                 Keyword.merge([max_tokens: 1200, temperature: 0.1], opts)
               ) do
          interpret(json)
        end
    end
  end

  defp interpret(%{"error" => message}) when is_binary(message) and message != "",
    do: {:error, message}

  defp interpret(%{"spec" => spec} = json) when is_map(spec) do
    case Spec.validate(spec) do
      {:ok, validated} ->
        {:ok,
         %{
           "name" => name(json, validated),
           "scope" => if(json["scope"] == "tree", do: "tree", else: "board"),
           "spec" => validated
         }}

      {:error, message} ->
        {:error, "The rule came back malformed (#{message}). Try describing it differently."}
    end
  end

  defp interpret(_),
    do: {:error, "The model didn't return a rule. Try describing it differently."}

  defp name(json, spec) do
    case json["name"] do
      name when is_binary(name) and name != "" -> String.slice(name, 0, 120)
      _ -> spec |> Spec.summary() |> String.slice(0, 120)
    end
  end

  # What this board makes available: the names a rule is allowed to mention.
  defp context(%Board{} = board) do
    """
    BOARD: #{board.name}
    Today is #{Date.utc_today()} (#{Calendar.strftime(Date.utc_today(), "%A")}).
    Lists, in order: #{names(board.columns, & &1.name)}
    Tags: #{names(board.tags, & &1.name)}
    People who can be assigned: #{names(Access.visible_users_for(board), &person/1)}
    """
  end

  defp person(%User{} = user) do
    case User.display_name(user) do
      name when name == user.email -> user.email
      name -> "#{name} <#{user.email}>"
    end
  end

  defp names(list, fun) when is_list(list) do
    case Enum.map(list, fun) do
      [] -> "(none)"
      names -> Enum.join(names, ", ")
    end
  end

  defp names(_, _), do: "(none)"
end
