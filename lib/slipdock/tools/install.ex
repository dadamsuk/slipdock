defmodule Slipdock.Tools.Install do
  @moduledoc """
  One person's install of a Tool: the version they have and the board it
  built for them. The skills a Tool carries are installed on the person's
  own machine or client and are not recorded here; `slipdock tools check`
  compares those against the server by sha.
  """
  use Ecto.Schema

  schema "tool_installs" do
    field :version, :string
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :tool, Slipdock.Tools.Tool
    belongs_to :board, Slipdock.Boards.Board
    timestamps(type: :utc_datetime)
  end
end
