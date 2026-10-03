defmodule Slipdock.AIProviderTest do
  @moduledoc """
  Resolving endpoint, key and model together — the part that decides *where*
  a request goes and *what* it asks for, which is what pointing the app at a
  local model server comes down to.
  """
  use Slipdock.DataCase, async: false

  import Slipdock.Fixtures

  alias Slipdock.AI
  alias Slipdock.AI.Keys

  setup do
    previous = Application.get_env(:slipdock, :ai)
    file = Path.join(System.tmp_dir!(), "ai_provider_#{System.unique_integer([:positive])}.json")

    Application.put_env(
      :slipdock,
      :ai,
      previous |> Keyword.put(:key_file, file) |> Keyword.put(:api_key, nil)
    )

    on_exit(fn ->
      Application.put_env(:slipdock, :ai, previous)
      File.rm(file)
    end)

    %{user: user_fixture("provider@example.com")}
  end

  defp ai(key, value) do
    Application.put_env(
      :slipdock,
      :ai,
      Keyword.put(Application.get_env(:slipdock, :ai), key, value)
    )
  end

  # Where a call actually went, and what it asked for: the stub reports the
  # host, the path, the model and whether an authorisation header came along.
  defp record_requests do
    test = self()

    Req.Test.stub(Slipdock.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:called,
         %{
           host: conn.host,
           port: conn.port,
           path: conn.request_path,
           auth: Plug.Conn.get_req_header(conn, "authorization"),
           body: Jason.decode!(body)
         }}
      )

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
      })
    end)
  end

  describe "an endpoint of your own" do
    test "is where the request goes, with no key and no imposed model", ctx do
      record_requests()
      :ok = Keys.put_settings(ctx.user, %{base_url: "http://box.local:1234/v1"})

      assert {:ok, "ok"} = AI.complete([%{role: "user", content: "hi"}], user: ctx.user)

      assert_receive {:called, call}
      assert call.host == "box.local"
      assert call.port == 1234
      assert call.path == "/v1/chat/completions"
      # No key of their own and none wanted: nothing is sent.
      assert call.auth == []
      # And no model id from the config, which would name an OpenRouter model
      # this endpoint has never heard of.
      refute Map.has_key?(call.body, "model")
    end

    test "never spends the server's shared key", ctx do
      record_requests()
      ai(:api_key, "sk-shared")
      :ok = Keys.put_settings(ctx.user, %{base_url: "http://box.local:1234/v1"})

      assert {:ok, _} = AI.complete([%{role: "user", content: "hi"}], user: ctx.user)
      assert_receive {:called, call}
      assert call.auth == []
    end

    test "carries their own key when they stored one", ctx do
      record_requests()

      :ok =
        Keys.put_settings(ctx.user, %{base_url: "http://box.local:1234/v1", api_key: "sk-local"})

      assert {:ok, _} = AI.complete([%{role: "user", content: "hi"}], user: ctx.user)
      assert_receive {:called, call}
      assert call.auth == ["Bearer sk-local"]
    end

    test "asks for the model they picked", ctx do
      record_requests()

      :ok =
        Keys.put_settings(ctx.user, %{
          base_url: "http://box.local:1234/v1",
          model: "qwen/qwen3.5-9b"
        })

      assert {:ok, _} = AI.complete([%{role: "user", content: "hi"}], user: ctx.user)
      assert_receive {:called, call}
      assert call.body["model"] == "qwen/qwen3.5-9b"
    end

    test "turns the AI features on all by itself", ctx do
      refute AI.configured?(ctx.user)
      :ok = Keys.put_settings(ctx.user, %{base_url: "http://box.local:1234/v1"})
      assert AI.configured?(ctx.user)
      assert {:ok, %{api_key: nil}} = AI.provider(user: ctx.user)
    end

    test "pointed at OpenRouter, a key is still the price of entry", ctx do
      :ok = Keys.put_settings(ctx.user, %{base_url: "https://openrouter.ai/api/v1"})
      assert {:error, message} = AI.provider(user: ctx.user)
      assert message =~ "OpenRouter"
    end
  end

  describe "the default endpoint" do
    test "is used, with the configured model, by anyone who has not changed it", ctx do
      record_requests()
      :ok = Keys.put(ctx.user, "sk-mine")

      assert {:ok, _} = AI.complete([%{role: "user", content: "hi"}], user: ctx.user)
      assert_receive {:called, call}
      assert call.host == "openrouter.ai"
      assert call.body["model"] == "test/model"
      assert call.auth == ["Bearer sk-mine"]
    end

    test "needs no key when the server itself points at a local one", ctx do
      ai(:base_url, "http://llm.lan:1234/v1")

      # Nobody has a key, nothing is shared — and AI still works, because the
      # endpoint this server talks to does not want one.
      assert AI.configured?()
      assert AI.configured?(ctx.user)
      assert {:ok, provider} = AI.provider(user: ctx.user)
      assert provider.base_url == "http://llm.lan:1234/v1"
      assert provider.api_key == nil
    end
  end

  describe "the endpoint as typed" do
    test "loses a trailing slash and a pasted /chat/completions", ctx do
      :ok = Keys.put_settings(ctx.user, %{base_url: "http://box.local:1234/v1/"})
      assert Keys.endpoint(ctx.user) == "http://box.local:1234/v1"

      :ok = Keys.put_settings(ctx.user, %{base_url: "http://box.local:1234/v1/chat/completions"})
      assert Keys.endpoint(ctx.user) == "http://box.local:1234/v1"
    end

    test "is refused when it is not a URL at all", ctx do
      assert {:error, message} = Keys.put_settings(ctx.user, %{base_url: "box.local:1234"})
      assert message =~ "URL"
      assert Keys.endpoint(ctx.user) == nil
    end

    test "cleared, goes back to the server's own without taking the key", ctx do
      :ok =
        Keys.put_settings(ctx.user, %{base_url: "http://box.local:1234/v1", api_key: "sk-mine"})

      :ok = Keys.put_settings(ctx.user, %{base_url: ""})

      assert Keys.endpoint(ctx.user) == nil
      assert Keys.get(ctx.user) == "sk-mine"
      assert {:ok, provider} = AI.provider(user: ctx.user)
      assert provider.base_url == AI.default_base_url()
    end

    test "is the whole of someone's settings, and removing the key removes the lot", ctx do
      :ok = Keys.put_settings(ctx.user, %{model: "local/small"})
      assert Keys.model(ctx.user) == "local/small"

      :ok = Keys.put_settings(ctx.user, %{model: ""})
      assert Keys.all() == %{}
    end
  end

  describe "models/1" do
    test "lists what the endpoint says it has, chat and embedding apart", ctx do
      Slipdock.AIStub.stub_models(["local/big", "local/small", "local/text-embedding-v1"])
      :ok = Keys.put_settings(ctx.user, %{base_url: "http://box.local:1234/v1"})

      assert {:ok, models} = AI.models(user: ctx.user)
      assert Enum.map(models, & &1.id) == ["local/big", "local/small", "local/text-embedding-v1"]
      assert Enum.map(models, & &1.embedding?) == [false, false, true]
    end

    test "can try an endpoint that has not been stored yet", ctx do
      Slipdock.AIStub.stub_models(["local/big"])
      refute AI.configured?(ctx.user)

      assert {:ok, [%{id: "local/big"}]} =
               AI.models(user: ctx.user, base_url: "http://untried.local:1234/v1")
    end

    test "says what went wrong rather than an empty list", ctx do
      Slipdock.AIStub.fail_with(404, "no such route")
      :ok = Keys.put_settings(ctx.user, %{base_url: "http://box.local:1234/v1"})

      assert {:error, message} = AI.models(user: ctx.user)
      assert message =~ "no such route"
    end
  end
end
