defmodule SlipdockWeb.CardSignControllerTest do
  @moduledoc """
  The doors to a card signed with its owner's passkey (#3532): the owner
  signing it from the browser, the panel showing it, the job's runner
  fetching it, and the owner's passkeys listed as keys to pin.
  """
  use SlipdockWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Slipdock.Fixtures

  alias Slipdock.{Boards, Intent, Repo, Runners}
  alias Slipdock.Accounts.Passkeys
  alias Slipdock.Boards.Card
  alias Slipdock.PasskeyAuthenticator, as: Authenticator

  setup %{user: owner} do
    board = board_fixture(%{"name" => "Signed"}, owner: owner)

    card =
      card_fixture(hd(board.columns), %{
        "title" => "Add a CSV export",
        "description" => "Export it."
      })

    %{owner: owner, board: board, card: card, key: passkey_for(owner)}
  end

  defp passkey_for(user) do
    a = Authenticator.new()
    {challenge, _} = Passkeys.registration_challenge(user, "https://slipdock.example.com")
    {:ok, _} = Passkeys.register(user, challenge, Authenticator.attest(a, challenge), "Phone")
    a
  end

  defp start(conn, card) do
    conn = post(conn, ~p"/cards/#{card.id}/sign/options")
    {conn, json_response(conn, 200), get_session(conn, :card_sign_challenge)}
  end

  defp member(ctx, level) do
    member = user_fixture("sign-#{level}-#{System.unique_integer([:positive])}@example.com")

    if level != "none" do
      Repo.insert!(
        Slipdock.Access.Grant.changeset(%Slipdock.Access.Grant{}, %{
          level: level,
          user_id: member.id,
          board_id: ctx.board.id
        })
      )
    end

    member
  end

  describe "signing from the browser" do
    test "the owner: a challenge over the card's text, then the answer keeps it", ctx do
      {conn, body, kept} = start(ctx.conn, ctx.card)

      assert kept.card_id == ctx.card.id
      assert body["publicKey"]["challenge"] == Passkeys.encode(kept.challenge.bytes)
      assert body["publicKey"]["userVerification"] == "required"

      assert kept.challenge.bytes ==
               Intent.challenge(Intent.fields(ctx.card, kept.challenge.origin, kept.signed_at))

      answer = Authenticator.assert(ctx.key, kept.challenge)
      conn = conn |> recycle() |> post(~p"/cards/#{ctx.card.id}/sign", answer)

      assert %{"signed_at" => _} = json_response(conn, 200)
      refute get_session(conn, :card_sign_challenge)
      assert {:signed, _} = Intent.state(Repo.get!(Card, ctx.card.id))

      # The answer can't be kept twice: the challenge went with the first.
      again = conn |> recycle() |> post(~p"/cards/#{ctx.card.id}/sign", answer)
      assert %{"error" => "That took too long" <> _} = json_response(again, 422)
    end

    test "anyone but the owner is refused, a writer and a reader alike", ctx do
      for level <- ~w(write read) do
        user = member(ctx, level)
        passkey_for(user)
        conn = build_conn() |> log_in_user(user)

        assert %{"error" => "Only the owner" <> _} =
                 conn |> post(~p"/cards/#{ctx.card.id}/sign/options") |> json_response(403)

        assert conn |> post(~p"/cards/#{ctx.card.id}/sign", %{}) |> json_response(422)
      end

      # Somebody who can't read the card at all finds no card.
      stranger = member(ctx, "none")
      conn = build_conn() |> log_in_user(stranger)

      assert %{"error" => "There is no such card."} =
               conn |> post(~p"/cards/#{ctx.card.id}/sign/options") |> json_response(404)

      assert Intent.state(Repo.get!(Card, ctx.card.id)) == :unsigned
    end

    test "a writer holding the owner's kept challenge is still refused", ctx do
      {_conn, _body, kept} = start(ctx.conn, ctx.card)
      writer = member(ctx, "write")
      writer_key = passkey_for(writer)

      conn =
        build_conn()
        |> Phoenix.ConnTest.init_test_session(%{card_sign_challenge: kept})
        |> log_in_user(writer)

      answer = Authenticator.assert(writer_key, kept.challenge)

      assert %{"error" => "Only the owner" <> _} =
               conn |> post(~p"/cards/#{ctx.card.id}/sign", answer) |> json_response(403)

      assert Intent.state(Repo.get!(Card, ctx.card.id)) == :unsigned
    end

    test "a challenge for one card doesn't sign another", ctx do
      other = card_fixture(hd(ctx.board.columns), %{"title" => "Other"})
      {conn, _body, kept} = start(ctx.conn, ctx.card)
      answer = Authenticator.assert(ctx.key, kept.challenge)

      # Refused before the text is compared: the kept challenge answers only
      # for the card it was made for.
      assert %{"error" => "That took too long" <> _} =
               conn
               |> recycle()
               |> post(~p"/cards/#{other.id}/sign", answer)
               |> json_response(422)

      assert Intent.state(Repo.get!(Card, other.id)) == :unsigned
    end

    test "an answer to the wrong challenge, or after an edit, is refused", ctx do
      {conn, _body, kept} = start(ctx.conn, ctx.card)

      wrong =
        Authenticator.assert(ctx.key, kept.challenge,
          challenge_bytes: :crypto.strong_rand_bytes(32)
        )

      assert %{"error" => "The passkey's signature couldn't be checked" <> _} =
               conn
               |> recycle()
               |> post(~p"/cards/#{ctx.card.id}/sign", wrong)
               |> json_response(422)

      {conn, _body, kept} = start(ctx.conn, ctx.card)
      {:ok, _} = Boards.Cards.update_card(ctx.card, %{"title" => "Changed"}, by: ctx.owner)
      answer = Authenticator.assert(ctx.key, kept.challenge)

      assert %{"error" => "The card changed" <> _} =
               conn
               |> recycle()
               |> post(~p"/cards/#{ctx.card.id}/sign", answer)
               |> json_response(422)

      assert Intent.state(Repo.get!(Card, ctx.card.id)) == :unsigned
    end
  end

  describe "the card panel" do
    defp sign!(ctx) do
      {conn, _body, kept} = start(ctx.conn, ctx.card)
      answer = Authenticator.assert(ctx.key, kept.challenge)
      conn |> recycle() |> post(~p"/cards/#{ctx.card.id}/sign", answer) |> json_response(200)
    end

    test "offers the owner the button, and shows signed, then edited", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      assert has_element?(view, "#card-unsigned")
      # Only once the browser says it has passkeys.
      refute has_element?(view, "#card-sign-button")

      view |> with_target("#board-card") |> render_hook("sign_support", %{"supported" => true})
      assert has_element?(view, "#card-sign-button", "Sign with passkey")

      sign!(ctx)
      view |> with_target("#board-card") |> render_hook("card_signed", %{})
      assert has_element?(view, "#card-signed", "Signed by the owner")

      {:ok, _} =
        Boards.Cards.update_card(Repo.get!(Card, ctx.card.id), %{"description" => "Changed"},
          by: ctx.owner
        )

      {:ok, view, _} = live(ctx.conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      assert has_element?(view, "#card-sign-edited", "Edited since it was signed")
    end

    defp open_panel(conn, ctx, supported \\ true) do
      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")

      view
      |> with_target("#board-card")
      |> render_hook("sign_support", %{"supported" => supported})

      view
    end

    test "Save and sign: the owner's description is saved, then signed", ctx do
      view = open_panel(ctx.conn, ctx)
      refute has_element?(view, "#card-description-save-sign")

      view |> element("#card-form button[phx-click=edit_description]") |> render_click()
      assert has_element?(view, "#card-description-save-sign", "Save and sign")

      view
      |> form("#card-form", card: %{description: "Export it as CSV."})
      |> put_submitter("#card-description-save-sign")
      |> render_submit()

      card_id = ctx.card.id
      assert_push_event(view, "card_sign_start", %{card_id: ^card_id})
      refute has_element?(view, "#card-description-save-sign")
      saved = Repo.get!(Card, card_id)
      assert saved.description == "Export it as CSV."

      # What the hook then runs: the challenge is over the text just saved.
      {conn, _body, kept} = start(ctx.conn, saved)

      assert kept.challenge.bytes ==
               Intent.challenge(Intent.fields(saved, kept.challenge.origin, kept.signed_at))

      answer = Authenticator.assert(ctx.key, kept.challenge)
      conn |> recycle() |> post(~p"/cards/#{card_id}/sign", answer) |> json_response(200)
      assert {:signed, _} = Intent.state(Repo.get!(Card, card_id))
    end

    test "Save and sign: the owner's bar too", ctx do
      {:ok, _} = Boards.Cards.update_card(ctx.card, %{"bar" => "1. CSV"}, by: ctx.owner)
      view = open_panel(ctx.conn, ctx)
      refute has_element?(view, "#card-bar-save-sign")

      view |> element("#card-bar-edit") |> render_click()

      view
      |> form("#card-bar-form", card: %{bar: "1. CSV; 2. JSON"})
      |> put_submitter("#card-bar-save-sign")
      |> render_submit()

      card_id = ctx.card.id
      assert_push_event(view, "card_sign_start", %{card_id: ^card_id})
      assert Repo.get!(Card, card_id).bar == "1. CSV; 2. JSON"
    end

    test "Save and sign: not offered where the browser has no passkeys", ctx do
      view = open_panel(ctx.conn, ctx, false)
      view |> element("#card-form button[phx-click=edit_description]") |> render_click()
      refute has_element?(view, "#card-description-save-sign")
    end

    test "Save and sign: a writer isn't offered it, and a sign sent anyway only saves", ctx do
      writer = member(ctx, "write")
      view = open_panel(build_conn() |> log_in_user(writer), ctx)

      view |> element("#card-form button[phx-click=edit_description]") |> render_click()
      refute has_element?(view, "#card-description-save-sign")

      view
      |> form("#card-form", card: %{description: "Changed by the writer."})
      |> render_submit(%{"sign" => "description"})

      refute_push_event(view, "card_sign_start", %{})
      assert Repo.get!(Card, ctx.card.id).description == "Changed by the writer."
    end

    test "shows a writer that it is signed, with no button", ctx do
      sign!(ctx)
      writer = member(ctx, "write")
      conn = build_conn() |> log_in_user(writer)

      {:ok, view, _} = live(conn, ~p"/boards/#{ctx.board}/cards/#{ctx.card.id}")
      view |> with_target("#board-card") |> render_hook("sign_support", %{"supported" => true})
      assert has_element?(view, "#card-signed")
      refute has_element?(view, "#card-sign-button")
      refute has_element?(view, "#card-sign[phx-hook]")
    end
  end

  describe "the runner's side" do
    setup ctx do
      {:ok, runner, token} =
        Runners.create_runner(ctx.board, %{"name" => "box", "pool" => "dev"}, ctx.owner)

      {:ok, _other, other_token} =
        Runners.create_runner(ctx.board, %{"name" => "other", "pool" => "dev"}, ctx.owner)

      %{runner: runner, token: token, other_token: other_token}
    end

    defp runner_conn(token),
      do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

    test "the job's runner fetches the signed text and assertion; another runner can't", ctx do
      {conn, _body, kept} = start(ctx.conn, ctx.card)
      answer = Authenticator.assert(ctx.key, kept.challenge)
      conn |> recycle() |> post(~p"/cards/#{ctx.card.id}/sign", answer) |> json_response(200)

      {:ok, job} = Runners.queue(ctx.card, %{pool: "dev", kind: "claude", prompt: "Work on it"})
      claim = ctx.token |> runner_conn() |> post("/api/runner/claim?wait=0")
      assert get_resp_header(claim, "x-job-id") == [to_string(job.id)]

      body =
        ctx.token
        |> runner_conn()
        |> get("/api/runner/jobs/#{job.id}/intent")
        |> json_response(200)

      assert body["signed"]
      assert body["version"] == "slipdock-intent-v1"
      assert body["title"] == "Add a CSV export"
      assert body["description"] == "Export it."
      assert body["bar"] == ""
      assert body["card_id"] == ctx.card.id
      assert body["assertion"]["signature"] == answer["signature"]
      assert body["assertion"]["client_data_json"] == answer["clientDataJSON"]

      other = ctx.other_token |> runner_conn() |> get("/api/runner/jobs/#{job.id}/intent")
      assert other.status == 404
      refute other.resp_body =~ "Export it"

      # An API token isn't a runner's.
      assert ctx.conn |> get("/api/runner/jobs/#{job.id}/intent") |> Map.fetch!(:status) == 401
    end

    test "the owner's keys, to pin", ctx do
      body = ctx.token |> runner_conn() |> get("/api/runner/owner-keys") |> json_response(200)

      assert body["owner_id"] == ctx.owner.id
      assert [key] = body["keys"]
      assert key["credential_id"] == Passkeys.encode(ctx.key.credential_id)
      assert key["algorithm"] == -7
      assert "sha256:" <> _ = key["fingerprint"]

      assert build_conn() |> get("/api/runner/owner-keys") |> Map.fetch!(:status) == 401
    end

    test "the owner's own passkeys list carries SPKI and fingerprint", ctx do
      assert %{"passkeys" => [p]} = ctx.conn |> get(~p"/api/me/passkeys") |> json_response(200)
      assert p["name"] == "Phone"
      assert p["credential_id"] == Passkeys.encode(ctx.key.credential_id)
      {:ok, der} = Passkeys.decode(p["spki"])
      assert p["fingerprint"] == Passkeys.fingerprint(der)
    end
  end
end
