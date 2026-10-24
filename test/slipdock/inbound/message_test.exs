defmodule Slipdock.Inbound.MessageTest do
  use ExUnit.Case, async: true

  alias Slipdock.Inbound.Message

  # Modelled on each client's real layout (boundaries, encodings, header
  # quirks), with the addresses swapped for example ones.
  defp fixture(name), do: File.read!(Path.join([__DIR__, "../../fixtures/inbound", name]))

  defp parse!(raw) do
    assert {:ok, message} = Message.parse(raw)
    message
  end

  describe "Gmail, multipart/alternative" do
    setup do
      %{message: parse!(fixture("gmail_plain.eml"))}
    end

    test "headers", %{message: m} do
      assert m.from == "alice@example.com"
      assert m.from_name == "Alice Example"
      assert m.to == ["card-abc123@example.com", "bob@example.com"]
      assert m.cc == ["carol@example.com"]
      assert m.message_id == "<CAF=abc123@example.com>"
      # Two encoded words, the space between them dropped, the one inside kept.
      assert m.subject == "Café menu — new card"
    end

    test "both bodies, decoded", %{message: m} do
      assert m.text =~ "café menu? This line is long enough that Gmail wraps it"
      assert m.html =~ "<b>card</b> for the café menu"
      assert m.attachments == []
    end

    test "every authentication header, top first, folded lines joined", %{message: m} do
      assert [{"arc-authentication-results", arc}, {"authentication-results", ar}] =
               m.authentication_results

      assert arc =~ "i=1; mx.cloudflare.net; dkim=pass header.d=example.com"
      assert arc =~ "dmarc=pass header.from=example.com"
      assert ar =~ "spf=fail"
    end
  end

  describe "Outlook, HTML only in Windows-1252" do
    test "the HTML body as UTF-8, no text body" do
      m = parse!(fixture("outlook_html_only.eml"))

      assert m.text == nil
      assert m.html =~ "The “release notes” page needs updating – today."
      assert m.html =~ "<o:p></o:p>"
      assert m.subject == "RE: Release notes"
      assert m.to == ["page-xyz789@example.com"]
      assert m.in_reply_to == "<earlier@example.com>"
    end
  end

  describe "Apple Mail, attachments and an inline image" do
    setup do
      %{message: parse!(fixture("apple_attachments.eml"))}
    end

    test "the HTML body from inside multipart/related", %{message: m} do
      assert m.html =~ ~s(<img src="cid:chart@local">)
      assert m.text == nil
      assert m.message_id == "<A1B2C3D4-0000-1111-2222-333344445555@example.com>"
    end

    test "the inline image, with its content id", %{message: m} do
      assert %{
               filename: "chart.png",
               content_type: "image/png",
               content_id: "chart@local",
               inline: true,
               data: "\x89PNG\r\n\x1a\nfakeimage"
             } = Enum.find(m.attachments, &(&1.content_type == "image/png"))
    end

    test "the attachment, its RFC 2231 file name decoded", %{message: m} do
      assert %{filename: "résumé.pdf", inline: false, content_id: nil, data: data} =
               Enum.find(m.attachments, &(&1.content_type == "application/pdf"))

      assert data == "%PDF-1.4 fake pdf bytes" <> <<0, 1, 2>>
    end
  end

  describe "Fastmail, a forward" do
    test "the note in ISO-8859-1, the forwarded message kept whole as a file" do
      m = parse!(fixture("fastmail_forward.eml"))

      assert m.subject == "Fwd: Invoice overdue"
      assert m.text =~ "Naïve question"

      assert [%{content_type: "message/rfc822", filename: "Invoice overdue.eml", data: data}] =
               m.attachments

      assert data =~ "Your invoice is overdue."
      # The preamble is not the body.
      refute m.text =~ "multi-part message"
    end
  end

  describe "a Gmail reply" do
    test "threading headers, and an 8-bit UTF-8 body intact" do
      m = parse!(fixture("gmail_reply.eml"))

      assert m.in_reply_to == "<notification-1233@example.com>"
      assert m.references == ["<thread-start@example.com>", "<notification-1233@example.com>"]
      assert m.text =~ "Sounds good — ship it. Ünïcödé survives 8bit."
      assert m.text =~ "> A card was updated."
    end
  end

  describe "automatic mail, with bare LF line ends" do
    test "Auto-Submitted, Precedence and List-Id" do
      m = parse!(fixture("auto_reply.eml"))

      assert m.auto_submitted == "auto-replied"
      assert m.precedence == "bulk"
      assert m.list_id == "Announcements <announce.example.com>"
      assert m.text == "I am away until Monday.\n"
    end
  end

  describe "edge cases" do
    test "no Content-Type is text/plain" do
      m = parse!("From: a@example.com\r\nSubject: Hi\r\n\r\nBody")
      assert m.text == "Body"
    end

    test "invalid UTF-8 in a UTF-8 part keeps the valid text and reads stray bytes as Windows-1252" do
      raw =
        "From: a@example.com\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nCafé " <>
          <<0x93>> <> "quoted" <> <<0x94>>

      assert parse!(raw).text == "Café “quoted”"
    end

    test "a raw UTF-8 header is kept, not turned into question marks" do
      assert parse!("From: a@example.com\r\nSubject: Grüße\r\n\r\nx").subject == "Grüße"
    end

    test "an ISO-8859-15 body" do
      raw =
        "From: a@example.com\r\nContent-Type: text/plain; charset=iso-8859-15\r\n\r\n" <>
          <<0xA4>> <> "5"

      assert parse!(raw).text == "€5"
    end

    test "a From with only an address, and a To with a comma in the display name" do
      m =
        parse!(
          "From: a@example.com\r\nTo: \"Doe, Jane\" <jane@example.com>, b@example.com\r\n\r\n"
        )

      assert m.from == "a@example.com"
      assert m.from_name == nil
      assert m.to == ["jane@example.com", "b@example.com"]
    end

    test "a bad quoted-printable escape is kept as written" do
      raw =
        "From: a@example.com\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n50=ZZ off =3D half"

      assert parse!(raw).text == "50=ZZ off = half"
    end

    test "an attachment with no name gets one from its type" do
      raw =
        "From: a@example.com\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n" <>
          "--b\r\nContent-Type: text/plain\r\n\r\nhi\r\n" <>
          "--b\r\nContent-Type: application/octet-stream\r\n\r\nbytes\r\n--b--\r\n"

      assert %{attachments: [%{filename: "attachment.octet-stream", data: "bytes"}]} = parse!(raw)
    end

    test "a boundary that is a prefix of another is not confused with it" do
      raw =
        "From: a@example.com\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n" <>
          "--b\r\nContent-Type: multipart/alternative; boundary=b2\r\n\r\n" <>
          "--b2\r\nContent-Type: text/plain\r\n\r\nplain\r\n" <>
          "--b2\r\nContent-Type: text/html\r\n\r\n<p>html</p>\r\n--b2--\r\n" <>
          "--b\r\nContent-Type: image/gif; name=a.gif\r\n\r\nGIF\r\n--b--\r\n"

      m = parse!(raw)
      assert m.text == "plain"
      assert m.html == "<p>html</p>"
      assert [%{filename: "a.gif", data: "GIF"}] = m.attachments
    end

    test "header/2 is case-insensitive and nil for a missing header" do
      m = parse!("From: a@example.com\r\nX-Thing: yes\r\n\r\n")
      assert Message.header(m.headers, "X-THING") == "yes"
      assert Message.header(m.headers, "x-missing") == nil
    end
  end

  describe "malformed mail is an error, never a crash" do
    test "empty, or not a binary" do
      assert Message.parse("") == {:error, :empty}
      assert Message.parse(nil) == {:error, :empty}
    end

    test "no headers at all" do
      assert Message.parse("just some bytes\r\n\r\nmore") == {:error, :no_headers}
    end

    test "a multipart with no boundary" do
      assert Message.parse("From: a@example.com\r\nContent-Type: multipart/mixed\r\n\r\nx") ==
               {:error, :no_boundary}
    end

    test "base64 that isn't" do
      raw =
        "From: a@example.com\r\nContent-Transfer-Encoding: base64\r\n\r\nQQ===A"

      assert {:error, _} = Message.parse(raw)
    end

    test "multiparts nested past any real message" do
      open =
        Enum.map_join(0..30, "", fn n ->
          "Content-Type: multipart/mixed; boundary=b#{n}\r\n\r\n--b#{n}\r\n"
        end)

      assert Message.parse("From: a@example.com\r\n" <> open) == {:error, :too_deep}
    end

    test "random bytes" do
      for _ <- 1..50 do
        raw =
          "From: a@example.com\r\nContent-Type: multipart/mixed; boundary=x\r\n\r\n" <>
            :crypto.strong_rand_bytes(200)

        assert match?({:ok, _}, Message.parse(raw)) or match?({:error, _}, Message.parse(raw))
      end
    end
  end
end
