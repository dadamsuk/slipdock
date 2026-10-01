defmodule Slipdock.Boards.CardUrl do
  @moduledoc """
  A link out of the system: a web page, a shared drive, a file somewhere else.

  A wiki page can hold them too — exactly one of `card_id` and `page_id` is
  set; see `Slipdock.Boards.Owned`.

  Cards already link to other cards (`Slipdock.Boards.CardLink`) and hold files
  of their own (`Slipdock.Boards.Attachment`); this is the third kind — a
  reference to something the board does not own. Each one is datestamped by
  its `inserted_at`, so a card says when the link was put there.

  A link typed without a scheme is taken to be `https`, which is what someone
  pasting `example.com/spec` means.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @schemes ~w(http https ftp ftps file smb mailto)

  schema "card_urls" do
    field :url, :string
    field :title, :string
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The URL schemes a link may use."
  def schemes, do: @schemes

  def changeset(card_url, attrs) do
    card_url
    |> cast(attrs, [:url, :title, :card_id, :page_id])
    |> update_change(:url, &normalise/1)
    |> update_change(:title, &blank_to_nil/1)
    |> validate_required([:url])
    |> Slipdock.Boards.Owned.validate_owner()
    |> validate_length(:url, max: 2000)
    |> validate_length(:title, max: 255)
    |> validate_change(:url, &valid_url/2)
  end

  # A bare "example.com/spec" is a web address; anything with a scheme keeps it.
  defp normalise(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: nil} when url != "" -> "https://" <> url
      _ -> url
    end
  end

  defp normalise(other), do: other

  defp blank_to_nil(title) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      t -> t
    end
  end

  defp blank_to_nil(other), do: other

  # A hostname, and nothing a hostname cannot hold — a sentence typed into the
  # box comes back from URI.parse as a "host" otherwise.
  @host ~r/^[a-z0-9._~%-]+(:\d+)?$/i

  defp valid_url(:url, url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme not in @schemes ->
        [url: "must be a web, file or mail address"]

      %URI{scheme: "mailto", path: path} ->
        if is_binary(path) and String.contains?(path, "@"),
          do: [],
          else: [url: "is not a complete address"]

      # file:///path names no host, and that is how it should be.
      %URI{scheme: "file", path: path} when is_binary(path) and path != "" ->
        []

      %URI{host: host} when is_binary(host) ->
        if Regex.match?(@host, host), do: [], else: [url: "is not a complete address"]

      _ ->
        [url: "is not a complete address"]
    end
  end

  @doc """
  What to show for the link: the title if it was given one, else the address
  with the noise trimmed off — no scheme, no `www.`, no trailing slash.
  """
  def label(%__MODULE__{title: title}) when is_binary(title), do: title

  def label(%__MODULE__{url: url}) do
    case URI.parse(url) do
      %URI{scheme: "mailto", path: path} when is_binary(path) ->
        path

      %URI{host: host} = uri when is_binary(host) ->
        host = String.replace_prefix(host, "www.", "")
        (host <> (uri.path || "")) |> String.trim_trailing("/")

      _ ->
        url
    end
  end

  @doc "A short word for the kind of thing linked to, used for the icon."
  def kind(%__MODULE__{url: url}) do
    case URI.parse(url) do
      %URI{scheme: "mailto"} -> :mail
      %URI{scheme: s} when s in ["file", "smb", "ftp", "ftps"] -> :file
      _ -> :web
    end
  end
end
