defmodule Slipdock.Automations.Callback do
  @moduledoc """
  One callback a rule made: where it went, how, and what came back — an HTTP
  status, or the reason there was none. Written by
  `Slipdock.Automations.Notifier` once the call has finished, which in
  production is after the change that set it off has long returned, so this
  is the only place a failed callback is seen at all.

  The rule's name and the card's title are copied in so the log still reads
  after either is gone. A board keeps its newest `Slipdock.Automations`
  `@callback_limit` of them.
  """
  use Ecto.Schema

  schema "automation_callbacks" do
    field :rule_name, :string
    field :card_title, :string
    field :method, :string
    field :url, :string
    field :status, :integer
    field :error, :string
    field :duration_ms, :integer

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :rule, Slipdock.Automations.Rule
    belongs_to :card, Slipdock.Boards.Card

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Whether the other end took it: a 2xx answer and no error."
  def ok?(%__MODULE__{error: nil, status: status}) when status in 200..299, do: true
  def ok?(%__MODULE__{}), do: false

  @doc "What came back, in a few words: `200`, `HTTP 503`, or the error."
  def outcome(%__MODULE__{error: nil, status: status}) when is_integer(status),
    do: to_string(status)

  def outcome(%__MODULE__{error: error}) when is_binary(error), do: error
  def outcome(%__MODULE__{}), do: "no answer"
end
