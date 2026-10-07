defmodule Slipdock.AIKeysTest do
  @moduledoc """
  Per-person OpenRouter keys: the JSON file they live in, how `Slipdock.AI`
  picks one for a call, and that a person without a key is declined rather
  than quietly spending someone else's.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.AI
  alias Slipdock.AI.Keys

  setup do
    # A file of this test's own, and no shared key unless a test asks for one:
    # the point of most of these is what happens when nobody has a key.
    file = Path.join(System.tmp_dir!(), "ai_keys_#{System.unique_integer([:positive])}.json")

    Slipdock.TestConfig.merge(:ai, key_file: file, api_key: nil)

    on_exit(fn ->
      File.rm(file)
      Enum.each(Path.wildcard(file <> "*.tmp"), &File.rm/1)
    end)

    %{key_file: file, user: user_fixture("keys@example.com")}
  end

  defp close_signups, do: {:ok, _} = Slipdock.Settings.update(%{signup_mode: :closed})

  defp make_admin(user),
    do: user |> Ecto.Changeset.change(admin: true) |> Slipdock.Repo.update!()

  defp shared_key(key), do: Slipdock.TestConfig.merge(:ai, api_key: key)

  describe "the store" do
    test "a key round-trips, and the file is readable only by its owner", ctx do
      assert Keys.get(ctx.user) == nil
      assert :ok = Keys.put(ctx.user, "sk-or-v1-secret")
      assert Keys.get(ctx.user) == "sk-or-v1-secret"
      assert Keys.get(ctx.user.id) == "sk-or-v1-secret"
      assert Keys.configured?(ctx.user)

      assert %{mode: mode} = File.stat!(ctx.key_file)
      assert Bitwise.band(mode, 0o077) == 0

      # The email is recorded alongside, so the file is readable by a human.
      assert File.read!(ctx.key_file) =~ fixture_email("keys@example.com")
    end

    test "a second key replaces the first, and leaves other people alone", ctx do
      other = user_fixture("other@example.com")
      :ok = Keys.put(ctx.user, "sk-one")
      :ok = Keys.put(other, "sk-other")
      :ok = Keys.put(ctx.user, "sk-two")

      assert Keys.get(ctx.user) == "sk-two"
      assert Keys.get(other) == "sk-other"
    end

    test "removing takes only that key out", ctx do
      other = user_fixture("other@example.com")
      :ok = Keys.put(ctx.user, "sk-one")
      :ok = Keys.put(other, "sk-other")

      assert :ok = Keys.delete(ctx.user)
      refute Keys.configured?(ctx.user)
      assert Keys.get(other) == "sk-other"

      # Removing a key nobody has is not an error.
      assert :ok = Keys.delete(ctx.user)
    end

    test "a blank key removes rather than storing nothing", ctx do
      :ok = Keys.put(ctx.user, "sk-one")
      assert :ok = Keys.put(ctx.user, "   ")
      refute Keys.configured?(ctx.user)
    end

    test "a missing or corrupt file reads as empty, and is never written over", ctx do
      assert Keys.all() == %{}
      File.write!(ctx.key_file, "{not json")
      assert Keys.all() == %{}

      # Saving over it would replace everybody's settings with this one.
      assert {:error, message} = Keys.put(ctx.user, "sk-one")
      assert message =~ "unreadable"
      assert File.read!(ctx.key_file) == "{not json"
    end

    test "saves at the same time don't lose each other", ctx do
      users = for n <- 1..20, do: user_fixture("writer#{n}@example.com")

      # Writes serialise under a :global lock whose retry backoff grows with
      # contention (up to 8s a round), so with 20 writers at once an unlucky
      # task can exceed Task.await's 5s default. The assertion is about
      # correctness, not latency, so allow generous time for the lock to drain.
      users
      |> Enum.map(fn user -> Task.async(fn -> Keys.put(user, "sk-#{user.id}") end) end)
      |> Enum.each(&assert(Task.await(&1, 30_000) == :ok))

      for user <- users, do: assert(Keys.get(user) == "sk-#{user.id}")
      assert Path.wildcard(ctx.key_file <> "*.tmp") == []
    end

    test "masked/1 shows the ends and hides the middle" do
      assert Keys.masked("sk-or-v1-0123456789abcdef") == "sk-or-v1…cdef"
      assert Keys.masked("short") == "•••••"
      assert Keys.masked(nil) == nil
    end

    test "updated_at/1 records when the key was set", ctx do
      assert Keys.updated_at(ctx.user) == nil
      :ok = Keys.put(ctx.user, "sk-one")
      assert {:ok, _, _} = DateTime.from_iso8601(Keys.updated_at(ctx.user))
    end
  end

  describe "system_key/0 — what unattended work spends" do
    test "a shared key wins, since the server owner meant it", ctx do
      :ok = Keys.put(ctx.user, "sk-mine")
      shared_key("sk-shared")
      assert Keys.system_key() == "sk-shared"
    end

    test "the only stored key, when there is just one person and they run the server", ctx do
      close_signups()
      admin = make_admin(ctx.user)
      :ok = Keys.put(admin, "sk-mine")
      assert Keys.system_key() == "sk-mine"
    end

    test "never a lone non-admin's settings: their endpoint would receive everyone's content",
         ctx do
      close_signups()
      :ok = Keys.put_settings(ctx.user, %{api_key: "sk-theirs", base_url: "https://evil.test/v1"})

      assert Keys.system_settings().base_url == nil
      assert Keys.system_key() == nil
      refute match?({:ok, %{base_url: "https://evil.test/v1"}}, AI.provider([]))
    end

    test "not even an admin's, unasked, once other people can sign up", ctx do
      admin = make_admin(ctx.user)
      :ok = Keys.put(admin, "sk-mine")
      {:ok, _} = Slipdock.Settings.update(%{signup_mode: :open})

      assert Keys.system_key() == nil
    end

    test "indexing and other people's searches don't go to one user's endpoint", ctx do
      searcher = user_fixture("searcher@example.com")
      shared_key("sk-shared")

      :ok =
        Keys.put_settings(ctx.user, %{api_key: "sk-theirs", base_url: "https://evil.test/v1"})

      # What the indexer and `Search.search/3` embed through.
      assert {:ok, provider} = AI.provider([])
      refute provider.base_url == "https://evil.test/v1"
      assert provider.api_key == "sk-shared"

      # And the searcher, asking for themselves, gets the shared key too.
      assert {:ok, %{api_key: "sk-shared"}} = AI.provider(user: searcher)
    end

    test "SLIPDOCK_AI_SYSTEM_USER settles it when several people have keys", ctx do
      other = user_fixture("other@example.com")
      :ok = Keys.put(ctx.user, "sk-mine")
      :ok = Keys.put(other, "sk-other")

      assert Keys.system_key() == nil

      Slipdock.TestConfig.merge(:ai, system_user: fixture_email("OTHER@example.com"))

      assert Keys.system_key() == "sk-other"
    end

    test "nothing stored, nothing shared, no key" do
      assert Keys.system_key() == nil
      refute AI.configured?()
    end
  end

  describe "Slipdock.AI picks the key" do
    test "the user's own key goes in the Authorization header", ctx do
      :ok = Keys.put(ctx.user, "sk-mine")
      Slipdock.AIStub.reply_with("fine")

      assert {:ok, "fine"} = AI.complete([%{role: "user", content: "hi"}], user: ctx.user)
      assert {:ok, "sk-mine"} = AI.api_key(user: ctx.user)
    end

    test "a user without a key is declined, and told where to get one", ctx do
      assert {:error, message} = AI.complete([%{role: "user", content: "hi"}], user: ctx.user)
      assert message =~ "OpenRouter"
      assert message =~ "Account"
      refute AI.configured?(ctx.user)
      refute AI.configured?(nil)
    end

    test "an explicit :api_key beats everything", ctx do
      :ok = Keys.put(ctx.user, "sk-mine")
      assert {:ok, "sk-given"} = AI.api_key(api_key: "sk-given", user: ctx.user)
    end

    test "a shared key covers people who have none of their own", ctx do
      shared_key("sk-shared")
      assert AI.configured?(ctx.user)
      assert {:ok, "sk-shared"} = AI.api_key(user: ctx.user)

      # Their own key still wins over the shared one.
      :ok = Keys.put(ctx.user, "sk-mine")
      assert {:ok, "sk-mine"} = AI.api_key(user: ctx.user)
    end

    test "with no user named, unattended work falls back to the system key", ctx do
      close_signups()
      :ok = Keys.put(make_admin(ctx.user), "sk-mine")
      assert {:ok, "sk-mine"} = AI.api_key([])
      assert AI.configured?()
    end

    test "embeddings decline when there is no key at all" do
      assert {:error, message} = AI.Embeddings.embed_all(["something"])
      assert message =~ "OpenRouter"
    end
  end

  describe "the features honour it" do
    test "the quick add model is skipped for a user without a key", ctx do
      board = board_fixture(%{"name" => "Inbox"}, owner: ctx.user)
      column = hd(board.columns)

      {:ok, user} =
        Slipdock.Accounts.update_quick_add(ctx.user, %{
          "quick_add_board_id" => board.id,
          "quick_add_column_id" => column.id,
          "quick_add_ai" => true
        })

      # No key: the typed syntax is read and the model is never called.
      assert {:ok, result} = Slipdock.QuickAdd.Capture.capture(user, "something #high")
      assert result.card.priority == "high"
      refute_receive {:ai_request, _}

      # With a key, the model gets a turn.
      :ok = Keys.put(user, "sk-mine")
      Slipdock.AIStub.reply_with(%{"title" => "Call the printers", "priority" => "critical"})
      assert {:ok, _} = Slipdock.QuickAdd.Capture.capture(user, "call the printers, urgent")
      assert_receive {:ai_request, _}
    end

    test "writing an automation rule needs the author's key", ctx do
      board = board_fixture(%{"name" => "Launch"}, owner: ctx.user)

      assert {:error, message} =
               Slipdock.Automations.create_rule_from_text(board, "email me when a card is late",
                 created_by: ctx.user
               )

      assert message =~ "Account → AI model"
    end

    test "rewriting a rule runs on the caller's model, not the system's", ctx do
      admin = make_admin(user_fixture("admin@example.com"))
      :ok = Keys.put(admin, "sk-admin")

      Slipdock.TestConfig.merge(:ai, system_user: fixture_email("admin@example.com"))

      board = board_fixture(%{"name" => "Launch"}, owner: ctx.user)

      {:ok, rule} =
        Slipdock.Automations.create_rule(%{
          "board_id" => board.id,
          "name" => "Old",
          "spec" => %{
            "trigger" => %{"type" => "card_created"},
            "actions" => [%{"type" => "email", "to" => fixture_email("keys@example.com")}]
          }
        })

      Slipdock.AIStub.reply_with(%{
        "name" => "New",
        "spec" => %{
          "trigger" => %{"type" => "card_created"},
          "actions" => [%{"type" => "email", "to" => fixture_email("keys@example.com")}]
        }
      })

      # The author has no model of their own: refused, not run on the admin's.
      assert {:error, message} =
               Slipdock.Automations.rewrite_rule(rule, "email ops", created_by: ctx.user)

      assert message =~ "Account → AI model"
      refute_received {:ai_request, _}

      :ok = Keys.put(ctx.user, "sk-mine")

      assert {:ok, %{name: "New"}} =
               Slipdock.Automations.rewrite_rule(rule, "email ops", created_by: ctx.user)
    end

    test "the researcher spends the asker's key", ctx do
      :ok = Keys.put(ctx.user, "sk-mine")
      Slipdock.AIStub.reply_with("Nothing much is happening.")

      assert {:ok, %{reply: _}} = AI.Researcher.ask(ctx.user, [], "What's happening?")
      assert_receive {:ai_request, _}
    end

    test "a stranger with no key gets the message, not an answer", ctx do
      stranger = user_fixture("stranger@example.com")
      _ = ctx

      assert {:error, message} = AI.Researcher.ask(stranger, [], "What's happening?")
      assert message =~ "OpenRouter"
    end
  end
end
