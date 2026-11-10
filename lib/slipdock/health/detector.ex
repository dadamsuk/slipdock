defmodule Slipdock.Health.Detector do
  @moduledoc """
  One kind of stuck the health monitor looks for (see `Slipdock.Health`).

  `detect/2` reads the tree through a `Slipdock.Health.Context` and returns
  what it finds; it changes nothing. Each finding is a map:

    * `:subject` – `%{"card" => id, "job" => id, "runner" => id, "board" => id,
      "cards" => [id]}`, whichever apply
    * `:card_id` – the card a flag and comments go on, or nil (then a flag is
      a board alert)
    * `:state` – whatever about the subject made it stuck (an `updated_at`, a
      job's status): it goes into the fingerprint, so a changed state is a new
      incident
    * `:summary` – what it is, in words, one or two sentences
    * `:data` – optional, string-keyed: what `resolve/2` needs

  `resolve/2` tries a safe fix for an open incident, the `attempt`th time
  (from 1). It touches only orchestration state — jobs, the queue, flags,
  comments — and never deletes, merges or closes anything by force:

    * `:fixed` or `{:fixed, what}` – it is dealt with
    * `{:tried, what}` – something was done; a later run sees whether it took
    * `:no_fix` – nothing safe to try: flag it now
    * `{:no_fix, why}` – the fix can't work (trying it again would fail
      the same way, #2705): flag it now, saying why

  A detector with no `resolve/2` has no fix. A module under
  `Slipdock.Health.Detectors` that implements this behaviour runs by itself.
  """

  alias Slipdock.Health.{Context, Incident}

  @type finding :: %{
          required(:subject) => map,
          required(:card_id) => integer | nil,
          required(:state) => term,
          required(:summary) => String.t(),
          optional(:data) => map
        }

  @doc "Its key: what settings, the API and the CLI call it."
  @callback key() :: String.t()

  @doc "A short human name."
  @callback label() :: String.t()

  @doc """
  Its thresholds when the tree hasn't changed them, string-keyed. May also
  override `"enabled"` and `"max_attempts"` (default true and 2).
  """
  @callback defaults() :: map

  @doc "What it finds, given the tree and its settings."
  @callback detect(Context.t(), settings :: map) :: [finding]

  @doc "Tries a fix for the `attempt`th time."
  @callback resolve(Incident.t(), attempt :: pos_integer) ::
              :fixed
              | {:fixed, String.t()}
              | {:tried, String.t()}
              | :no_fix
              | {:no_fix, String.t()}

  @optional_callbacks resolve: 2
end
