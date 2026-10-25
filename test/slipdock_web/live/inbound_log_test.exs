defmodule SlipdockWeb.InboundLogTest do
  @moduledoc """
  The inbound log (#1242): `Slipdock.Inbound.recent/2`, the account's Email
  Log tab (#1290) and `GET /api/inbound/log`.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Inbound, Repo, TestConfig}
  alias Slipdock.Inbound.Email

  defp on, do: TestConfig.put(:inbound, domain: "example.com", secrets: ["s"])

  defp log(user, attrs) do
    defaults = %{
      message_id: "<#{System.unique_integer([:positive])}@example.com>",
      recipient: "card-abc@example.com",
      kind: "card",
      outcome: "rejected",
      reason: "Mail to this address isn't set up on this server yet.",
      subject: "Hello",
      sender: user.email,
      user_id: user.id
    }

    %Email{} |> Email.changeset(Map.merge(defaults, Map.new(attrs))) |> Repo.insert!()
  end

  defp at(email, seconds_ago) do
    time = DateTime.utc_now() |> DateTime.add(-seconds_ago) |> DateTime.truncate(:second)
    email |> Ecto.Changeset.change(inserted_at: time) |> Repo.update!()
  end

  describe "Inbound.recent/2" do
    test "the user's own rows only, newest first, at most the limit", %{user: user} do
      other = user_fixture("other@example.com")
      old = log(user, subject: "old") |> at(60)
      new = log(user, subject: "new")
      log(other, subject: "not mine")

      assert [%{id: new_id}, %{id: old_id}] = Inbound.recent(user)
      assert {new_id, old_id} == {new.id, old.id}
      assert [%{id: ^new_id}] = Inbound.recent(user, 1)
    end

    test "created_path/1 for a card, a page, a comment, and nothing", %{user: user} do
      board = board_fixture(%{}, owner: user)
      [_backlog, todo | _] = board.columns
      card = card_fixture(todo)
      page = page_fixture(board)
      {:ok, comment} = Boards.add_comment(card, "From mail")

      log(user, outcome: "accepted", reason: nil, card_id: card.id)
      log(user, outcome: "accepted", reason: nil, page_id: page.id)
      log(user, outcome: "accepted", reason: nil, comment_id: comment.id)
      log(user, [])

      paths =
        user
        |> Inbound.recent()
        |> Enum.map(&Inbound.created_path/1)
        |> Enum.sort_by(&to_string/1)

      assert paths == [
               nil,
               "/boards/#{board.id}/cards/#{card.id}",
               "/boards/#{board.id}/cards/#{card.id}",
               "/boards/#{board.id}/wiki/#{page.slug}"
             ]
    end
  end

  describe "the Email Log tab" do
    test "while inbound mail is off: no tab, and its URL is a 404", %{conn: conn, user: user} do
      TestConfig.put(:inbound, domain: nil, secrets: [])
      log(user, [])

      {:ok, view, _html} = live(conn, ~p"/account")
      refute has_element?(view, ~s{#account-tabs a[href="/account/email-log"]})
      refute has_element?(view, "#inbound-log")

      assert_raise SlipdockWeb.InboundOff, fn -> live(conn, ~p"/account/email-log") end
    end

    test "is a tab of its own: on the tab bar, and gone from the Account tab", %{
      conn: conn,
      user: user
    } do
      on()
      email = log(user, subject: "Where did it go")

      {:ok, view, _html} = live(conn, ~p"/account")
      assert has_element?(view, ~s{#account-tabs a[href="/account/email-log"]}, "Email Log")
      refute has_element?(view, "#inbound-log")
      # The addresses stay on the Account tab; only the log moved.
      assert has_element?(view, "#account-inbound")

      {:ok, view, _html} = live(conn, ~p"/account/email-log")
      assert page_title(view) =~ "Email Log"
      assert has_element?(view, ~s{#account-tabs a[aria-current="page"]}, "Email Log")
      assert has_element?(view, "#inbound-#{email.id}", "Where did it go")
      refute has_element?(view, "#account-inbound")
    end

    test "lists each message with what came of it and why", %{conn: conn, user: user} do
      on()
      board = board_fixture(%{}, owner: user)
      [_backlog, todo | _] = board.columns
      card = card_fixture(todo)

      bounced = log(user, subject: "Bounced one")
      made = log(user, subject: "Made a card", outcome: "accepted", reason: nil, card_id: card.id)

      ignored =
        log(user,
          subject: "Away",
          outcome: "dropped",
          reason: "Automatic mail (Auto-Submitted) is ignored."
        )

      {:ok, view, _html} = live(conn, ~p"/account/email-log")

      assert view |> element("#inbound-#{bounced.id}") |> render() =~ "Bounced"

      assert view |> element("#inbound-#{bounced.id}") |> render() =~
               "isn&#39;t set up on this server yet"

      assert view |> element("#inbound-#{ignored.id}") |> render() =~ "Ignored"
      assert view |> element("#inbound-#{ignored.id}") |> render() =~ "Auto-Submitted"

      assert has_element?(
               view,
               ~s(#inbound-#{made.id} a[href="/boards/#{board.id}/cards/#{card.id}"])
             )

      refute has_element?(view, "#inbound-#{bounced.id} a")
    end

    test "says so when there is nothing yet, and refresh picks up new mail", %{
      conn: conn,
      user: user
    } do
      on()
      {:ok, view, _html} = live(conn, ~p"/account/email-log")
      assert has_element?(view, "#inbound-log-empty")

      email = log(user, subject: "Just arrived")
      view |> element("#inbound-log-refresh") |> render_click()

      refute has_element?(view, "#inbound-log-empty")
      assert has_element?(view, "#inbound-#{email.id}", "Just arrived")
    end
  end

  describe "GET /api/inbound/log" do
    test "404 while inbound mail is off", %{conn: conn} do
      TestConfig.put(:inbound, domain: nil, secrets: [])

      assert %{"error" => "inbound email is off on this server"} =
               conn |> get("/api/inbound/log") |> json_response(404)
    end

    test "the caller's own messages, newest first, with links", %{conn: conn, user: user} do
      on()
      other = user_fixture("other@example.com")
      board = board_fixture(%{}, owner: user)
      [_backlog, todo | _] = board.columns
      card = card_fixture(todo)

      log(user, subject: "first") |> at(60)
      log(user, subject: "second", outcome: "accepted", reason: nil, card_id: card.id)
      log(other, subject: "theirs")

      assert %{"domain" => "example.com", "inbound" => [second, first]} =
               conn |> get("/api/inbound/log") |> json_response(200)

      assert %{"subject" => "second", "outcome" => "accepted", "link" => link, "card_id" => id} =
               second

      assert link == "/boards/#{board.id}/cards/#{card.id}"
      assert id == card.id

      assert %{
               "subject" => "first",
               "outcome" => "rejected",
               "reason" => "Mail to" <> _,
               "link" => nil
             } =
               first
    end

    @tag :anonymous
    test "needs a token", %{conn: conn} do
      on()

      assert conn
             |> put_req_header("accept", "application/json")
             |> get("/api/inbound/log")
             |> json_response(401)
    end
  end
end
