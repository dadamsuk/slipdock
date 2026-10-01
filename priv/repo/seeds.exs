# Sample data so the app has something to show on first boot.
#
#     mix run priv/repo/seeds.exs
#
# The workspace itself is `Slipdock.Demo`, which `mix slipdock.demo` also calls —
# one sample dataset, so the screenshots in the README and a fresh install
# show the same thing. This is a no-op once there is a board.
case Slipdock.Demo.build() do
  {:ok, _board} -> :ok
  {:error, :not_empty} -> :ok
end
