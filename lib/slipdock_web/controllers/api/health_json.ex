defmodule SlipdockWeb.API.HealthJSON do
  @moduledoc "How the health monitor's incidents and detectors read over HTTP."

  alias Slipdock.Health.Incident

  def incident(%Incident{} = i) do
    %{
      id: i.id,
      detector: i.detector,
      status: i.status,
      summary: i.summary,
      subject: i.subject,
      card: card(i.card),
      attempts: i.attempts,
      log: i.log,
      alert_id: i.alert_id,
      opened_at: i.inserted_at,
      updated_at: i.updated_at,
      flagged_at: i.flagged_at,
      resolved_at: i.resolved_at
    }
  end

  def detectors(list) do
    Enum.map(list, fn d ->
      %{key: d.key, label: d.label, enabled: d.settings["enabled"], settings: d.settings}
    end)
  end

  defp card(%Slipdock.Boards.Card{} = c), do: %{id: c.id, title: c.title, board_id: c.board_id}
  defp card(_), do: nil
end
