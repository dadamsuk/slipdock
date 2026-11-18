defmodule SlipdockCLI.Op do
  @moduledoc """
  A CLI command made from the server's definition
  of the operation. `priv/ops.json` is `SlipdockWeb.Ops.manifest_json/0`
  (held to it by the app's `OpsTest`), read at compile time: the route, the
  params and how argv maps onto them come from there, not from this client.
  What the command prints stays here, hand-written.

  The flags a command takes come from there too (#3191): the definition's
  `flags`, and the three every command takes (`--json`, `--url`, `--help`).
  Any other is refused before a request is made, with the flags the command
  does take. A flag whose definition says `read` names a file (or `-`,
  stdin) the command reads the param from itself: it is taken, but what the
  request carries is what the command read, given in `set`. One whose
  definition says `read: "parsed"` (`--no-due`, `--route KIND=EMAIL`) is
  one the command works a param out from: it gives the param in `params`
  (#3361), by the definition's name, a nil sent as null (it clears).
  """

  alias SlipdockCLI.HTTP

  @path Path.expand("../../priv/ops.json", __DIR__)
  @external_resource @path
  # By command; an operation the CLI has no command for has no `cli`.
  @ops @path
       |> File.read!()
       |> JSON.decode!()
       |> Enum.filter(& &1["cli"])
       |> Map.new(&{&1["cli"]["command"], &1})

  def ops, do: @ops

  # The flags every command takes, an operation's or not: output, the
  # server, the help (`slipdock <command> [args] [--json] [--url URL]`).
  @global ~w(json url help)

  # A command typed under a name of its own, or one usage of an operation's
  # command that takes only some of its flags: what is typed => {the
  # operation's command, the definition's flags this takes}. Any other
  # command takes all of its definition's flags.
  @usages %{
    "archive" => {"archive", []},
    "restore" => {"archive", []},
    "activity" => {"activity", ~w(card limit since)},
    "ledger" => {"activity", ~w(since)},
    "page history" => {"page history", ~w(limit)},
    "page diff" => {"page history", ~w(against rev)},
    "garden apply" => {"garden", ~w(choice keep)},
    "garden dismiss" => {"garden", []},
    "garden undo" => {"garden", []},
    # edit_card's (#3361): edit takes the fields, done the evidence and the
    # change, and the rest each set one param from their words.
    "edit" => {"edit", ~w(title short_name desc bar priority start no_start due no_due percent
                          no_percent paths profile no_profile caused_by no_caused_by missed_by
                          no_missed_by spent no_spent estimate no_estimate unit log color
                          no_color column assignee no_assignee add_assignee remove_assignee
                          border no_border border_top border_right border_bottom border_left)},
    "done" => {"edit", ~w(evidence evidence_commit branch tests suite pr no_code diff_base
                          changed_lines changed_files)},
    "undone" => {"edit", []},
    "flag" => {"edit", []},
    "tag" => {"edit", []},
    "set" => {"edit", []},
    "log" => {"edit", []}
  }

  def global, do: @global

  @doc false
  def usages, do: @usages

  @doc "The flags a command takes from its definition, by name (`base_hash`), sorted."
  def takes(usage) do
    {command, only} = usage(usage)
    flags = @ops |> Map.fetch!(command) |> get_in(["cli", "flags"]) |> Map.keys()

    case only do
      nil -> Enum.sort(flags)
      only -> Enum.sort(only)
    end
  end

  defp usage(usage) do
    case @usages do
      %{^usage => {command, only}} -> {command, only}
      _ -> {usage, nil}
    end
  end

  @doc """
  `:ok` when every flag in `opts` is one `usage` takes, or a global one;
  else `{:error, message}`, naming the flags it does take.
  """
  def check(usage, opts) do
    allowed = takes(usage) ++ @global

    case opts |> Keyword.keys() |> Enum.map(&to_string/1) |> Enum.uniq() |> Kernel.--(allowed) do
      [] -> :ok
      extra -> {:error, refusal(usage, Enum.sort(extra))}
    end
  end

  defp refusal(usage, extra) do
    every = "--json and --url, as every command does"

    takes =
      case takes(usage) do
        [] -> "it takes only #{every}"
        flags -> "it takes #{Enum.map_join(flags, ", ", &flag/1)}, and #{every}"
      end

    "slipdock #{usage} does not take #{Enum.map_join(extra, ", ", &flag/1)}: #{takes}"
  end

  defp flag(name), do: "--" <> String.replace(name, "_", "-")

  @doc "Refuses (`fail/1`) a flag `usage` doesn't take; else `:ok`."
  def check!(usage, opts) do
    case check(usage, opts) do
      :ok -> :ok
      {:error, message} -> SlipdockCLI.Util.fail(message)
    end
  end

  @doc """
  The request a command makes: `{verb, path, body}`. Positional words fill
  the definition's `positional` params in order (a trailing `name...` takes
  the rest, joined by spaces); flags map onto params by the definition's
  `flags`. Path params go into the path, the rest into the body: for a GET,
  the query string (`HTTP.get/2`). `params` are the ones the command worked
  out itself, over the rest; a name the definition doesn't have raises.
  """
  def request(usage, words, opts, set \\ [], params \\ %{}) do
    {command, _} = usage(usage)
    op = Map.fetch!(@ops, command)
    opts = Keyword.merge(opts, set)

    params =
      positional(op["cli"]["positional"], words)
      |> Map.merge(flags(op["cli"]["flags"], opts))
      |> Map.merge(given(op, params))

    path =
      Enum.reduce(op["params"], op["path"], fn
        %{"in_path" => key, "name" => name}, path ->
          String.replace(path, ":" <> key, HTTP.seg(to_string(Map.fetch!(params, name))))

        _, path ->
          path
      end)

    body = Map.drop(params, for(%{"in_path" => _, "name" => n} <- op["params"], do: n))

    {op["verb"] |> String.downcase() |> String.to_atom(), String.replace_prefix(path, "/api", ""),
     body}
  end

  @doc """
  Makes the request: what `HTTP.<verb>` answers. `opts` are the flags as
  typed, refused unless `usage` takes them (`check!/2`); `set` are the flags'
  values the command worked out itself (a file read, a mode it is), not
  checked, and over `opts`.
  """
  def run(usage, words, opts, set \\ [], params \\ %{}) do
    check!(usage, opts)
    {verb, path, body} = request(usage, words, opts, set, params)
    apply(HTTP, verb, [path, body])
  end

  # The params a command worked out itself, each one its definition names:
  # a name it doesn't is this client and the server come apart.
  defp given(op, params) do
    names = Enum.map(op["params"], & &1["name"])

    case Map.keys(params) -- names do
      [] -> params
      extra -> raise ArgumentError, "#{op["name"]} has no param #{Enum.join(extra, ", ")}"
    end
  end

  defp positional(names, words) do
    {params, _} =
      Enum.reduce(names, {%{}, words}, fn
        _name, {acc, []} ->
          {acc, []}

        name, {acc, rest} ->
          if String.ends_with?(name, "...") do
            {Map.put(acc, String.trim_trailing(name, "..."), Enum.join(rest, " ")), []}
          else
            [word | rest] = rest
            {Map.put(acc, name, word), rest}
          end
      end)

    params
  end

  defp flags(flags, opts) do
    Enum.reduce(flags, %{}, fn
      # Read by the command, which sets the param's own flag to what it read.
      {_flag, %{"read" => _}}, acc ->
        acc

      {flag, spec}, acc ->
        case opts[String.to_atom(flag)] do
          nil -> acc
          false -> acc
          value -> Map.put(acc, spec["param"], Map.get(spec, "value", value))
        end
    end)
  end
end
