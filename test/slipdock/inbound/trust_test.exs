defmodule Slipdock.Inbound.TrustTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, TestConfig}
  alias Slipdock.Inbound.{Message, Trust}

  @cloudflare_pass "i=1; mx.cloudflare.net; dkim=pass header.d=example.com header.s=s1; " <>
                     "dmarc=pass header.from=example.com; spf=pass smtp.mailfrom=example.com"

  defp message(from, auth \\ [{"arc-authentication-results", @cloudflare_pass}], extra \\ []) do
    struct!(%Message{from: from, authentication_results: auth}, extra)
  end

  setup do
    owner = user_fixture("owner@example.com")
    board = board_fixture(%{}, owner: owner)
    [_backlog, todo | _] = board.columns
    %{owner: owner, board: board, card: card_fixture(todo)}
  end

  describe "check/3, all well" do
    test "the owner, from their own address, authenticated, on their board", ctx do
      assert Trust.check(message(ctx.owner.email), ctx.owner, {:board, ctx.board}) == :ok
      assert Trust.check(message(ctx.owner.email), ctx.owner, {:card, ctx.card}) == :ok
    end

    test "the From: address matches in any case", ctx do
      assert Trust.check(message(String.upcase(ctx.owner.email)), ctx.owner, {:board, ctx.board}) ==
               :ok
    end
  end

  describe "check/3, refusals" do
    test "an unknown or disabled account", ctx do
      assert {:reject, "This address is no longer active."} =
               Trust.check(message(ctx.owner.email), nil, {:board, ctx.board})

      disabled = %{ctx.owner | disabled_at: DateTime.utc_now()}

      assert {:reject, "This address is no longer active."} =
               Trust.check(message(ctx.owner.email), disabled, {:board, ctx.board})
    end

    test "From: someone else", ctx do
      assert {:reject, "Mail to this address has to come from" <> _} =
               Trust.check(message("someone@example.com"), ctx.owner, {:board, ctx.board})

      assert {:reject, _} = Trust.check(message(nil), ctx.owner, {:board, ctx.board})
    end

    test "not authenticated", ctx do
      assert {:reject, "We couldn't confirm this message came from " <> _} =
               Trust.check(message(ctx.owner.email, []), ctx.owner, {:board, ctx.board})
    end

    test "someone who can only read the board, or nobody to it", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")
      stranger = user_fixture("stranger@example.com")

      for user <- [reader, stranger] do
        assert {:reject, "You can no longer add to this board."} =
                 Trust.check(message(user.email), user, {:board, ctx.board})
      end
    end

    test "a commenter may reply on a card but not add to the board", ctx do
      commenter = user_fixture("commenter@example.com")
      share_fixture(ctx.board, commenter, "comment")

      assert Trust.check(message(commenter.email), commenter, {:card, ctx.card}) == :ok
      assert {:reject, _} = Trust.check(message(commenter.email), commenter, {:board, ctx.board})
    end

    test "a writer may add", ctx do
      writer = user_fixture("writer@example.com")
      share_fixture(ctx.board, writer, "write")
      assert Trust.check(message(writer.email), writer, {:board, ctx.board}) == :ok
    end
  end

  describe "authenticated?/1" do
    defp auth(from, headers), do: Trust.authenticated?(message(from, headers))

    test "DMARC pass from the trusted server" do
      assert auth("a@example.com", [
               {"authentication-results", "mx.cloudflare.net; dmarc=pass header.from=example.com"}
             ])
    end

    test "an aligned DKIM pass, without DMARC" do
      assert auth("a@example.com", [
               {"authentication-results",
                "mx.cloudflare.net; dkim=pass (2048-bit key) header.d=example.com; dmarc=none"}
             ])

      # Relaxed alignment: a subdomain either way.
      assert auth("a@" <> "mail.example.com", [
               {"authentication-results", "mx.cloudflare.net; dkim=pass header.d=example.com"}
             ])

      assert auth("a@example.com", [
               {"authentication-results", "mx.cloudflare.net; dkim=pass header.i=@example.com"}
             ])
    end

    test "a DKIM pass for another domain is not enough" do
      refute auth("a@example.com", [
               {"authentication-results",
                "mx.cloudflare.net; dkim=pass header.d=example.net; dmarc=fail"}
             ])

      # A suffix that isn't a subdomain doesn't align either.
      refute auth("a@" <> "badexample.com", [
               {"authentication-results", "mx.cloudflare.net; dkim=pass header.d=example.com"}
             ])
    end

    test "failures, and SPF alone, are not enough" do
      refute auth("a@example.com", [
               {"authentication-results",
                "mx.cloudflare.net; dkim=fail header.d=example.com; dmarc=fail; spf=pass"}
             ])
    end

    test "results from a server we don't trust are ignored" do
      refute auth("a@example.com", [
               {"authentication-results", "mx.example.net; dmarc=pass header.from=example.com"}
             ])
    end

    test "only the topmost trusted header counts: a forged one below is ignored" do
      refute auth("a@example.com", [
               {"arc-authentication-results", "i=1; mx.cloudflare.net; dmarc=fail; dkim=none"},
               {"authentication-results", "mx.cloudflare.net; dmarc=pass header.from=example.com"}
             ])
    end

    test "an untrusted header above the trusted one doesn't hide it" do
      assert auth("a@example.com", [
               {"authentication-results", "mx.example.net; dmarc=fail"},
               {"arc-authentication-results", @cloudflare_pass}
             ])
    end

    test "no From:, or no headers" do
      refute Trust.authenticated?(message(nil))
      refute auth("a@example.com", [])
    end

    test "the trusted servers can be configured" do
      TestConfig.put(:inbound, authserv_ids: ["mx.example.net"])

      assert auth("a@example.com", [
               {"authentication-results", "mx.example.net; dmarc=pass header.from=example.com"}
             ])

      refute auth("a@example.com", [{"arc-authentication-results", @cloudflare_pass}])
    end
  end

  describe "automatic/1" do
    defp auto(extra), do: Trust.automatic(message("a@example.com", [], extra))

    test "ordinary mail is not automatic" do
      assert auto([]) == nil
      assert auto(auto_submitted: "no") == nil
      assert auto(precedence: "first-class") == nil
    end

    test "Auto-Submitted other than no" do
      assert auto(auto_submitted: "auto-replied") =~ "Auto-Submitted"
      assert auto(auto_submitted: "Auto-Generated") =~ "Auto-Submitted"
    end

    test "Precedence bulk, junk or list" do
      for p <- ~w(bulk junk list Bulk), do: assert(auto(precedence: p) =~ "Bulk", p)
    end

    test "a List-Id" do
      assert auto(list_id: "<announce.example.com>") =~ "list"
      assert auto(list_id: "  ") == nil
    end

    test "our own sending address" do
      {_, ours} =
        case Slipdock.Mailer.from() do
          {name, address} -> {name, address}
          address -> {nil, address}
        end

      assert Trust.automatic(message(String.upcase(ours))) =~ "Slipdock itself"
    end
  end

  describe "through the endpoint" do
    test "automatic mail is recorded as dropped and never bounced" do
      TestConfig.put(:inbound, domain: "example.com", secrets: ["s"])
      raw = File.read!(Path.join([__DIR__, "../../fixtures/inbound/auto_reply.eml"]))

      assert {:dropped, reason, email} =
               Slipdock.Inbound.receive_message(%{
                 raw: raw,
                 envelope_to: "card-abc123@example.com"
               })

      assert reason =~ "Auto-Submitted"
      assert %{outcome: "dropped", reason: ^reason} = Repo.reload(email)

      # A repeat is a duplicate, not a second row or a bounce.
      assert {:duplicate, _} =
               Slipdock.Inbound.receive_message(%{
                 raw: raw,
                 envelope_to: "card-abc123@example.com"
               })
    end
  end
end
