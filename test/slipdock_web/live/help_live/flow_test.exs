defmodule SlipdockWeb.HelpLive.FlowTest do
  @moduledoc """
  Help › How work flows (#1885): one card from being written to the deploy.

  What matters: the Working with an AI agent page, the Runners topic and the
  hub all lead to it; it has the seven stages in order, each saying who acts;
  every place a person must act is marked; and every `slipdock …` command
  and board setting it names still exists, checked against the CLI's own
  help (`cli/help.txt`) and the board's Agentic Building page, so a rename breaks
  this test rather than leaving the page wrong.
  """
  use SlipdockWeb.ConnCase, async: true

  import Slipdock.DocsFacts, only: [assert_states: 2, assert_states: 3]

  import Phoenix.LiveViewTest

  alias SlipdockWeb.HelpLive.{CLIHelp, Flow}

  @stages [
    "1. Writing the card",
    "2. Queued and claimed",
    "3. Building",
    "4. Shipping",
    "5. Submitting",
    "6. Verifying",
    "7. Afterwards"
  ]

  # The page, mounted. A join the server refuses as stale or unauthorized
  # comes back from LiveViewTest as a redirect to the page's own URL, and once
  # under load (seed 711914 in `mix pre_push`'s repo checks, #2828) the first
  # join here was, though nothing on the page or its hooks redirects. Such a
  # refusal is tried once more; a page that really sends itself to itself is
  # refused again, and the caller's `{:ok, …}` match fails as before. The
  # mount is an argument so "mounting it" below can hold that with a stand-in.
  defp live_flow(conn, mount \\ &live/2) do
    path = ~p"/help/agents/flow"

    case mount.(conn, path) do
      {:error, {:redirect, %{to: to}}} = refused ->
        if URI.parse(to).path == path, do: mount.(conn, path), else: refused

      mounted ->
        mounted
    end
  end

  defp doc(html), do: LazyHTML.from_document(html)

  defp texts(doc, selector),
    do: doc |> LazyHTML.query(selector) |> Enum.map(&(LazyHTML.text(&1) |> squash()))

  defp squash(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp assert_stages(html) do
    assert texts(doc(html), "#help-flow section[id^='flow-'] h2.section-title")
           |> Enum.filter(&(&1 =~ ~r/^\d\. /)) == @stages
  end

  describe "the way to it" do
    @tag :anonymous
    test "Working with an AI agent links to it near the top, and the link lands", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/help/agents")

      # Above the ways in, as their overview.
      [intro_at, ways_at] =
        Enum.map(["help-flow-intro", "help-ways"], fn id ->
          :binary.match(html, ~s{id="#{id}"}) |> elem(0)
        end)

      assert intro_at < ways_at

      view |> element("#help-flow-link") |> render_click()

      assert_patch(view, ~p"/help/agents/flow")
      assert_stages(render(view))
      assert page_title(view) =~ "How work flows"
    end

    @tag :anonymous
    test "the Runners topic links to it, and the link lands", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help/agents/runners")

      view |> element("#help-runners-flow") |> render_click()

      assert_patch(view, ~p"/help/agents/flow")
      assert_stages(render(view))
    end

    test "the hub and every topic's nav reach it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/help")
      view |> element("#help-hub-agents-flow") |> render_click()
      assert_patch(view, ~p"/help/agents/flow")

      {:ok, view, _html} = live(conn, ~p"/help/agents/mcp")
      view |> element("#help-topics-flow") |> render_click()
      assert_patch(view, ~p"/help/agents/flow")
      assert has_element?(view, ~s{#help-topics-flow[aria-current="page"]})
      refute has_element?(view, "#help-compare")
    end
  end

  describe "mounting it" do
    # live_flow/2 with a stand-in mount that answers from a script, one reply
    # per mount, and counts the mounts: what a refused join, a second
    # refusal and a real redirect each get.
    @self_refusal {:error, {:redirect, %{to: "http://www.example.com/help/agents/flow"}}}

    defp scripted_mount(replies) do
      Process.put(:flow_mount_replies, replies)

      fn _conn, path ->
        send(self(), {:mounted, path})
        [reply | rest] = Process.get(:flow_mount_replies)
        Process.put(:flow_mount_replies, rest)
        reply
      end
    end

    defp mounts do
      receive do
        {:mounted, "/help/agents/flow"} -> 1 + mounts()
      after
        0 -> 0
      end
    end

    test "a mount that works first time is mounted once", %{conn: conn} do
      assert live_flow(conn, scripted_mount([{:ok, :view, "html"}])) == {:ok, :view, "html"}
      assert mounts() == 1
    end

    test "a join refused once is tried again, and the second mount is what comes back",
         %{conn: conn} do
      mount = scripted_mount([@self_refusal, {:ok, :view, "html"}])

      assert live_flow(conn, mount) == {:ok, :view, "html"}
      assert mounts() == 2
    end

    test "a page refused twice gives back the refusal, so the caller's {:ok, …} match fails",
         %{conn: conn} do
      mount = scripted_mount([@self_refusal, @self_refusal, {:ok, :view, "html"}])

      assert live_flow(conn, mount) == @self_refusal
      assert mounts() == 2
    end

    test "a redirect to another page comes back at once, with no second mount",
         %{conn: conn} do
      elsewhere = {:error, {:redirect, %{to: "http://www.example.com/help/agents"}}}
      live_redirect = {:error, {:live_redirect, %{to: "/help/agents/flow"}}}

      assert live_flow(conn, scripted_mount([elsewhere, {:ok, :view, "html"}])) == elsewhere
      assert mounts() == 1

      assert live_flow(conn, scripted_mount([live_redirect, {:ok, :view, "html"}])) ==
               live_redirect

      assert mounts() == 1
    end

    test "the real page mounts through it", %{conn: conn} do
      assert {:ok, _view, html} = live_flow(conn)
      assert_stages(html)
    end
  end

  describe "the page" do
    @tag :anonymous
    test "has the seven stages in order, each saying who acts", %{conn: conn} do
      {:ok, _view, html} = live_flow(conn)
      d = doc(html)

      assert_stages(html)

      for s <- Flow.stages() do
        [who] = texts(d, "#flow-#{s.id} p:has(> span.badge)")
        assert who =~ "Who acts:"
        assert s.actors != []
      end
    end

    @tag :anonymous
    test "the diagram has a node per stage, in order, ringing the ones a person acts at",
         %{conn: conn} do
      {:ok, _view, html} = live_flow(conn)
      d = doc(html)

      ids =
        d |> LazyHTML.query("#flow-diagram ol > li") |> Enum.map(&LazyHTML.attribute(&1, "id"))

      assert ids == Enum.map(Flow.stages(), &["flow-node-#{&1.id}"])

      ringed =
        for s <- Flow.stages(),
            d |> LazyHTML.query(~s{#flow-node-#{s.id} [data-person="true"]}) |> Enum.any?(),
            do: s.id

      assert ringed == ~w(writing building verifying afterwards)

      for id <- ringed, do: assert(texts(d, "#flow-node-#{id}") |> hd() =~ "You act here")

      # Both ways back are drawn on the diagram.
      [verifying] = texts(d, "#flow-node-verifying")
      assert verifying =~ "Rejected: back to 2"
      assert_states(verifying, "Rejected past the limit: a wait on you")
      assert texts(d, "#flow-node-building") |> hd() =~ "a wait on you"
    end

    @tag :anonymous
    test "says a resubmission is judged on what changed, the rest carried (#1944)", %{
      conn: conn
    } do
      {:ok, _view, html} = live_flow(conn)

      text =
        doc(html) |> texts("#flow-verifying") |> Enum.join(" ") |> String.replace(~r/\s+/, " ")

      assert_states(
        text,
        "Submitted again, it is judged on what failed and what the new commits touch"
      )

      assert_states(text, "shown as carried from the commit it passed at")
    end

    @tag :anonymous
    test "says the server moves a list_top job's card on claim, the prompt naming the list (#2633)",
         %{conn: conn} do
      {:ok, _view, html} = live_flow(conn)
      text = doc(html) |> texts("#flow-claimed") |> Enum.join(" ")

      assert_states(text, "the server makes the move the moment a runner claims it")
      assert_states(text, "the job's prompt names that list")
      refute text =~ "The agent moves the card into progress"
    end

    @tag :anonymous
    test "marks every point where a person must act", %{conn: conn} do
      {:ok, _view, html} = live_flow(conn)
      d = doc(html)

      notes = fn id -> texts(d, ~s{#flow-#{id} [data-person="true"]}) |> Enum.join(" ") end

      # Applying proposals.
      assert_states(notes.("afterwards"), "The proposals are yours to apply")
      assert notes.("afterwards") =~ "Tidy-up page"
      # Rejections over the limit.
      assert notes.("verifying") =~ "Rejections before a person decides"
      assert notes.("verifying") =~ "accept it as is"
      # Accepting on a board without a verifier.
      assert notes.("verifying") =~ "With no verify pool"
      assert_states(notes.("submitting"), "With A second agent verifies off")
      # Waits.
      assert notes.("building") =~ "Answer its waits"
      # A bar a person has to word, and a pause only a person lifts.
      assert_states(notes.("writing"), "Write a bar that can be met")
      assert notes.("claimed") =~ "Only a person resumes it"
    end

    test "draws nothing wider than a phone: no fixed minimum widths or sideways scroll" do
      source = Slipdock.DocsText.read!("lib/slipdock_web/live/help_live/flow.ex")

      refute source =~ ~r/min-w-\[|w-\[\d|overflow-x-(auto|scroll)|whitespace-nowrap/
    end
  end

  describe "what it names exists" do
    @tag :anonymous
    test "every slipdock command on the page is in the CLI's help", %{conn: conn} do
      {:ok, _view, html} = live_flow(conn)

      commands =
        doc(html)
        |> texts("#help-flow code")
        |> Enum.filter(&String.starts_with?(&1, "slipdock "))

      # The page names a good many; the settings section alone has nine.
      assert length(commands) >= 20

      entries = help_entries()

      for c <- commands do
        assert check_command(c, entries) == :ok, "#{c}: #{inspect(check_command(c, entries))}"
      end
    end

    test "the check catches a renamed command, subcommand, verb or option" do
      entries = help_entries()

      assert check_command("slipdock garden propose B p.json", entries) == :ok
      assert check_command("slipdock verify 12 accept", entries) == :ok
      assert {:error, {:command, "gardn"}} = check_command("slipdock gardn B", entries)

      assert {:error, {:subcommand, "proposes"}} =
               check_command("slipdock garden proposes B p.json", entries)

      assert {:error, {:verb, "approve"}} = check_command("slipdock verify 12 approve", entries)

      assert {:error, {:option, "--verify-pools"}} =
               check_command("slipdock set-board B --verify-pools x", entries)

      # Options after `--` are the wrapped command's, not slipdock's.
      assert check_command("slipdock deploy run --env production -- ./deploy.sh --x", entries) ==
               :ok
    end

    test "every board setting it names is on the Agentic Building page and in set-board's help" do
      form = Slipdock.DocsText.read!("lib/slipdock_web/live/agentic_live/index.ex")
      entries = help_entries()

      for {label, cli, _what} <- Flow.settings() do
        # A field's label, a switch's, or a section's heading.
        assert form =~ ~s{label="#{label}"} or form =~ ~s{>#{label}</span>} or
                 form =~ ~s{title="#{label}"},
               "#{label} isn't on the board's Agentic Building page"

        assert String.starts_with?(cli, "slipdock set-board B --")
        assert check_command(cli, entries) == :ok, cli
      end
    end
  end

  describe "the manual" do
    test "points to it from Verified work and from Runners" do
      manual = Slipdock.DocsText.read!("docs/manual.md") |> String.replace(~r/\s+/, " ")

      for heading <- ["## Verified work", "## Runners"] do
        [_, rest] = String.split(manual, heading <> " ", parts: 2)
        [section | _] = String.split(rest, " ## ", parts: 2)

        assert_states(
          section,
          "the help page **How work flows** (`/help/agents/flow`)",
          "#{heading} doesn't point to the page"
        )
      end
    end
  end

  # ── Checking a command against the help ───────────────────────────────────

  # Every entry of `slipdock help`, as {the words its usage starts with, all
  # of its text}. An entry like `accept <id> … | reject <id> …` is one entry
  # per side, so each command is found by its own name.
  defp help_entries do
    for g <- CLIHelp.parse(CLIHelp.text()).groups,
        e <- g.entries,
        alt <- String.split(e.usage, ~r/\s+\|\s+/),
        do: {lead_words(alt), Enum.join([e.usage, e.desc | e.details], " ")}
  end

  defp lead_words(usage) do
    usage
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take_while(&(&1 =~ ~r/^[a-z][a-z0-9-]*$/))
  end

  defp check_command("slipdock " <> rest, entries) do
    {words, _wrapped} =
      rest |> String.split(~r/\s+/, trim: true) |> Enum.split_while(&(&1 != "--"))

    [cmd | args] = words
    mine = Enum.filter(entries, &match?({[^cmd | _], _}, &1))

    with :ok <- if(mine == [], do: {:error, {:command, cmd}}, else: :ok),
         {:ok, matched} <- subcommand(cmd, args, mine),
         :ok <- verb(args, matched) do
      known_options(args, matched)
    end
  end

  # A command with literal subcommands (`garden propose`): a lower-case word
  # after the command must be one of them; a placeholder (B, 12) is not one.
  defp subcommand(_cmd, [sub | _], mine) do
    subs = for {[_, s | _], _} = e <- mine, into: %{}, do: {s, e}

    cond do
      not (sub =~ ~r/^[a-z][a-z-]*$/) -> {:ok, mine}
      Map.has_key?(subs, sub) -> {:ok, Enum.filter(mine, &match?({[_, ^sub | _], _}, &1))}
      true -> {:error, {:subcommand, sub}}
    end
  end

  defp subcommand(_cmd, [], mine), do: {:ok, mine}

  # `verify 12 accept`: a word after an id is a verb the usage spells out.
  defp verb([id, word | _], matched) do
    if id =~ ~r/^\d+$/ and word =~ ~r/^[a-z]+$/ and
         not Enum.any?(matched, fn {_, text} -> text =~ ~r/\b#{word}\b/ end),
       do: {:error, {:verb, word}},
       else: :ok
  end

  defp verb(_args, _matched), do: :ok

  defp known_options(args, matched) do
    text = Enum.map_join(matched, " ", &elem(&1, 1))

    case Enum.find(args, &(String.starts_with?(&1, "--") and not (text =~ option_re(&1)))) do
      nil -> :ok
      opt -> {:error, {:option, opt}}
    end
  end

  defp option_re(opt), do: ~r/#{Regex.escape(opt)}(?![a-z-])/
end
