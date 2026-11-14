defmodule Slipdock.Boards.CardUrls do
  @moduledoc """
  Links to somewhere outside the system, on a card or a wiki page.
  """

  import Ecto.Query, warn: false

  alias Slipdock.Boards
  alias Slipdock.Boards.CardUrl
  alias Slipdock.Policy
  alias Slipdock.Repo

  ## External links ----------------------------------------------------------

  @doc """
  Puts a link to somewhere outside the system on a card. `attrs` carries the
  `url` and an optional `title`; the datestamp is the row's own `inserted_at`.
  Asks write on the card or page (`Slipdock.Policy`, `:edit_card_urls`).
  """
  def add_card_url(owner, attrs) do
    with :ok <- Policy.authorize(:edit_card_urls, owner), do: insert(owner, attrs)
  end

  defp insert(owner, attrs) do
    %CardUrl{}
    |> struct!(Boards.Shared.owned_by(owner))
    |> CardUrl.changeset(stringify(attrs))
    |> Repo.insert()
    |> Boards.Shared.tap_ok(fn url ->
      Boards.Shared.log_owned(owner, "link", "linked “#{owner.title}” to #{url.url}")
      Boards.PubSub.broadcast(owner.board_id)
    end)
  end

  def get_card_url!(id), do: CardUrl |> Repo.get!(id) |> Repo.preload([:card, :page])

  @doc "Takes a web link off its card or page: write on it (`:edit_card_urls`)."
  def delete_card_url(%CardUrl{} = url) do
    with :ok <- Policy.authorize(:edit_card_urls, url), do: delete(url)
  end

  defp delete(url) do
    owner = Boards.Shared.owner_of(url)

    Repo.delete(url)
    |> Boards.Shared.tap_ok(fn _ ->
      Boards.Shared.log_owned(owner, "link", "unlinked #{url.url} from “#{owner.title}”")
      Boards.PubSub.broadcast(owner.board_id)
    end)
  end

  # Params reach us as atoms from Elixir and strings from the wire.
  defp stringify(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  ## Lookups (#2791): plain reads the web layer makes through this context

  @doc "The link `id` on a card or page, or nil, with nothing loaded."
  def get_card_url(id), do: Repo.get(CardUrl, id)
end
