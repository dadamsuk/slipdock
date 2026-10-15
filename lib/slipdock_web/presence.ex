defmodule SlipdockWeb.Presence do
  @moduledoc """
  Who is where, live (#825): Phoenix.Presence over `Slipdock.PubSub`. Its
  first use is a drawing's editors (`SlipdockWeb.DrawingLive`), tracked on
  `"drawing:<kind>:<id>"`, one entry per open tab, gone when the tab is.
  """
  use Phoenix.Presence, otp_app: :slipdock, pubsub_server: Slipdock.PubSub

  # Collaborator colours: distinct from each other, legible on a white or a
  # dark canvas, and a person keeps theirs across drawings and visits.
  @colours ~w(#e03131 #1971c2 #2f9e44 #f08c00 #9c36b5 #0c8599 #e8590c #6741d9)

  @doc "A person's colour: the same every time for the same user id."
  def colour(user_id), do: Enum.at(@colours, :erlang.phash2(user_id, length(@colours)))
end
