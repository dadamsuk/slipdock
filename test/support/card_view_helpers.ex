defmodule Slipdock.CardViewHelpers do
  @moduledoc """
  Card views in tests (#2031): what a person's cards show is their card
  views, not the URL's `show=` (the Display menu's old checkboxes).
  """

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest, only: [live: 2]

  alias Slipdock.CardViews
  alias Slipdock.Swimlanes.Config

  @endpoint SlipdockWeb.Endpoint

  @doc """
  `show_on_cards/4` for `user`, then the board's page at `path`: what a test
  used to do with `?show=` in the URL.
  """
  def live_showing(conn, user, board, path, keys, opts \\ []) do
    show_on_cards(user, board, keys, opts)
    live(conn, path)
  end

  @doc """
  Sets `user`'s level for `board` (or one list on it, `list:`) so that the
  card front shows exactly the facets in `keys`: every other facet hidden,
  the marks left as they are. `extra:` states more elements as given.
  """
  def show_on_cards(user, board, keys, opts \\ []) do
    elements =
      Config.facet_keys()
      |> Map.new(&{&1, &1 in keys})
      |> Map.merge(Map.new(Keyword.get(opts, :extra, %{})))

    scope =
      case opts[:list] do
        nil -> {:board, board}
        column -> {:list, board, column}
      end

    {:ok, level} = CardViews.update_level(user, scope, %{"elements" => elements})
    level
  end
end
