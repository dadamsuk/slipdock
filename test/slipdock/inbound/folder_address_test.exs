defmodule Slipdock.Inbound.FolderAddressTest do
  @moduledoc """
  A wiki folder's own page address (#1277): its token (`Slipdock.Inbound.Tokens`
  with a folder), and mail to it end to end through
  `Slipdock.Inbound.receive_message/1`, filed in that folder.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Inbound, Repo, TestConfig, Wiki}
  alias Slipdock.Inbound.{Pages, Tokens}
  alias Slipdock.Boards.Board
  alias Slipdock.Wiki.{Folder, Folders, Page}

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    {:ok, projects} = Folders.create(board, %{"name" => "Projects"})
    {:ok, folder} = Folders.create(board, %{"name" => "Notes", "parent_id" => projects.id})
    {:ok, address} = Tokens.address(user, folder, :page)
    %{user: user, board: board, projects: projects, folder: folder, address: address}
  end

  defp mail(from, to, subject, body) do
    "ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=pass header.d=example.com;\r\n" <>
      " dmarc=pass header.from=example.com\r\n" <>
      "From: Sender <#{from}>\r\nTo: #{to}\r\nSubject: #{subject}\r\n" <>
      "Message-ID: <#{System.unique_integer([:positive])}@example.com>\r\n" <>
      "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"
  end

  defp send_to(ctx, subject, body, from \\ nil),
    do:
      Inbound.receive_message(%{
        raw: mail(from || ctx.user.email, ctx.address, subject, body),
        envelope_to: ctx.address,
        envelope_from: nil
      })

  defp page!(email), do: Repo.get!(Page, email.page_id) |> Repo.preload(:folder)

  defp local(address), do: address |> String.split("@") |> hd()

  describe "the folder's address" do
    test "is a page- address of its own, the same each time it is asked for", ctx do
      assert ctx.address =~ ~r/^page-[a-z0-9]{26}@in\.example\.com$/
      {:ok, board_page} = Tokens.address(ctx.user, ctx.board, :page)
      assert ctx.address != board_page
      assert Tokens.address(ctx.user, ctx.folder, :page) == {:ok, ctx.address}
      assert Tokens.addresses(ctx.user, ctx.folder) == {:ok, %{page: ctx.address}}
    end

    test "has no card address", ctx do
      assert Tokens.address(ctx.user, ctx.folder, :card) == {:error, :wrong_kind}
      token = ctx.address |> local() |> String.replace_prefix("page-", "card-")
      assert Tokens.resolve(token) == {:error, :wrong_kind}
    end

    test "resolves to the folder, with its board", ctx do
      assert {:ok, {:page, user, %Folder{} = folder}} = Tokens.resolve(local(ctx.address))
      assert user.id == ctx.user.id
      assert folder.id == ctx.folder.id
      assert folder.board.id == ctx.board.id
    end

    test "each folder has its own, and so does each person", ctx do
      {:ok, other} = Tokens.address(ctx.user, ctx.projects, :page)
      assert other != ctx.address

      writer = user_fixture("writer@example.com")
      share_fixture(ctx.board, writer, "write")
      {:ok, theirs} = Tokens.address(writer, ctx.folder, :page)
      assert theirs != ctx.address
    end

    test "rotating it leaves the board's addresses alone, and the other way round", ctx do
      {:ok, %{page: board_page}} = Tokens.addresses(ctx.user, ctx.board)

      assert {:ok, %{page: new}} = Tokens.rotate(ctx.user, ctx.folder)
      assert new != ctx.address
      assert Tokens.resolve(local(ctx.address)) == {:error, :revoked}
      assert {:ok, {:page, _, %Board{}}} = Tokens.resolve(local(board_page))

      assert {:ok, %{page: new_board_page}} = Tokens.rotate(ctx.user, ctx.board)
      assert new_board_page != board_page
      assert {:ok, {:page, _, %Folder{}}} = Tokens.resolve(local(new))
    end

    test "revoking it turns it off; asking again makes a new one", ctx do
      assert Tokens.revoke(ctx.user, ctx.folder) == :ok
      assert Tokens.resolve(local(ctx.address)) == {:error, :revoked}
      assert {:ok, again} = Tokens.address(ctx.user, ctx.folder, :page)
      assert again != ctx.address
    end

    test "not for somebody who can only read the board", ctx do
      reader = user_fixture("reader@example.com")
      share_fixture(ctx.board, reader, "read")
      assert Tokens.address(reader, ctx.folder, :page) == {:error, :forbidden}
    end

    test "taking the board's share back revokes it", ctx do
      writer = user_fixture("writer@example.com")
      share_fixture(ctx.board, writer, "write")
      {:ok, theirs} = Tokens.address(writer, ctx.folder, :page)

      [grant] = Slipdock.Access.list_grants(ctx.board)
      {:ok, _} = Slipdock.Access.revoke(grant)
      assert Tokens.resolve(local(theirs)) == {:error, :revoked}
      assert {:ok, _} = Tokens.resolve(local(ctx.address))
    end

    test "deleting the folder deletes the address", ctx do
      Repo.delete!(ctx.folder)
      assert Tokens.resolve(local(ctx.address)) == {:error, :unknown}
    end

    test "follows the folder to another board", ctx do
      other = board_fixture(%{}, owner: ctx.user)
      ctx.folder |> Ecto.Changeset.change(board_id: other.id, parent_id: nil) |> Repo.update!()

      assert {:ok, {:page, _, %Folder{board: board}}} = Tokens.resolve(local(ctx.address))
      assert board.id == other.id

      {:ok, _} = Boards.archive_board(other)
      assert Tokens.resolve(local(ctx.address)) == {:error, :archived}
    end
  end

  describe "mail to it" do
    test "is a page in that folder, and makes no Inbox", ctx do
      assert {:accepted, email} = send_to(ctx, "Fwd: Kickoff", "We met.")
      page = page!(email)
      assert page.title == "Kickoff"
      assert page.folder_id == ctx.folder.id
      assert page.board_id == ctx.board.id
      assert page.body =~ "We met."
      refute Repo.get_by(Folder, board_id: ctx.board.id, name: "Inbox")
    end

    test "goes in this folder, not another of the same name", ctx do
      {:ok, top_notes} = Folders.create(ctx.board, %{"name" => "Notes"})
      assert {:accepted, email} = send_to(ctx, "Which one", "x")
      assert page!(email).folder_id == ctx.folder.id
      refute page!(email).folder_id == top_notes.id
    end

    test "[Sub/Path] Title files it beneath the folder, making what is missing", ctx do
      assert {:accepted, email} = send_to(ctx, "[2026 / Q4] Plan", "y")
      page = page!(email)
      assert page.title == "Plan"
      assert Folders.path(page.folder) == "Projects/Notes/2026/Q4"
    end

    test "an empty [] is the folder itself", ctx do
      assert {:accepted, email} = send_to(ctx, "[] Loose", "z")
      assert page!(email).folder_id == ctx.folder.id
    end

    test "+ Title adds to that page", ctx do
      {:ok, journal} =
        Wiki.create_page(ctx.board, %{"title" => "Journal", "body" => "Start."}, by: ctx.user)

      assert {:accepted, email} = send_to(ctx, "+ journal", "Today went well.")
      assert email.page_id == journal.id
      assert Repo.get!(Page, journal.id).body =~ "Today went well."
    end

    test "from somebody else bounces", ctx do
      assert {:rejected, reason, _} = send_to(ctx, "Hi", "x", "intruder@example.com")
      assert reason =~ "has to come from the address of the account"
      assert Repo.aggregate(Page, :count) == 0
    end

    test "after the folder is deleted bounces", ctx do
      Repo.delete!(ctx.folder)
      assert {:rejected, reason, _} = send_to(ctx, "Late", "x")
      assert reason == "No such address here."
    end
  end

  describe "subject/2 with a base folder" do
    test "the folder itself, or a path beneath it" do
      assert Pages.subject("Plan", "A/B") == {"A/B", "Plan"}
      assert Pages.subject("[C] Plan", "A/B") == {"A/B/C", "Plan"}
      assert Pages.subject("[ C / D ] Plan", "A/B") == {"A/B/C/D", "Plan"}
      assert Pages.subject("[] Plan", "A/B") == {"A/B", "Plan"}
      assert Pages.subject("+ Plan", "A/B") == {:append, "Plan"}
      assert Pages.subject("Plan", nil) == {"Inbox", "Plan"}
    end
  end
end
