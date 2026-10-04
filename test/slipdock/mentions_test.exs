defmodule Slipdock.MentionsTest do
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures
  import Swoosh.TestAssertions

  alias Slipdock.{Access, Boards, Mentions}
  alias SlipdockWeb.RichText

  setup do
    # Addresses of their own, so concurrent tests never race to insert the same user.
    domain = "#{System.unique_integer([:positive])}.example.com"
    owner = user_fixture("owner@#{domain}")
    board = board_fixture(%{}, owner: owner)
    {:ok, priya} = Slipdock.Accounts.get_or_create_user_by_email("priya@#{domain}")
    {:ok, priya} = priya |> Ecto.Changeset.change(name: "Priya Shah") |> Repo.update()
    {:ok, _} = Access.grant(board, priya, "write", owner)
    stranger = user_fixture("stranger@#{domain}")

    %{
      owner: owner,
      board: board,
      priya: priya,
      stranger: stranger,
      domain: domain,
      card: card_fixture(hd(board.columns), %{"title" => "Fix the login"})
    }
  end

  describe "names/1" do
    test "finds handles, drops sentence punctuation, ignores emails and URLs" do
      assert Mentions.names("ask @Priya and @bob. cc carol@example.com") == ["priya", "bob"]
      assert Mentions.names("see https://x.com/@nobody and @priya @priya") == ["priya"]
      assert Mentions.names(nil) == []
    end
  end

  describe "people/2" do
    test "only resolves people who can see the board", %{board: board, priya: priya} do
      assert [%{id: id}] = Mentions.people(board, "@priya @stranger @nobody")
      assert id == priya.id
    end

    test "matching ignores case", %{board: board, priya: priya} do
      assert Mentions.people(board, "@PRIYA") |> Enum.map(& &1.id) == [priya.id]
    end
  end

  describe "a comment" do
    test "emails whoever it mentions, naming the writer", %{
      card: card,
      owner: owner,
      domain: domain
    } do
      {:ok, _} = Boards.add_comment(card, "@priya can you look? @stranger too", by: owner)

      assert_email_sent(fn email ->
        assert email.to == [{"", "priya@#{domain}"}]
        assert email.subject =~ "mentioned you on “Fix the login”"
        assert email.text_body =~ "> @priya can you look?"
        assert email.text_body =~ "/cards/#{card.id}"
      end)

      refute_email_sent()
    end

    test "does not email the writer about their own mention", %{card: card, priya: priya} do
      {:ok, _} = Boards.add_comment(card, "note to self @priya", by: priya)
      refute_email_sent()
    end

    test "on a wiki page notifies nobody", %{board: board, owner: owner} do
      page = page_fixture(board, %{}, user: owner)
      {:ok, _} = Boards.add_comment(page, "@priya")
      refute_email_sent()
    end
  end

  describe "a description" do
    test "emails people only when an edit newly mentions them", %{card: card, owner: owner} do
      {:ok, card} = Boards.update_card(card, %{"description" => "For @priya"}, by: owner)
      assert_email_sent(subject: ~r/mentioned you/)

      {:ok, card} = Boards.update_card(card, %{"description" => "For @priya, soon"}, by: owner)
      {:ok, _} = Boards.update_card(card, %{"title" => "Fix the login page"}, by: owner)
      refute_email_sent()
    end

    test "on a new card emails who it mentions", %{board: board, owner: owner, domain: domain} do
      {:ok, _} =
        Boards.create_card(hd(board.columns), %{"title" => "T", "description" => "@priya"},
          by: owner
        )

      assert_email_sent(to: [{"", "priya@#{domain}"}])
    end
  end

  describe "rendering" do
    test "draws a member's mention as a chip, and leaves anybody else alone", %{board: board} do
      {:safe, html} = RichText.render("hi @priya. and @stranger", board: board)
      assert html =~ ~s|title="Priya Shah">@priya</span>.|
      assert html =~ "and @stranger"
      refute html =~ ">@stranger<"
    end

    test "leaves an @ inside a link alone", %{board: board} do
      {:safe, html} = RichText.render("https://x.com/a?u=@priya", board: board)
      refute html =~ "<span"
    end

    test "without a board, mentions are plain text" do
      assert RichText.render("@priya") == {:safe, "@priya"}
    end
  end
end
