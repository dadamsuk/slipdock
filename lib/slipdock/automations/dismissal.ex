defmodule Slipdock.Automations.Dismissal do
  @moduledoc "Records that one person has dismissed one alert."
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "alert_dismissals" do
    belongs_to :alert, Slipdock.Automations.Alert
    belongs_to :user, Slipdock.Accounts.User
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
