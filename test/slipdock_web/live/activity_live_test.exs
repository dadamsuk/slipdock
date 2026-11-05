defmodule SlipdockWeb.ActivityLiveTest do
  @moduledoc """
  The board's Activity panel (#1735): every entry names who did it, entries
  are grouped by day on the reader's calendar, one icon per kind of change,
  and more load as the list scrolls.
  """
  use SlipdockWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Accounts, Repo}
  alias Slipdock.Boards.Activity
  alias SlipdockWeb.BoardLive.{ActivityComponent, Helpers}

  setup do
    user = user_fixture("activity.live@example.com")
    user = Repo.update!(Ecto.Changeset.change(user, name: "Ash Reader"))
    board = board_fixture(%{"name" => "Activity panel"}, owner: user)
    # The board's own "created board" line, out of the way.
    Repo.delete_all(from(a in Activity, where: a.board_id == ^board.id))
    %{user: user, board: board}
  end

  defp entry(board, attrs) do
    Repo.insert!(
      struct!(
        %Activity{board_id: board.id, kind: "card", message: "moved “X” to Doing"},
        attrs
      )
    )
  end

  defp open(conn, user, board), do: live(log_in_user(conn, user), ~p"/boards/#{board}/activity")

  describe "who did it" do
    test "a change made on the board names its person, with their avatar", ctx do
      {:ok, board_view, _} = live(log_in_user(ctx.conn, ctx.user), ~p"/boards/#{ctx.board}")
      render_hook(board_view, "add_column", %{"name" => "Later"})

      [added] = Repo.all(from(a in Activity, where: a.board_id == ^ctx.board.id))
      assert {added.actor_kind, added.user_id} == {"person", ctx.user.id}

      {:ok, view, _} = open(ctx.conn, ctx.user, ctx.board)
      row = "#activity-#{added.id}[data-actor-kind=person]"
      assert has_element?(view, row <> " [data-role=activity-actor]", "Ash Reader")
      assert has_element?(view, row <> " .avatar-initials", "AR")
      assert has_element?(view, row, "added list “Later”")
    end

    test "each kind of actor reads as itself", ctx do
      rows = [
        {%{actor_kind: "email", user_id: ctx.user.id, actor_name: "Ash Reader"}, "email",
         "Email from Ash Reader"},
        {%{actor_kind: "email"}, "email", "Email"},
        {%{actor_kind: "agent", actor_name: "claude-laptop"}, "agent", "claude-laptop"},
        {%{actor_kind: "agent"}, "agent", "Agent"},
        {%{actor_kind: "automation", actor_name: "Triage"}, "automation", "Automation: Triage"},
        {%{actor_kind: "automation"}, "automation", "Automation"},
        {%{actor_kind: "system"}, "system", "System"},
        # From before actors were recorded.
        {%{}, "unknown", "Someone"}
      ]

      ids = for {attrs, _, _} <- rows, do: entry(ctx.board, attrs).id
      {:ok, view, _} = open(ctx.conn, ctx.user, ctx.board)

      for {id, {_, kind, name}} <- Enum.zip(ids, rows) do
        assert has_element?(
                 view,
                 "#activity-#{id}[data-actor-kind=#{kind}] [data-role=activity-actor]",
                 name
               )
      end

      refute has_element?(view, "[data-role=activity-actor]", ~r/^\s*$/)
    end

    test "a deleted user's entry keeps their name and an avatar from it", ctx do
      gone = user_fixture("activity.gone.live@example.com")
      gone = Repo.update!(Ecto.Changeset.change(gone, name: "Gale Gone"))
      kept = entry(ctx.board, %{actor_kind: "person", user_id: gone.id, actor_name: "Gale Gone"})
      nameless = entry(ctx.board, %{actor_kind: "person", user_id: nil, actor_name: nil})
      {:ok, _} = Accounts.delete_user(gone)

      {:ok, view, _} = open(ctx.conn, ctx.user, ctx.board)

      assert has_element?(
               view,
               "#activity-#{kept.id} [data-role=activity-actor][title='This account has been deleted']",
               "Gale Gone"
             )

      assert has_element?(view, "#activity-#{kept.id} .avatar-initials", "GG")

      assert has_element?(
               view,
               "#activity-#{nameless.id} [data-role=activity-actor]",
               "A deleted user"
             )

      assert has_element?(view, "#activity-#{nameless.id} .avatar-initials", "?")
    end

    test "actor/1 prefers the person's current name to the snapshot", ctx do
      a = %Activity{actor_kind: "person", user: ctx.user, actor_name: "Old name"}
      assert %{name: "Ash Reader", user: %{id: id}} = ActivityComponent.actor(a)
      assert id == ctx.user.id
    end
  end

  describe "days" do
    # 10:30 UTC on 5 Nov is 23:30 on the 5th in Auckland; 11:30 is 00:30 on
    # the 6th; 10:00 on the 3rd is late on the 3rd there.
    @before_midnight ~U[2026-11-05 10:30:00Z]
    @after_midnight ~U[2026-11-05 11:30:00Z]
    @days_ago ~U[2026-11-03 10:00:00Z]
    @now ~U[2026-11-05 12:00:00Z]

    defp labelled(entries, zone) do
      entries
      |> ActivityComponent.by_day(zone: zone, now: @now)
      |> Enum.map(fn {label, run} -> {label, Enum.map(run, & &1.id)} end)
    end

    test "midnight falls on the reader's calendar, not UTC's" do
      entries = [
        %Activity{id: 3, inserted_at: @after_midnight},
        %Activity{id: 2, inserted_at: @before_midnight},
        %Activity{id: 1, inserted_at: @days_ago}
      ]

      assert labelled(entries, "Pacific/Auckland") ==
               [{"Today", [3]}, {"Yesterday", [2]}, {"Tue 3 Nov", [1]}]

      assert labelled(entries, "Etc/UTC") == [{"Today", [3, 2]}, {"Tue 3 Nov", [1]}]
    end

    test "nothing is no days, and an unknown zone falls back to UTC" do
      assert ActivityComponent.by_day([], zone: "Pacific/Auckland", now: @now) == []

      assert labelled([%Activity{id: 1, inserted_at: @before_midnight}], "Not/AZone") ==
               [{"Today", [1]}]
    end

    test "the panel groups in the reader's own timezone", ctx do
      user = Repo.update!(Ecto.Changeset.change(ctx.user, timezone: "Pacific/Auckland"))
      zone = "Pacific/Auckland"
      today = zone |> DateTime.now!() |> DateTime.to_date()

      midnight =
        today |> DateTime.new!(~T[00:00:00], zone) |> DateTime.shift_zone!("Etc/UTC")

      late = entry(ctx.board, %{inserted_at: DateTime.add(midnight, -60), message: "late"})
      early = entry(ctx.board, %{inserted_at: DateTime.add(midnight, 60), message: "early"})

      {:ok, view, _} = open(ctx.conn, user, ctx.board)
      html = render(view)

      assert [_, today_part, yesterday_part] =
               String.split(html, ~r/data-role="activity-day"/, parts: 3)

      assert today_part =~ "Today" and today_part =~ "activity-#{early.id}"
      assert yesterday_part =~ "Yesterday" and yesterday_part =~ "activity-#{late.id}"
      # Yesterday's entry gives its clock time in the reader's zone.
      assert has_element?(view, "#activity-#{late.id} time", "23:59")
    end
  end

  describe "kinds of change" do
    test "one icon per kind, from the kind or the message's verb" do
      assert Helpers.activity_icon("card", "moved “X” to Done") == "hero-arrows-right-left"
      assert Helpers.activity_icon("comment", "commented on “X”") == "hero-chat-bubble-left"
      assert Helpers.activity_icon("vote", "voted for “X”") == "hero-hand-thumb-up"

      assert Helpers.activity_icon("page_created", "wrote “Pricing decision”") ==
               "hero-document-plus"

      assert Helpers.activity_icon("page_updated", "edited “X”") == "hero-pencil-square"
      assert Helpers.activity_icon("card", "archived “X”") == "hero-archive-box"
      assert Helpers.activity_icon("card", "something new") == "hero-rectangle-stack"
      assert Helpers.activity_icon("card") == "hero-rectangle-stack"
      assert Helpers.activity_icon("mystery", nil) == "hero-sparkles"
      assert Helpers.activity_icon(nil, "") == "hero-sparkles"
    end

    test "each entry wears its kind's icon", ctx do
      a = entry(ctx.board, %{kind: "comment", message: "commented on “X”"})
      {:ok, view, _} = open(ctx.conn, ctx.user, ctx.board)

      assert has_element?(
               view,
               "#activity-#{a.id} [data-role=activity-kind][data-icon=hero-chat-bubble-left]"
             )
    end
  end

  describe "loading more" do
    defp many(board, n) do
      base = DateTime.add(DateTime.utc_now(:second), -3600)

      for i <- 1..n,
          do: entry(board, %{message: "entry #{i}", inserted_at: DateTime.add(base, i)})
    end

    test "the first 50 show, and more load from the bottom", ctx do
      [oldest | _] = many(ctx.board, 60)
      {:ok, view, _} = open(ctx.conn, ctx.user, ctx.board)
      refute has_element?(view, "#activity-#{oldest.id}")

      assert count(view) == 50
      assert has_element?(view, "#activity-days[phx-viewport-bottom=load_more]")

      view |> element("#activity-more") |> render_click()

      assert count(view) == 60
      refute has_element?(view, "#activity-more")
      refute has_element?(view, "#activity-days[phx-viewport-bottom]")
      assert has_element?(view, "#activity-#{oldest.id}", "entry 1")

      # Nothing more to load is a no-op.
      render_hook(view, "load_more", %{})
      assert count(view) == 60
    end

    test "a change on the board keeps what was loaded, plus the new entry", ctx do
      many(ctx.board, 55)
      {:ok, view, _} = open(ctx.conn, ctx.user, ctx.board)
      view |> element("#activity-more") |> render_click()
      assert count(view) == 55

      card_fixture(hd(ctx.board.columns), %{"title" => "Brand new"})
      :sys.get_state(view.pid)
      :sys.get_state(view.pid)

      assert count(view) == 56
      assert render(view) =~ "Brand new"
    end

    test "a few entries need no more", ctx do
      many(ctx.board, 3)
      {:ok, view, _} = open(ctx.conn, ctx.user, ctx.board)
      assert count(view) == 3
      refute has_element?(view, "#activity-more")
    end

    defp count(view),
      do: view |> render() |> then(&Regex.scan(~r/id="activity-\d+"/, &1)) |> length()
  end

  test "an empty board says so", ctx do
    {:ok, view, _} = open(ctx.conn, ctx.user, ctx.board)
    assert has_element?(view, "#activity-empty")
    refute has_element?(view, "[data-role=activity-day]")
  end
end
