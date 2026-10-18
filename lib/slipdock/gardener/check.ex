defmodule Slipdock.Gardener.Check do
  @moduledoc """
  One kind of rot the gardener looks for (W-1807).

  A check reads the board through a `Slipdock.Gardener.Context` and returns
  its findings; it changes nothing. Each finding is a map:

    * `:subject` – `%{"cards" => [id], "pages" => [id]}`
    * `:state` – whatever about the subject made it a finding (an
      `updated_at`, a due date): it goes into the fingerprint, so a dismissal
      lasts until this changes
    * `:proposal` – the steps the fix takes (see `Slipdock.Gardener.Steps`)
    * `:alternatives` – optional, `%{name => steps}`: other fixes on offer
    * `:explanation` – one sentence with the evidence
  """

  alias Slipdock.Gardener.Context

  @type finding :: %{
          required(:subject) => map,
          required(:state) => term,
          required(:proposal) => [map],
          optional(:alternatives) => %{String.t() => [map]},
          required(:explanation) => String.t()
        }

  @doc "Its key: what settings, the API and the CLI call it."
  @callback key() :: String.t()

  @doc "A short human name, for the Tidy-up page's group heading."
  @callback label() :: String.t()

  @doc """
  Its settings when the board hasn't changed them: `"enabled"` and any
  thresholds, string-keyed.
  """
  @callback defaults() :: map

  @doc "What it finds, given the board and its settings."
  @callback find(Context.t(), settings :: map) :: [finding]
end
