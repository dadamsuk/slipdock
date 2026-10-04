defmodule SlipdockCLI.Auth do
  @moduledoc false

  # Who you are and where you are talking to: signing in (by token or by the
  # device flow), the saved server address, and the AI provider settings that
  # hang off the account.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP
  alias SlipdockCLI.Render

  @commands ~w(auth whoami ai-key ai ai-endpoint ai-models ai-model url logout)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("auth", [token], o) do
    System.put_env("SLIPDOCK_TOKEN", token)

    HTTP.get("/me")
    |> out(o, fn r ->
      path = HTTP.save_token(token)
      remember_server()
      IO.puts("signed in as #{r["user"]["email"]}; token saved to #{path}")
    end)
  end

  # No token to paste: ask the server for a code, show it, and wait for a
  # person to approve it in a browser (RFC 8628). Nothing here needs access to
  # the machine the server runs on, which is the whole point.
  def run("auth", [], o) do
    label = o[:label] || default_label()

    case HTTP.post("/auth/device", %{label: label, scope: o[:scope] || "write"}) do
      {:ok, started} ->
        IO.puts("")
        started = Render.scrub(started)
        IO.puts("  Open  #{Render.bold(started["verification_uri"])}")
        IO.puts("  Enter #{Render.bold(started["user_code"])}")
        IO.puts("")
        IO.puts(Render.dim("  Signing in as \"#{label}\". Waiting — Ctrl-C to stop."))

        started
        |> await_device_approval(started["interval"] || 5)
        |> finish_device_auth(o)

      {:error, _, %{"error_description" => why}} ->
        fail(Render.scrub(why))

      other ->
        out(other, o, fn _ -> :ok end)
    end
  end

  def run("whoami", [], o) do
    HTTP.get("/me")
    |> out(o, fn r ->
      IO.puts(
        "#{r["user"]["email"]}#{if r["user"]["name"], do: " (#{r["user"]["name"]})", else: ""}"
      )

      # Where this account stands, so a batch can be sized before it starts
      # rather than hitting a 402 halfway through.
      for line <- standing_lines(r["limits"]), do: IO.puts("  " <> line)
    end)
  end

  # The OpenRouter key the server spends on your behalf. Shown masked; set by
  # passing it, or read from OPENROUTER_API_KEY when no argument is given.
  def run("ai-key", args, o) do
    cond do
      o[:remove] ->
        HTTP.delete("/me/ai-key") |> out(o, &render_ai_key/1)

      args != [] ->
        HTTP.put("/me/ai-key", %{api_key: Enum.join(args, " ")}) |> out(o, &render_ai_key/1)

      key = System.get_env("OPENROUTER_API_KEY") ->
        HTTP.put("/me/ai-key", %{api_key: key}) |> out(o, &render_ai_key/1)

      true ->
        HTTP.get("/me") |> out(o, &render_ai_key/1)
    end
  end

  def run("ai", [], o), do: HTTP.get("/me") |> out(o, &render_ai/1)

  def run("ai-endpoint", args, o) do
    cond do
      o[:remove] ->
        put_ai(%{base_url: ""}, o)

      args != [] ->
        %{base_url: Enum.join(args, " ")}
        |> then(&if(o[:key], do: Map.put(&1, :api_key, o[:key]), else: &1))
        |> put_ai(o)

      true ->
        HTTP.get("/me") |> out(o, &render_ai/1)
    end
  end

  def run("ai-models", [], o) do
    HTTP.get("/me/ai-models") |> out(o, &render_ai_models(&1["models"]))
  end

  def run("ai-model", args, o) when args != [] do
    %{model: Enum.join(args, " ")}
    |> then(&if(o[:embed], do: Map.put(&1, :embed_model, o[:embed]), else: &1))
    |> put_ai(o)
  end

  def run("ai-model", [], o) do
    if o[:remove] or o[:embed] do
      %{}
      |> then(&if(o[:remove], do: Map.put(&1, :model, ""), else: &1))
      |> then(&if(o[:embed], do: Map.put(&1, :embed_model, o[:embed]), else: &1))
      |> put_ai(o)
    else
      fail("ai-model needs a model id (see `slipdock ai-models`), or --remove")
    end
  end

  # Which server, remembered. `--remove` goes back to working it out.
  def run("url", [], o) do
    if o[:remove] do
      HTTP.forget_url()
      IO.puts("forgotten; now using #{HTTP.base_url()} (#{HTTP.url_source()})")
    else
      IO.puts("#{HTTP.base_url()}  (from #{HTTP.url_source()})")
    end
  end

  def run("url", [url], _o) do
    url = if String.contains?(url, "://"), do: url, else: "https://" <> url
    path = HTTP.save_url(url)
    System.put_env("SLIPDOCK_URL", url)

    case HTTP.get("/guide") do
      {:ok, _} -> IO.puts("saved #{HTTP.base_url()} to #{path}")
      {:error, :connect, _} -> IO.puts("saved #{url} to #{path}, but could not reach it")
      {:error, _, _} -> IO.puts("saved #{HTTP.base_url()} to #{path}")
    end

    if HTTP.insecure?(url),
      do:
        IO.puts(
          :stderr,
          "warning: #{url} is plain http; a token sent there can be read on the way"
        )

    unless HTTP.token(),
      do: IO.puts(Render.dim("no token for this server yet — run `slipdock auth`"))
  end

  def run("logout", [], _o) do
    HTTP.forget_token()
    IO.puts("token forgotten")
  end

  def run(cmd, _args, _o), do: bad_usage(cmd)

  ## Helpers ------------------------------------------------------------------

  defp standing_lines(%{} = limits) do
    [
      usage_line("items", limits["items"], &Integer.to_string/1),
      usage_line("boards", limits["boards"], &Integer.to_string/1),
      usage_line("files", limits["storage"], &human_bytes/1),
      trial_line(limits["trial"])
    ]
    |> Enum.filter(& &1)
  end

  defp standing_lines(_limits), do: []

  defp usage_line(name, %{"limited?" => true} = s, format),
    do: "#{name}: #{format.(s["used"])} of #{format.(s["limit"])} used"

  defp usage_line(_name, _status, _format), do: nil

  defp trial_line(%{"applies?" => true, "expired?" => true}),
    do: "free trial: over — nothing new can be added"

  defp trial_line(%{"applies?" => true} = trial),
    do: "free trial: #{trial["days_left"]} day(s) left"

  defp trial_line(_trial), do: nil

  defp human_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1024 * 1024 * 1024 -> "#{Float.round(bytes / 1024 / 1024 / 1024, 1)} GB"
      bytes >= 1024 * 1024 -> "#{Float.round(bytes / 1024 / 1024, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} bytes"
    end
  end

  defp human_bytes(other), do: "#{other}"

  defp put_ai(attrs, o), do: HTTP.put("/me/ai-provider", attrs) |> out(o, &render_ai/1)

  # Endpoint, key and model together, because one without the others tells you
  # nothing about where your requests are actually going.
  defp render_ai(%{"ai" => ai} = me) do
    own = if ai["own_endpoint"], do: "", else: Render.dim(" (server default)")
    IO.puts("endpoint  #{ai["base_url"]}#{own}")
    IO.write("key       ")
    render_ai_key(me)
    model = ai["model"] || "whatever the endpoint has loaded"

    IO.puts(
      "model     #{model}#{if ai["own_model"], do: "", else: Render.dim(" (server default)")}"
    )

    if ai["embed_model"], do: IO.puts("embedding #{ai["embed_model"]}")
  end

  defp render_ai(me), do: render_ai_key(me)

  defp render_ai_models([]), do: IO.puts("no models")

  defp render_ai_models(models) when is_list(models) do
    for m <- models do
      IO.puts("#{m["id"]}#{if m["embedding?"], do: Render.dim("  (embedding)")}")
    end
  end

  defp render_ai_models(_), do: IO.puts("no models")

  defp render_ai_key(%{"ai_key" => k}) do
    cond do
      k["masked"] ->
        IO.puts(
          "#{k["masked"]}#{if k["set_at"], do: "  set #{String.slice(k["set_at"], 0, 10)}"}"
        )

      k["ai_available"] ->
        IO.puts("no key of your own; this server has a shared one")

      true ->
        IO.puts("none (slipdock ai-key <key>, or slipdock ai-endpoint <url> for a local model)")
    end
  end

  # Poll until somebody decides. The server tells us how often to ask and says
  # `slow_down` if we ask faster; ignoring either is how a client locks itself
  # out, so the interval widens rather than the loop tightening.
  # `sleep` is there for the tests, which would rather not wait for real.
  @doc false
  def await_device_approval(started, interval, sleep \\ &Process.sleep/1) do
    deadline = System.monotonic_time(:second) + (started["expires_in"] || 600)
    poll_device(started["device_code"], interval, deadline, sleep)
  end

  defp poll_device(device_code, interval, deadline, sleep) do
    sleep.(interval * 1000)

    cond do
      System.monotonic_time(:second) > deadline ->
        {:error, "the code expired before anybody approved it — run `slipdock auth` again"}

      true ->
        case HTTP.post("/auth/device/token", %{device_code: device_code}) do
          {:ok, %{"token" => token}} ->
            {:ok, token}

          {:error, _, %{"error" => "authorization_pending"}} ->
            poll_device(device_code, interval, deadline, sleep)

          {:error, _, %{"error" => "slow_down"}} ->
            poll_device(device_code, interval + 5, deadline, sleep)

          {:error, _, %{"error" => "access_denied"}} ->
            {:error, "the request was refused"}

          {:error, _, %{"error" => "expired_token"}} ->
            {:error, "the code expired before anybody approved it — run `slipdock auth` again"}

          {:error, :connect, reason} ->
            {:error, "lost the server while waiting (#{inspect(reason)})"}

          _ ->
            {:error, "the server gave an answer this version does not understand"}
        end
    end
  end

  defp finish_device_auth({:ok, token}, o) do
    System.put_env("SLIPDOCK_TOKEN", token)

    HTTP.get("/me")
    |> out(o, fn r ->
      path = HTTP.save_token(token)
      remember_server()
      IO.puts("signed in as #{r["user"]["email"]}; token saved to #{path}")
    end)
  end

  defp finish_device_auth({:error, message}, _o), do: fail(message)

  # Signing in says which server you meant, so remember it: the next command,
  # and every agent session after it, should not need the address again.
  defp remember_server do
    HTTP.save_url(HTTP.base_url())
  rescue
    _ -> :ok
  end

  # What the person approving will see named on the screen, so make it say
  # something about this machine rather than "CLI".
  defp default_label do
    host =
      case :inet.gethostname() do
        {:ok, name} -> to_string(name)
        _ -> "unknown host"
      end

    "slipdock CLI on #{host}"
  end
end
