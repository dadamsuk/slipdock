defmodule Slipdock.Inbound.PagesTest do
  @moduledoc """
  Email to a board's page address (#1251), end to end through
  `Slipdock.Inbound.receive_message/1` with the real dispatcher: a new page
  (#1252), and a `+ Title` subject adding to one (#1253).
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Boards, Inbound, Repo, Settings, TestConfig, Wiki}
  alias Slipdock.Boards.Attachment
  alias Slipdock.Inbound.{Pages, Tokens}
  alias Slipdock.Wiki.{Folder, Folders, Page, Revision}

  @domain "in.example.com"

  setup do
    TestConfig.put(:inbound, domain: @domain, secrets: ["s"])
    TestConfig.own_uploads_dir()
    user = user_fixture()
    board = board_fixture(%{}, owner: user)
    {:ok, address} = Tokens.address(user, board, :page)
    %{user: user, board: board, address: address}
  end

  defp mail(from, to, subject, body_part) do
    "ARC-Authentication-Results: i=1; mx.cloudflare.net; dkim=pass header.d=example.com;\r\n" <>
      " dmarc=pass header.from=example.com\r\n" <>
      "From: Sender <#{from}>\r\nTo: #{to}\r\n" <>
      if(subject, do: "Subject: #{subject}\r\n", else: "") <>
      "Message-ID: <#{System.unique_integer([:positive])}@example.com>\r\n" <>
      "MIME-Version: 1.0\r\n" <> body_part
  end

  defp text(body), do: "Content-Type: text/plain; charset=utf-8\r\n\r\n#{body}\r\n"

  defp multipart(parts) do
    boundary = "b#{System.unique_integer([:positive])}"

    "Content-Type: multipart/mixed; boundary=#{boundary}\r\n\r\n" <>
      Enum.map_join(parts, "", &"--#{boundary}\r\n#{&1}\r\n") <> "--#{boundary}--\r\n"
  end

  defp file(name, type, data) do
    "Content-Type: #{type}; name=\"#{name}\"\r\nContent-Transfer-Encoding: base64\r\n" <>
      "Content-Disposition: attachment; filename=\"#{name}\"\r\n\r\n" <>
      Base.encode64(data) <> "\r\n"
  end

  defp inline_image_body(cid) do
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>
    boundary = "rel#{System.unique_integer([:positive])}"

    "Content-Type: multipart/related; boundary=#{boundary}\r\n\r\n" <>
      "--#{boundary}\r\nContent-Type: text/html; charset=utf-8\r\n\r\n" <>
      "<p>See this:</p><img src=\"cid:#{cid}\" alt=\"shot\">\r\n" <>
      "--#{boundary}\r\nContent-Type: image/png; name=\"shot.png\"\r\n" <>
      "Content-Transfer-Encoding: base64\r\nContent-ID: <#{cid}>\r\n" <>
      "Content-Disposition: inline; filename=\"shot.png\"\r\n\r\n" <>
      Base.encode64(png) <> "\r\n--#{boundary}--\r\n"
  end

  defp deliver(raw, to),
    do: Inbound.receive_message(%{raw: raw, envelope_to: to, envelope_from: nil})

  defp send_page(ctx, subject, body),
    do: deliver(mail(ctx.user.email, ctx.address, subject, body), ctx.address)

  defp page!(email), do: Repo.get!(Page, email.page_id) |> Repo.preload(:folder)

  defp files(page), do: Repo.all(from(a in Attachment, where: a.page_id == ^page.id))

  describe "a message to the page address" do
    test "becomes a page in Inbox, as the address's owner", ctx do
      assert {:accepted, email} =
               send_page(ctx, "Fwd: Meeting notes", text("Agreed the roadmap.\n\nMore detail."))

      page = page!(email)
      assert page.board_id == ctx.board.id
      assert page.title == "Meeting notes"
      assert page.body =~ "Agreed the roadmap."
      assert page.summary == "Agreed the roadmap."
      assert page.created_by_id == ctx.user.id
      assert %Folder{name: "Inbox", parent_id: nil} = page.folder
      assert email.kind == "page" and email.user_id == ctx.user.id

      assert [%Revision{via: "email", summary: summary, author_id: uid}] =
               Wiki.list_revisions(page)

      assert summary == "By email from #{ctx.user.email}"
      assert uid == ctx.user.id
    end

    test "a second mail goes in the same Inbox", ctx do
      assert {:accepted, one} = send_page(ctx, "One", text("a"))
      assert {:accepted, two} = send_page(ctx, "Two", text("b"))
      assert page!(one).folder_id == page!(two).folder_id
      assert Repo.aggregate(from(f in Folder, where: f.board_id == ^ctx.board.id), :count) == 1
    end

    test "[folder/path] Title files it there, making what is missing", ctx do
      {:ok, design} = Folders.create(ctx.board, %{"name" => "Design"})

      assert {:accepted, email} =
               send_page(ctx, "[design / Decisions] Use Postgres", text("Because."))

      page = page!(email)
      assert page.title == "Use Postgres"
      assert page.folder.name == "Decisions"
      assert page.folder.parent_id == design.id
      assert Folders.path(page.folder) == "Design/Decisions"
    end

    test "an empty [] is the Inbox, and a bare [folder] gets (no subject)", ctx do
      assert {:accepted, a} = send_page(ctx, "[] Loose", text("x"))
      assert page!(a).folder.name == "Inbox"

      assert {:accepted, b} = send_page(ctx, "[Notes]", text("x"))
      assert page!(b).title == "(no subject)"
      assert page!(b).folder.name == "Notes"
    end

    test "a title another page has makes a second page with its own slug", ctx do
      assert {:accepted, a} = send_page(ctx, "Standup", text("Monday"))
      assert {:accepted, b} = send_page(ctx, "Standup", text("Tuesday"))
      assert a.page_id != b.page_id
      assert page!(a).title == page!(b).title
      assert page!(a).slug != page!(b).slug
    end

    test "attachments become the page's files", ctx do
      raw =
        multipart([text("Attached."), file("invoice.pdf", "application/pdf", "%PDF-1.4 hello")])

      assert {:accepted, email} = send_page(ctx, "Invoice", raw)
      page = page!(email)
      assert [%Attachment{filename: "invoice.pdf"} = a] = files(page)
      assert File.read!(Boards.attachment_path(a)) == "%PDF-1.4 hello"
      assert page.body =~ "Attached."
    end

    test "an inline cid: image is attached and shown in the body", ctx do
      assert {:accepted, email} =
               send_page(ctx, "Screenshot", inline_image_body("s1@example.com"))

      page = page!(email)
      assert [%Attachment{filename: "shot.png"} = a] = files(page)
      assert page.body =~ "See this:"
      assert page.body =~ "](#{Boards.attachment_url(a)})"
    end

    test "the card address still makes cards, not pages", ctx do
      {:ok, card_address} = Tokens.address(ctx.user, ctx.board, :card)

      assert {:accepted, email} =
               deliver(mail(ctx.user.email, card_address, "A card", text("x")), card_address)

      assert email.card_id && is_nil(email.page_id)
    end
  end

  describe "bounces" do
    test "from somebody else's address", ctx do
      raw = mail("stranger@example.com", ctx.address, "Spam", text("buy"))
      assert {:rejected, reason, _} = deliver(raw, ctx.address)
      assert reason =~ "has to come from the address of the account"
      assert Repo.aggregate(Page, :count) == 0
    end

    test "an archived board", ctx do
      {:ok, _} = Boards.archive_board(ctx.board)
      assert {:rejected, reason, _} = send_page(ctx, "x", text("x"))
      assert reason =~ "archived"
    end

    test "a full account bounces in plain words, and makes no folder", ctx do
      {:ok, _} =
        Settings.complete_setup(%{
          "admin_email" => "admin@example.com",
          "item_limit_enabled" => true,
          "item_limit" => 1
        })

      [_, todo | _] = ctx.board.columns
      card_fixture(todo, %{"title" => "Already here"})

      assert {:rejected, reason, email} = send_page(ctx, "One more", text("x"))
      assert reason =~ "is full, so no page was made"
      assert email.user_id == ctx.user.id
      assert Repo.aggregate(Page, :count) == 0
      assert Repo.aggregate(Folder, :count) == 0
    end
  end

  describe "the storage limit" do
    setup do
      {:ok, _} =
        Settings.complete_setup(%{
          "admin_email" => "admin@example.com",
          "storage_limit_enabled" => true,
          "storage_limit_mb" => 1
        })

      :ok
    end

    test "files that don't fit are left off and named at the end of the page", ctx do
      big = :binary.copy("x", 1024 * 1024 + 1)

      raw =
        multipart([
          text("Two files."),
          file("small.txt", "text/plain", "tiny"),
          file("huge.log", "text/plain", big)
        ])

      assert {:accepted, email} = send_page(ctx, "Logs", raw)
      page = page!(email)
      assert [%Attachment{filename: "small.txt"}] = files(page)
      assert page.body =~ "Two files."
      assert page.body =~ "**Not attached.**"
      assert page.body =~ "`huge.log` (1.0 MB): the account's storage is full"
      refute page.body =~ "small.txt"
    end

    test "a message that is only files, with no room for any, bounces", ctx do
      big = :binary.copy("x", 1024 * 1024 + 1)
      raw = multipart([file("scan.pdf", "application/pdf", big)])

      assert {:rejected, reason, _} = send_page(ctx, "Scan", raw)
      assert reason =~ "out of storage"
      assert Repo.aggregate(Page, :count) == 0
    end
  end

  describe "a + Title subject" do
    setup ctx do
      {:ok, page} =
        Wiki.create_page(ctx.board, %{"title" => "Journal", "body" => "# Journal\n\nStarted."},
          user: ctx.user
        )

      %{page: page}
    end

    test "adds a dated section from the sender to that page, ignoring case", ctx do
      assert {:accepted, email} = send_page(ctx, "+ journal", text("Walked the dog."))
      assert email.page_id == ctx.page.id

      page = Repo.get!(Page, ctx.page.id)
      today = Date.utc_today() |> Date.to_iso8601()
      assert page.body =~ "Started.\n\n## #{today} — Sender\n\nWalked the dog."
      assert Repo.aggregate(Page, :count) == 1

      assert %Revision{via: "email", summary: summary} = hd(Wiki.list_revisions(page))
      assert summary == "By email from #{ctx.user.email}"
    end

    test "a second mail adds a second section after the first", ctx do
      assert {:accepted, _} = send_page(ctx, "+Journal", text("One."))
      assert {:accepted, _} = send_page(ctx, "Re: + Journal", text("Two."))
      body = Repo.get!(Page, ctx.page.id).body
      assert [_, after_one] = String.split(body, "One.")
      assert after_one =~ "Two."
    end

    test "the date is the sender's own day when they've set a timezone", ctx do
      {:ok, _} =
        ctx.user |> Ecto.Changeset.change(timezone: "Pacific/Kiritimati") |> Repo.update()

      assert {:accepted, _} = send_page(ctx, "+ Journal", text("Late."))
      {:ok, now} = DateTime.now("Pacific/Kiritimati")

      assert Repo.get!(Page, ctx.page.id).body =~
               "## #{Date.to_iso8601(DateTime.to_date(now))} — "
    end

    test "attachments go to the page and a cid: image is shown in the section", ctx do
      assert {:accepted, _} = send_page(ctx, "+ Journal", inline_image_body("j1@example.com"))
      page = Repo.get!(Page, ctx.page.id)
      assert [%Attachment{filename: "shot.png"} = a] = files(page)
      assert page.body =~ "See this:"
      assert page.body =~ "](#{Boards.attachment_url(a)})"
    end

    test "a long body goes in whole, in one revision", ctx do
      long = String.duplicate("A line of the log.\n", 5_000)
      before = length(Wiki.list_revisions(ctx.page))
      assert {:accepted, _} = send_page(ctx, "+ Journal", text(long))
      page = Repo.get!(Page, ctx.page.id)
      assert length(String.split(page.body, "A line of the log.")) == 5_001
      assert length(Wiki.list_revisions(page)) == before + 1
    end

    test "the most lately changed page wins when titles are shared", ctx do
      {:ok, newer} = Wiki.create_page(ctx.board, %{"title" => "JOURNAL", "body" => "x"})

      Repo.update_all(from(p in Page, where: p.id == ^newer.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(), 60)]
      )

      assert {:accepted, email} = send_page(ctx, "+ Journal", text("Here."))
      assert email.page_id == newer.id
    end

    test "no page of that title bounces with near matches", ctx do
      for t <- ~w(Journal2 Jurnal Roadmap),
          do: {:ok, _} = Wiki.create_page(ctx.board, %{"title" => t})

      assert {:rejected, reason, _} = send_page(ctx, "+ Journl", text("x"))
      assert reason =~ "no page called “Journl”"
      assert reason =~ "“Journal”"
      assert reason =~ "“Jurnal”"
      refute reason =~ "Roadmap"
      assert Repo.get!(Page, ctx.page.id).body == "# Journal\n\nStarted."
    end

    test "no near matches says so without a list", ctx do
      assert {:rejected, reason, _} = send_page(ctx, "+ Quarterly budget", text("x"))
      assert reason =~ "no page called “Quarterly budget”"
      refute reason =~ "Did you mean"
    end

    test "archived pages and templates are not added to", ctx do
      {:ok, _} = Wiki.archive_page(ctx.page)
      {:ok, _} = Wiki.create_page(ctx.board, %{"title" => "Weekly", "template" => true})
      assert {:rejected, _, _} = send_page(ctx, "+ Journal", text("x"))
      assert {:rejected, _, _} = send_page(ctx, "+ Weekly", text("x"))
    end

    test "a bare + and an empty message bounce", ctx do
      assert {:rejected, reason, _} = send_page(ctx, "+", text("x"))
      assert reason =~ "Name the page"
      assert {:rejected, reason, _} = send_page(ctx, "+ Journal", text(""))
      assert reason =~ "nothing in it to add"
      assert Repo.get!(Page, ctx.page.id).body == "# Journal\n\nStarted."
    end

    test "another board's page is not found", ctx do
      other = board_fixture(%{}, owner: ctx.user)
      {:ok, _} = Wiki.create_page(other, %{"title" => "Elsewhere"})
      assert {:rejected, reason, _} = send_page(ctx, "+ Elsewhere", text("x"))
      assert reason =~ "no page called"
    end
  end

  describe "near_matches/2" do
    test "at most five, closest first" do
      pages = for t <- ~w(Log Logs Logbook Blog Catalog Logo Login), do: %Page{title: t}
      near = Pages.near_matches("log", pages)
      assert length(near) == 5
      assert hd(near) == "Log"
    end
  end

  describe "subject/1 and summary/1" do
    test "the folder and title a subject names" do
      assert Pages.subject("Notes") == {"Inbox", "Notes"}
      assert Pages.subject("Re: [A/B] Notes") == {"A/B", "Notes"}
      assert Pages.subject("[ a // b ] Notes") == {"a/b", "Notes"}
      assert Pages.subject(nil) == {"Inbox", "(no subject)"}
      assert Pages.subject("Fwd: + Journal") == {:append, "Journal"}
      assert Pages.subject("+") == {:append, ""}
    end

    test "the first line with text, marks off, at most 300 characters" do
      assert Pages.summary("\n\n# Heading\nmore") == "Heading"
      assert Pages.summary("- **Bold** item") == "Bold item"
      assert Pages.summary("> quoted") == "quoted"
      assert Pages.summary("") == nil
      assert Pages.summary(nil) == nil
      assert Pages.summary(String.duplicate("a", 400)) == String.duplicate("a", 300)
    end
  end
end
