defmodule Slipdock.WikiObsidianTemplatesTest do
  @moduledoc """
  Obsidian's template placeholders (W-103 R7.2): `{{title}}`, `{{date}}`,
  `{{time}}` and their `:FORMAT` forms, filled alongside Slipdock's own.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Wiki
  alias Slipdock.Wiki.ObsidianPlaceholders, as: P

  # A Saturday afternoon, so the 12-hour clock, the weekday and the padding
  # all have something to show.
  @now ~U[2026-03-07 14:05:09Z]

  describe "fill/3" do
    test "the bare forms" do
      assert P.fill("{{title}} on {{date}} at {{time}}", "Retro", @now) ==
               "Retro on 2026-03-07 at 14:05"

      assert P.fill("{{ title }}", "Spaced", @now) == "Spaced"
    end

    test "Moment formats, the subset Obsidian templates use" do
      assert P.fill("{{date:dddd D MMMM YYYY}}", nil, @now) == "Saturday 7 March 2026"
      assert P.fill("{{date:ddd, MMM D YY}}", nil, @now) == "Sat, Mar 7 26"
      assert P.fill("{{date:YYYY-MM-DD[T]HH:mm:ss}}", nil, @now) == "2026-03-07T14:05:09"
      assert P.fill("{{time:h:mm A}}", nil, @now) == "2:05 PM"
      assert P.fill("{{time:hh:m a}}", nil, ~U[2026-03-07 00:07:00Z]) == "12:7 am"
      assert P.fill("{{date:[Week of] M/D}}", nil, @now) == "Week of 3/7"
    end

    test "everything else is left exactly as written" do
      text = "{{card.title}} {{today}} {{count: flag=blocked}} {{title:x}} {{dates}}"
      assert P.fill(text, "T", @now) == text
      # With no title to give, {{title}} waits for Slipdock's own values.
      assert P.fill("{{title}}", nil, @now) == "{{title}}"
      assert P.fill(nil, "T", @now) == nil
    end
  end

  describe "making a page from a template" do
    setup do
      user = user_fixture()
      board = board_fixture(%{"name" => "Notes", "code" => "obstpl"}, owner: user)

      {:ok, template} =
        Wiki.create_page(
          board,
          %{
            "title" => "Daily {{date}}",
            "template" => true,
            "summary" => "{{title}} summary",
            "body" =>
              "# {{title}}\n\nCreated {{date:dddd D MMMM}} at {{time}} on {{board.name}}. {{unknown}}"
          },
          user: user
        )

      %{user: user, board: board, template: template}
    end

    test "Obsidian's and Slipdock's placeholders fill together", ctx do
      {:ok, page} =
        Wiki.create_from_template(ctx.board, ctx.template, %{}, user: ctx.user, now: @now)

      assert page.title == "Daily 2026-03-07"
      assert page.summary == "Daily 2026-03-07 summary"

      assert page.body ==
               "# Daily 2026-03-07\n\nCreated Saturday 7 March at 14:05 on Notes. {{unknown}}"
    end

    test "a title given for the page is the {{title}}", ctx do
      {:ok, page} =
        Wiki.create_from_template(ctx.board, ctx.template, %{},
          user: ctx.user,
          now: @now,
          title: "Kickoff"
        )

      assert page.title == "Kickoff"
      assert page.body =~ "# Kickoff\n"
    end

    test "a value passed in by name wins", ctx do
      {:ok, page} =
        Wiki.create_from_template(ctx.board, ctx.template, %{"title" => "From values"},
          user: ctx.user,
          now: @now,
          title: "Page title"
        )

      assert page.body =~ "# From values\n"
    end

    test "today's date when none is given", ctx do
      {:ok, page} = Wiki.create_from_template(ctx.board, ctx.template, %{}, user: ctx.user)
      assert page.title == "Daily " <> Date.to_iso8601(Date.utc_today())
    end
  end
end
