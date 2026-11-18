defmodule SlipdockWeb.Ops.AddCard do
  @moduledoc """
  A new card on a board, `POST /api/boards/:board/cards`, defined once
  (#3361): the REST action and the CLI's `add`. The MCP tool `create_card`
  also makes subcards (`parent`, making the sub-board) and can put the card
  at the top, so it stays hand-composed (SPEC-4), and takes each param it
  shares with this from here (`SlipdockWeb.Ops.params_from/2`).

  Its params are every key `CardWrites.create/3` reads: a field a new card
  doesn't have is refused (422, naming the ones it does), as the route has
  always refused one. A field's schema is `edit_card`'s, but where a new
  card reads it otherwise.
  """
  @behaviour SlipdockWeb.Ops.Op

  alias SlipdockWeb.API.{Authorize, CardWrites}
  alias SlipdockWeb.Ops.EditCard
  import SlipdockWeb.Ops.Shared, only: [card_json: 2]

  # Where a new card reads a field otherwise than an edit does.
  defp own do
    %{
      "short_name" => %{
        type: "string",
        description: "At most 40 characters, for tight spaces. Made for you if left out."
      },
      "description" => %{type: "string", description: "Markdown: the brief."},
      "start_date" => %{type: "string", description: "YYYY-MM-DD."},
      "due_date" => %{type: "string", description: "YYYY-MM-DD."},
      "column" => %{
        type: "string",
        description:
          "List name or id. Left out: REST and the CLI put it in the board's first list, " <>
            "create_card in its ready list."
      },
      "tags" => %{
        type: "array",
        items: %{type: "string"},
        description: "Tag names already on the board (get_board lists them; create_tag adds one)."
      },
      "assignees" => %{
        type: "array",
        items: %{type: "string"},
        description: "Emails; \"me\" for yourself."
      },
      "archived" => %{
        type: "boolean",
        description: "File it away as soon as it is made, e.g. a record of finished work."
      },
      # Where it came from (#2778): the server records it; a job may only
      # name the generator it is running.
      "origin" => %{
        type: "string",
        enum: Slipdock.Origin.claimable(),
        description:
          "Only inside a runner job, to name the generator filing it (the sweep, findings " <>
            "triage). Leave it out otherwise: the server records who made the card."
      }
    }
  end

  @doc "The body params, `{name, schema}`: every key a new card takes."
  def body do
    own = own()
    edit = Map.new(EditCard.body())

    for name <- CardWrites.create_keys(),
        do: {name, Map.get(own, name) || Map.fetch!(edit, name)}
  end

  @impl true
  def definition do
    %{
      name: "add_card",
      title: "Add a card",
      summary: "Adds a card to a board, with any of the fields edit_card changes.",
      verb: :post,
      path: "/api/boards/:board/cards",
      permission: {:board, :write},
      writes?: true,
      status: :created,
      params:
        [
          %{
            name: "board",
            type: :string,
            required: true,
            in_path: "board",
            doc: "Board id, code or name."
          }
        ] ++ for({name, schema} <- body(), do: %{name: name, type: :any, schema: schema}),
      cli: %{
        command: "add",
        positional: ["board", "title..."],
        flags: %{
          "short_name" => %{param: "short_name"},
          "column" => %{param: "column"},
          "desc" => %{param: "description", read: :stdin},
          "bar" => %{param: "bar", read: :stdin},
          "priority" => %{param: "priority"},
          "flag" => %{param: "flags", read: :parsed},
          "tag" => %{param: "tags", read: :parsed},
          "start" => %{param: "start_date"},
          "due" => %{param: "due_date"},
          "percent" => %{param: "percent_complete"},
          "paths" => %{param: "paths"},
          "profile" => %{param: "profile"},
          "caused_by" => %{param: "caused_by"},
          "missed_by" => %{param: "missed_by"},
          "origin" => %{param: "origin"},
          "spent" => %{param: "time_spent"},
          "estimate" => %{param: "time_estimate"},
          "unit" => %{param: "time_unit"},
          "color" => %{param: "color"},
          "archived" => %{param: "archived", value: true},
          "assignee" => %{param: "assignees", read: :parsed},
          "border" => %{param: "border_top", read: :parsed},
          "no_border" => %{param: "border_top", read: :parsed},
          "border_top" => %{param: "border_top", read: :parsed},
          "border_right" => %{param: "border_right", read: :parsed},
          "border_bottom" => %{param: "border_bottom", read: :parsed},
          "border_left" => %{param: "border_left", read: :parsed}
        }
      }
    }
  end

  @impl true
  def run(%{"board" => ref} = params, auth) do
    with {:ok, board} <- Authorize.fetch_board(auth, ref, :write),
         {:ok, card} <- CardWrites.create(auth, board, Map.delete(params, "board")) do
      {:ok, %{card: card_json(auth, card)}}
    end
  end
end
