defmodule SlipdockWeb.MCP.Tools.CommitCapture do
  @moduledoc """
  Commits a reviewed meeting capture: everything it proposes, written in one
  go, refused if anything it changes has moved since it was read.
  """
  @behaviour SlipdockWeb.MCP.Tool

  alias Slipdock.Meetings.Commit
  alias SlipdockWeb.MCP.Tools.GetCapture

  @impl true
  def name, do: "commit_capture"

  @impl true
  def title, do: "Commit a meeting capture"

  @impl true
  def description,
    do:
      "Writes a ready meeting capture to the board in one go — only when the person has asked you to. " <>
        "Pass the preview digest from get_capture so exactly what they saw is written. Refused if a " <>
        "question is open or a card it changes was edited since; undoable from the capture's page."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        capture: %{type: "integer"},
        preview: %{type: "string", description: "The digest get_capture gave as preview."}
      },
      required: ["capture"],
      additionalProperties: false
    }
  end

  @impl true
  def read_only?, do: false

  @impl true
  def call(args, context) do
    with {:ok, capture} <- GetCapture.fetch(args, context, :write) do
      case Commit.commit(capture, context.user, digest: args["preview"], via: "agent") do
        {:ok, capture} ->
          {:ok,
           %{
             committed: true,
             url: SlipdockWeb.API.MeetingJSON.url(context.base_url, capture),
             written: Enum.map(capture.change_set["changes"], &written/1)
           }}

        {:error, :stale, targets} ->
          {:error,
           "not committed: changed since it was read — " <>
             Enum.map_join(targets, "; ", &"#{&1["ref"] || &1["title"]} (#{&1["why"]})")}

        {:error, _kind, message} ->
          {:error, "not committed: #{message}"}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  defp written(%{"op" => "create_card"} = c), do: "new card #{c["ref"]} “#{c["title"]}”"
  defp written(%{"op" => "update_card"} = c), do: "changed #{c["ref"]} “#{c["title"]}”"
  defp written(%{"op" => "comment"} = c), do: "commented on #{c["ref"]}"
  defp written(%{"op" => "decision_entry"} = c), do: "decisions on #{c["page_title"]}"
end
