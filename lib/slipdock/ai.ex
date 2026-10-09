defmodule Slipdock.AI do
  @moduledoc """
  The one place the app talks to a language model: an OpenAI-compatible chat
  completions API — OpenRouter by default, or whatever endpoint a person has
  pointed at instead (LM Studio, Ollama, llama.cpp, vLLM, a company gateway).

  **Whose model.** Each person brings their own: a key, an endpoint, or
  both, stored by `Slipdock.AI.Keys` and set in Account settings. Every call
  resolves the three of them together — endpoint, key, model — into a
  *provider* (see `provider/1`), because they only make sense as a set: a key
  for one endpoint is no use at another, and a model id from OpenRouter means
  nothing to a box in the corner of the room.

  Resolution order, for each of the three:

    * `opts[:base_url]` / `opts[:api_key]` / `opts[:model]` when the caller
      has them in hand;
    * otherwise `opts[:user]` — the person the work is for — and what they
      have stored, declining with a message that points at Account settings
      when they have nothing;
    * otherwise the system settings (`Slipdock.AI.Keys.system_settings/0`):
      the shared `:api_key` config, or the named or sole admin's own, which is what
      work nobody is sitting in front of runs on (the search indexer) and
      what the test stub uses.

  A key is **not** required when the endpoint is the person's own: a local
  model server usually wants no authorisation at all, so a `base_url` on its
  own is enough. The shared OpenRouter key is never sent to somebody else's
  endpoint.

  So the gate lives here rather than at every call site, and `:user` travels
  in the `opts` that `Slipdock.AI.Assistant`, `Narrator`, `Researcher`,
  `Slipdock.QuickAdd.Model` and `Slipdock.Automations.Parser` already thread.

  Configured under `config :slipdock, :ai`:

    * `:api_key` – from `OPENROUTER_API_KEY` (see runtime.exs); the shared
      fallback key, normally unset now that keys are per-user
    * `:key_file` – where per-user settings are stored (`SLIPDOCK_AI_KEY_FILE`)
    * `:model` – the default model id (`SLIPDOCK_AI_MODEL`)
    * `:quick_model` – an even cheaper model for the one-line quick add
      (`SLIPDOCK_AI_QUICK_MODEL`); falls back to `:model`
    * `:base_url` – the default API root (`SLIPDOCK_AI_BASE_URL`), used by
      anyone who has not pointed at one of their own
    * `:req_options` – extra `Req` options, used by tests to plug in a stub

  The features built on it live in `Slipdock.AI.Context` (what the model is
  told), `Slipdock.AI.Assistant` (chat and edit proposals), `Slipdock.AI.Actions`
  (applying proposals) and `Slipdock.AI.Narrator` (narrative prose).
  """

  require Logger

  alias Slipdock.AI.Keys

  @type message :: %{role: String.t(), content: String.t()}

  @no_key "AI features need a model to talk to: an OpenRouter API key, or a " <>
            "local endpoint of your own. Set one under Account → AI model."

  # OpenRouter is a paid, public API: reaching it without a key is pointless,
  # so that is the one endpoint where a key is the price of entry. Anything
  # else — a box on the LAN, a gateway at work — is asked and allowed to say
  # no itself, because most of them want no authorisation at all.
  @paid_endpoint "https://openrouter.ai"

  @doc """
  Whether unattended AI work can run at all: the system settings name a key
  or an endpoint (see `Slipdock.AI.Keys.system_settings/0`), or the server's
  default endpoint needs no key. For a person, ask `configured?/1`.
  """
  def configured? do
    settings = Keys.system_settings()
    Keys.usable?(settings) or keyless?(settings.base_url || default_base_url())
  end

  @doc """
  Whether this person can run AI features — they have a key or an endpoint of
  their own, or a shared key is configured for everyone. `nil` (nobody signed
  in) is false.
  """
  def configured?(nil), do: false

  def configured?(user) do
    Keys.own?(user) or present?(shared_key_for(user)) or
      keyless?(Keys.endpoint(user) || default_base_url())
  end

  # Whether this endpoint can be asked without a key at all.
  defp keyless?(base_url), do: not String.starts_with?(to_string(base_url), @paid_endpoint)

  @doc """
  Everything one call needs, resolved together: `%{base_url:, api_key:,
  model:, embed_model:, custom?:}`, or `{:error, message}` when the person
  named has brought nothing and nothing is shared.

  Options: `:user` (whose work this is), and `:base_url` / `:api_key` /
  `:model` to override any of the three. `:quick` asks for the cheap model
  (`quick_model/0`) when the person has not picked one of their own, which is
  what the header's quick add uses.

  `custom?` says the endpoint is not the server's default — which is why no
  key is demanded, and why a model id from the config is not imposed on it.

  An endpoint a person typed (anyone but an admin) goes through
  `Slipdock.Egress` here: refused if it is private or loopback, otherwise
  pinned to the address that was checked. The server's own endpoints — the
  config and the system settings, both the admin's — are not.
  """
  @spec provider(keyword()) :: {:ok, map()} | {:error, String.t()}
  def provider(opts) do
    settings =
      case opts[:user] do
        nil -> Keys.system_settings()
        user -> Keys.settings(user)
      end

    base_url = opts[:base_url] || settings.base_url || config()[:base_url]
    custom? = present?(opts[:base_url]) or present?(settings.base_url)
    guarded? = custom? and opts[:user] != nil and not Slipdock.Accounts.admin?(opts[:user])

    key =
      cond do
        present?(opts[:api_key]) -> opts[:api_key]
        present?(settings.api_key) -> settings.api_key
        # Never spend the server's shared key against somebody else's endpoint.
        custom? -> nil
        true -> shared_key_for(opts[:user])
      end

    with true <- present?(key) or keyless?(base_url) or {:error, @no_key},
         {:ok, target, req_options} <- egress(base_url, guarded?) do
      {:ok,
       %{
         base_url: base_url,
         target: target,
         req_options: req_options,
         api_key: key,
         model: opts[:model] || settings.model || default_model(opts[:quick], custom?),
         embed_model: settings.embed_model,
         custom?: custom?,
         guarded?: guarded?
       }}
    end
  end

  defp egress(base_url, false), do: {:ok, base_url, []}

  # A query or fragment would swallow the "/models" or "/chat/completions"
  # appended to it, so an API root has neither.
  defp egress(base_url, true) do
    with %URI{query: nil, fragment: nil} <- URI.parse(base_url),
         {:ok, target, options} <- Slipdock.Egress.prepare(base_url) do
      {:ok, target, options}
    else
      %URI{} ->
        {:error, "That endpoint can't have a query string or a fragment."}

      {:error, reason} ->
        {:error,
         "That endpoint #{reason}, so it can't be used. A server's admin can allow " <>
           "addresses on their own network with SLIPDOCK_EGRESS_ALLOW."}
    end
  end

  # An endpoint of someone's own gets no model id out of the config: the
  # config names an OpenRouter model, and sending "google/gemini-2.5-flash" to
  # a box running two local models is a 404 with a baffling message. Nil means
  # "whatever you have loaded", which is what LM Studio and friends do.
  defp default_model(quick?, custom?) do
    cond do
      custom? -> nil
      quick? -> quick_model()
      true -> model()
    end
  end

  @doc """
  The key a call should use, given its options (`:api_key`, `:user`), or
  `{:error, message}` when the person named has brought nothing and nothing
  is shared. `{:ok, nil}` for an endpoint that needs no key.
  """
  def api_key(opts) do
    with {:ok, provider} <- provider(opts), do: {:ok, provider.api_key}
  end

  @doc """
  Which models an endpoint has, for picking one: `{:ok, [%{id:, name:,
  embedding?:}]}` sorted by id, or `{:error, message}`.

  `GET /models` is part of the OpenAI-compatible surface, so OpenRouter,
  LM Studio, Ollama, vLLM and llama.cpp all answer it. Options are
  `provider/1`'s — `:user`, or a `:base_url` and `:api_key` not yet saved,
  which is how the Account page can check an endpoint before it is stored.
  """
  @spec models(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def models(opts \\ []) do
    with {:ok, provider} <- provider(opts) do
      case Req.get(request(provider), url: "/models") do
        {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
          case Enum.flat_map(data, &model_entry/1) do
            [] -> {:error, "That endpoint listed no models."}
            models -> {:ok, Enum.sort_by(models, & &1.id)}
          end

        {:ok, %Req.Response{status: 200, body: body}} ->
          Logger.warning("Model list had no data: #{inspect(body)}")
          {:error, "That endpoint answered, but not with a list of models."}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("Model list failed with #{status}: #{inspect(body)}")
          {:error, refusal(status, body, provider)}

        {:error, exception} ->
          Logger.warning("Model list failed: #{Exception.message(exception)}")
          {:error, "Couldn't reach #{provider.base_url}."}
      end
    end
  end

  defp model_entry(%{"id" => id} = model) when is_binary(id) and id != "" do
    [
      %{
        id: id,
        name: (is_binary(model["name"]) && model["name"]) || id,
        # Embedding models cannot hold a conversation, so the picker keeps the
        # two lists apart. The id is all every server agrees to tell us.
        embedding?: String.contains?(id, "embed")
      }
    ]
  end

  defp model_entry(_), do: []

  @doc """
  The server-wide key, if this person may spend it.

  `OPENROUTER_API_KEY` is one key everybody on the server falls back to, which
  means the person running the server pays for everyone's AI. On a private
  instance that is the point. On one being run for other people it is an open
  tab, and the bill arrives a month later.

  So there is a lever: `config :slipdock, :ai, shared_key_for_admins_only: true`
  (`SLIPDOCK_SHARED_AI_KEY_ADMINS_ONLY=true`) keeps the shared key for admins,
  and everybody else brings their own or gets no AI.

  **It is off by default**, deliberately. The card limit already bounds how much
  any one free account can index, and AI working out of the box is a good reason
  to subscribe. This exists so that if the bill ever bites, the answer is one
  setting rather than an emergency — and so the decision is written down rather
  than rediscovered.
  """
  @spec shared_key_for(Slipdock.Accounts.User.t() | nil) :: String.t() | nil
  def shared_key_for(user) do
    cond do
      not present?(config()[:api_key]) -> nil
      not admins_only?() -> config()[:api_key]
      Slipdock.Accounts.admin?(user) -> config()[:api_key]
      true -> nil
    end
  end

  defp admins_only?, do: config()[:shared_key_for_admins_only] == true

  defp present?(value), do: is_binary(value) and value != ""

  def model, do: config()[:model]

  @doc "The endpoint anyone who has not pointed at one of their own uses."
  def default_base_url, do: config()[:base_url]

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
  `:model`, and `:on_usage` — a function called with what each successful
  call cost (`:model`, `:tokens_in`, `:tokens_out`, `:cost`, `:custom?`).
  """
  def complete(messages, opts \\ []) do
    case do_complete(messages, opts) do
      # Not every endpoint takes `response_format: json_object` — LM Studio
      # wants a `json_schema` or nothing at all. The prompts ask for JSON in
      # words anyway, and `decode_json/1` tolerates prose and code fences
      # around the object, so asking again without the flag is the right
      # answer rather than refusing to work with the endpoint.
      {:error, :no_json_mode} ->
        Logger.info("Endpoint rejected JSON mode; asking again without it")
        retry(messages, Keyword.put(opts, :json, false))

      # Cheap models occasionally return an empty choice; one retry usually fixes it.
      {:error, :empty} ->
        retry(messages, opts)

      other ->
        other
    end
  end

  defp retry(messages, opts) do
    case do_complete(messages, opts) do
      {:error, :empty} -> {:error, "The model returned an empty answer; please try again."}
      {:error, :no_json_mode} -> {:error, "That endpoint would not answer in JSON."}
      other -> other
    end
  end

  defp do_complete(messages, opts) do
    with {:ok, provider} <- provider(opts) do
      body =
        %{
          messages: Enum.map(messages, &normalize/1),
          max_tokens: opts[:max_tokens] || 1500,
          temperature: opts[:temperature] || 0.4
        }
        |> maybe_model(provider.model)
        |> maybe_json(opts[:json])

      started = System.monotonic_time(:millisecond)

      case Req.post(request(provider), url: "/chat/completions", json: body) do
        {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]} = resp}} ->
          Logger.info(
            "AI completion via #{resp["model"] || body[:model] || provider.base_url} in " <>
              "#{System.monotonic_time(:millisecond) - started}ms" <>
              usage(resp["usage"])
          )

          report_usage(opts[:on_usage], resp, body, provider)

          case get_in(choice, ["message", "content"]) do
            text when is_binary(text) and text != "" ->
              {:ok, text}

            _ ->
              Logger.warning("AI completion returned no text: #{inspect(resp)}")
              empty_answer(choice)
          end

        {:ok, %Req.Response{status: 200, body: body}} ->
          Logger.warning("AI completion returned no choices: #{inspect(body)}")
          {:error, "The model returned an empty answer."}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("AI completion failed with #{status}: #{inspect(body)}")

          if opts[:json] && refused_json_mode?(status, body) do
            {:error, :no_json_mode}
          else
            {:error, refusal(status, body, provider)}
          end

        {:error, exception} ->
          Logger.warning("AI completion failed: #{Exception.message(exception)}")
          {:error, "Couldn't reach the model."}
      end
    end
  end

  # Somebody keeping accounts (meeting capture's usage ledger) is told what
  # each call cost, as the endpoint reported it: tokens, and a cost where the
  # provider gives one (OpenRouter does, as `usage.cost`).
  defp report_usage(nil, _resp, _body, _provider), do: :ok

  defp report_usage(fun, resp, body, provider) when is_function(fun, 1) do
    usage = resp["usage"] || %{}

    fun.(%{
      model: resp["model"] || body[:model] || provider.model,
      tokens_in: usage["prompt_tokens"],
      tokens_out: usage["completion_tokens"],
      cost: usage["cost"],
      custom?: provider.custom?
    })
  end

  # A thinking model that spent its whole budget thinking: there is no answer
  # to wait for, and asking again changes nothing, so say what happened.
  defp empty_answer(%{"finish_reason" => "length"}) do
    {:error,
     "The model used up its token budget before saying anything — it is " <>
       "probably a reasoning model, which needs a larger one than this."}
  end

  defp empty_answer(_choice), do: {:error, :empty}

  # Told apart from a real refusal by what the endpoint complains about: the
  # field we sent rather than the request we made.
  defp refused_json_mode?(status, body) when status in 400..422 do
    body
    |> inspect()
    |> String.contains?("response_format")
  end

  defp refused_json_mode?(_status, _body), do: false

  @doc """
  A completion the model may answer with tool calls instead of prose.

  `tools` is a list of OpenAI-style tool definitions. Returns
  `{:ok, message}` with the assistant's raw message map — `"content"` when
  it answered, `"tool_calls"` when it wants something looked up — so the
  caller can run the tools and call again with the results appended. See
  `Slipdock.AI.Researcher` for the loop that does this.
  """
  def complete_tools(messages, tools, opts \\ []) do
    with {:ok, provider} <- provider(opts) do
      body =
        %{
          messages: Enum.map(messages, &normalize/1),
          tools: tools,
          tool_choice: opts[:tool_choice] || "auto",
          max_tokens: opts[:max_tokens] || 1500,
          temperature: opts[:temperature] || 0.3
        }
        |> maybe_model(provider.model)

      started = System.monotonic_time(:millisecond)

      case Req.post(request(provider), url: "/chat/completions", json: body) do
        {:ok, %Req.Response{status: 200, body: %{"choices" => [choice | _]} = resp}} ->
          Logger.info(
            "AI tool completion via #{resp["model"] || body[:model] || provider.base_url} in " <>
              "#{System.monotonic_time(:millisecond) - started}ms" <> usage(resp["usage"])
          )

          {:ok, choice["message"] || %{}}

        {:ok, %Req.Response{status: 200, body: body}} ->
          Logger.warning("AI tool completion returned no choices: #{inspect(body)}")
          {:error, "The model returned an empty answer."}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("AI tool completion failed with #{status}: #{inspect(body)}")
          {:error, refusal(status, body, provider)}

        {:error, exception} ->
          Logger.warning("AI tool completion failed: #{Exception.message(exception)}")
          {:error, "Couldn't reach the model."}
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
  The configured `Req` request for a provider (see `provider/1`): its base
  URL, key and headers. Public so `Slipdock.AI.Embeddings` can reach a
  different endpoint on the same connection settings.
  """
  def request(%{base_url: base_url} = provider) do
    Req.new(
      [
        base_url: provider[:target] || base_url,
        headers: headers(provider[:api_key]),
        receive_timeout: 90_000,
        retry: false,
        redirect: false
      ] ++ (provider[:req_options] || []) ++ (config()[:req_options] || [])
    )
  end

  # A local model server usually has no notion of a key, and some reject a
  # bearer token they did not ask for, so an absent key means no header.
  defp headers(key) do
    auth = if present?(key), do: [{"authorization", "Bearer #{key}"}], else: []

    auth ++
      [
        # OpenRouter shows this on the key owner's dashboard, so it should
        # name the instance making the call, not whoever wrote the code.
        {"http-referer", Slipdock.Config.get(:source_url, "")},
        {"x-title", "Slipdock"}
      ]
  end

  # Nil means "whatever that endpoint has loaded": a single-model local server
  # answers happily with no model named, and guessing one only gets a 404.
  defp maybe_model(body, nil), do: body
  defp maybe_model(body, model), do: Map.put(body, :model, model)

  defp maybe_json(body, true), do: Map.put(body, :response_format, %{type: "json_object"})
  defp maybe_json(body, _), do: body

  defp normalize(%{role: role, content: content}), do: %{role: to_string(role), content: content}
  # Tool-call turns carry "tool_calls" or "tool_call_id" and must go back to
  # the model exactly as they came, so they pass through whole.
  defp normalize(%{"role" => _} = m), do: m

  defp usage(%{"prompt_tokens" => p, "completion_tokens" => c}), do: " (#{p} in, #{c} out)"
  defp usage(_), do: ""

  # What an endpoint someone typed says in its error body is not repeated
  # back: that would read JSON off whatever the URL pointed at.
  defp refusal(status, _body, %{guarded?: true}), do: api_error(status, nil)
  defp refusal(status, body, _provider), do: api_error(status, body)

  @doc false
  def api_error(401, _), do: "The OpenRouter API key was rejected."
  def api_error(402, _), do: "OpenRouter reports no credit left."
  def api_error(429, _), do: "The model is rate-limited right now; try again in a moment."

  def api_error(status, %{"error" => %{"message" => msg}}) when is_binary(msg),
    do: "The model refused the request (#{status}): #{msg}"

  def api_error(status, _), do: "The model refused the request (HTTP #{status})."

  defp config, do: Slipdock.Config.get(:ai, [])
end
