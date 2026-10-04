defmodule SlipdockWeb.Mention do
  @moduledoc """
  The people the `Mention` hook offers when somebody types `@` in a card's
  description or a comment: the board's members (see `Slipdock.Mentions`).
  """

  alias Slipdock.Wiki.Links

  @doc "The board's members as JSON for the hook's `data-people`: handle, name, email."
  def people(board) do
    board
    |> Links.members()
    |> Enum.map(&%{handle: Links.handle(&1), name: &1.name, email: &1.email})
    |> Jason.encode!()
  end
end
