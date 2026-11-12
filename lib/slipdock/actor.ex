defmodule Slipdock.Actor do
  @moduledoc """
  Who made a change, and through which door: the small map a card move
  carries to its choke points (`Slipdock.Boards.Cards.move_card/4` and friends), so
  a move can be told apart as a person's, an agent's or an automation's.

      %{kind: "human" | "agent" | "automation" | nil,
        via: "web" | "cli" | "mcp" | "api" | "runner" | "assistant" | "automation" | "email" | nil,
        user_id: integer | nil, agent: token label | nil, job_id: integer | nil}

  How a request is classified:

    * the web UI is a person;
    * the CLI is a person, unless it says `x-slipdock-agent` (it does when it
      runs under Claude Code or a runner job, see `SlipdockCli.HTTP`);
    * MCP, a runner job and the in-app assistant are agents;
    * REST with a token and no CLI header is an agent: a script, not a person;
    * rules, Recovery, snooze wake and gardener steps are automation.

  A move given no actor is automation while an automation rule is running
  (`Process.get(:automation_depth)`), else unknown — visible as unknown
  rather than misfiled.
  """

  alias Slipdock.Accounts.User

  @kinds ~w(human agent automation)
  @vias ~w(web cli mcp api runner assistant automation email)

  @doc "The kinds an actor can be classified as."
  def kinds, do: @kinds

  @doc "The doors a change can arrive through."
  def vias, do: @vias

  @doc "A person in the web UI."
  def web(user), do: build("human", "web", user)

  @doc "An agent over MCP, under its token's label."
  def mcp(%{user: user} = context) do
    build("agent", "mcp", user, label(context[:token]), context[:job_id])
  end

  @doc "A person who emailed it in (#1247): `Slipdock.Inbound`."
  def email(user), do: build("human", "email", user)

  @doc "The in-app assistant, acting for `user`."
  def assistant(user), do: build("agent", "assistant", user)

  @doc "A runner job's agent."
  def runner(user, job_id, label \\ nil), do: build("agent", "runner", user, label, job_id)

  @doc "A rule, Recovery, snooze wake or a gardener step."
  def automation, do: build("automation", "automation", nil)

  @doc "Nobody said who."
  def unknown, do: %{kind: nil, via: nil, user_id: nil, agent: nil, job_id: nil}

  ## The process's actor (#1735) ---------------------------------------------
  #
  # Every write a process makes is someone's: the person behind a LiveView,
  # the token behind a request, the sender of an email. The activity log
  # reads it from here rather than from every function's opts, the way
  # `SlipdockWeb.Dates` keeps the reader's timezone.

  @current {__MODULE__, :current}
  @rule {__MODULE__, :rule}

  @doc """
  Sets who this process's writes are by: an actor from the builders above,
  with the name to show for it when it is a person (a snapshot, so a deleted
  user's entries still name them). `nil` clears it.
  """
  def put(actor, name \\ nil)
  def put(nil, _name), do: Process.delete(@current)
  def put(%{kind: _} = actor, name), do: Process.put(@current, Map.put(actor, :name, name))

  @doc """
  Who this process's writes are by: the automation rule while one is firing
  (`Slipdock.Automations`), else what `put/2` was given, else `unknown/0`.
  """
  def current do
    if Process.get(:automation_depth, 0) > 0 do
      Map.put(automation(), :name, Process.get(@rule))
    else
      Process.get(@current) || unknown()
    end
  end

  @doc """
  Runs `fun` as the automation rule `name`, so `current/0` names it. The
  caller keeps `:automation_depth` itself (`Slipdock.Automations.fire/3`).
  """
  def as_rule(name, fun) do
    previous = Process.get(@rule)
    Process.put(@rule, name)

    try do
      fun.()
    after
      if previous, do: Process.put(@rule, previous), else: Process.delete(@rule)
    end
  end

  @doc """
  The actor for an HTTP request, or anything shaped like one (`assigns` with
  `current_user` and `api_token`, and optionally an `actor` already worked
  out — which is what MCP's tools hand `SlipdockWeb.API.CardWrites`).
  """
  def from_conn(%{assigns: %{actor: %{} = actor}}), do: actor

  def from_conn(%{assigns: assigns} = conn) do
    user = assigns[:current_user]
    token = assigns[:api_token]
    client = header(conn, "x-slipdock-client") || header(conn, "x-kanban-client")
    agent? = not Enum.member?([nil, "", "0", "false"], header(conn, "x-slipdock-agent"))
    job_id = conn |> header("x-slipdock-job") |> parse_id()

    cond do
      is_nil(token) -> web(user)
      client == "cli" and not agent? -> build("human", "cli", user, label(token))
      client == "cli" -> build("agent", "cli", user, label(token), job_id)
      true -> build("agent", "api", user, label(token), job_id)
    end
  end

  @doc """
  The actor a move's `opts` name: `opts[:actor]` as given, or one built from
  `:by`, `:via`, `:agent` and `:job_id` (mirroring `update_card/3`'s
  `opts[:by]`), else the fallback described in the moduledoc.
  """
  def resolve(opts) when is_list(opts) do
    cond do
      match?(%{kind: _}, opts[:actor]) ->
        opts[:actor]

      opts[:via] ->
        build(
          classify(opts[:via], opts[:kind]),
          opts[:via],
          opts[:by],
          opts[:agent],
          opts[:job_id]
        )

      Process.get(:automation_depth, 0) > 0 ->
        automation()

      true ->
        unknown()
    end
  end

  # A door's default kind, for `opts` that name a door but not a kind.
  defp classify(_via, kind) when kind in @kinds, do: kind
  defp classify(via, _) when via in ~w(web cli email), do: "human"
  defp classify("automation", _), do: "automation"
  defp classify(_via, _), do: "agent"

  defp build(kind, via, user, agent \\ nil, job_id \\ nil) do
    %{kind: kind, via: via, user_id: user_id(user), agent: agent, job_id: job_id}
  end

  defp user_id(%User{id: id}), do: id
  defp user_id(id) when is_integer(id), do: id
  defp user_id(_), do: nil

  defp label(%{label: label}), do: label
  defp label(_), do: nil

  defp header(%Plug.Conn{} = conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp header(_, _), do: nil

  defp parse_id(nil), do: nil

  defp parse_id(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end
end
