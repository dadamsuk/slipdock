defmodule Slipdock.Credo.InOutsideGuard do
  @moduledoc false

  use Credo.Check,
    id: "SD0001",
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      Outside a guard, write `Enum.member?(list, x)` rather than `x in list`.

      `:cover` (`mix test --cover`) can't instrument `in` outside a guard, so
      a module that uses it loses its coverage (handbook W-1950 §Tests).

      Guards (`when x in [...]`, `defguard`) and Ecto queries (`from p in
      Post`, `where: p.id in ^ids`) need `in`, and are left alone. So is a
      rescue clause's `e in [File.Error] ->`, which matches the exception's
      struct and is no membership test.
      """
    ]

  # Ecto.Query's macros, where `in` is part of the query language.
  @query_macros ~w(from where or_where having or_having select select_merge join
                   left_join inner_join right_join full_join cross_join on dynamic
                   update order_by group_by distinct preload windows with_cte
                   exists subquery lock limit offset)a

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params \\ []) do
    ctx = Context.build(source_file, params, __MODULE__)
    Credo.Code.prewalk(source_file, &walk/2, ctx).issues
  end

  # A guard: walk the heads, never the guard itself.
  defp walk({:when, meta, args}, ctx) when is_list(args) and length(args) >= 2,
    do: {{:when, meta, Enum.drop(args, -1)}, ctx}

  defp walk({name, _meta, args}, ctx) when name in @query_macros and is_list(args),
    do: {:skipped, ctx}

  # Ecto.Query.from(...), Ecto.Query.where(...) and so on, called in full.
  defp walk({{:., _, [{:__aliases__, _, [:Ecto, :Query]}, name]}, _meta, args}, ctx)
       when name in @query_macros and is_list(args),
       do: {:skipped, ctx}

  # A try's or a function body's rescue clauses: `e in [Mod] ->` and `e in Mod ->`
  # match the exception's struct. Walk each clause's body, never that head.
  defp walk({:rescue, clauses}, ctx) when is_list(clauses),
    do: {{:rescue, Enum.map(clauses, &drop_rescue_in/1)}, ctx}

  defp walk({:in, meta, [_left, _right]} = ast, ctx),
    do: {ast, put_issue(ctx, issue_for(ctx, meta))}

  defp walk(ast, ctx), do: {ast, ctx}

  defp drop_rescue_in({:->, meta, [[{:in, _, [left, _mods]}], body]}),
    do: {:->, meta, [[left], body]}

  defp drop_rescue_in(clause), do: clause

  defp issue_for(ctx, meta) do
    format_issue(ctx,
      message:
        "Outside a guard, use Enum.member?/2 rather than `in`: :cover can't instrument it.",
      trigger: "in",
      line_no: meta[:line]
    )
  end
end
