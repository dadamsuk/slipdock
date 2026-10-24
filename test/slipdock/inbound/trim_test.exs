defmodule Slipdock.Inbound.TrimTest do
  use ExUnit.Case, async: true

  alias Slipdock.Inbound.{Message, Trim}

  defp message(name) do
    {:ok, message} =
      Path.join([__DIR__, "../../fixtures/inbound", name]) |> File.read!() |> Message.parse()

    message
  end

  describe "each client's reply, text and HTML" do
    test "Gmail, text: the attribution and the quote go" do
      m = message("gmail_reply.eml")
      assert Trim.text(m.text) == "Sounds good — ship it. Ünïcödé survives 8bit."
    end

    test "Gmail, HTML in French: gmail_quote and gmail_signature go" do
      m = message("gmail_reply_html.eml")
      assert Trim.markdown(m) == "Merci, c'est fait."
    end

    test "Outlook, text: the phone footer and the From/Sent/To/Subject block go" do
      m = message("outlook_reply.eml")
      assert Trim.text(m.text) == "Agreed, let's do it Monday."
    end

    test "Outlook, HTML: everything from divRplyFwdMsg on goes" do
      m = message("outlook_reply.eml")
      md = m.html |> Trim.html() |> Slipdock.Inbound.HtmlToMarkdown.convert() |> Trim.text()
      assert md == "Agreed, let's do it **Monday**."
    end

    test "Apple Mail, text and HTML" do
      m = message("apple_reply.eml")
      assert Trim.text(m.text) == "Yes, both are paid.\n\nErin"

      md = m.html |> Trim.html() |> Slipdock.Inbound.HtmlToMarkdown.convert()
      assert md =~ "Yes, both are paid."
      refute md =~ "A card was updated"
    end

    test "markdown/1 prefers the text part" do
      assert Trim.markdown(message("apple_reply.eml")) == "Yes, both are paid.\n\nErin"
    end
  end

  describe "attribution lines" do
    for {lang, line} <- [
          {"English", "On Sat, 24 Oct 2026 at 13:00, Bob <bob@example.com> wrote:"},
          {"Apple Mail", "On 24 Oct 2026, at 13:00, Bob <bob@example.com> wrote:"},
          {"French", "Le sam. 24 oct. 2026 à 13:00, Bob <bob@example.com> a écrit :"},
          {"German", "Am Sa., 24. Okt. 2026 um 13:00 Uhr schrieb Bob <bob@example.com>:"},
          {"Spanish", "El sáb, 24 oct 2026 a las 13:00, Bob (<bob@example.com>) escribió:"},
          {"Italian",
           "Il giorno sab 24 ott 2026 alle ore 13:00 Bob <bob@example.com> ha scritto:"},
          {"Dutch", "Op za 24 okt 2026 om 13:00 schreef Bob <bob@example.com>:"},
          {"Portuguese", "Em sáb., 24 de out. de 2026 às 13:00, Bob <bob@example.com> escreveu:"},
          {"Swedish", "Den lör 24 okt. 2026 kl 13:00 skrev Bob <bob@example.com>:"},
          {"Polish", "W dniu sob., 24.10.2026 o 13:00 Bob <bob@example.com> napisał(a):"},
          {"Russian", "сб, 24 окт. 2026 г. в 13:00, Bob <bob@example.com> написал:"},
          {"Japanese", "2026年10月24日(土) 13:00 Bob <bob@example.com>:書き込みました:"},
          {"Chinese", "Bob <bob@example.com> 于2026年10月24日周六 13:00写道："}
        ] do
      test "#{lang}" do
        assert Trim.text("My reply.\n\n#{unquote(line)}\nOld text\nmore") == "My reply."
      end
    end

    test "an attribution Gmail wrapped over two lines" do
      text =
        "My reply.\n\nOn Sat, 24 Oct 2026 at 13:00, A Very Long Name\n<bob@example.com> wrote:\n\nOld"

      assert Trim.text(text) == "My reply."
    end

    test "a sentence that merely starts with On is kept" do
      text = "On Monday we ship.\nThat is all."
      assert Trim.text(text) == text
    end
  end

  describe "Outlook" do
    test "-----Original Message----- and what follows" do
      assert Trim.text("Fine.\n\n-----Original Message-----\nFrom: x\nOld") == "Fine."
      assert Trim.text("Gut.\n-----Ursprüngliche Nachricht-----\nVon: x") == "Gut."
    end

    test "a localised header block" do
      text = "D'accord.\n\nDe : Bob <bob@example.com>\nEnvoyé : samedi\nÀ : Dee\nObjet : x\n\nOld"
      assert Trim.text(text) == "D'accord."
    end

    test "a header block in bold, as converted from HTML" do
      text = "OK.\n\n**From:** Bob\n**Sent:** Saturday\n**To:** Dee\n\nOld"
      assert Trim.text(text) == "OK."
    end

    test "a From: line in prose, with no Sent/To after it, is kept" do
      text = "Note the header.\nFrom: the field we read\nis how we match senders."
      assert Trim.text(text) == text
    end
  end

  describe "quotes, signatures and footers" do
    test "every > line goes, inline replies stay" do
      text = "> Can you?\nYes.\n> And this?\nNo."
      assert Trim.text(text) == "Yes.\nNo."
    end

    test "a signature from -- on" do
      assert Trim.text("Thanks!\n-- \nAlice\nProduct, Example") == "Thanks!"
      assert Trim.text("Thanks!\n--\nAlice") == "Thanks!"
    end

    test "a dash line inside the prose that isn't a separator is kept" do
      assert Trim.text("a -- b\n--- c") == "a -- b\n--- c"
    end

    test "phone footers" do
      for footer <- [
            "Sent from my iPhone",
            "Sent from my iPad",
            "Sent from Outlook for Android",
            "Get Outlook for iOS",
            "Envoyé de mon iPhone",
            "Von meinem iPhone gesendet"
          ] do
        assert Trim.text("Done.\n\n#{footer}") == "Done.", footer
      end
    end
  end

  describe "never empty" do
    test "a reply that is all quote comes back whole" do
      text = "> just the quote\n> nothing else"
      assert Trim.text(text) == text
    end

    test "a message that is only an attribution comes back whole" do
      text = "On Sat, 24 Oct 2026 at 13:00, Bob <bob@example.com> wrote:\nOld"
      assert Trim.text(text) == text
    end

    test "HTML that is all quote comes back whole" do
      html = ~s(<blockquote type="cite">Only the quote</blockquote>)
      assert Trim.html(html) == html
    end

    test "nothing in, nothing out" do
      assert Trim.text(nil) == ""
      assert Trim.text("   ") == ""
      assert Trim.html(nil) == ""
      assert Trim.markdown(%Message{}) == ""
    end
  end

  test "a forward is not trimmed" do
    text =
      "FYI\n\n---------- Forwarded message ---------\nFrom: Billing <billing@example.org>\nDate: Sat\nSubject: Invoice\nTo: Frank\n\nYour invoice is overdue."

    assert Trim.text(text) =~ "Your invoice is overdue."
  end

  test "HTML: Thunderbird's cite prefix and quote" do
    html =
      ~s(<p>Thanks</p><div class="moz-cite-prefix">On 24/10/2026 Bob wrote:</div>) <>
        ~s(<blockquote type="cite">old</blockquote>)

    md = html |> Trim.html() |> Slipdock.Inbound.HtmlToMarkdown.convert()
    assert md == "Thanks"
  end
end
