defmodule SlipdockWeb.ExternalImages do
  @moduledoc """
  Pictures from other hosts, when an admin has turned them off (#3559).

  With `Slipdock.Settings.block_external_images?/0` on, the
  Content-Security-Policy (`SlipdockWeb.Plugs.ContentSecurityPolicy`) loads
  images only from this server, so a picture a card or page points at
  elsewhere would show as a broken image. `as_links/1` is the one place the
  renderers turn each such `<img>` into a link to the picture instead, named
  by its alt text, or its address when it has none. It runs on the finished
  HTML of `SlipdockWeb.RichText` (card descriptions and comments) and of
  `SlipdockWeb.Wiki.Renderer` (pages, published and shared ones included).

  An `<img>` already inside a link (a picture that links somewhere) becomes
  that text alone, since a link can't hold another. Pictures from this server,
  `data:` and `blob:` ones and relative paths are left alone.

  It reads HTML a sanitiser wrote, or that `SlipdockWeb.RichText` built from
  escaped text: a `<` there only ever opens a tag, and every attribute value
  is in double quotes.
  """

  @doc "Whether external pictures are turned off on this server."
  @spec blocked?() :: boolean()
  def blocked?, do: Slipdock.Settings.block_external_images?()

  @doc """
  The HTML with each external `<img>` turned into a link to the picture, when
  `blocked?/0`; otherwise as it was.
  """
  @spec as_links(String.t()) :: String.t()
  def as_links(html) when is_binary(html) do
    # The setting is read only when there is an external picture to change,
    # so text with none never waits on it.
    with true <- String.contains?(html, "<img"),
         rewritten when rewritten != html <- replace(html),
         true <- blocked?() do
      rewritten
    else
      _ -> html
    end
  end

  @doc false
  # Public for the tests: the rewrite, whatever the setting says.
  def replace(html) do
    ~r/<[^>]*>|[^<]+/
    |> Regex.scan(html)
    |> Enum.map_reduce(0, &token/2)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp token(["<a" <> rest = tag], depth) when binary_part(rest, 0, 1) in [" ", ">"],
    do: {tag, depth + 1}

  defp token(["</a>" = tag], depth), do: {tag, max(depth - 1, 0)}

  defp token(["<img" <> _ = tag], depth) do
    src = attribute(tag, "src")

    if src && external?(src) do
      label = blank_to(attribute(tag, "alt"), src)

      if depth > 0,
        do: {label, depth},
        else: {~s|<a href="#{src}" target="_blank" rel="noopener noreferrer">#{label}</a>|, depth}
    else
      {tag, depth}
    end
  end

  defp token([other], depth), do: {other, depth}

  defp attribute(tag, name) do
    case Regex.run(~r/\s#{name}="([^"]*)"/, tag) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp blank_to(nil, fallback), do: fallback
  defp blank_to(value, fallback), do: if(String.trim(value) == "", do: fallback, else: value)

  @doc """
  Whether a picture's address is on another host: an absolute `http(s)` or
  scheme-relative (`//`) URL whose host isn't this server's.
  """
  @spec external?(String.t()) :: boolean()
  def external?(src) do
    src = String.trim(src)

    case URI.parse(src) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https", nil] and is_binary(host) ->
        (scheme != nil or String.starts_with?(src, "//")) and
          String.downcase(host) != own_host()

      _ ->
        false
    end
  end

  defp own_host, do: String.downcase(SlipdockWeb.Endpoint.host())
end
