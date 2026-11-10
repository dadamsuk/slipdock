defmodule SlipdockWeb.MCP.Tools.VerifyCard do
  @moduledoc """
  Accepts or rejects a card waiting for verification (#1633), as
  `POST /api/cards/:id/verify` does: on a board that verifies work, an
  agent's completion waits for a different agent, or a person, to decide.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Boards
  alias SlipdockWeb.API.CardWrites
  alias SlipdockWeb.MCP.{Args, Tools}

  @impl true
  def name, do: "verify_card"

  @impl true
  def title, do: "Verify a card's work"

  @impl true
  def description,
    do:
      "Accepts or rejects a card waiting for verification, after checking it at the evidence's " <>
        "commit. accept completes it; reject needs the reason and a failing check. " <>
        "checks: the verdict in parts. Not on a card you submitted."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        card: %{type: "integer"},
        decision: %{
          type: "string",
          enum: ["accept", "reject", "merged", "agree", "disagree"],
          description:
            "merged: a person merged a merging card's pull request by hand. agree/disagree: " <>
              "an audit job's say on an accepted card (a comment; disagree alerts the owner " <>
              "and files a rework card, or comments on the open one)."
        },
        reason: %{
          type: "string",
          description:
            "Why: required to reject (what falls short of the bar), optional to accept. " <>
              SlipdockWeb.MCP.Tool.shape() <>
              " Its first line titles an audit's rework card; the parts go in checks, not here."
        },
        commit: %{
          type: "string",
          description: "The commit you checked the work at (for merged: the merge commit)."
        },
        checks: %{
          type: "array",
          items: %{type: "string"},
          description:
            "The verdict in parts, one each: ask=ok|misses, bar:2=ok|fail[:why], " <>
              "suite=412:0, rule:UX-4=ok|broken|n/a[:why], handbook_line=ok|disputed; " <>
              "a rule broken in several places: one rule:UX-4=broken:<file>:<line>[:why] " <>
              "per instance, every one found, all in this rejection (listed under the rule); " <>
              "rule:UX-4=pre-existing:<file>:<line> for a rule broken only in unchanged lines " <>
              "(never a rejection); " <>
              "defect:important|nit|pre-existing=<file>:<line>[:why] for a schema or " <>
              "security card's defect review (only important fails); " <>
              "mutant:killed|survived|pre-existing=<file>:<line>:<mutation>[:note] for each " <>
              "changed line the mutation review broke (survived fails: name the missing test; " <>
              "pre-existing is a survivor in unchanged lines, kept as a finding), or " <>
              "mutants=n/a:<why> when nothing in the diff is worth mutating; " <>
              "on a resubmission, =carried for a part passed before."
        }
      },
      required: ["card", "decision"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    auth = Args.auth(context)

    with {:ok, id} <- Args.id(args, "card"),
         {:ok, decision} <- Args.required(args, "decision"),
         {:ok, reason} <- Args.optional(args, "reason"),
         {:ok, commit} <- Args.optional(args, "commit"),
         checks = args["checks"],
         {:ok, card} <- Args.refusal(CardWrites.fetch_card(id)),
         {:ok, card} <-
           Args.refusal(
             CardWrites.verify(auth, card, %{
               "decision" => decision,
               "reason" => reason,
               "commit" => commit,
               "checks" => checks
             })
           ) do
      {:ok, card |> Map.get(:id) |> Boards.get_card!() |> Tools.card_written(context.base_url)}
    end
  end
end
