defmodule SlipdockWeb.Ops.VerifyCard do
  @moduledoc """
  Deciding a card waiting for verification (#1633), defined once (#3187):
  accept or reject it, or for an audit agree or disagree, or say a merging
  card's pull request was merged by hand. `Slipdock.Verified.decide/5` does
  the deciding. Before it, MCP answered the card's line and REST `{card}`:
  now both answer `{card}`. A decision that isn't one of the five is
  refused by the cast (400) on both, where REST's was refused by `decide`
  (422).
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [card_json: 2]

  alias SlipdockWeb.API.CardWrites

  @impl true
  def definition do
    %{
      name: "verify_card",
      title: "Verify a card's work",
      summary:
        "Accepts or rejects a card waiting for verification, after checking it at the evidence's " <>
          "commit. accept completes it; reject needs the reason and a failing check. " <>
          "checks: the verdict in parts. Not on a card you submitted.",
      verb: :post,
      path: "/api/cards/:id/verify",
      permission: {:card, :write},
      writes?: true,
      params: [
        %{name: "card", type: :integer, required: true, in_path: "id"},
        %{
          name: "decision",
          type: {:enum, ["accept", "reject", "merged", "agree", "disagree"]},
          required: true,
          doc:
            "merged: a person merged a merging card's pull request by hand. agree/disagree: " <>
              "an audit job's say on an accepted card (a comment; disagree alerts the owner " <>
              "and files a rework card, or comments on the open one)."
        },
        %{
          name: "reason",
          type: :string,
          doc: "Why: required to reject (what falls short of the bar), optional to accept."
        },
        %{
          name: "commit",
          type: :string,
          doc: "The commit you checked the work at (for merged: the merge commit)."
        },
        # A list of lines, or (REST) the same as one string or a map of
        # parts: `Slipdock.Verified.Checks.parse/1` reads each.
        %{
          name: "checks",
          type: :any,
          schema: %{type: "array", items: %{type: "string"}},
          doc:
            "The verdict in parts, one each: ask=ok|misses, bar:2=ok|fail[:why], " <>
              "suite=412:0, rule:UX-4=ok|broken|n/a[:why], handbook_line=ok|disputed, " <>
              "evidence=ok|disputed (the evidence's format; it and the Handbook line are " <>
              "paperwork, kept as a finding: when they are all that fails, it accepts); " <>
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
      ],
      cli: %{
        command: "verify",
        positional: ["card", "decision"],
        flags: %{
          "reason" => %{param: "reason"},
          "evidence_commit" => %{param: "commit"},
          "check" => %{param: "checks"},
          # `--checks-file F`: the checks a line each (or a JSON map), read by the CLI.
          "checks_file" => %{param: "checks", read: :file}
        }
      }
    }
  end

  @impl true
  def run(%{"card" => id} = params, auth) do
    with {:ok, card} <- CardWrites.fetch_card(id),
         {:ok, card} <- CardWrites.verify(auth, card, params) do
      {:ok, %{card: card_json(auth, card)}}
    end
  end
end
