defmodule Slipdock.Credo.ABCSize do
  @moduledoc false

  alias Credo.Check.Refactor.ABCSize, as: Upstream

  use Credo.Check,
    id: "SD0002",
    base_priority: :normal,
    category: :refactor,
    param_defaults: [max_size: 50, excluded_functions: []],
    explanations: [
      check: """
      A function's ABC size (assignments, branches and conditions) stays at
      or under `max_size`: credo's `Credo.Check.Refactor.ABCSize`, with a
      message `credo diff` can match (handbook W-1950 §Credo's size checks).

      Credo's own message carries the score, and `credo diff` counts an issue
      whose message changed as new: every edit to a function already over the
      limit would fail, a refactor that lowers its score too. This one says
      only that the function is over, so `credo diff` flags a function that
      is new or newly over, and leaves alone one that was over already.
      `mix credo --checks ABCSize` gives the scores.
      """,
      params: [
        max_size: "The largest ABC size a function may have.",
        excluded_functions: "Calls (by name) not counted as branches; Ecto.Query's never are."
      ]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params \\ []) do
    max_size = Params.get(params, :max_size, __MODULE__)

    upstream_params = [
      max_size: max_size,
      excluded_functions: Params.get(params, :excluded_functions, __MODULE__)
    ]

    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Upstream.run(upstream_params)
    |> Enum.map(fn issue ->
      format_issue(issue_meta,
        message: "Function is too complex (ABC size is over #{max_size}).",
        trigger: issue.trigger,
        line_no: issue.line_no,
        column: issue.column
      )
    end)
  end
end
