defmodule Slipdock.SkillRegistry.Fetch do
  @moduledoc """
  One GET for the skills registry, the only way it reaches out (#2060).

  Every request goes through `Slipdock.Egress` (private ranges refused, the
  address pinned, redirects off) and `Req` (ARCH-9), and stops reading at a
  byte cap, so a large or endless response costs no more than the cap. What
  comes back on failure is a phrase fit to follow the URL in a sentence
  ("is not a public address", "is larger than 256 KB"), never the transport's
  own error.

  Config, under `config :slipdock, :skill_registry` (read with
  `Slipdock.Config`, so a test can stub it):

    * `req_options` – merged into every request (tests: `plug: {Req.Test, …}`);
    * `github_token` – sent to `api.github.com` only, for its higher rate limit.
  """

  alias Slipdock.Egress

  @type result :: {:ok, %{body: binary(), etag: String.t() | nil}} | {:error, String.t()}

  @doc """
  GETs `url`, reading at most `max_bytes` of its body. `opts`: `:max_bytes`
  (required), `:headers`.
  """
  @spec get(String.t(), keyword()) :: result
  def get(url, opts) do
    max = Keyword.fetch!(opts, :max_bytes)

    case Egress.prepare(url) do
      {:ok, pinned, egress_options} ->
        [
          url: pinned,
          method: :get,
          headers: headers(url, opts[:headers] || []),
          retry: false,
          decode_body: false,
          receive_timeout: 15_000,
          into: capped(max)
        ]
        |> Keyword.merge(egress_options)
        |> Keyword.merge(config()[:req_options] || [])
        |> Req.request()
        |> answer(max)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "A byte count as people read it: `256 KB`, `2 MB`."
  def size(bytes) when bytes >= 1_000_000, do: "#{div(bytes, 1_000_000)} MB"
  def size(bytes), do: "#{div(bytes, 1000)} KB"

  defp headers(url, extra) do
    base = [{"user-agent", "Slipdock skills registry"} | extra]

    case {URI.parse(url).host, config()[:github_token]} do
      {"api.github.com", token} when is_binary(token) and token != "" ->
        [{"authorization", "Bearer " <> token} | base]

      _ ->
        base
    end
  end

  # Collects the body as iodata and halts, marking the response, once it
  # would pass `max`.
  defp capped(max) do
    fn {:data, data}, {req, resp} ->
      body = if is_binary(resp.body) or is_list(resp.body), do: resp.body, else: ""

      if IO.iodata_length(body) + byte_size(data) > max do
        {:halt, {req, Req.Response.put_private(resp, :too_big, true)}}
      else
        {:cont, {req, %{resp | body: [body | data]}}}
      end
    end
  end

  defp answer({:ok, %Req.Response{} = resp}, max) do
    if Req.Response.get_private(resp, :too_big),
      do: {:error, "is larger than #{size(max)}"},
      else: status(resp.status, resp)
  end

  defp answer({:error, %Req.TransportError{reason: :timeout}}, _max), do: {:error, "timed out"}
  defp answer({:error, _exception}, _max), do: {:error, "could not be reached"}

  defp status(code, resp) when code in 200..299,
    do: {:ok, %{body: binary(resp.body), etag: etag(resp)}}

  defp status(code, _resp) when code in 300..399,
    do: {:error, "redirects elsewhere (redirects are not followed)"}

  defp status(404, _resp), do: {:error, "was not found"}

  defp status(code, _resp) when code in [403, 429],
    do: {:error, "was refused (HTTP #{code}; rate limited?)"}

  defp status(code, _resp), do: {:error, "answered HTTP #{code}"}

  defp binary(body) when is_binary(body), do: body
  defp binary(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp binary(_), do: ""

  defp etag(resp) do
    case Req.Response.get_header(resp, "etag") do
      [tag | _] -> tag
      [] -> nil
    end
  end

  defp config, do: Slipdock.Config.get(:skill_registry, [])
end
