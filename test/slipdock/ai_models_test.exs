defmodule Slipdock.AIModelsTest do
  @moduledoc """
  Which model a call asks for, and what happens when it is rate-limited
  (#1670): fallbacks in OpenRouter's `models` array, one retry after a 429,
  and the admin's models between a person's own and the environment.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{AI, Settings, TestConfig}
  alias Slipdock.AI.Keys

  @hi [%{role: "user", content: "hi"}]

  setup do
    file = Path.join(System.tmp_dir!(), "ai_models_#{System.unique_integer([:positive])}.json")
    TestConfig.merge(:ai, key_file: file)
    on_exit(fn -> File.rm(file) end)
    %{user: user_fixture("models@example.com")}
  end

  defp fallbacks(ids), do: TestConfig.merge(:ai, fallback_models: ids)

  # Answers each call with the next status in `statuses` (the last repeating),
  # sending the test each request's body and the status it got.
  defp answer_with(statuses, headers \\ []) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> statuses end)

    Req.Test.stub(Slipdock.AI, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      status =
        Agent.get_and_update(agent, fn
          [only] -> {only, [only]}
          [head | tail] -> {head, tail}
        end)

      send(test, {:ai_request, status, Jason.decode!(body)})

      case status do
        200 ->
          Req.Test.json(conn, %{
            "model" => "test/answered",
            "choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]
          })

        status ->
          Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(%{"error" => %{"message" => "Rate limit exceeded", "code" => status}})
      end
    end)
  end

  describe "the request body" do
    test "OpenRouter gets the models array, primary first, and no single model" do
      fallbacks(["test/a", "test/model", "test/b"])
      Slipdock.AIStub.reply_with("ok")

      assert {:ok, "ok"} = AI.complete(@hi)
      assert_receive {:ai_request, body}
      # The primary isn't listed twice.
      assert body["models"] == ["test/model", "test/a", "test/b"]
      refute Map.has_key?(body, "model")
    end

    test "tool completions go out with the fallbacks too" do
      fallbacks(["test/a"])
      Slipdock.AIStub.reply_with("ok")

      assert {:ok, _} = AI.complete_tools(@hi, [])
      assert_receive {:ai_request, %{"models" => ["test/model", "test/a"]}}
    end

    test "with no fallbacks it is a single model, as before" do
      Slipdock.AIStub.reply_with("ok")
      assert {:ok, "ok"} = AI.complete(@hi)
      assert_receive {:ai_request, body}
      assert body["model"] == "test/model"
      refute Map.has_key?(body, "models")
    end

    test "a server endpoint that isn't OpenRouter gets a single model" do
      fallbacks(["test/a"])
      TestConfig.merge(:ai, base_url: "http://models.example.com:1234/v1")
      Slipdock.AIStub.reply_with("ok")

      assert {:ok, "ok"} = AI.complete(@hi)
      assert_receive {:ai_request, body}
      assert body["model"] == "test/model"
      refute Map.has_key?(body, "models")
    end

    test "a person's own model is respected: no fallbacks to one they didn't pick", %{
      user: user
    } do
      fallbacks(["test/a"])
      :ok = Keys.put_settings(user, %{model: "mine/model"})
      Slipdock.AIStub.reply_with("ok")

      assert {:ok, "ok"} = AI.complete(@hi, user: user)
      assert_receive {:ai_request, body}
      assert body["model"] == "mine/model"
      refute Map.has_key?(body, "models")
      assert AI.fallback_models(user) == []
    end

    test "a person on the server's model gets the fallbacks", %{user: user} do
      fallbacks(["test/a"])
      Slipdock.AIStub.reply_with("ok")

      assert {:ok, "ok"} = AI.complete(@hi, user: user)
      assert_receive {:ai_request, %{"models" => ["test/model", "test/a"]}}
      assert AI.fallback_models(user) == ["test/a"]
    end

    test "a caller naming a model outright gets that one alone" do
      fallbacks(["test/a"])
      Slipdock.AIStub.reply_with("ok")

      assert {:ok, "ok"} = AI.complete(@hi, model: "caller/model")
      assert_receive {:ai_request, body}
      assert body["model"] == "caller/model"
      refute Map.has_key?(body, "models")
    end

    test "the model that answered is what the caller is told" do
      fallbacks(["test/a"])
      answer_with([200])

      assert {:ok, "ok"} =
               AI.complete(@hi, on_usage: fn usage -> send(self(), {:used, usage.model}) end)

      assert_receive {:used, "test/answered"}
    end
  end

  describe "a 429" do
    test "is asked once more, and the second answer is the answer" do
      answer_with([429, 200])

      assert {:ok, "ok"} = AI.complete(@hi)
      assert_receive {:ai_request, 429, _}
      assert_receive {:ai_request, 200, _}
    end

    test "twice is the rate-limited message, after exactly two requests" do
      answer_with([429])

      assert {:error, "The model is rate-limited right now; try again in a moment."} =
               AI.complete(@hi)

      assert_receive {:ai_request, 429, _}
      assert_receive {:ai_request, 429, _}
      refute_receive {:ai_request, _, _}
    end

    test "tool completions are retried the same way" do
      answer_with([429, 200])
      assert {:ok, %{"content" => "ok"}} = AI.complete_tools(@hi, [])
      assert_receive {:ai_request, 429, _}
      assert_receive {:ai_request, 200, _}
    end

    test "a long Retry-After isn't waited for" do
      answer_with([429, 200], [{"retry-after", "60"}])

      assert {:error, "The model is rate-limited" <> _} = AI.complete(@hi)
      assert_receive {:ai_request, 429, _}
      refute_receive {:ai_request, _, _}
    end

    test "a short Retry-After is" do
      answer_with([429, 200], [{"retry-after", "0"}])
      assert {:ok, "ok"} = AI.complete(@hi)
    end

    test "how long the wait is" do
      resp = fn headers -> %Req.Response{status: 429, headers: headers} end
      TestConfig.merge(:ai, retry_backoff_ms: 750, retry_after_max_ms: 5_000)

      assert AI.backoff(resp.(%{})) == 750
      assert AI.backoff(resp.(%{"retry-after" => ["2"]})) == 2_000
      assert AI.backoff(resp.(%{"retry-after" => ["5"]})) == 5_000
      assert AI.backoff(resp.(%{"retry-after" => ["6"]})) == nil
      # An HTTP date isn't parsed: the ordinary wait.
      assert AI.backoff(resp.(%{"retry-after" => ["Wed, 21 Oct 2026 07:28:00 GMT"]})) == 750
    end
  end

  describe "precedence: a person's own > the admin's > env > config" do
    test "config, then env, then the admin, and clearing the admin's falls back" do
      assert AI.model_setting(:model) == %{value: "test/model", source: :config}

      TestConfig.merge(:ai, model: "env/model", from_env: [:model])
      assert AI.model_setting(:model) == %{value: "env/model", source: :env}

      {:ok, _} = Settings.update(%{"ai_model" => "admin/model"})
      assert AI.model_setting(:model) == %{value: "admin/model", source: :admin}
      assert AI.model() == "admin/model"

      {:ok, _} = Settings.update(%{"ai_model" => ""})
      assert Settings.get().ai_model == nil
      assert AI.model_setting(:model) == %{value: "env/model", source: :env}
    end

    test "a person's own model beats the admin's", %{user: user} do
      {:ok, _} = Settings.update(%{"ai_model" => "admin/model"})
      Slipdock.AIStub.reply_with("ok")

      assert {:ok, _} = AI.complete(@hi, user: user)
      assert_receive {:ai_request, %{"model" => "admin/model"}}

      :ok = Keys.put_settings(user, %{model: "mine/model"})
      assert {:ok, _} = AI.complete(@hi, user: user)
      assert_receive {:ai_request, %{"model" => "mine/model"}}
    end

    test "the quick and organise models follow the admin's choices" do
      TestConfig.merge(:ai, quick_model: nil, organise_model: nil)
      assert AI.model_setting(:quick_model) == %{value: "test/model", source: :inherited}
      assert AI.model_setting(:organise_model) == %{value: "test/model", source: :inherited}

      {:ok, _} = Settings.update(%{"ai_quick_model" => "admin/quick"})
      assert AI.quick_model() == "admin/quick"
      assert AI.model_setting(:organise_model) == %{value: "admin/quick", source: :inherited}

      {:ok, _} = Settings.update(%{"ai_organise_model" => "admin/organise"})
      assert AI.model_setting(:organise_model) == %{value: "admin/organise", source: :admin}

      Slipdock.AIStub.reply_with("ok")
      assert {:ok, _} = AI.complete(@hi, quick: true)
      assert_receive {:ai_request, %{"model" => "admin/quick"}}
    end

    test "fallbacks: the admin's list wins over the environment's, and clears back to it" do
      TestConfig.merge(:ai, fallback_models: ["env/a"], from_env: [:fallback_models])
      assert AI.model_setting(:fallback_models) == %{value: ["env/a"], source: :env}

      {:ok, _} = Settings.update(%{"ai_fallback_models" => " admin/a,\nadmin/b  admin/a "})
      assert Settings.get().ai_fallback_models == "admin/a,admin/b"
      assert AI.fallback_models() == ["admin/a", "admin/b"]
      assert AI.model_setting(:fallback_models).source == :admin

      {:ok, _} = Settings.update(%{"ai_fallback_models" => ""})
      assert AI.fallback_models() == ["env/a"]
    end

    test "a model id with a space in it is refused" do
      assert {:error, changeset} = Settings.update(%{"ai_quick_model" => "two models"})
      assert %{ai_quick_model: [_]} = errors_on(changeset)
    end
  end
end
