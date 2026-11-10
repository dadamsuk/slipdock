defmodule SlipdockWeb.MCP.Tools.CompleteCard do
  @moduledoc "Finishes a card the way the guide asks: completed, and in the done list."
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.MCP.{Args, Tools}

  @impl true
  def name, do: "complete_card"

  @impl true
  def title, do: "Complete a card"

  @impl true
  def description,
    do:
      "Marks a card completed and moves it to its board's done list, with an optional " <>
        "closing comment saying what was done. An epic closes after its subcards."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        comment: %{
          type: "string",
          description: "What was done, added before closing. " <> SlipdockWeb.MCP.Tool.shape()
        },
        evidence: %{
          type: "string",
          description:
            "What you checked (tests run, output); a board may require it. " <>
              SlipdockWeb.MCP.Tool.shape() <>
              " The commit, tests, suite and PR go in their own fields, not here."
        },
        commit: %{type: "string", description: "The commit the evidence is for."},
        branch: %{type: "string", description: "The commit's branch."},
        pr: %{
          type: "string",
          description:
            "The pull request's URL, on a board that ships by pull request. Give commit " <>
              "with it, the PR's head: the PR is merged at that commit, and a PR without " <>
              "one is refused, on a resubmission too."
        },
        no_code: %{
          type: "string",
          description:
            "Why the card changes no code (a sweep, a handbook reconcile, a read-and-file " <>
              "card): on a board that ships by pull request, given in place of pr, and " <>
              "accepting it merges nothing. Not with pr."
        },
        changed_lines: %{
          type: "integer",
          minimum: 0,
          description:
            "The change's changed lines, added plus removed (`git diff --numstat`). With " <>
              "profiles on, a fix or docs card over 400 is raised to feature."
        },
        changed_files: %{
          type: "array",
          items: %{type: "string"},
          description:
            "The files the change touches. With profiles on, a migration raises the card's " <>
              "profile to schema and a security path to security; never lowered."
        },
        tests: %{
          type: "array",
          items: %{type: "string"},
          description: "The test files added or changed."
        },
        suite: %{
          type: "object",
          properties: %{
            result: %{type: "string", enum: ["passed", "failed"]},
            passed: %{type: "integer", minimum: 0},
            failed: %{type: "integer", minimum: 0}
          },
          required: ["result"],
          additionalProperties: false,
          description: "The test suite's result and counts."
        }
      },
      required: ["card"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, note} <- Args.optional(args, "comment"),
         {:ok, evidence} <- Args.optional(args, "evidence"),
         {:ok, commit} <- Args.optional(args, "commit"),
         {:ok, branch} <- Args.optional(args, "branch"),
         {:ok, pr} <- Args.optional(args, "pr"),
         {:ok, no_code} <- Args.optional(args, "no_code"),
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         :ok <- Args.refusal(Authorize.card(auth, card, :write)),
         :ok <- comment(card, note, context.user),
         # On a board that verifies work (#1633) the card is submitted, and
         # stays where it is until it is accepted.
         verifies? = Boards.get_board!(card.board_id).verify_work,
         done = if(verifies?, do: nil, else: done_list(card)),
         params =
           %{
             "completed" => true,
             "evidence" => evidence,
             "evidence_commit" => commit,
             "evidence_branch" => branch,
             "evidence_pr" => pr,
             "evidence_no_code" => no_code,
             "evidence_tests" => args["tests"],
             "evidence_suite" => args["suite"],
             # The actual change, for the profile (#2017).
             "changed_lines" => args["changed_lines"],
             "changed_files" => args["changed_files"]
           }
           |> Map.reject(fn {_, v} -> is_nil(v) end)
           |> then(&if(done, do: Map.put(&1, "column", done.id), else: &1)),
         {:ok, card} <- Args.refusal(CardWrites.update(auth, card, params)) do
      {:ok,
       card
       |> Tools.card_written(context.base_url)
       |> Map.put(:note, note(card, done))}
    end
  end

  defp note(%{verify_state: "pending"}, _done),
    do:
      "submitted for verification: a different agent or a person accepts it (verify_card) " <>
        "before it is done"

  defp note(_card, nil), do: "this board has no done list, so the card stayed where it was"
  defp note(_card, _done), do: nil

  defp comment(_card, nil, _user), do: :ok

  defp comment(card, body, user) do
    with {:ok, _} <- Args.refusal(Boards.add_comment(card, body, by: user)), do: :ok
  end

  defp done_list(card) do
    SlipdockWeb.APIGuide.list_roles(Boards.get_board!(card.board_id).columns).done
  end
end
