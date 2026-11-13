defmodule SlipdockCLI.AttachmentsTest do
  @moduledoc """
  `slipdock attach`, `attachments`, `download` and `detach`: which path each asks (a
  number is a card, anything else a page), what the upload carries, and what
  is printed. The refusals end in `System.halt/1`, so they are covered on the
  server's side, in `SlipdockWeb.API.AttachmentsTest`.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables and changes the working
  # directory, each of which is one for the whole VM.
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
    # Its hash goes with it, for the server to check what arrived against (#1014).
    sha256 = :crypto.hash(:sha256, "PNG!") |> Base.encode16(case: :lower)
    assert body =~ ~s(name="sha256"\r\n\r\n#{sha256}\r\n)

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
    [_fields, file_part] = :binary.split(body, ~s(name="file"))
    [_head, rest] = :binary.split(file_part, "\r\n\r\n")
    [boundary_line | _] = String.split(body, "\r\n", parts: 2)
    assert rest == bytes <> "\r\n" <> boundary_line <> "--\r\n"
    # Hashed a chunk at a time, it is still the hash of the whole file.
    sha256 = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert body =~ ~s(name="sha256"\r\n\r\n#{sha256}\r\n)
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

  test "attachment-text prints the words, or says why there are none" do
    serve([
      {200, ~s({"text":{"status":"done","text":"Invoice 42"}})},
      {200, ~s({"text":{"status":"done","text":""}})},
      {200, ~s({"text":{"status":"queued","text":null}})}
    ])

    assert capture_io(fn -> Boards.run("attachment-text", ["5"], []) end) =~ "Invoice 42"
    assert_received {:request, "GET", "/api/attachments/5/text", _}
    assert capture_io(fn -> Boards.run("attachment-text", ["5"], []) end) =~ "no text was found"
    assert capture_io(fn -> Boards.run("attachment-text", ["5"], []) end) =~ "not read yet"
  end

  test "read-text asks for the card's file to be read again" do
    serve([{202, ~s({"attachment":{"id":5,"filename":"scan.pdf"}})}])

    out = capture_io(fn -> Boards.run("read-text", ["12", "5"], []) end)

    assert_received {:request, "POST", "/api/cards/12/attachments/5/read-text", _}
    assert out =~ "reading scan.pdf [attachment #5] again"
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

  test "attach --replace sends the field and says which older files went (#1017)", %{
    home: home
  } do
    replaced =
      ~s|{"attachment":{"id":9,"filename":"out.docx","content_type":"x","size":1,"markdown":"[out.docx](/attachments/9/out.docx)"},"replaced":[3,4]}|

    serve([
      {201, replaced},
      {201, attached(10, "b.png", "![b.png](/attachments/10/b.png)")}
    ])

    a = file(home, "out.docx", "D")
    out = capture_io(fn -> Boards.run("attach", ["12", a], replace: true) end)
    assert_received {:request, "POST", "/api/cards/12/attachments", body}
    assert body =~ ~s(name="replace"\r\n\r\ntrue)
    assert out =~ "attached out.docx to card #12 [attachment #9]"
    assert out =~ "replaced attachment #3, attachment #4"

    out = capture_io(fn -> Boards.run("attach", ["12", a], []) end)
    assert_received {:request, "POST", "/api/cards/12/attachments", body}
    refute body =~ ~s(name="replace")
    refute out =~ "replaced"
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

  # A download the server refuses, or that never reaches it (#2088). Each of
  # these ends in `fail/1`'s `System.halt(1)`, so the command runs in a child
  # VM, against a FakeServer (or a closed port) started here: what is asserted
  # is what the person sees, the exit status, and that nothing is left where
  # the file would have gone.
  describe "a download that fails" do
    defp child(code, home, url) do
      System.cmd("elixir", ["-pa", Mix.Project.compile_path(), "-e", code],
        cd: home,
        env: [
          {"HOME", home},
          {"TMPDIR", Path.join(home, "tmp")},
          {"SLIPDOCK_URL", url},
          {"SLIPDOCK_TOKEN", "test-token"}
        ],
        stderr_to_stdout: true
      )
    end

    defp main(argv, home, url), do: child("SlipdockCLI.main(#{inspect(argv)})", home, url)

    defp plain(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

    # A port nothing listens on: bound, then let go.
    defp closed_url do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listen)
      :ok = :gen_tcp.close(listen)
      "http://127.0.0.1:#{port}"
    end

    # A server that starts a file and hangs up: a 200 whose content-length
    # promises 1000 bytes, four of them sent, then the socket closed. It is the
    # one failure that leaves bytes on disk, so the one where the callers'
    # clean-up does anything: on a refusal or a closed port `:httpc` never
    # creates the file.
    defp cut_off_url do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      pid =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          read_head(socket, "")

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: application/octet-stream\r\n",
              "content-length: 1000\r\nconnection: close\r\n\r\n",
              "%PDF"
            ])

          :gen_tcp.close(socket)
        end)

      :ok = :gen_tcp.controlling_process(listen, pid)
      "http://127.0.0.1:#{port}"
    end

    defp read_head(socket, acc) do
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      acc = acc <> data
      if acc =~ "\r\n\r\n", do: :ok, else: read_head(socket, acc)
    end

    setup %{home: home} do
      File.mkdir_p!(Path.join(home, "tmp"))
      :ok
    end

    for {status, body, said} <- [
          {404, ~s({"error":"attachment not found"}), "error: attachment not found (HTTP 404)"},
          {403, ~s({"error":"forbidden"}), "error: forbidden (HTTP 403)"},
          {500, "Internal Server Error", ~s(error: HTTP 500: %{"raw" => "Internal Server Error"})}
        ] do
      test "slipdock download --out on a #{status}: says so, exits 1, and leaves no file",
           %{home: home} do
        url = FakeServer.start([{unquote(status), unquote(body)}])
        dest = Path.join(home, "invoice.pdf")

        {out, code} = main(["download", "7", "--out", dest], home, url)

        assert_received {:request, "GET", "/api/attachments/7/file", _}
        assert code == 1
        assert plain(out) =~ unquote(said)
        refute plain(out) =~ "saved"
        refute File.exists?(dest)
        refute File.exists?(dest <> ".part")
      end
    end

    test "a refused download leaves the file already at --out as it was", %{home: home} do
      url = FakeServer.start([{404, ~s({"error":"attachment not found"})}])
      dest = Path.join(home, "invoice.pdf")
      File.write!(dest, "the copy I had")

      assert {_, 1} = main(["download", "7", "--out", dest], home, url)

      assert File.read!(dest) == "the copy I had"
      refute File.exists?(dest <> ".part")
    end

    test "with no --out, a refused file is not saved under its own name", %{home: home} do
      url =
        FakeServer.start([
          {200, ~s({"attachment":{"id":7,"filename":"invoice.pdf","size":4,"card":12}})},
          {404, ~s({"error":"attachment not found"})}
        ])

      {out, code} = main(["download", "7"], home, url)

      assert code == 1
      assert plain(out) =~ "error: attachment not found (HTTP 404)"
      assert File.ls!(home) |> Enum.sort() == ["tmp"]
    end

    test "--out - on a refusal writes no bytes and removes its temp file", %{home: home} do
      url = FakeServer.start([{404, ~s({"error":"attachment not found"})}])

      {out, code} = main(["download", "7", "--out", "-"], home, url)

      assert code == 1
      assert plain(out) == "error: attachment not found (HTTP 404)\n"
      assert File.ls!(Path.join(home, "tmp")) == []
    end

    test "a server that isn't there: says it could not reach it, exits 1, no file",
         %{home: home} do
      url = closed_url()
      dest = Path.join(home, "invoice.pdf")

      {out, code} = main(["download", "7", "--out", dest], home, url)

      assert code == 1
      assert plain(out) =~ "error: could not reach #{url}"
      assert plain(out) =~ "econnrefused"
      refute File.exists?(dest)
      refute File.exists?(dest <> ".part")
    end

    test "Util.download_to/3 on a 404: the error, exit 1, neither dest nor dest.part",
         %{home: home} do
      url = FakeServer.start([{404, ~s({"error":"tool not found"})}])
      dest = Path.join(home, "demo.tar.gz")

      {out, code} =
        child(
          "SlipdockCLI.Util.download_to(#{inspect("/tools/demo/package.tar.gz")}, " <>
            "#{inspect(dest)}, [])",
          home,
          url
        )

      assert_received {:request, "GET", "/api/tools/demo/package.tar.gz", _}
      assert code == 1
      assert plain(out) =~ "error: tool not found (HTTP 404)"
      refute plain(out) =~ "saved"
      refute File.exists?(dest)
      refute File.exists?(dest <> ".part")
    end

    test "slipdock tools download on a 404 leaves no package behind", %{home: home} do
      url = FakeServer.start([{404, ~s({"error":"tool not found"})}])
      dest = Path.join(home, "demo.tar.gz")

      {out, code} =
        main(["tools", "download", "demo", "--version", "1.0.0", "--out", dest], home, url)

      assert code == 1
      assert plain(out) =~ "error: tool not found (HTTP 404)"
      refute File.exists?(dest)
      refute File.exists?(dest <> ".part")
    end

    test "Util.download_to/3 with the server gone: could not reach it, no dest.part",
         %{home: home} do
      url = closed_url()
      dest = Path.join(home, "demo.tar.gz")

      {out, code} =
        child(
          "SlipdockCLI.Util.download_to(\"/tools/demo/package.tar.gz\", #{inspect(dest)}, [])",
          home,
          url
        )

      assert code == 1
      assert plain(out) =~ "error: could not reach #{url}"
      refute File.exists?(dest)
      refute File.exists?(dest <> ".part")
    end

    test "Util.download_to_stdout/2 on a 500: no bytes out, its temp file removed",
         %{home: home} do
      url = FakeServer.start([{500, ~s({"error":"boom"})}])

      {out, code} =
        child("SlipdockCLI.Util.download_to_stdout(\"/tools/demo/files/a.txt\", [])", home, url)

      assert code == 1
      assert plain(out) == "error: boom (HTTP 500)\n"
      assert File.ls!(Path.join(home, "tmp")) == []
    end

    test "slipdock download --out cut off mid-body: says so, exits 1, no dest or dest.part",
         %{home: home} do
      url = cut_off_url()
      dest = Path.join(home, "invoice.pdf")

      {out, code} = main(["download", "7", "--out", dest], home, url)

      assert code == 1
      assert plain(out) =~ "error: could not reach #{url}"
      assert plain(out) =~ "server_closed"
      refute plain(out) =~ "saved"
      refute File.exists?(dest)
      refute File.exists?(dest <> ".part")
      assert File.ls!(home) == ["tmp"]
    end

    test "a download cut off mid-body leaves the file already at --out as it was",
         %{home: home} do
      url = cut_off_url()
      dest = Path.join(home, "invoice.pdf")
      File.write!(dest, "the copy I had")

      {out, code} = main(["download", "7", "--out", dest], home, url)

      assert code == 1
      assert plain(out) =~ "error: could not reach #{url}"
      assert File.read!(dest) == "the copy I had"
      refute File.exists?(dest <> ".part")
    end

    test "--out - cut off mid-body: the error, exit 1, no temp file left", %{home: home} do
      url = cut_off_url()

      {out, code} = main(["download", "7", "--out", "-"], home, url)

      assert code == 1
      assert plain(out) =~ "error: could not reach #{url}"
      assert plain(out) =~ "server_closed"
      assert File.ls!(Path.join(home, "tmp")) == []
    end

    test "Util.download_to/3 cut off mid-body: the error, exit 1, neither dest nor dest.part",
         %{home: home} do
      url = cut_off_url()
      dest = Path.join(home, "demo.tar.gz")

      {out, code} =
        child(
          "SlipdockCLI.Util.download_to(\"/tools/demo/package.tar.gz\", #{inspect(dest)}, [])",
          home,
          url
        )

      assert code == 1
      assert plain(out) =~ "error: could not reach #{url}"
      assert plain(out) =~ "server_closed"
      refute plain(out) =~ "saved"
      refute File.exists?(dest)
      refute File.exists?(dest <> ".part")
    end

    # The temp file a cut-off download leaves is not asserted here: `out/3`
    # halts the VM inside the `try`, so the `after` that removes it never
    # runs. That is a fault in the code, not in a test, and this card is
    # test-only: it is filed as its own card. What the `after` does do, on a
    # download that works, is held by the test after this one.
    test "Util.download_to_stdout/2 cut off mid-body: the error, exit 1, no bytes out",
         %{home: home} do
      url = cut_off_url()

      {out, code} =
        child("SlipdockCLI.Util.download_to_stdout(\"/tools/demo/files/a.txt\", [])", home, url)

      assert code == 1
      assert plain(out) =~ ~r/\Aerror: could not reach #{Regex.escape(url)} .*server_closed/
      refute out =~ "%PDF"
    end

    test "Util.download_to_stdout/2 that works: the bytes out, its temp file removed",
         %{home: home} do
      url = FakeServer.start([{200, "print('hi')\n"}])

      {out, code} =
        child("SlipdockCLI.Util.download_to_stdout(\"/tools/demo/files/a.txt\", [])", home, url)

      assert_received {:request, "GET", "/api/tools/demo/files/a.txt", _}
      assert code == 0
      assert out == "print('hi')\n"
      assert File.ls!(Path.join(home, "tmp")) == []
    end
  end
end
