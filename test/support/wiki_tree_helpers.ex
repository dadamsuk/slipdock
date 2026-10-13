defmodule SlipdockWeb.WikiTreeHelpers do
  @moduledoc """
  The wiki's tree in LiveView tests. The tree is drawn by a hook in the
  browser, so a test asks what the hook asks (`tree_load`) and reads the
  rows that come back, as the hook would draw them.
  """
  import ExUnit.Assertions
  import Phoenix.LiveViewTest

  @doc "What the hook gets back for `params` (scope board, nothing open, by default)."
  def tree_load(view, params \\ %{}) do
    render_hook(view, "tree_load", Map.merge(%{"scope" => "board", "keys" => []}, params))
    assert_reply(view, reply)
    reply
  end

  @doc "What the hook gets on a fresh visit: no keys, so what the server kept."
  def tree_load_kept(view, params \\ %{}) do
    render_hook(view, "tree_load", Map.merge(%{"scope" => "board"}, params))
    assert_reply(view, reply)
    reply
  end

  @doc "The titles of one container's rows, in order."
  def titles(reply, key), do: reply.nodes |> Map.get(key, []) |> Enum.map(& &1.title)

  @doc "The row titled `title` in a container, or nil."
  def row(reply, key, title),
    do: reply.nodes |> Map.get(key, []) |> Enum.find(&(&1.title == title))

  @doc "Every title the reply holds, wherever it is."
  def all_titles(reply),
    do: reply.nodes |> Map.values() |> List.flatten() |> Enum.map(& &1.title) |> Enum.sort()
end
