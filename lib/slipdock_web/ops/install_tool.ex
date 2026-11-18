defmodule SlipdockWeb.Ops.InstallTool do
  @moduledoc """
  Installing a Tool's board (#961), defined once (#3188): the server builds
  the lists, folders, tags, page skeletons and rules from the Tool's
  blueprint; installing again adds what a newer version brings, or answers
  the board already made. The built-in handbook (#1262) and code sweep
  (#1793) go onto a board that exists instead, named by `board`.

  Before it, REST answered `{install}` (201 when the board is new) and MCP
  the install bare; MCP called the new board's name `board_name`, REST
  `name`. Now both answer `{install}` and take `name` (MCP refuses
  `board_name`, naming the arguments it takes). A refusal is REST's on
  both: a Tool or version not there is a 404, a token confined to some
  boards a 403, the handbook or sweep without a board a 422.
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [base_url: 1]

  alias Slipdock.Tools
  alias SlipdockWeb.API.{Authorize, ToolJSON}

  @impl true
  def definition do
    %{
      name: "install_tool",
      title: "Install a Tool's board",
      summary:
        "Builds the board a Tool (see list_tools) comes with and returns its code. " <>
          "Already installed, it adds what a newer version brings without touching edited " <>
          "pages. tool: \"handbook\" or tool: \"sweep\" with board installs that on its " <>
          "root instead.",
      verb: :post,
      path: "/api/tools/:slug/install",
      permission: {:tool, :read},
      writes?: true,
      # A new board is made (201); one already there is not.
      status: &if(&1.install.created, do: :created, else: :ok),
      params: [
        %{
          name: "tool",
          type: :string,
          required: true,
          in_path: "slug",
          doc: "The Tool's name, as list_tools gives it."
        },
        %{name: "version", type: :string, doc: "A version other than the latest."},
        %{name: "name", type: :string, doc: "The new board's name; the Tool's title otherwise."},
        %{
          name: "board",
          type: :string,
          doc:
            "For the handbook (W-1934) or the sweep (W-2310: its rotation page, a Triage list " <>
              "and a weekly Sweep the code card): the board (id, code or name) to install it " <>
              "on; it goes on the root."
        }
      ],
      cli: %{
        command: "tools install-board",
        positional: ["tool"],
        flags: %{
          "version" => %{param: "version"},
          "name" => %{param: "name"},
          "board" => %{param: "board"}
        }
      }
    }
  end

  @impl true
  def run(%{"tool" => ref} = params, auth) do
    user = auth.assigns.current_user

    with {:ok, result} <-
           (case on_board(ref, params["board"], user) do
              nil -> install_tool(params, ref, user, auth)
              mod -> install_on_board(mod, params["board"], auth)
            end) do
      {:ok, %{install: ToolJSON.install(result, base_url(auth))}}
    end
  end

  # The built-in Tools that go onto a board that exists: the handbook
  # (#1262) and the code sweep (#1793). Named without a board, a published
  # Tool of the same name is the one meant.
  defp on_board(ref, board, user) do
    mod = Enum.find([Slipdock.Handbook, Slipdock.Sweep], & &1.tool?(ref))
    if mod && (board || not match?({:ok, _}, Tools.fetch(user, ref))), do: mod
  end

  defp install_on_board(mod, nil, _auth),
    do:
      {:error, :unprocessable_entity,
       "the #{mod.name()} installs onto a board: give board (id, code or name)"}

  defp install_on_board(mod, ref, auth) do
    with {:ok, board} <- Authorize.fetch_board(auth, ref, :write) do
      case mod.install(auth.assigns.current_user, board) do
        {:ok, result} -> {:ok, result}
        {:error, message} -> {:error, :unprocessable_entity, message}
      end
    end
  end

  defp install_tool(params, ref, user, auth) do
    with :ok <- unscoped(auth.assigns[:api_token]),
         {:ok, tool} <- fetch(user, ref) do
      case Tools.install_board(user, tool, version: params["version"], name: params["name"]) do
        {:ok, result} ->
          {:ok, result}

        {:error, :not_found} ->
          {:error, :not_found, "version #{params["version"]} of Tool #{inspect(ref)}"}

        {:error, message} when is_binary(message) ->
          {:error, :unprocessable_entity, message}

        other ->
          other
      end
    end
  end

  defp unscoped(%{scope_boards: [_ | _]}),
    do: {:error, :forbidden, "this token is confined to some boards, so it can't make one"}

  defp unscoped(_), do: :ok

  defp fetch(user, ref) do
    case Tools.fetch(user, ref) do
      {:ok, tool} -> {:ok, tool}
      _ -> {:error, :not_found, "Tool #{inspect(ref)}"}
    end
  end
end
