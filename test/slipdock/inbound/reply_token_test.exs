defmodule Slipdock.Inbound.ReplyTokenTest do
  @moduledoc "Signed reply addresses (#1256): what they hold, and every way one is refused."
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, TestConfig}
  alias Slipdock.Inbound.ReplyToken

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["current-secret"])
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    card = card_fixture(hd(board.columns))
    %{user: user, board: board, card: card}
  end

  test "round trips to the card and the person", %{card: card, user: user} do
    token = ReplyToken.sign(card, user)
    assert {:ok, found_card, found_user} = ReplyToken.verify(token)
    assert {found_card.id, found_user.id} == {card.id, user.id}
  end

  test "the address fits a 64-character local part, even for the largest ids" do
    token = ReplyToken.sign(0xFFFFFFFFFF, 0xFFFFFFFFFF)
    assert token =~ ~r/^[a-z2-7]+$/
    assert String.length("reply-" <> token) <= 64
    assert {"reply", ^token} = Slipdock.Inbound.address("reply-#{token}@#{@domain}")
  end

  test "address/2 is the full Reply-To, and nil when inbound mail is off", ctx do
    assert "reply-" <> rest = ReplyToken.address(ctx.card, ctx.user)
    assert String.ends_with?(rest, "@" <> @domain)

    TestConfig.put(:inbound, domain: nil, secrets: [])
    assert ReplyToken.address(ctx.card, ctx.user) == nil
    assert ReplyToken.sign(ctx.card, ctx.user) == nil
  end

  test "an id too large to pack signs nothing" do
    assert ReplyToken.sign(0x10000000000, 1) == nil
  end

  describe "refused" do
    test "a changed character, garbage, the wrong length or a non-string", ctx do
      token = ReplyToken.sign(ctx.card, ctx.user)
      <<first::binary-size(1), rest::binary>> = token
      flipped = if first == "a", do: "b" <> rest, else: "a" <> rest

      assert ReplyToken.verify(flipped) == {:error, :invalid}
      assert ReplyToken.verify("not-base32!") == {:error, :invalid}
      assert ReplyToken.verify(token <> "aa") == {:error, :invalid}
      assert ReplyToken.verify(String.slice(token, 0, 20)) == {:error, :invalid}
      assert ReplyToken.verify(nil) == {:error, :invalid}
    end

    test "forged for another card: the MAC covers the ids", ctx do
      other = card_fixture(hd(ctx.board.columns))
      token = ReplyToken.sign(ctx.card, ctx.user)
      {:ok, <<v, _card::40, rest::binary>>} = Base.decode32(String.upcase(token), padding: false)
      forged = Base.encode32(<<v, other.id::40, rest::binary>>, case: :lower, padding: false)
      assert ReplyToken.verify(forged) == {:error, :invalid}
    end

    test "signed with a secret this server doesn't have", ctx do
      TestConfig.put(:inbound, domain: @domain, secrets: ["somebody-elses"])
      token = ReplyToken.sign(ctx.card, ctx.user)
      TestConfig.put(:inbound, domain: @domain, secrets: ["current-secret"])
      assert ReplyToken.verify(token) == {:error, :invalid}
    end

    test "after a year, and when dated in the future", ctx do
      today = Date.utc_today()
      old = ReplyToken.sign(ctx.card, ctx.user, Date.add(today, -ReplyToken.max_age_days()))
      older = ReplyToken.sign(ctx.card, ctx.user, Date.add(today, -ReplyToken.max_age_days() - 1))
      future = ReplyToken.sign(ctx.card, ctx.user, Date.add(today, 1))

      assert {:ok, _, _} = ReplyToken.verify(old)
      assert ReplyToken.verify(older) == {:error, :expired}
      assert ReplyToken.verify(future) == {:error, :expired}
    end

    test "the card deleted or archived", ctx do
      token = ReplyToken.sign(ctx.card, ctx.user)

      {:ok, _} =
        ctx.card |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update()

      assert ReplyToken.verify(token) == {:error, :gone}

      Repo.delete!(Repo.reload!(ctx.card))
      assert ReplyToken.verify(token) == {:error, :gone}
    end

    test "a person who can no longer comment on the card", ctx do
      stranger = user_fixture("stranger@example.com")
      assert ReplyToken.verify(ReplyToken.sign(ctx.card, stranger)) == {:error, :forbidden}

      viewer = user_fixture("viewer@example.com")
      share_fixture(ctx.board, viewer, "read")
      assert ReplyToken.verify(ReplyToken.sign(ctx.card, viewer)) == {:error, :forbidden}

      commenter = user_fixture("commenter@example.com")
      share_fixture(ctx.board, commenter, "comment")
      assert {:ok, _, _} = ReplyToken.verify(ReplyToken.sign(ctx.card, commenter))
    end
  end

  test "rotation: the previous secret is still accepted until it is dropped", ctx do
    old = ReplyToken.sign(ctx.card, ctx.user)

    TestConfig.put(:inbound, domain: @domain, secrets: ["new-secret", "current-secret"])
    assert {:ok, _, _} = ReplyToken.verify(old)
    fresh = ReplyToken.sign(ctx.card, ctx.user)
    refute fresh == old

    TestConfig.put(:inbound, domain: @domain, secrets: ["new-secret"])
    assert ReplyToken.verify(old) == {:error, :invalid}
    assert {:ok, _, _} = ReplyToken.verify(fresh)
  end
end
