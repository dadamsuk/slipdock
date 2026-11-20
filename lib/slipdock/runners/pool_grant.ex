defmodule Slipdock.Runners.PoolGrant do
  @moduledoc """
  One person given a runner pool on a board tree by the tree's owner
  (#3492): with it, a writer of the root board takes that pool's jobs, from
  a Claude session or a machine of their own. Only
  `Slipdock.Runners.PoolGrants` makes or deletes one; nothing here is cast.
  """
  use Ecto.Schema

  schema "runner_pool_grants" do
    field :pool, :string
    belongs_to :board, Slipdock.Boards.Board
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :granted_by, Slipdock.Accounts.User
    timestamps(type: :utc_datetime)
  end
end
