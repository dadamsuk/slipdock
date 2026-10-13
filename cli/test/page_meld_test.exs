defmodule SlipdockCLI.PageMeldTest do
  @moduledoc """
  `slipdock page encrypt|decrypt` (W-103 R6.8): Meld Encrypt's format, done
  on this machine. The vectors were made by Meld's own code (see the wiki's
  W-1656); what is checked of the commands is what reaches the server.
  Refusals end in `System.halt/1`, so they are covered as the values the
  command halts on.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{FakeServer, Meld, Wiki}

  @vectors "../test/support/fixtures/meld_vectors.json"
           |> Path.expand(__DIR__ <> "/..")
           |> File.read!()
           |> :json.decode()

  defp v(n), do: Enum.at(@vectors["inline"], n)

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-meld-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    saved =
      Map.new(
        ~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN SLIPDOCK_MELD_PASSPHRASE),
        &{&1, System.get_env(&1)}
      )

    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    Enum.each(~w(SLIPDOCK_URL KANBAN_TOKEN SLIPDOCK_MELD_PASSPHRASE), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  # Runs a command against canned answers; gives back every request made,
  # what was printed, and what went to stderr.
  defp run(args, opts, responses) do
    System.put_env("SLIPDOCK_URL", FakeServer.start(Enum.map(responses, &{200, &1})))

    err =
      capture_io(:stderr, fn ->
        send(self(), {:out, capture_io(fn -> Wiki.run("page", args, opts) end)})
      end)

    assert_received {:out, out}
    {requests(length(responses)), out, err}
  end

  defp requests(0), do: []

  defp requests(n) do
    receive do
      {:request, method, path, body} -> [{method, path, body} | requests(n - 1)]
    after
      2_000 -> []
    end
  end

  defp page_json(body),
    do:
      :json.encode(%{
        "page" => %{
          "code" => "W-9",
          "title" => "Bank",
          "url" => "/x",
          "body" => body,
          "content_hash" => "h1"
        }
      })
      |> IO.iodata_to_binary()

  defp json(map), do: map |> :json.encode() |> IO.iodata_to_binary()

  describe "the format" do
    test "decrypts every block Meld wrote, every version and marker" do
      for vector <- @vectors["inline"] do
        assert [block] = Meld.blocks("x " <> vector["text"] <> " y")
        assert block.version == vector["version"]
        assert block.hint == vector["hint"]
        assert block.visible == vector["visible"]
        assert Meld.decrypt_block(block, vector["passphrase"]) == {:ok, vector["plaintext"]}
        assert Meld.decrypt_block(vector["text"], vector["passphrase"] <> "!") == :error
      end
    end

    test "damaged or not-a-block text is an error, not a crash" do
      [block] = Meld.blocks(v(0)["text"])
      assert Meld.decrypt_block(%{block | base64: "AAAA"}, "pw") == :error
      assert Meld.decrypt_block(%{block | base64: "!!"}, "pw") == :error
      assert Meld.decrypt_block("plain", "pw") == :error
    end

    test "what it writes is version 2, reads back, and keeps the hint and the marker" do
      text = Meld.encrypt_block("Sort code 12-34-56\nün 🎉", "s3cret ü", "bank", false)
      assert String.starts_with?(text, "%%🔐β 💡bank💡")
      assert String.ends_with?(text, " 🔐%%")
      assert [%{version: 2, hint: "bank", visible: false} = block] = Meld.blocks(text)
      assert Meld.decrypt_block(block, "s3cret ü") == {:ok, "Sort code 12-34-56\nün 🎉"}
      refute Meld.encrypt_block("a", "b") =~ "💡"
    end

    @tag :node
    test "Meld's own code decrypts what this writes" do
      node = System.find_executable("node")

      if node do
        text = Meld.encrypt_block("from the CLI ✓", "pw ü", "h")
        reference = Path.expand("../test/support/fixtures/meld_reference.mjs", File.cwd!())

        script = """
        const ref = await import(#{inspect("file://" <> reference)})
        const p = new ref.InlineParser(process.argv[1])
        const h = ref.CryptoHelperFactory.BuildFromDecryptableOrThrow(p.decryptable)
        process.stdout.write(await h.decryptFromBase64(p.decryptable.base64CipherText, "pw ü"))
        """

        assert {"from the CLI ✓", 0} =
                 System.cmd(node, ["--input-type=module", "-e", script, text])
      end
    end

    test "encrypt_text keeps the whitespace around the block outside it" do
      out = Meld.encrypt_text("\n\nSecret line\n\n", "pw")
      assert String.starts_with?(out, "\n\n🔐β ")
      assert String.ends_with?(out, " 🔐\n\n")
      assert {:ok, "\n\nSecret line\n\n"} = Meld.decrypt_all(out, "pw")
    end

    test "decrypt_all opens every block, or says how many it couldn't" do
      text = "a #{v(0)["text"]} b #{v(1)["text"]}"
      assert Meld.decrypt_all(text, v(0)["passphrase"]) == {:error, 1}

      mixed = "a #{v(2)["text"]} b #{v(3)["text"]}"

      assert Meld.decrypt_all(mixed, "legacy") ==
               {:ok, "a #{v(2)["plaintext"]} b #{v(3)["plaintext"]}"}
    end

    test "what is refused: bad hints, nothing to encrypt, text already encrypted" do
      assert Meld.check_hint("fine") == nil
      assert Meld.check_hint(nil) == nil
      for bad <- ["a💡", "🔐", "two\nlines"], do: assert(Meld.check_hint(bad))
      assert Meld.refuse_encrypt("  \n") =~ "nothing"
      assert Meld.refuse_encrypt("x #{v(0)["text"]}") =~ "already"
      assert Meld.refuse_encrypt("plain") == nil
    end

    test "the passphrase comes from a file or the environment, never empty", %{home: home} do
      file = Path.join(home, "pass")
      File.write!(file, "from file\nsecond line")
      assert Meld.passphrase(passphrase_file: file) == {:ok, "from file"}
      File.write!(file, "\n")
      assert {:error, "the passphrase is empty"} = Meld.passphrase(passphrase_file: file)

      assert {:error, "can't read " <> _} =
               Meld.passphrase(passphrase_file: Path.join(home, "nope"))

      System.put_env("SLIPDOCK_MELD_PASSPHRASE", "from env")
      assert Meld.passphrase([]) == {:ok, "from env"}
    end
  end

  describe "page encrypt" do
    test "sends only ciphertext, with the hash it read, and counts the revisions still holding the text" do
      System.put_env("SLIPDOCK_MELD_PASSPHRASE", "pw")

      revisions =
        json(%{
          "revisions" => [%{"id" => 1, "body" => "PIN 4921"}, %{"id" => 2, "body" => "new"}]
        })

      {[get, patch, history], out, err} =
        run(["encrypt", "W-9"], [hint: "bank"], [
          page_json("PIN 4921\n"),
          page_json("x"),
          revisions
        ])

      assert {"GET", "/api/pages/W-9", _} = get
      {"PATCH", "/api/pages/W-9", sent} = patch
      refute sent =~ "4921"
      refute sent =~ "\"pw\""
      %{"body" => body, "base_hash" => "h1"} = :json.decode(sent)
      assert {:ok, "PIN 4921\n"} = Meld.decrypt_all(body, "pw")
      assert [%{hint: "bank"}] = Meld.blocks(body)

      assert {"GET", "/api/pages/W-9/revisions?bodies=all", _} = history
      assert out =~ "encrypted the page of W-9"
      assert err =~ "1 earlier revision of W-9 still holds the text in plain"
    end

    test "--purge-history asks the server to delete exactly the revisions holding it" do
      System.put_env("SLIPDOCK_MELD_PASSPHRASE", "pw")

      revisions =
        json(%{
          "revisions" => [
            %{"id" => 4, "body" => "PIN 4921"},
            %{"id" => 5, "body" => "other"},
            %{"id" => 6, "body" => "PIN 4921 again"},
            %{"id" => 7, "body" => "newest, the encrypted one"}
          ]
        })

      {[_, _, _, purge], out, _} =
        run(["encrypt", "W-9"], [purge_history: true], [
          page_json("PIN 4921"),
          page_json("x"),
          revisions,
          json(%{"purged" => 2})
        ])

      assert {"POST", "/api/pages/W-9/revisions/purge", sent} = purge
      assert :json.decode(sent) == %{"ids" => [4, 6]}
      refute sent =~ "4921"
      assert out =~ "purged 2 earlier revisions"
    end

    test "--section encrypts the text under the heading and keeps the heading" do
      System.put_env("SLIPDOCK_MELD_PASSPHRASE", "pw")
      section = json(%{"body" => "## Keys\nalarm 1234\n"})

      {[_, read, heading, put, _], _out, _} =
        run(["encrypt", "W-9"], [section: "Keys"], [
          page_json("# T\n## Keys\nalarm 1234\n"),
          section,
          section,
          page_json("x"),
          json(%{"revisions" => []})
        ])

      assert {"GET", "/api/pages/W-9/section/Keys", _} = read
      assert {"GET", "/api/pages/W-9/section/Keys", _} = heading
      assert {"PUT", "/api/pages/W-9/section/Keys", sent} = put
      %{"body" => body, "base_hash" => "h1"} = :json.decode(sent)
      assert String.starts_with?(body, "## Keys\n🔐β ")
      refute body =~ "1234"
      assert {:ok, "## Keys\nalarm 1234\n"} = Meld.decrypt_all(body, "pw")
    end
  end

  describe "page decrypt" do
    test "prints the page with its blocks opened, and sends nothing back" do
      System.put_env("SLIPDOCK_MELD_PASSPHRASE", v(0)["passphrase"])

      {[{"GET", _, _}], out, _} =
        run(["decrypt", "W-9"], [], [page_json("PIN: #{v(0)["text"]}.")])

      assert out == "PIN: #{v(0)["plaintext"]}."
    end

    test "--in-place saves the plain text, with the hash it read" do
      System.put_env("SLIPDOCK_MELD_PASSPHRASE", v(0)["passphrase"])

      {[_, {"PATCH", _, sent}], out, _} =
        run(["decrypt", "W-9"], [in_place: true], [
          page_json("PIN: #{v(0)["text"]}."),
          page_json("x")
        ])

      assert %{"body" => "PIN: My PIN is 4921.", "base_hash" => "h1"} = :json.decode(sent)
      assert out =~ "removed the encryption from the page of W-9"
    end
  end
end
