defmodule SlipdockWeb.Ops.NewBoard do
  @moduledoc """
  A new board of the caller's own, `POST /api/boards`, defined once (#3361):
  the REST action and the CLI's `new-board`. The MCP tool `create_board`
  answers the board's summary and link rather than the whole board, so it
  stays hand-composed (SPEC-4), and takes each param it shares with this
  from here (`SlipdockWeb.Ops.params_from/2`).

  Two things it settled between the surfaces:

    * the board's own lists are `lists` everywhere, as MCP and the CLI's
      `--list` called them; REST's `columns` is still taken, as the old name
    * a token confined to some boards may not make one on any surface (it
      could not reach the board it made), as MCP refused it: REST let it
  """
  @behaviour SlipdockWeb.Ops.Op

  alias Slipdock.Boards
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  @lists %{
    type: "array",
    items: %{type: "string"},
    description:
      "The board's own list names, in order, instead of a template's. Names like " <>
        "To Do, In Progress and Done are given those roles. REST and the CLI also take " <>
        "{name, wip_limit, color} for one."
  }

  @doc "The body params, `{name, schema}`."
  def body do
    [
      {"name", %{type: "string"}},
      {"code", %{type: "string", description: "Short slug; made from the name if left out."}},
      {"shortcut", %{type: "string", description: "A key to open it with in the web app."}},
      {"description", %{type: "string"}},
      {"color", %{type: "string", description: "A palette colour."}},
      {"kind", %{type: "string", description: "sprints, or left out for none."}},
      {"simple", %{type: "boolean", description: "A plain to-do list."}},
      {"template", %{type: "string", description: "Template name or id for its lists."}},
      {"lists", @lists},
      {"columns", %{@lists | description: "The old name for lists, still taken."}},
      {"save_template",
       %{
         type: "string",
         description:
           "Also keep the board's lists as a template with this name (REST also takes " <>
             "true, for the board's own name)."
       }}
    ]
  end

  @impl true
  def definition do
    %{
      name: "new_board",
      title: "Create a board",
      summary: "Creates a board of your own, with a template's lists or lists of its own.",
      verb: :post,
      path: "/api/boards",
      permission: :unconfined,
      writes?: true,
      status: :created,
      params:
        for({name, schema} <- body(), do: %{name: name, type: :any, schema: schema})
        |> Enum.map(&if(&1.name == "name", do: Map.put(&1, :required, true), else: &1)),
      cli: %{
        command: "new-board",
        positional: ["name..."],
        flags: %{
          "code" => %{param: "code"},
          "shortcut" => %{param: "shortcut"},
          "desc" => %{param: "description", read: :stdin},
          "color" => %{param: "color"},
          "template" => %{param: "template"},
          # Repeatable: `Name[:wip[:color]]`, worked out by the CLI.
          "list" => %{param: "lists", read: :parsed},
          "save_template" => %{param: "save_template"}
        }
      }
    }
  end

  @impl true
  def run(params, auth) do
    user = auth.assigns.current_user

    with :ok <- Authorize.unconfined(auth, "create boards"),
         {:ok, template} <- template(user, params["template"]),
         {:ok, board} <-
           Boards.create_board(
             Map.take(params, ~w(name code shortcut description color kind simple)),
             template: template,
             owner_id: user.id,
             columns: params["lists"] || params["columns"],
             save_template: save_template(params["save_template"])
           ) do
      {:ok, %{board: V.board(Authorize.visible(auth, Boards.get_board!(board.id)))}}
    end
  end

  defp template(_user, blank) when blank in [nil, ""], do: {:ok, nil}

  defp template(user, ref) do
    case Boards.Templates.find_template(user, ref) do
      {:ok, t} -> {:ok, t}
      _ -> {:error, :not_found, "template"}
    end
  end

  # `save_template` names the template the new board's lists are kept as;
  # `true` keeps them under the board's own name.
  defp save_template(value) when value in [nil, "", false, "false"], do: nil
  defp save_template(value) when value in [true, "true"], do: true
  defp save_template(name), do: to_string(name)
end
