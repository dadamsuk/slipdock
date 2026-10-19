defmodule Slipdock.Actor do
  @moduledoc """
  Who made a change, and through which door: the small map a card move
  carries to its choke points (`Slipdock.Boards.move_card/4` and friends), so
  a move can be told apart as a person's, an agent's or an automation's.

      %{kind: "human" | "agent" | "automation" | nil,
        via: "web" | "cli" | "mcp" | "api" | "runner" | "assistant" | "automation" | nil,
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
  @vias ~w(web cli mcp api runner assistant automation)

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

  @doc "The in-app assistant, acting for `user`."
  def assistant(user), do: build("agent", "assistant", user)

  @doc "A runner job's agent."
  def runner(user, job_id, label \\ nil), do: build("agent", "runner", user, label, job_id)

  @doc "A rule, Recovery, snooze wake or a gardener step."
  def automation, do: build("automation", "automation", nil)

  @doc "Nobody said who."
  def unknown, do: %{kind: nil, via: nil, user_id: nil, agent: nil, job_id: nil}

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
    agent? = header(conn, "x-slipdock-agent") not in [nil, "", "0", "false"]
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
  defp classify(via, _) when via in ~w(web cli), do: "human"
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
