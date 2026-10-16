defmodule SlipdockCLI.AttachmentsTest do
  @moduledoc """
  `slipdock attach`, `attachments`, `download` and `detach`: which path each asks (a
  number is a card, anything else a page), what the upload carries, and what
  is printed. The refusals end in `System.halt/1`, so they are covered on the
  server's side, in `SlipdockWeb.API.AttachmentsTest`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, Render}

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-attach-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  defp file(home, name, contents) do
    path = Path.join(home, name)
    File.write!(path, contents)
    path
  end

  defp attached(id, name, markdown),
    do:
      ~s({"attachment":{"id":#{id},"filename":"#{name}","content_type":"image/png","size":4,"url":"/attachments/#{id}/#{name}","markdown":"#{markdown}"}})

  test "attach uploads the bytes as `file` and prints the Markdown that embeds it", %{home: home} do
    serve([{201, attached(5, "shot.png", "![shot.png](/attachments/5/shot.png)")}])
    shot = file(home, "shot.png", "PNG!")

    out = capture_io(fn -> Boards.run("attach", ["12", shot], []) end)

    assert_received {:request, "POST", "/api/cards/12/attachments", body}
    assert body =~ ~s(name="file"; filename="shot.png")
    assert body =~ "content-type: application/octet-stream"
    assert body =~ "PNG!"

    assert out =~ "attached shot.png to card #12 [attachment #5]"
    assert out =~ "![shot.png](/attachments/5/shot.png)"
  end

  test "a file larger than a read is streamed from disk whole, length and all", %{home: home} do
    serve([{201, attached(7, "big.bin", "[big.bin](/attachments/7/big.bin)")}])
    # Three reads' worth and a bit, with a pattern that shows any lost chunk.
    bytes = for(n <- 0..(3 * 1_048_576 + 4), into: <<>>, do: <<rem(n, 251)>>)
    big = file(home, "big.bin", bytes)

    capture_io(fn -> Boards.run("attach", ["12", big], []) end)

    assert_received {:request, "POST", "/api/cards/12/attachments", body}
    [_head, rest] = :binary.split(body, "\r\n\r\n")
    [boundary_line | _] = String.split(body, "\r\n", parts: 2)
    assert rest == bytes <> "\r\n" <> boundary_line <> "--\r\n"
  end

  test "a page code goes to the page, and --name renames the file", %{home: home} do
    serve([{201, attached(6, "diagram.png", "![diagram.png](/attachments/6/diagram.png)")}])
    tmp = file(home, "tmp-123", "PNG!")

    out = capture_io(fn -> Boards.run("attach", ["W-31", tmp], name: "diagram.png") end)

    assert_received {:request, "POST", "/api/pages/W-31/attachments", body}
    assert body =~ ~s(filename="diagram.png")
    assert out =~ "attached diagram.png to page W-31"
  end

  test "several files are several uploads", %{home: home} do
    serve([
      {201, attached(1, "a.png", "![a.png](/attachments/1/a.png)")},
      {201, attached(2, "b.png", "![b.png](/attachments/2/b.png)")}
    ])

    a = file(home, "a.png", "A")
    b = file(home, "b.png", "B")

    out = capture_io(fn -> Boards.run("attach", ["12", a, b], []) end)

    assert_received {:request, "POST", "/api/cards/12/attachments", _}
    assert_received {:request, "POST", "/api/cards/12/attachments", _}
    assert out =~ "[attachment #1]" and out =~ "[attachment #2]"
  end

  test "attachments lists each file, and says so when there are none" do
    serve([
      {200,
       ~s({"attachments":[{"id":5,"filename":"shot.png","content_type":"image/png","size":2048,"url":"/attachments/5/shot.png"}]})},
      {200, ~s({"attachments":[]})}
    ])

    out = capture_io(fn -> Boards.run("attachments", ["12"], []) end)
    assert_received {:request, "GET", "/api/cards/12/attachments", _}
    assert out =~ "shot.png (image/png, 2 KB) /attachments/5/shot.png [attachment #5]"

    assert capture_io(fn -> Boards.run("attachments", ["W-31"], []) end) =~
             "no attachments on page W-31"

    assert_received {:request, "GET", "/api/pages/W-31/attachments", _}
  end

  test "detach deletes each one named" do
    serve([{200, ~s({"ok":true})}, {200, ~s({"ok":true})}])

    out = capture_io(fn -> Boards.run("detach", ["12", "5", "6"], []) end)

    assert_received {:request, "DELETE", "/api/cards/12/attachments/5", _}
    assert_received {:request, "DELETE", "/api/cards/12/attachments/6", _}
    assert out =~ "removed attachment #5 from card #12"
    assert out =~ "removed attachment #6 from card #12"
  end

  test "card shows the card's files, with the ids detach takes" do
    card = %{
      "id" => 12,
      "title" => "Has a screenshot",
      "board_id" => 3,
      "blocked_by" => [],
      "blocks" => [],
      "flags" => [],
      "tags" => [],
      "assignees" => [],
      "checklist" => %{"done" => 0, "total" => 0, "items" => []},
      "comments" => [],
      "urls" => [],
      "links" => [],
      "attachments" => [
        %{
          "id" => 5,
          "filename" => "shot.png",
          "content_type" => "image/png",
          "size" => 2048,
          "url" => "/attachments/5/shot.png"
        }
      ]
    }

    out = capture_io(fn -> Render.card(card) end)
    assert out =~ "Files"
    assert out =~ "shot.png (image/png, 2 KB) /attachments/5/shot.png [attachment #5]"

    refute capture_io(fn -> Render.card(%{card | "attachments" => []}) end) =~ "Files"
  end

  test "attach --hide-on-card sends the field; without it, nothing is sent", %{home: home} do
    serve([
      {201, attached(5, "a.png", "![a.png](/attachments/5/a.png)")},
      {201, attached(6, "b.png", "![b.png](/attachments/6/b.png)")}
    ])

    a = file(home, "a.png", "A")
    capture_io(fn -> Boards.run("attach", ["12", a], hide_on_card: true) end)
    assert_received {:request, "POST", "/api/cards/12/attachments", body}
    assert body =~ ~s(name="hide_on_card"\r\n\r\ntrue)

    capture_io(fn -> Boards.run("attach", ["12", a], []) end)
    assert_received {:request, "POST", "/api/cards/12/attachments", body}
    refute body =~ "hide_on_card"
  end

  test "card-front lets an image be the thumbnail, and --off keeps it off" do
    patched = fn hide ->
      ~s({"attachment":{"id":5,"filename":"shot.png","hide_on_card":#{hide}}})
    end

    serve([{200, patched.(true)}, {200, patched.(false)}])

    out = capture_io(fn -> Boards.run("card-front", ["12", "5"], off: true) end)
    assert_received {:request, "PATCH", "/api/cards/12/attachments/5", body}
    assert JSON.decode!(body) == %{"hide_on_card" => true}
    assert out =~ "shot.png [attachment #5] kept off the front of card #12"

    out = capture_io(fn -> Boards.run("card-front", ["12", "5"], []) end)
    assert_received {:request, "PATCH", "/api/cards/12/attachments/5", body}
    assert JSON.decode!(body) == %{"hide_on_card" => false}
    assert out =~ "may show on the front of card #12"
  end

  test "a file kept off the card front says so in its line" do
    line = Render.attachment_line(%{"filename" => "f.png", "size" => 1, "hide_on_card" => true})
    assert line =~ "(not on the card front)"
    refute Render.attachment_line(%{"filename" => "f.png", "size" => 1}) =~ "card front"
  end

  describe "transcribe" do
    setup do
      saved = System.get_env("SLIPDOCK_POLL_MS")
      System.put_env("SLIPDOCK_POLL_MS", "0")

      on_exit(fn ->
        if saved,
          do: System.put_env("SLIPDOCK_POLL_MS", saved),
          else: System.delete_env("SLIPDOCK_POLL_MS")
      end)
    end

    defp audio(status, extra \\ "") do
      ~s({"id":5,"filename":"call.mp3","content_type":"audio/mpeg","size":9,"url":"/attachments/5/call.mp3","transcript_status":"#{status}"#{extra}})
    end

    test "starts it and says how to follow it" do
      serve([{202, ~s({"attachment":#{audio("running")}})}])

      out = capture_io(fn -> Boards.run("transcribe", ["12", "5"], []) end)

      assert_received {:request, "POST", "/api/cards/12/attachments/5/transcribe", _}
      assert out =~ "transcribing call.mp3 [attachment #5]"
      assert out =~ "--wait"
    end

    test "--wait asks after it until it is done, and prints the transcript" do
      serve([
        {202, ~s({"attachment":#{audio("running")}})},
        {200, ~s({"attachments":[#{audio("running")}]})},
        {200,
         ~s({"attachments":[#{audio("done", ~s(,"transcript":"Steve: Ship it.\\nJohn: Agreed."))}]})}
      ])

      out = capture_io(fn -> Boards.run("transcribe", ["12", "5"], wait: true) end)

      assert_received {:request, "POST", "/api/cards/12/attachments/5/transcribe", _}
      assert_received {:request, "GET", "/api/cards/12/attachments", _}
      assert_received {:request, "GET", "/api/cards/12/attachments", _}
      assert out == "Steve: Ship it.\nJohn: Agreed.\n"
    end

    test "--wait on silence says there was no speech" do
      serve([{202, ~s({"attachment":#{audio("done", ~s(,"transcript":null))}})}])
      out = capture_io(fn -> Boards.run("transcribe", ["12", "5"], wait: true) end)
      assert out =~ "call.mp3: no speech was found"
    end

    test "a listing says where each recording has got to" do
      for {status, words} <- [
            {"running", "(transcribing)"},
            {"done", "(transcribed)"},
            {"failed", "(transcription failed)"}
          ] do
        line =
          Render.attachment_line(%{
            "filename" => "c.mp3",
            "size" => 1,
            "transcript_status" => status
          })

        assert line =~ words
      end
    end
  end

  test "a file's line gives its size in the unit that reads" do
    line = fn size -> Render.attachment_line(%{"filename" => "f", "size" => size}) end

    assert line.(12) =~ "12 B"
    assert line.(4096) =~ "4 KB"
    assert line.(3 * 1_048_576) =~ "3.0 MB"
  end

  describe "download" do
    setup %{home: home} do
      here = File.cwd!()
      File.cd!(home)
      on_exit(fn -> File.cd!(here) end)
      :ok
    end

    defp details(id, name),
      do: ~s({"attachment":{"id":#{id},"filename":"#{name}","size":4,"card":12}})

    test "with no --out, saves it under its own name here", %{home: home} do
      serve([{200, details(5, "shot.png")}, {200, "PNG!"}])

      out = capture_io(fn -> Boards.run("download", ["5"], []) end)

      assert_received {:request, "GET", "/api/attachments/5", _}
      assert_received {:request, "GET", "/api/attachments/5/file", _}
      assert File.read!(Path.join(home, "shot.png")) == "PNG!"
      refute File.exists?(Path.join(home, "shot.png.part"))
      assert out =~ "saved attachment #5 to shot.png (4 bytes)"
    end

    test "--out names the file, and asks for no details first", %{home: home} do
      serve([{200, "bytes"}])
      dest = Path.join(home, "renamed.bin")

      out = capture_io(fn -> Boards.run("download", ["7"], out: dest) end)

      assert_received {:request, "GET", "/api/attachments/7/file", _}
      refute_received {:request, "GET", "/api/attachments/7", _}
      assert File.read!(dest) == "bytes"
      assert out =~ "saved attachment #7 to #{dest} (5 bytes)"
    end

    test "--out - writes the bytes to stdout and nothing else" do
      serve([{200, <<0, 1, 2, 255>>}])

      out = capture_io(fn -> Boards.run("download", ["7"], out: "-") end)

      assert out == <<0, 1, 2, 255>>
    end

    test "--json reports where it went", %{home: home} do
      serve([{200, "abc"}])
      dest = Path.join(home, "a.txt")

      out = capture_io(fn -> Boards.run("download", ["7"], out: dest, json: true) end)

      assert JSON.decode!(out) == %{"attachment" => "7", "path" => dest, "size" => 3}
    end

    test "the name is only ever a name, and a file already here is kept", %{home: home} do
      assert Boards.download_dest("../../etc/passwd", 5, []) == {:ok, "passwd"}
      assert Boards.download_dest("..", 5, []) == {:ok, "attachment-5"}
      assert Boards.download_dest("", 5, []) == {:ok, "attachment-5"}

      File.write!(Path.join(home, "shot.png"), "mine")

      assert {:error, "shot.png is already here: --force" <> _} =
               Boards.download_dest("shot.png", 5, [])

      assert Boards.download_dest("shot.png", 5, force: true) == {:ok, "shot.png"}
    end
  end
end
