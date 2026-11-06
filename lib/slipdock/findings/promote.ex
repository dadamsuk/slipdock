defmodule Slipdock.Findings.Promote do
  @moduledoc """
  Promotion by recurrence (#1942, W-2310 §Findings): a finding counted to
  its board's `findings_propose_at` (3 by default, 0 off) is settled
  knowledge waiting for a person, so the server drafts the promotion and
  leaves it where a person already approves things, as a garden proposal
  (`Slipdock.Gardener.propose/4`).

  The proposal is one `edit_section` on the `## Rules` of the handbook page
  whose `covers:` take in the finding's cards' paths (most first), else the
  Specification page. The rule is drafted up the ladder: when the finding
  names a check (a `*_test.exs`, a `mix` command, `repo_checks`), a `must`
  rule citing it; otherwise a `should` rule, left to judgement. One
  `Slipdock.AI` call words it, given the finding, its cards and the page's
  rules; with AI off or failing, the rule is a `should` with the finding's
  text verbatim. Its id is the page's prefix and the next number.

  A finding has at most one open proposal. Accepting it marks the finding
  `promoted` with the rule id in its note; dismissing it leaves the finding
  open with a note, and no new proposal is drafted until its count has risen
  by the threshold again; undoing an accepted one opens the finding again.
  Only the project's findings (`scope: "board"`) are proposed, and only on a
  board tree with a handbook.

  `consider/1` is called whenever a count changes. It runs under
  `Slipdock.TaskSupervisor` unless `config :slipdock, :findings,
  async: false` (as in tests), since drafting calls a model.
  """

  require Logger

  import Ecto.Query

  alias Slipdock.{AI, Gardener, Handbook, Repo}
  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card}
  alias Slipdock.Findings.Finding
  alias Slipdock.Gardener.Suggestion
  alias Slipdock.Handbook.Rules
  alias Slipdock.Wiki.{Page, Section}

  @check ~r{(?:[\w./-]*_test\.exs)|(?:\bmix [a-z][\w.]*(?: --?[\w-]+)*)|(?:\brepo_checks\b)}

  @doc """
  Looks at each of these findings (or the one a merged finding was merged
  into) after its count changed, and drafts a proposal for any that reached
  the threshold. Returns `:ok` at once when it runs in the background.
  """
  def consider(findings) do
    ids =
      findings
      |> List.wrap()
      |> Enum.flat_map(fn
        %Finding{status: "merged", merged_into_id: into} when not is_nil(into) -> [into]
        %Finding{id: id} -> [id]
        id when is_integer(id) -> [id]
        _ -> []
      end)
      |> Enum.uniq()

    if ids == [], do: :ok, else: run(fn -> Enum.each(ids, &check/1) end)
  end

  defp run(fun) do
    if Slipdock.Config.get(:findings, [])[:async] == false do
      fun.()
    else
      case Task.Supervisor.start_child(Slipdock.TaskSupervisor, fun) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("Findings.Promote not started: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  Drafts and files the proposal for one finding when it is due:
  `{:ok, suggestion}`, or `:skip` with nothing filed.
  """
  def check(id) do
    with %Finding{} = finding <- Repo.get(Finding, id),
         %Board{} = root <- due(finding),
         %{} = handbook <- Handbook.find(root),
         %User{} = owner <- Repo.get(User, root.owner_id),
         {:ok, page, path} <- rules_page(handbook, finding),
         {:ok, rule_id, line} <- draft(finding, handbook, page, owner) do
      file(finding, root, owner, page, path, rule_id, line)
    else
      _ -> :skip
    end
  rescue
    # Drafting a proposal is never worth breaking the write that counted.
    error ->
      Logger.warning("Findings.Promote failed for finding #{id}: #{Exception.message(error)}")
      :skip
  end

  # The finding's root board when its count has reached the threshold and no
  # proposal of its is open.
  defp due(%Finding{status: "open", scope: "board"} = finding) do
    root = Repo.get!(Board, finding.board_id)
    threshold = root.findings_propose_at || 0

    cond do
      threshold <= 0 -> nil
      open_proposal?(finding) -> nil
      finding.count < (finding.proposed_at_count || 0) + threshold -> nil
      true -> root
    end
  end

  defp due(_finding), do: nil

  defp open_proposal?(%Finding{proposal_id: nil}), do: false

  defp open_proposal?(%Finding{proposal_id: id}),
    do: Repo.exists?(from s in Suggestion, where: s.id == ^id and s.state == "open")

  @doc """
  The page the rule goes on and its `## Rules` path: the first handbook page
  whose `covers:` take in the finding's cards' paths (most covered first)
  that has a Rules section, else the Specification page.
  """
  def rules_page(handbook, %Finding{} = finding) do
    paths = finding |> cards() |> Enum.flat_map(&(&1.paths || []))
    covering = Enum.map(Handbook.pages_for(handbook, paths), & &1.code)

    spec = Enum.filter(handbook.pages, &(Handbook.key(&1) == "specification"))

    ordered =
      Enum.map(covering, fn code -> Enum.find(handbook.pages, &(&1.code == code)) end) ++ spec

    Enum.find_value(ordered, {:error, :no_rules_page}, fn
      %Page{} = page ->
        case rules_path(page) do
          nil -> nil
          path -> {:ok, page, path}
        end

      _ ->
        nil
    end)
  end

  defp rules_path(%Page{body: body}) do
    body
    |> Section.headings()
    |> Enum.find(&(&1.level == 2 and String.downcase(String.trim(&1.title)) == "rules"))
    |> case do
      nil -> nil
      heading -> heading.path
    end
  end

  # The finding's own card and those of the findings merged into it.
  defp cards(%Finding{} = finding) do
    merged =
      Repo.all(
        from c in Card,
          join: f in Finding,
          on: f.card_id == c.id,
          where: f.merged_into_id == ^finding.id
      )

    own = if finding.card_id, do: List.wrap(Repo.get(Card, finding.card_id)), else: []
    Enum.uniq_by(own ++ merged, & &1.id)
  end

  @doc """
  The rule's id and its line: `{:ok, "SPEC-12", "- **SPEC-12** should · judgement · …"}`.
  """
  def draft(%Finding{} = finding, handbook, %Page{} = page, owner) do
    prefix = Rules.prefix(Handbook.key(page)) || "RULE"
    rule_id = "#{prefix}-#{next_number(handbook, prefix)}"
    check = named_check(finding.text)
    {severity, check, text} = word(finding, page, check, owner)
    {:ok, rule_id, "- **#{rule_id}** #{severity} · #{check} · #{one_line(text)}"}
  end

  @doc "The check a finding's text names, as a rule cites it, or nil."
  def named_check(text) do
    case Regex.run(@check, text || "") do
      [found | _] -> String.trim(found)
      nil -> nil
    end
  end

  defp next_number(handbook, prefix) do
    handbook
    |> Rules.parse()
    |> then(fn {rules, problems} -> Enum.map(rules, & &1.id) ++ Enum.map(problems, & &1.item) end)
    |> Enum.flat_map(fn text ->
      case Regex.run(~r/\b#{Regex.escape(prefix)}-(\d+)\b/, text || "") do
        [_, n] -> [String.to_integer(n)]
        nil -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  # Up the ladder: a check named makes a `must` citing it, else a `should`
  # left to judgement; the model words it. Without a model, a `should` with
  # the finding's own words.
  defp word(finding, page, check, owner) do
    severity = if check, do: "must", else: "should"
    cites = check_field(check)

    with true <- AI.configured?(owner) or AI.configured?(),
         {:ok, %{"text" => text}} when is_binary(text) <-
           AI.complete_json(messages(finding, page, severity, check),
             user: owner,
             max_tokens: 300,
             temperature: 0.2
           ),
         text when text != "" <- String.trim(text) do
      {severity, cites, text}
    else
      _ -> {"should", "judgement", finding.text}
    end
  end

  # A rule's check part is a test path or `judgement`; a `mix` command or
  # the repo checks list is cited in the rule's words instead.
  defp check_field(nil), do: "judgement"

  defp check_field(check) do
    cond do
      String.ends_with?(check, "_test.exs") -> check
      check == "repo_checks" -> "test/repo_checks.txt"
      true -> "judgement"
    end
  end

  defp messages(finding, page, severity, check) do
    rules =
      page
      |> Rules.parse_page()
      |> elem(0)
      |> Enum.map_join("\n", &"- #{&1.id} #{&1.severity}: #{&1.text}")

    cards = finding |> cards() |> Enum.map_join("\n", &"- ##{&1.id} #{&1.title}")

    [
      %{
        role: "system",
        content: """
        You turn a lesson an agent learned several times into one rule for a
        project's handbook. Answer with JSON: {"text": "<the rule>"}. The rule
        is one sentence, a statement a change must keep to, in plain words,
        with no id, severity or check: those are added for you.
        """
      },
      %{
        role: "user",
        content: """
        The lesson (#{finding.kind}, said #{finding.count} times): #{finding.text}

        On cards:
        #{if cards == "", do: "(none)", else: cards}

        The rule is a `#{severity}` rule on the handbook page "#{page.title}".
        #{if check, do: "It cites the check `#{check}`: say what that check holds.", else: "It is left to judgement."}

        The page's rules now:
        #{if rules == "", do: "(none)", else: rules}
        """
      }
    ]
  end

  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp file(finding, root, owner, page, path, rule_id, line) do
    {:ok, current} = Section.read(page.body, path)
    existing = current |> String.split("\n", parts: 2) |> Enum.at(1, "") |> String.trim()
    body = if existing == "", do: line, else: existing <> "\n" <> line
    cards = finding |> cards() |> Enum.map(& &1.id)

    explanation =
      "Finding ##{finding.id} was seen #{finding.count} times" <>
        if(cards == [], do: "", else: " (cards #{Enum.map_join(cards, ", ", &"##{&1}")})") <>
        ": #{one_line(finding.text)}. Proposed as #{rule_id} on #{page.title}."

    attrs = %{
      "explanation" => explanation,
      "steps" => [%{"op" => "edit_section", "page" => page.id, "section" => path, "body" => body}],
      "findings" => [finding.id],
      "cards" => cards
    }

    case Gardener.propose(root, owner, attrs, round: {finding.id, finding.count}) do
      {:ok, %Suggestion{state: "open"} = suggestion, _new_or_exists} ->
        finding
        |> Ecto.Changeset.change(
          proposal_id: suggestion.id,
          proposed_rule: rule_id,
          proposed_at_count: finding.count
        )
        |> Repo.update!()

        {:ok, suggestion}

      _ ->
        :skip
    end
  end

  @doc """
  A person decided a proposal (`Slipdock.Gardener`): accepting it promotes
  the findings it was drafted for, with the rule id in their note;
  dismissing it leaves them open with a note; undoing an accepted one opens
  them again.
  """
  def decided(%Suggestion{id: id}, decision) do
    from(f in Finding, where: f.proposal_id == ^id)
    |> Repo.all()
    |> Enum.each(&decided_one(&1, id, decision))
  end

  defp decided_one(finding, id, :applied) do
    finding
    |> Finding.triage_changeset(%{
      status: "promoted",
      note: "#{finding.proposed_rule} (proposal ##{id})"
    })
    |> Repo.update!()
  end

  defp decided_one(finding, id, :dismissed) do
    finding
    |> Finding.triage_changeset(%{status: "open", note: "proposal ##{id} dismissed"})
    |> Repo.update!()
  end

  defp decided_one(%Finding{status: "promoted"} = finding, id, :undone) do
    finding
    |> Finding.triage_changeset(%{status: "open", note: "proposal ##{id} undone"})
    |> Repo.update!()
  end

  defp decided_one(_finding, _id, _decision), do: :ok
end
