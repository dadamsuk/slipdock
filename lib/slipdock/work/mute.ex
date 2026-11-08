defmodule Slipdock.Work.Mute do
  @moduledoc """
  A board one person keeps off their own Waiting on you (#2069), its whole
  tree with it. The board works as before for everyone, this person included.
  """
  use Ecto.Schema

  schema "waiting_mutes" do
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :board, Slipdock.Boards.Board
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
