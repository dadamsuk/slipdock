defmodule Slipdock.AI.CardRecord do
  @moduledoc """
  The card chat's tools (#1875): the server's record of how a card's work
  went, for the open card and any card beneath it.

  `Slipdock.AI.Assistant.chat/4` is given the open card as text, which says
  what the card *is*. How its work *went* is elsewhere: the runner jobs sent
  on it and the steps they reported, the lists it sat in and the waits it
  asked, the bar and the evidence, each rejection and audit, the merge and
  the deploy. These tools read that record and render it as plain text for
  the model:

    * `read_card` — a card in full, with its handoff, wait and subcards
    * `card_comments` — every comment, oldest first, a page at a time
    * `card_handoffs` — each handoff left on it, newest first
    * `card_links` — links to other cards and dependencies
    * `card_subcards` — each subcard's state, verification and latest job
    * `card_jobs` — each runner job: kind, pool, runner, times, every step
      it reported, exit status and summary
    * `read_job` — one job in full, its prompt included when asked
    * `card_timeline` — the lists it sat in and for how long, waits and
      their answers, and its activity log (flags, snoozes, edits)
    * `card_verification` — bar, evidence, verdicts, rejections with their
      reasons, audits, merge jobs and deploys
    * `card_lead_time` — where its time went: its lead time by phase,
      worked out by `Slipdock.LeadTime` (#1876), per subcard and in total
      on an epic
    * `job_log_summary` — a job's log summed up (#1877,
      `Slipdock.Runners.TranscriptSummary`): what the agent said, where its
      time went (model and tool time by kind), the longest calls and the
      failed ones, each with its line in the log
    * `job_log` — one stretch of a job's log in full, by line

  Each takes a `card_id`, the open card when left out. A card outside the
  open card's tree is refused, so the chat stays about the card it was
  opened on, and every read makes the same permission check the card page
  makes, as the asking user: the record of a card they can't open is not
  theirs to read through here either.
  """

  import Ecto.Query

  alias Slipdock.{Access, Boards, CardTimeline, Deployments, LeadTime, Repo, Verified}
  alias Slipdock.Accounts.User
  alias Slipdock.AI.Context
  alias Slipdock.Boards.{Activity, Board, Card, CardLink, Comment, Handoff}
  alias Slipdock.Runners.{Job, Transcript, TranscriptRetention, TranscriptSummary, TranscriptView}

  @comments_per_page 25
  @comment_cap 3_000
  @output_cap 2_000
  @prompt_cap 12_000
  @activity_limit 80
  @log_messages 40
  @log_message_cap 400
  @log_stretch 120
  @log_stretch_cap 30_000
  @log_entry_cap 3_000
  @job_tools ~w(read_job job_log_summary job_log)

  @card_id %{
    type: "integer",
    description: "The card's id: the open card's when left out, else one of its subcards'."
  }

  @tools [
    {"read_card",
     "One card in full (the open card, or one of its subcards): fields, description, " <>
       "checklist, recent comments, its handoff, any open wait, and its subcards.", %{}},
    {"card_comments",
     "Every comment on a card, oldest first, #{@comments_per_page} a page, each with its id, " <>
       "author and time. read_card shows only the recent ones.",
     %{page: %{type: "integer", description: "Which page, from 1. Defaults to 1."}}},
    {"card_handoffs",
     "Every handoff left on a card, newest first: the next step and the note, who left it " <>
       "and from which job.", %{}},
    {"card_links", "A card's links to other cards, and what it is blocked by and blocks.", %{}},
    {"card_subcards",
     "A card's subcards: each one's list, whether it is done, its verification state and " <>
       "rejections, and its latest runner job.", %{}},
    {"card_jobs",
     "Every runner job sent on a card, oldest first: kind (work, verify, merge), pool, " <>
       "runner, status, when it was queued, claimed, started and finished, every step its " <>
       "agent reported with times, exit status, error and summary.", %{}},
    {"read_job", "One runner job in full by its id (from card_jobs), with its prompt when asked.",
     %{
       job_id: %{type: "integer", description: "The job's id."},
       prompt: %{type: "boolean", description: "Include the prompt the job was sent with."}
     }},
    {"card_timeline",
     "A card's timeline: each list it sat in, from when to when and who moved it, each " <>
       "time it waited on a person with the question and the answer, its jobs as spans, and " <>
       "its activity log (flags, snoozes, edits).", %{}},
    {"card_verification",
     "A card's verified-work record: the bar, the evidence (commit, branch, tests, suite, " <>
       "pull request), the verdict and who gave it, each rejection with its reason, audits, " <>
       "the verify and merge jobs and their outcome, the merge commit, and the deploys that " <>
       "shipped it where the board records deploys.", %{}},
    {"card_lead_time",
     "Where a card's time went: its lead time, from creation to its first deploy (or its " <>
       "completion, or now), by phase — backlog, waiting for a runner (and which jobs held " <>
       "the pool), build, CI, waiting on a person, verification wait, verify, rework, merge, " <>
       "deploy, and time the record can't explain — with each span in order and what it " <>
       "came from. On an epic, each subcard's too, and the subcards added up. Quote its " <>
       "numbers rather than adding them up yourself.", %{}},
    {"job_log_summary",
     "A runner job's log summed up (by its id, from card_jobs): what its agent said step by " <>
       "step, where its time went (model time, and tool time by kind: tests, checks, CI waits, " <>
       "git, slipdock, reading and editing code, subagents), its longest calls and every call " <>
       "that failed with what it said, each with its line in the log. Works on a running " <>
       "job, a finished one and a kept log; says when a log has expired.",
     %{job_id: %{type: "integer", description: "The job's id."}}},
    {"job_log",
     "One stretch of a runner job's log in full, by line (from job_log_summary): each " <>
       "message, tool call with its input, and tool result with its text, at most " <>
       "#{@log_stretch} lines a call.",
     %{
       job_id: %{type: "integer", description: "The job's id."},
       from: %{type: "integer", description: "The first line, from 0."},
       to: %{type: "integer", description: "The last line (at most #{@log_stretch} after from)."}
     }}
  ]

  @doc "The tool definitions, in the OpenAI function-calling shape."
  def tools do
    Enum.map(@tools, fn {name, description, props} ->
      job? = Enum.member?(@job_tools, name)
      props = if job?, do: props, else: Map.put(props, :card_id, @card_id)
      required = if job?, do: ["job_id"], else: []

      %{
        type: "function",
        function: %{
          name: name,
          description: description,
          parameters: %{type: "object", properties: props, required: required}
        }
      }
    end)
  end

  @doc "The tools' names."
  def names, do: Enum.map(@tools, &elem(&1, 0))

  @doc """
  Runs tool `name` with `args` for `user`, about the card `root` and its
  tree. Returns the text the model is given; a refusal is text too.
  """
  def call(%User{} = user, %Card{} = root, name, args) when name in @job_tools do
    with {:ok, id} <- int(args["job_id"], "#{name} needs a numeric job_id."),
         {:ok, job} <- fetch_job(id),
         {:ok, card} <- resolve(user, root, job.card_id, "Job ##{id}") do
      job_tool(name, %{job | card: card}, args)
    else
      {:error, message} -> message
    end
  end

  def call(%User{} = user, %Card{} = root, name, args) do
    with true <- Enum.member?(names(), name) || {:error, "There is no tool called #{name}."},
         {:ok, card} <- resolve(user, root, args["card_id"], nil) do
      render(name, card, args)
    else
      {:error, message} -> message
    end
  end

  def call(_user, _root, _name, _args), do: "Nobody is signed in."

  defp job_tool("read_job", job, args), do: job_text(job, args["prompt"] == true)
  defp job_tool("job_log_summary", job, _args), do: log_summary_text(job)
  defp job_tool("job_log", job, args), do: log_stretch_text(job, args)

  ## Which card ----------------------------------------------------------------

  defp fetch_job(id) do
    case Repo.get(Job, id) do
      nil -> {:error, "There is no job ##{id}."}
      job -> {:ok, job}
    end
  end

  # The open card, or a card beneath it that the asker may read.
  defp resolve(user, root, nil, _what), do: readable(user, root, root.id)

  defp resolve(user, root, id, what) do
    with {:ok, id} <- int(id, "card_id must be a card's number."),
         {:ok, card} <- fetch_card(id),
         :ok <- in_tree(root, card, what || "Card ##{id}") do
      readable(user, root, card)
    end
  end

  defp fetch_card(id) do
    case Repo.get(Card, id) do
      nil -> {:error, "There is no card ##{id} you can see."}
      card -> {:ok, card}
    end
  end

  defp in_tree(%Card{id: id}, %Card{id: id}, _what), do: :ok

  defp in_tree(root, card, what) do
    if Enum.member?(Boards.subtree_board_ids(root.id), card.board_id),
      do: :ok,
      else:
        {:error,
         "#{what} isn't on this card or beneath it: " <>
           "these tools read only the open card (##{root.id}) and its subcards."}
  end

  defp readable(user, root, id) when is_integer(id), do: readable(user, root, Repo.get(Card, id))

  defp readable(user, _root, %Card{} = card) do
    if Access.can_read?(Access.card_permission(user, card)),
      do: {:ok, card},
      else: {:error, "There is no card ##{card.id} you can see."}
  end

  defp readable(_user, _root, nil), do: {:error, "That card no longer exists."}

  ## The tools -----------------------------------------------------------------

  defp render("read_card", card, _args) do
    card = Repo.preload(card, full_preloads(), force: true)
    board = Repo.preload(card.board, [:columns, :fields])

    [
      Context.card_text(card, board),
      handoff_line(card.handoff),
      wait_line(Boards.current_wait(card)),
      verify_line(card),
      "",
      subcards_text(card)
    ]
    |> lines()
  end

  defp render("card_comments", card, args) do
    total = Repo.aggregate(from(c in Comment, where: c.card_id == ^card.id), :count)
    pages = max(div(total + @comments_per_page - 1, @comments_per_page), 1)
    page = args["page"] |> int(nil) |> elem_or(1) |> max(1) |> min(pages)

    comments =
      from(c in Comment,
        where: c.card_id == ^card.id,
        order_by: [asc: c.inserted_at, asc: c.id],
        offset: ^((page - 1) * @comments_per_page),
        limit: @comments_per_page,
        preload: :user
      )
      |> Repo.all()

    first = (page - 1) * @comments_per_page + 1

    [
      if(total == 0,
        do: "#{label(card)} has no comments.",
        else:
          "Comments on #{label(card)}: #{first}–#{first + length(comments) - 1} of #{total}, " <>
            "oldest first (page #{page} of #{pages})."
      ),
      Enum.map(comments, fn c ->
        ["", "[comment ##{c.id}] #{at(c.inserted_at)} · #{author(c)}", cap(c.body, @comment_cap)]
      end),
      page < pages && "\nMore: card_comments with page #{page + 1}."
    ]
    |> lines()
  end

  defp render("card_handoffs", card, _args) do
    handoffs =
      from(h in Handoff,
        where: h.card_id == ^card.id,
        order_by: [desc: h.inserted_at, desc: h.id],
        preload: :user
      )
      |> Repo.all()

    case handoffs do
      [] ->
        "#{label(card)} has never had a handoff."

      list ->
        [
          "Handoffs on #{label(card)}, newest first (#{length(list)}):",
          Enum.map(list, fn h ->
            [
              "",
              "[handoff ##{h.id}] #{at(h.inserted_at)} · by #{handoff_by(h)}",
              "Next: #{h.next_step || "(none)"}",
              present(h.body) && cap(h.body, @comment_cap)
            ]
          end)
        ]
        |> lines()
    end
  end

  defp render("card_links", card, _args) do
    card = Repo.preload(card, [[links_out: :to], [links_in: :from], :blocked_by, :blocks])

    links =
      Enum.map(card.links_out, &"- #{CardLink.label(&1.kind, :out)} #{label(&1.to)}") ++
        Enum.map(card.links_in, &"- #{CardLink.label(&1.kind, :in)} #{label(&1.from)}")

    [
      "Links and dependencies of #{label(card)}:",
      "Blocked by: " <> cards_or_none(card.blocked_by),
      "Blocks: " <> cards_or_none(card.blocks),
      if(links == [], do: "Links: none", else: ["Links:" | links])
    ]
    |> lines()
  end

  defp render("card_subcards", card, _args), do: subcards_text(card, true)

  defp render("card_jobs", card, _args) do
    case jobs(card) do
      [] ->
        "No runner job has been sent on #{label(card)}."

      jobs ->
        [
          "Runner jobs on #{label(card)}, oldest first (#{length(jobs)}):",
          Enum.map(jobs, &["", job_text(&1, false)])
        ]
        |> lines()
    end
  end

  defp render("card_timeline", card, _args) do
    timeline = CardTimeline.for_card(card)
    waits = Boards.list_waits(card) |> Enum.reverse()

    activity =
      from(a in Activity,
        where: a.card_id == ^card.id,
        order_by: [desc: a.inserted_at, desc: a.id],
        limit: @activity_limit
      )
      |> Repo.all()
      |> Enum.reverse()

    [
      "Timeline of #{label(card)}, from #{at(timeline.from)} to now (#{at(timeline.to)}), " <>
        "#{dur(CardTimeline.seconds(timeline))} in all.",
      "",
      "Lists it sat in:",
      if(timeline.stays == [],
        do: "- (no moves recorded)",
        else: Enum.map(timeline.stays, &stay_line/1)
      ),
      "",
      "Waits on a person:",
      if(waits == [], do: "- none", else: Enum.map(waits, &wait_text/1)),
      "",
      "Runner jobs:",
      if(timeline.jobs == [],
        do: "- none",
        else:
          Enum.map(timeline.jobs, fn j ->
            "- job ##{j.id} (#{j.kind}, #{j.status}): #{span(j)}"
          end)
      ),
      "",
      "Activity log (newest #{@activity_limit} at most, oldest first):",
      if(activity == [],
        do: "- none",
        else: Enum.map(activity, &"- #{at(&1.inserted_at)} · #{&1.message}#{actor(&1)}")
      )
    ]
    |> lines()
  end

  defp render("card_verification", card, _args) do
    root = Repo.get!(Board, Boards.root_of_board(card.board_id))
    jobs = jobs(card)

    [
      "Verified work on #{label(card)}:",
      "Board checks on: #{switches_text(Verified.switches(root))}",
      bar_text(card),
      "",
      evidence_text(card),
      "",
      verdict_text(card),
      opt(present(card.verify_note), "Latest reason: #{card.verify_note}"),
      opt(card.verify_commit, "Commit checked: #{card.verify_commit}"),
      "Rejections: #{card.verify_rejections}",
      "",
      "Verdicts, rejections and audits, as commented:",
      verdicts_text(verdict_comments(card)),
      "",
      "Verify jobs: " <> jobs_brief(Enum.filter(jobs, &(&1.kind == "verify"))),
      "Merge jobs: " <> jobs_brief(Enum.filter(jobs, &(&1.kind == Verified.merge_kind()))),
      opt(card.merge_sha, "Merged as: #{card.merge_sha}"),
      "",
      deploys_text(card, root)
    ]
    |> lines()
  end

  defp render("card_lead_time", card, _args) do
    epic = LeadTime.for_epic(card)

    [
      lead_text(card, epic.card, true),
      subcards_lead_text(epic)
    ]
    |> lines()
  end

  defp bar_text(%Card{bar: bar} = card) do
    cond do
      not present(bar) -> "Bar: none written"
      card.bar_locked_at -> "Bar: (locked #{at(card.bar_locked_at)})\n#{bar}"
      true -> "Bar: (not locked yet)\n#{bar}"
    end
  end

  defp evidence_text(card) do
    if Verified.evidence?(card),
      do: Verified.evidence_text(card),
      else: "Evidence: none on the card now (it is cleared when work is sent back)."
  end

  defp verdict_text(card) do
    "Verdict: #{card.verify_state || "never submitted"}" <>
      suffix(card.verify_submitter, fn ->
        "; submitted by #{Verified.who(card.verify_submitter)}"
      end) <>
      suffix(card.verify_by, fn -> "; decided by #{Verified.who(card.verify_by)}" end) <>
      suffix(card.verify_at, fn -> " at #{at(card.verify_at)}" end)
  end

  defp verdicts_text([]), do: "- none"

  defp verdicts_text(verdicts),
    do: Enum.map(verdicts, &["", "[comment ##{&1.id}] #{at(&1.inserted_at)}", &1.body])

  ## Lead time -----------------------------------------------------------------

  @phase_names %{
    backlog: "backlog",
    waiting_for_runner: "waiting for a runner",
    build: "build",
    ci: "CI",
    waiting_on_person: "waiting on a person",
    verification_wait: "waiting for verification",
    verify: "verify",
    rework: "rework after a rejection",
    merge: "merge",
    deploy: "deploy",
    unexplained: "unexplained (the record holds nothing for it)"
  }

  @segment_cap 60
  @held_cap 5

  defp lead_text(card, lt, segments?) do
    [
      "Lead time of #{label(card)}: #{dur(lt.seconds)}, #{lead_span(lt)}.",
      "By phase:",
      phase_lines(lt.totals, lt.seconds),
      opt(segments?, ["", "In order (#{length(lt.segments)} spans):" | segment_lines(lt)]),
      opt(
        segments? and lt.jobs == 0,
        "No runner job was ever sent on it: its time comes from the lists it sat in."
      )
    ]
  end

  defp lead_span(%{ends: :deployed} = lt),
    do:
      "from its creation #{at(lt.from)} to its first deploy #{at(lt.to)}; " <>
        "done #{at(lt.done_at)}, #{dur(lt.done_seconds)} after creation"

  defp lead_span(%{ends: :completed} = lt),
    do:
      "from its creation #{at(lt.from)} to done #{at(lt.to)} " <>
        "(no recorded deploy names it)"

  defp lead_span(lt), do: "from its creation #{at(lt.from)} to now (#{at(lt.to)}): still open"

  defp phase_lines(totals, seconds) do
    LeadTime.phases()
    |> Enum.filter(&(totals[&1] > 0))
    |> Enum.map(fn phase ->
      "- #{@phase_names[phase]}: #{dur(totals[phase])}" <>
        if(seconds > 0, do: " (#{round(totals[phase] * 100 / seconds)}%)", else: "")
    end)
    |> case do
      [] -> ["- none: no time has passed"]
      lines -> lines
    end
  end

  defp segment_lines(lt) do
    shown = Enum.take(lt.segments, @segment_cap)

    Enum.map(shown, &segment_line/1) ++
      if length(lt.segments) > @segment_cap,
        do: ["- … #{length(lt.segments) - @segment_cap} more spans not shown"],
        else: []
  end

  defp segment_line(s) do
    "- #{at(s.from)} → #{at(s.to)} · #{@phase_names[s.phase]} (#{dur(s.seconds)})" <>
      suffix(s.note, fn -> ": #{s.note}" end) <>
      suffix(s.refs != [], fn -> " [#{Enum.join(s.refs, ", ")}]" end) <>
      held_text(s[:held_by])
  end

  defp held_text(nil), do: ""
  defp held_text([]), do: " · no other job on its pool was running"

  defp held_text(jobs) do
    more = length(jobs) - @held_cap

    " · its pool was busy with " <>
      Enum.map_join(Enum.take(jobs, @held_cap), "; ", fn j ->
        "job ##{j.job_id} (#{j.kind}) on ##{j.card_id} “#{j.title}”, #{at(j.from)} → " <>
          if(j.to, do: at(j.to), else: "still running")
      end) <>
      if(more > 0, do: "; and #{more} more jobs", else: "")
  end

  defp subcards_lead_text(%{subcards: []}), do: nil

  defp subcards_lead_text(%{subcards: subs, total: total}) do
    [
      "",
      "Its subcards (#{length(subs)}), each from its own creation:",
      Enum.map(subs, fn {sub, lt} ->
        [
          "",
          "Lead time of #{label(sub)}: #{dur(lt.seconds)}, #{lead_span(lt)}."
          | phase_lines(lt.totals, lt.seconds)
        ]
      end),
      "",
      "The subcards added up: #{dur(total.seconds)}.",
      phase_lines(total.totals, total.seconds)
    ]
  end

  ## Job logs ------------------------------------------------------------------

  # Where the log stands: nil when there is one to read, else what to say.
  defp log_missing(%Job{} = job) do
    job = Repo.preload(job, :transcript_page)

    cond do
      job.transcript_deleted_at ->
        "Job ##{job.id}'s log has expired: it was deleted #{at(job.transcript_deleted_at)}, " <>
          "as the board deletes logs nobody kept. The job's steps, summary and exit status " <>
          "remain (read_job)."

      job.transcript_lines == 0 and job.transcript_page ->
        "Job ##{job.id}'s log isn't on the server any more, but it was kept as page " <>
          "#{job.transcript_page.code} (#{job.transcript_page.title}), which holds what its " <>
          "agent said."

      job.transcript_lines == 0 ->
        "Job ##{job.id} has no log: its runner sent none" <>
          if(Job.open?(job), do: " yet.", else: " (runners send one since #1870).")

      true ->
        nil
    end
  end

  defp log_summary_text(job) do
    case log_missing(job) do
      nil -> job |> Transcript.read() |> TranscriptSummary.summarise() |> summary_text(job)
      message -> message
    end
  end

  defp summary_text(sum, job) do
    [
      "Log of job ##{job.id} (#{job.kind} on ##{job.card_id}): #{sum.lines} lines" <>
        log_state(job) <> ".",
      "Spans #{at(sum.from)} → #{at(sum.to)}, #{dur(sum.seconds)}.",
      "",
      "Where the time went (each stretch between two lines goes to the tool call waiting " <>
        "for its answer, else to the model):",
      "- model (thinking and writing): #{dur(sum.model_seconds)}#{share(sum.model_seconds, sum.seconds)}",
      "- tools: #{dur(sum.tool_seconds)}#{share(sum.tool_seconds, sum.seconds)}",
      tool_kind_lines(sum),
      "",
      "Longest calls:",
      if(sum.longest == [], do: "- none", else: Enum.map(sum.longest, &call_line/1)),
      "",
      "Failed calls (#{length(sum.failed)}):",
      if(sum.failed == [],
        do: "- none",
        else:
          Enum.map(
            sum.failed,
            &[call_line(&1), "  said: " <> String.replace(&1.error, "\n", "\n  ")]
          )
      ),
      "",
      "What the agent said (#{length(sum.messages)} messages):",
      message_lines(sum.messages),
      "",
      "job_log with from and to reads any stretch of it in full."
    ]
    |> lines()
  end

  defp log_state(job) do
    job = Repo.preload(job, :transcript_page)

    cond do
      Job.open?(job) -> ", still coming in: the job is #{job.status}"
      job.transcript_page -> ", kept as page #{job.transcript_page.code}"
      exp = TranscriptRetention.expires_at(job) -> ", expiring #{at(exp)}"
      true -> ""
    end <>
      if(job.transcript_capped,
        do: " (it reached its size limit, so its end is missing)",
        else: ""
      )
  end

  defp share(_part, 0), do: ""
  defp share(part, whole), do: " (#{round(part * 100 / whole)}%)"

  defp tool_kind_lines(sum) do
    TranscriptSummary.kinds()
    |> Enum.filter(&(sum.tools[&1].calls > 0))
    |> Enum.map(fn kind ->
      t = sum.tools[kind]
      "  - #{kind}: #{dur(t.seconds)} over #{t.calls} call#{if t.calls == 1, do: "", else: "s"}"
    end)
  end

  defp call_line(c) do
    took = if c.seconds, do: " · #{dur(c.seconds)}", else: " · no answer in the log"
    "- line #{c.line} · #{at(c.at)} · #{c.name} (#{c.kind}): #{c.what}#{took}"
  end

  defp message_lines([]), do: "- none"

  defp message_lines(messages) do
    shown =
      if length(messages) > @log_messages,
        do:
          Enum.take(messages, div(@log_messages, 2)) ++
            [:gap] ++ Enum.take(messages, -div(@log_messages, 2)),
        else: messages

    Enum.map(shown, fn
      :gap -> "- … #{length(messages) - @log_messages} more in between (job_log reads them)"
      m -> "- line #{m.line} · #{at(m.at)}: #{cap(m.text, @log_message_cap)}"
    end)
  end

  defp log_stretch_text(job, args) do
    with nil <- log_missing(job),
         {:ok, from} <- int(args["from"] || 0, "from must be a line number."),
         {:ok, to} <- int(args["to"] || from + @log_stretch - 1, "to must be a line number.") do
      from = max(from, 0)
      to = to |> min(from + @log_stretch - 1) |> max(from)
      stretch(job, from, to)
    else
      {:error, message} -> message
      message -> message
    end
  end

  defp stretch(job, from, to) do
    text =
      job
      |> Transcript.read(from)
      |> String.split("\n")
      |> Enum.take(to - from + 1)
      |> Enum.join("\n")

    entries = TranscriptView.entries(text, from)

    body =
      Enum.map_join(entries, "\n", fn e ->
        line = "[line #{e.line}] " <> TranscriptView.format(e)
        if e.detail, do: line <> "\n" <> cap(e.detail, @log_entry_cap), else: line
      end)

    [
      "Job ##{job.id}'s log, lines #{from}–#{to} of #{job.transcript_lines} " <>
        "(#{length(entries)} entries; hook output and thinking are left out):",
      if(body == "", do: "(nothing to show in these lines)", else: cap(body, @log_stretch_cap)),
      to + 1 < job.transcript_lines && "More: job_log from #{to + 1}."
    ]
    |> lines()
  end

  ## Pieces --------------------------------------------------------------------

  defp full_preloads do
    [
      :board,
      :column,
      :tags,
      :assignee,
      :assignees,
      :checklist_items,
      :status_updates,
      :attachments,
      :blocked_by,
      :blocks,
      :votes,
      :handoff,
      [comments: from(c in Comment, order_by: [asc: c.inserted_at, asc: c.id])],
      [sub_board: :cards],
      [links_out: :to],
      [links_in: :from],
      [field_values: []]
    ]
  end

  defp subcards_text(card, full? \\ false) do
    card = Repo.preload(card, [sub_board: [:columns, cards: [:column, :assignees]]], force: true)

    case card.sub_board do
      nil ->
        "#{label(card)} has no subcards."

      %Board{cards: cards} = board ->
        cards = Enum.sort_by(cards, &{&1.column && &1.column.position, &1.position})
        latest = latest_jobs(Enum.map(cards, & &1.id))
        done = Enum.count(cards, & &1.completed)

        [
          "Subcards of #{label(card)} (board #{board.code || board.id}): #{done} of #{length(cards)} done.",
          Enum.map(cards, &subcard_line(&1, latest[&1.id], full?))
        ]
        |> lines()
    end
  end

  defp subcard_line(card, job, full?) do
    people = Card.assignees(card)

    [
      "- #{label(card)} · #{column_name(card)}",
      if(card.completed, do: " · done", else: " · open"),
      opt(card.archived_at, " · archived"),
      opt(card.verify_state, " · verification: #{card.verify_state}"),
      opt(card.verify_rejections > 0, " · rejected #{card.verify_rejections}×"),
      opt(full? and card.flags != [], " · flags: #{Enum.join(card.flags, ", ")}"),
      opt(
        full? and people != [],
        " · assigned: #{Enum.map_join(people, ", ", &User.display_name/1)}"
      ),
      suffix(job, fn -> " · latest job ##{job.id} (#{job.kind}, #{job.status})" end)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end

  defp column_name(%Card{column: %{name: name}}), do: name
  defp column_name(_), do: "?"

  defp latest_jobs([]), do: %{}

  defp latest_jobs(ids) do
    from(j in Job,
      where: j.card_id in ^ids,
      distinct: j.card_id,
      order_by: [asc: j.card_id, desc: j.inserted_at, desc: j.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.card_id, &1})
  end

  defp jobs(card) do
    from(j in Job, where: j.card_id == ^card.id, order_by: [asc: j.inserted_at, asc: j.id])
    |> Repo.all()
    |> Repo.preload(:transcript_page)
  end

  @doc false
  def job_text(%Job{} = job, prompt?) do
    job = Repo.preload(job, :transcript_page)

    [
      job_head(job),
      job_times(job),
      opt(job.recovery, "Recovery: #{job.recovery}"),
      opt(job.merged_sha, "Merged as: #{job.merged_sha}"),
      opt(present(job.error), "Error: #{cap(job.error, @output_cap)}"),
      opt(present(job.output), "Summary: #{cap(job.output, @output_cap)}"),
      steps_text(job),
      log_line(job),
      opt(prompt?, "Prompt:\n" <> cap(job.prompt || "(none)", @prompt_cap))
    ]
    |> lines()
  end

  defp job_head(job) do
    "Job ##{job.id} · #{job.kind}#{suffix(job.audit, " (an audit)")} · pool #{job.pool} · " <>
      "runner #{job.runner_name || "none yet"} · #{job.status}" <>
      suffix(job.exit_code, fn -> " (exit #{job.exit_code})" end) <>
      suffix(job.attempts > 1, fn -> " · #{job.attempts} attempts" end)
  end

  defp job_times(job) do
    "Queued #{at(job.inserted_at)}" <>
      stamp("claimed", job.claimed_at, job.inserted_at) <>
      stamp("started", job.started_at, job.claimed_at) <>
      stamp("finished", job.finished_at, job.started_at || job.claimed_at)
  end

  defp steps_text(%Job{steps: steps} = job) when is_list(steps) and steps != [] do
    {lines, _} =
      Enum.map_reduce(steps, job.started_at || job.claimed_at, fn step, prev ->
        when_at = parse_at(step["at"])
        gap = if prev && when_at, do: " (+#{dur(DateTime.diff(when_at, prev))})", else: ""
        {"  - #{at(when_at)}#{gap} #{step["text"]}", when_at || prev}
      end)

    ["Steps it reported (#{length(steps)}):" | lines]
  end

  defp steps_text(%Job{step: step, step_at: step_at}) when is_binary(step),
    do: "Latest step it reported: #{at(step_at)} #{step} (earlier steps weren't kept then)"

  defp steps_text(_job), do: "Steps: none reported."

  defp log_line(%Job{transcript_lines: 0, transcript_deleted_at: nil}), do: nil

  defp log_line(%Job{} = job) do
    cond do
      job.transcript_page ->
        "Log: kept as page #{job.transcript_page.code} (#{job.transcript_page.title})"

      job.transcript_deleted_at ->
        "Log: expired and deleted #{at(job.transcript_deleted_at)}"

      true ->
        expiry = TranscriptRetention.expires_at(job)

        "Log: #{job.transcript_lines} lines on the server" <>
          if(expiry, do: ", expiring #{at(expiry)}", else: "")
    end
  end

  defp stamp(_what, nil, _prev), do: ""

  defp stamp(what, at, prev) do
    gap = if prev, do: " (+#{dur(DateTime.diff(at, prev))})", else: ""
    ", #{what} #{at(at)}#{gap}"
  end

  defp jobs_brief([]), do: "none"

  defp jobs_brief(jobs) do
    Enum.map_join(jobs, "; ", fn j ->
      "##{j.id} #{j.status}" <>
        suffix(j.audit, " (audit)") <>
        suffix(j.runner_name, fn -> " on #{j.runner_name}" end) <>
        suffix(j.finished_at, fn -> " #{at(j.finished_at)}" end) <>
        suffix(present(j.error), fn -> " — #{cap(j.error, 300)}" end)
    end)
  end

  # The comments verification wrote: each verdict, rejection and audit
  # with its reason, oldest first.
  defp verdict_comments(card) do
    from(c in Comment,
      where:
        c.card_id == ^card.id and
          (like(c.body, "**Rejected** by%") or like(c.body, "**Accepted** by%") or
             like(c.body, "**Audit: %") or like(c.body, "**Evidence.**%") or
             like(c.body, "**Merge%")),
      order_by: [asc: c.inserted_at, asc: c.id]
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | body: cap(&1.body, @comment_cap)})
  end

  defp deploys_text(card, root) do
    if Deployments.enabled?(root),
      do: shipped_text(Deployments.shipped(card)),
      else:
        "Deploys: this board doesn't record deploys (its delivery metrics are off), " <>
          "so the record can't say whether it shipped."
  end

  defp shipped_text([]), do: "Deploys: no recorded deploy names this card."

  defp shipped_text(list),
    do: ["Deploys:" | Enum.map(list, &"- #{Deployments.shipped_text(&1)} (#{at(&1.at)})")]

  defp switches_text([]), do: "none"
  defp switches_text(on), do: Enum.map_join(on, ", ", &to_string/1)

  defp stay_line(stay) do
    how =
      case stay.how do
        %{by: by, kind: kind} when is_binary(by) -> " · #{kind} by #{by}"
        %{kind: kind} -> " · #{kind}"
        _ -> ""
      end

    "- #{stay.list}#{if stay.category, do: " (#{stay.category})", else: ""}: #{span(stay)}#{how}" <>
      if(stay.unsure, do: " · the ledger can't vouch for this span's edges", else: "")
  end

  defp span(%{from: from, to: to} = s) do
    "#{at(from)} → #{if s[:open], do: "now", else: at(to)} (#{dur(DateTime.diff(to, from))}" <>
      if(s[:open], do: ", still going)", else: ")")
  end

  defp wait_text(w) do
    [
      "- wait ##{w.id} on #{Slipdock.Boards.Wait.on_name(w)}, opened #{at(w.inserted_at)}" <>
        suffix(w.agent, fn -> " by #{w.agent}" end) <>
        suffix(w.job_id, fn -> " from job ##{w.job_id}" end) <>
        wait_end(w),
      "  Asked: #{cap(w.needs, 800)}",
      wait_questions(w),
      opt(present(w.answer), "  Answer: #{cap(w.answer || "", 800)}"),
      opt(w.requeue_job_id, "  The answer started job ##{w.requeue_job_id}.")
    ]
    |> lines()
  end

  defp wait_end(%{closed_at: nil}), do: ", still open"

  defp wait_end(w),
    do:
      ", closed #{at(w.closed_at)} (#{w.close_reason}) after " <>
        dur(DateTime.diff(w.closed_at, w.inserted_at))

  defp wait_questions(w) do
    answers = w.answers || []

    (w.questions || [])
    |> Enum.with_index(1)
    |> Enum.map(fn {q, i} ->
      "  Q#{i}: #{cap(q, 400)}" <>
        case Enum.at(answers, i - 1) do
          a when is_binary(a) and a != "" -> "\n  A#{i}: #{cap(a, 600)}"
          _ -> ""
        end
    end)
  end

  defp handoff_line(%Handoff{} = h),
    do: "Handoff (#{at(h.inserted_at)}): next — #{h.next_step || "(none)"}"

  defp handoff_line(_), do: nil

  defp wait_line(nil), do: nil

  defp wait_line(w),
    do: "Open wait ##{w.id} on #{Slipdock.Boards.Wait.on_name(w)}: #{cap(w.needs, 400)}"

  defp verify_line(%Card{verify_state: nil}), do: nil

  defp verify_line(card),
    do:
      "Verification: #{card.verify_state}, rejected #{card.verify_rejections}× " <>
        "(card_verification has the detail)"

  defp handoff_by(%Handoff{} = h) do
    who = if h.user, do: User.display_name(h.user), else: "the server"
    via = if h.via, do: " via #{h.via}", else: ""
    job = if h.job_id, do: ", job ##{h.job_id}", else: ""
    who <> via <> job
  end

  defp author(%Comment{user: %User{} = u}), do: User.display_name(u)
  defp author(%Comment{kind: "epic_log"}), do: "the server (epic progress)"
  defp author(_), do: "the server"

  defp actor(%Activity{actor_name: name}) when is_binary(name) and name != "", do: " (#{name})"
  defp actor(_), do: ""

  defp cards_or_none([]), do: "none"
  defp cards_or_none(cards), do: Enum.map_join(cards, ", ", &label/1)

  defp label(%Card{} = card), do: "##{card.id} “#{card.title}”"
  defp label(_), do: "a card"

  ## Formatting ----------------------------------------------------------------

  @doc false
  def at(nil), do: "?"
  def at(%DateTime{} = t), do: Calendar.strftime(t, "%Y-%m-%d %H:%M:%S UTC")
  def at(%NaiveDateTime{} = t), do: t |> DateTime.from_naive!("Etc/UTC") |> at()

  @doc "A duration in seconds, in words a person reads: `45s`, `51m`, `1h 18m`, `2d 3h`."
  def dur(s) when not is_integer(s) or s < 0, do: "0s"
  def dur(s) when s < 60, do: "#{s}s"
  def dur(s) when s < 600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  def dur(s) when s < 3600, do: "#{div(s, 60)}m"
  def dur(s) when s < 86_400, do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
  def dur(s), do: "#{div(s, 86_400)}d #{div(rem(s, 86_400), 3600)}h"

  defp parse_at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, t, _} -> t
      _ -> nil
    end
  end

  defp parse_at(_), do: nil

  defp int(n, _msg) when is_integer(n), do: {:ok, n}

  defp int(n, msg) when is_binary(n) do
    case Integer.parse(String.trim_leading(n, "#")) do
      {v, ""} -> {:ok, v}
      _ -> {:error, msg}
    end
  end

  defp int(_n, msg), do: {:error, msg}

  defp elem_or({:ok, v}, _default), do: v
  defp elem_or(_, default), do: default

  # `text` when `value` is truthy, else nothing (left out of `lines/1`).
  defp opt(value, _text) when value in [nil, false], do: nil
  defp opt(_value, text), do: text

  # `text` (or what the function makes) when `value` is truthy, else "".
  defp suffix(value, _text) when value in [nil, false], do: ""
  defp suffix(_value, text) when is_function(text, 0), do: text.()
  defp suffix(_value, text), do: text

  defp present(s) when is_binary(s), do: String.trim(s) != ""
  defp present(_), do: false

  defp cap(nil, _n), do: ""

  defp cap(text, n) do
    if String.length(text) > n,
      do: String.slice(text, 0, n) <> " … (cut at #{n} characters)",
      else: text
  end

  defp lines(parts) do
    parts
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end
end
