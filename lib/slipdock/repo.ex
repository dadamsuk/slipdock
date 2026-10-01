defmodule Slipdock.Repo do
  use Ecto.Repo,
    otp_app: :slipdock,
    adapter: Ecto.Adapters.SQLite3
end
