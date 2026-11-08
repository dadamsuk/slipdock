defmodule SlipdockWeb.CardShapeDocsTest do
  @moduledoc """
  How a one-sentence ask becomes a card (#2042): eight bullets in the
  guide's *Epics and subcards*, and the line saying a handbook's Playbook
  overrides them, said the same in `docs/agents.md`, on the agents help
  page and in `slipdock-work`. Sprints moved to a section of
  their own so the short guide, which carries Epics whole, keeps its caps.
  """
  # The guide reads the settings, so this needs the database.
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SlipdockWeb.APIGuide

  @root Path.expand("../..", __DIR__)

  # Line breaks folded, for prose that is rewrapped as it changes.
  defp flat(text), do: String.replace(text, ~r/\s+/, " ")

  defp copies(skill) do
    [Path.join([@root, "priv/skills", skill, "SKILL.md"])]
  end

  # The bullets after the first "Card shape" up to the override line, flattened.
  defp bullets(text) do
    [_, after_heading] = String.split(text, "Card shape", parts: 2)
    [list, _] = String.split(after_heading, "A board's handbook can override these", parts: 2)

    ~r/^- (\*\*.+?)(?=^- \*\*|\z)/ms
    |> Regex.scan(list)
    |> Enum.map(fn [_, item] -> flat(item) |> String.trim() end)
  end

  defp epics do
    {:ok, epics} = APIGuide.section("epics", [])
    epics
  end

  test "the guide's Epics and subcards carries the eight bullets" do
    items = bullets(epics())
    assert length(items) == 8

    for {start, item} <-
          Enum.zip(
            [
              "**One card** when the ask fits one sitting, one agent and one PR",
              "**Where:** under the epic it serves",
              "**Three things in the description**",
              "**Don't add** an estimate, priority, tags, a due date or an assignee",
              "**Don't repeat the repo's rules**",
              "**Two readings:** write the obvious one",
              # The same, applied to a locked bar (#2096).
              "**A bar item made moot** by a later, cited decision or rule",
              "**Dependencies:** `blocked_by` means *can't start until*"
            ],
            items
          ),
        do: assert(String.starts_with?(item, start), item)

    text = flat(epics())
    assert text =~ "Never an epic with one subcard"
    assert text =~ "a **done-when** line, the stop condition the evidence answers"
    assert text =~ "no Given/When/Then unless the board's Playbook asks for it"
    assert text =~ "A one-card ask gets none unless the person said \"after X\"."
  end

  test "and says a handbook's Playbook overrides them" do
    assert flat(epics()) =~
             "A board's handbook can override these: the `## Card shape` section of its Playbook page wins wherever it says otherwise."
  end

  test "docs/agents.md says the same, bullet for bullet" do
    agents = File.read!(Path.join(@root, "docs/agents.md"))
    assert agents =~ "## How an ask becomes a card"
    assert bullets(agents) == bullets(epics())

    assert flat(agents) =~
             "the `## Card shape` section of its Playbook page wins wherever it says otherwise"
  end

  test "slipdock-work points at it", %{} do
    for path <- copies("slipdock-work") do
      text = flat(File.read!(path))
      assert text =~ "A one-sentence ask becomes a card as the guide's **Card shape** says", path
      assert text =~ "A board's handbook Playbook `## Card shape` overrides it.", path
    end
  end

  test "the agents help page lists them", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/help/agents/guide")
    assert html =~ "How an ask becomes a card"
    assert html =~ "Never an epic with one subcard"
    assert html =~ "the Card shape section of its Playbook page wins"
  end

  test "sprints are their own section, and the short guide keeps its caps" do
    {:ok, sprints} = APIGuide.section("sprints", [])
    assert sprints =~ "## Sprints"
    assert sprints =~ "POST /api/cards/:sprint/sprint"
    refute epics() =~ "POST /api/cards/:sprint/sprint"
    # What a working agent must still know is in Epics: a stand-in is not work.
    assert flat(epics()) =~ "It is not work: do not pick it up, edit it or count it"

    short = APIGuide.short()
    assert short =~ "**Card shape.**"
    assert short =~ "- `sprints` — Sprints"
    assert byte_size(short) < 22_000
  end
end
