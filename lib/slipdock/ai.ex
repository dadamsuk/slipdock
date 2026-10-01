defmodule Slipdock.AI do
  @moduledoc """
  The one place the app talks to a language model: OpenRouter's
  OpenAI-compatible chat completions API, with a cheap model by default.

  **Whose key.** Each person brings their own OpenRouter key, stored by
  `Slipdock.AI.Keys` and set in Account settings. Every call resolves one:

    * `opts[:api_key]` when the caller has a key in hand;
    * otherwise `opts[:user]` — the person the work is for — and their stored
      key, declining with a message that points at Account settings when they
      have none;
    * otherwise the server-wide `:api_key` config, which is the shared
      fallback for work nobody is sitting in front of (the search indexer)
      and what the test stub uses.

  So the gate lives here rather than at every call site, and `:user` travels
  in the `opts` that `Slipdock.AI.Assistant`, `Narrator`, `Researcher`,
  `Slipdock.QuickAdd.Model` and `Slipdock.Automations.Parser` already thread.

  Configured under `config :slipdock, :ai`:

    * `:api_key` – from `OPENROUTER_API_KEY` (see runtime.exs); the shared
      fallback key, normally unset now that keys are per-user
    * `:key_file` – where per-user keys are stored (`SLIPDOCK_AI_KEY_FILE`)
    * `:model` – the OpenRouter model id (`SLIPDOCK_AI_MODEL`)
    * `:quick_model` – an even cheaper model for the one-line quick add
      (`SLIPDOCK_AI_QUICK_MODEL`); falls back to `:model`
    * `:base_url` – the API root
    * `:req_options` – extra `Req` options, used by tests to plug in a stub

  The features built on it live in `Slipdock.AI.Context` (what the model is
  told), `Slipdock.AI.Assistant` (chat and edit proposals), `Slipdock.AI.Actions`
  (applying proposals) and `Slipdock.AI.Narrator` (narrative prose).
  """

  require Logger

  alias Slipdock.AI.Keys

  @type message :: %{role: String.t(), content: String.t()}

  @no_key "AI features need an OpenRouter API key. Add one under Account → AI key."

  @doc """
  Whether unattended AI work can run at all: a shared or system key exists
  (see `Slipdock.AI.Keys.system_key/0`). For a person, ask `configured?/1`.
  """
  def configured?, do: present?(Keys.system_key())

  @doc """
  Whether this person can run AI features — they have a key of their own, or
  a shared key is configured for everyone. `nil` (nobody signed in) is false.
  """
  def configured?(nil), do: false

  def configured?(user), do: present?(Keys.get(user)) or present?(config()[:api_key])

  @doc """
  The key a call should use, given its options (`:api_key`, `:user`), or
  `{:error, message}` when the person named has no key and none is shared.
  """
  def api_key(opts) do
    cond do
      present?(opts[:api_key]) -> {:ok, opts[:api_key]}
      present?(key = Keys.get(opts[:user])) -> {:ok, key}
      present?(config()[:api_key]) -> {:ok, config()[:api_key]}
      opts[:user] -> {:error, @no_key}
      present?(key = Keys.system_key()) -> {:ok, key}
      true -> {:error, @no_key}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  def model, do: config()[:model]

  @doc """
  The model for the short, latency-sensitive calls (the header's quick add):
  `:quick_model` when one is configured, otherwise the ordinary model.
  """
  def quick_model, do: config()[:quick_model] || model()

  @doc """
  Sends `messages` (maps with `"role"`/`:role` and `"content"`/`:content`)
  and returns `{:ok, text}` with the assistant's reply, or `{:error, reason}`
  with a message fit to show the user.

  Options: `:json` (ask for a JSON object), `:max_tokens`, `:temperature`,
  `:model`.
  """
  def complete(messages, opts \\ []) do
    case do_complete(messages, opts) do
      # Cheap models occasionally return an empty choice; one retry usually fixes it.
      {:error, :empty} ->
        case do_complete(messages, opts) do
          {:error, :empty} -> {:error, "The model returned an empty answer; please try again."}
          other -> other
        end

      other ->
        other
    end
  end

  defp do_complete(messages, opts) do
    with {:ok, key} <- api_key(opts) do
      body =
        %{
          model: opts[:model] || model(),
          messages: Enum.map(messages, &normalize/1),
          max_tokens: opts[:max_tokens] || 1500,
          temperature: opts[:temperature] || 0.4
        }
        |> maybe_json(opts[:json])

      started = System.monotonic_time(:millisecond)

      case Req.post(request(key), url: "/chat/completions", json: body) do
        {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]} = resp}} ->
          Logger.info(
            "AI completion via #{resp["model"] || body.model} in #{System.monotonic_time(:millisecond) - started}ms" <>
              usage(resp["usage"])
          )

          case get_in(choice, ["message", "content"]) do
            text when is_binary(text) and text != "" ->
              {:ok, text}

            _ ->
              Logger.warning("AI completion returned no text: #{inspect(resp)}")
              {:error, :empty}
          end

        {:ok, %Req.Response{status: 200, body: body}} ->
          Logger.warning("AI completion returned no choices: #{inspect(body)}")
          {:error, "The model returned an empty answer."}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("AI completion failed with #{status}: #{inspect(body)}")
          {:error, api_error(status, body)}

        {:error, exception} ->
          Logger.warning("AI completion failed: #{Exception.message(exception)}")
          {:error, "Couldn't reach the model (#{Exception.message(exception)})."}
      end
    end
  end

  @doc """
  A completion the model may answer with tool calls instead of prose.

  `tools` is a list of OpenAI-style tool definitions. Returns
  `{:ok, message}` with the assistant's raw message map — `"content"` when
  it answered, `"tool_calls"` when it wants something looked up — so the
  caller can run the tools and call again with the results appended. See
  `Slipdock.AI.Researcher` for the loop that does this.
  """
  def complete_tools(messages, tools, opts \\ []) do
    with {:ok, key} <- api_key(opts) do
      body = %{
        model: opts[:model] || model(),
        messages: Enum.map(messages, &normalize/1),
        tools: tools,
        tool_choice: opts[:tool_choice] || "auto",
        max_tokens: opts[:max_tokens] || 1500,
        temperature: opts[:temperature] || 0.3
      }

      started = System.monotonic_time(:millisecond)

      case Req.post(request(key), url: "/chat/completions", json: body) do
        {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]} = resp}} ->
          Logger.info(
            "AI tool completion via #{resp["model"] || body.model} in " <>
              "#{System.monotonic_time(:millisecond) - started}ms" <> usage(resp["usage"])
          )

          {:ok, choice["message"] || %{}}

        {:ok, %Req.Response{status: 200, body: body}} ->
          Logger.warning("AI tool completion returned no choices: #{inspect(body)}")
          {:error, "The model returned an empty answer."}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("AI tool completion failed with #{status}: #{inspect(body)}")
          {:error, api_error(status, body)}

        {:error, exception} ->
          Logger.warning("AI tool completion failed: #{Exception.message(exception)}")
          {:error, "Couldn't reach the model (#{Exception.message(exception)})."}
      end
    end
  end

  @doc """
  Like `complete/2` in JSON mode, decoding the reply into a map. Code fences
  and stray prose around the object are tolerated, since not every cheap
  model honours `response_format` to the letter.
  """
  def complete_json(messages, opts \\ []) do
    opts = Keyword.put(opts, :json, true)

    with {:ok, text} <- complete(messages, opts),
         {:error, _} <- decode_json(text) do
      Logger.warning(
        "AI answer wasn't JSON, retrying once: #{inspect(String.slice(text, 0, 500))}"
      )

      with {:ok, text} <- complete(messages, opts) do
        decode_json(text)
      end
    end
  end

  @doc false
  def decode_json(text) do
    candidates = [text, strip_fences(text), between_braces(text)]

    Enum.find_value(candidates, {:error, "The model's answer wasn't valid JSON."}, fn s ->
      case s && Jason.decode(String.trim(s)) do
        {:ok, %{} = map} -> {:ok, map}
        _ -> nil
      end
    end)
  end

  defp strip_fences(text) do
    case Regex.run(~r/```(?:json)?\s*(.*?)```/s, text) do
      [_, inner] -> inner
      _ -> nil
    end
  end

  defp between_braces(text) do
    with first when first != nil <- :binary.match(text, "{"),
         {start, _} <- first,
         last when last != nil <- last_brace(text) do
      binary_part(text, start, last - start + 1)
    else
      _ -> nil
    end
  end

  defp last_brace(text) do
    case :binary.matches(text, "}") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  @doc """
  The configured `Req` request for the OpenRouter API: base URL, key and
  headers. Public so `Slipdock.AI.Embeddings` can reach a different endpoint
  on the same connection settings; it takes the key to use, since that is
  per-person now.
  """
  def request(key) do
    Req.new(
      [
        base_url: config()[:base_url],
        headers: [
          {"authorization", "Bearer #{key}"},
          # OpenRouter shows this on the key owner's dashboard, so it should
          # name the instance making the call, not whoever wrote the code.
          {"http-referer", Application.get_env(:slipdock, :source_url, "")},
          {"x-title", "Slipdock"}
        ],
        receive_timeout: 90_000,
        retry: false
      ] ++ (config()[:req_options] || [])
    )
  end

  defp maybe_json(body, true), do: Map.put(body, :response_format, %{type: "json_object"})
  defp maybe_json(body, _), do: body

  defp normalize(%{role: role, content: content}), do: %{role: to_string(role), content: content}
  # Tool-call turns carry "tool_calls" or "tool_call_id" and must go back to
  # the model exactly as they came, so they pass through whole.
  defp normalize(%{"role" => _} = m), do: m

  defp usage(%{"prompt_tokens" => p, "completion_tokens" => c}), do: " (#{p} in, #{c} out)"
  defp usage(_), do: ""

  @doc false
  def api_error(401, _), do: "The OpenRouter API key was rejected."
  def api_error(402, _), do: "OpenRouter reports no credit left."
  def api_error(429, _), do: "The model is rate-limited right now; try again in a moment."

  def api_error(status, %{"error" => %{"message" => msg}}) when is_binary(msg),
    do: "The model refused the request (#{status}): #{msg}"

  def api_error(status, _), do: "The model refused the request (HTTP #{status})."

  defp config, do: Application.get_env(:slipdock, :ai, [])
end
