defmodule Slipdock.Updates do
  @moduledoc """
  Whether a newer image has been published than the build that is running.

  The published image (`ghcr.io/dadamsuk/slipdock:latest` unless configured
  otherwise) carries the commit it was built from as the OCI label
  `org.opencontainers.image.revision`, and when as `.created`. GHCR hands out
  an anonymous pull token for a public image, so the whole check is three GETs
  with no credentials: a token, the manifest, and the image config it points at.

  Comparing commits rather than version numbers is deliberate — `latest` is
  the tip of main, which moves without the version in `mix.exs` changing. A
  different commit is only called *newer* when it was also built after this
  one; a build compiled from a checkout ahead of the published image says so
  rather than offering a downgrade.

  Nothing here pulls or restarts anything. Asked only when an admin looks
  (Configuration, `GET /api/admin/updates`), never on a timer, so a server
  nobody is administering never calls out. `SLIPDOCK_UPDATE_CHECK=false` turns
  it off altogether, for a server that should not reach the internet.
  """

  alias Slipdock.Build

  @revision "org.opencontainers.image.revision"
  @created "org.opencontainers.image.created"

  @manifest_types Enum.join(
                    [
                      "application/vnd.oci.image.index.v1+json",
                      "application/vnd.docker.distribution.manifest.list.v2+json",
                      "application/vnd.oci.image.manifest.v1+json",
                      "application/vnd.docker.distribution.manifest.v2+json"
                    ],
                    ","
                  )

  @doc "Whether checking is switched on."
  def enabled?, do: config()[:enabled] != false

  @doc "The image reference checked, as `registry/owner/name:tag`."
  def image_ref, do: "#{config()[:image]}:#{config()[:tag]}"

  @doc """
  Compares the running build with the published image.

  Returns a map with `:status` — `:current`, `:available` (published is a
  different commit, built later), `:ahead` (published is a different commit,
  built earlier), `:unknown` (this build does not know its own commit) or
  `:disabled` — plus `:running` and `:latest` (`%{revision, created}`, nil when
  not fetched). `{:error, reason}` when the registry could not be asked.
  """
  def check do
    running = %{revision: Build.sha(), created: Build.timestamp()}

    if enabled?() do
      with {:ok, latest} <- latest() do
        {:ok,
         %{status: compare(running, latest), image: image_ref(), running: running, latest: latest}}
      end
    else
      {:ok, %{status: :disabled, image: image_ref(), running: running, latest: nil}}
    end
  end

  @doc false
  def compare(%{revision: "unknown"}, _latest), do: :unknown
  def compare(%{revision: same}, %{revision: same}), do: :current

  def compare(%{created: built}, %{created: %DateTime{} = published}) do
    if DateTime.compare(published, built) == :gt, do: :available, else: :ahead
  end

  def compare(_running, _latest), do: :available

  @doc "The commit and build time of the published image."
  def latest do
    {host, repo} = split_image(config()[:image])
    base = "https://#{host}/v2/#{repo}"

    with {:ok, token} <- token(host, repo),
         auth = [{"authorization", "Bearer #{token}"}],
         {:ok, manifest} <- get_json("#{base}/manifests/#{config()[:tag]}", auth),
         {:ok, manifest} <- pick_platform(manifest, base, auth),
         {:ok, digest} <- config_digest(manifest),
         {:ok, image_config} <- get_json("#{base}/blobs/#{digest}", auth) do
      labels = get_in(image_config, ["config", "Labels"]) || %{}

      case labels[@revision] do
        revision when is_binary(revision) and revision != "" ->
          {:ok,
           %{revision: revision, created: parse_time(labels[@created] || image_config["created"])}}

        _ ->
          {:error, "the published image does not say which commit it was built from"}
      end
    end
  end

  defp token(host, repo) do
    case get_json("https://#{host}/token?scope=repository:#{repo}:pull&service=#{host}", []) do
      {:ok, %{"token" => token}} -> {:ok, token}
      {:ok, _} -> {:error, "#{host} did not hand out a pull token"}
      error -> error
    end
  end

  # A multi-architecture tag is an index of per-platform manifests. Every
  # platform is built from the same commit, so any real one will do; the
  # attestation entries say `unknown` and have no image config worth reading.
  defp pick_platform(%{"manifests" => entries}, base, auth) do
    case Enum.find(entries, &(get_in(&1, ["platform", "os"]) == "linux")) do
      %{"digest" => digest} -> get_json("#{base}/manifests/#{digest}", auth)
      nil -> {:error, "the published image has no Linux build"}
    end
  end

  defp pick_platform(manifest, _base, _auth), do: {:ok, manifest}

  defp config_digest(%{"config" => %{"digest" => digest}}), do: {:ok, digest}
  defp config_digest(_), do: {:error, "the registry sent a manifest without an image config"}

  defp get_json(url, headers) do
    options =
      [
        url: url,
        headers: [{"accept", @manifest_types} | headers],
        receive_timeout: 10_000,
        retry: false
      ] ++ (config()[:req_options] || [])

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, "the registry sent something that is not JSON"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "the registry answered HTTP #{status}"}

      {:error, exception} ->
        {:error, "could not reach the registry: #{Exception.message(exception)}"}
    end
  end

  defp split_image(image) do
    [host | rest] = String.split(image, "/")
    {host, Enum.join(rest, "/")}
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.truncate(time, :second)
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp config do
    Keyword.merge(
      [image: "ghcr.io/dadamsuk/slipdock", tag: "latest", enabled: true],
      Application.get_env(:slipdock, :updates, [])
    )
  end
end
