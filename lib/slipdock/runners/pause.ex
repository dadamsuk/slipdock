defmodule Slipdock.Runners.Pause do
  @moduledoc """
  The brake (#1116, KTD10): a board tree, or one runner pool on it, held by
  its owner with a reason. While a pause is open no job of its scope is
  claimed and no `list_top` rule on the tree sends a card; jobs still queue,
  and the ones already running finish as they would have.

  Kept on the root board: a pool is only a string the whole tree shares, so
  a pause asked for on a sub-board is the tree's. `pool` nil is the whole
  tree. At most one open pause per tree and pool (`runner_pauses_one_open`);
  resuming closes it, and a resume releases exactly the scope it names.

  Anyone the board's owner can pause, agents included (a brake should be
  easy to pull). Resuming is a person's (see `Slipdock.Runners.resume/3`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "runner_pauses" do
    field :pool, :string
    field :reason, :string
    # The token's label when an agent pulled it, as `Slipdock.Actor` has it.
    field :agent, :string
    field :resumed_at, :utc_datetime

    belongs_to :root_board, Slipdock.Boards.Board
    belongs_to :paused_by, Slipdock.Accounts.User
    belongs_to :resumed_by, Slipdock.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @max_reason 500

  def changeset(pause, attrs) do
    pause
    |> cast(attrs, [:pool, :reason])
    |> update_change(:reason, &String.trim/1)
    |> update_change(:pool, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:reason], message: "can't be blank: say why it is paused")
    |> validate_length(:reason, max: @max_reason)
    |> validate_format(:pool, Slipdock.Runners.Runner.name_format(),
      message: "must be lower case letters, digits, - or _"
    )
    |> unique_constraint([:root_board_id],
      name: :runner_pauses_one_open,
      message: "is already paused"
    )
  end

  @doc "What it holds, in words: `\"pool dev\"` or `\"the whole tree\"`."
  def scope(%__MODULE__{pool: nil}), do: "the whole tree"
  def scope(%__MODULE__{pool: pool}), do: "pool #{pool}"

  @doc "The held line: `\"paused by David: bad deploy\"`."
  def line(%__MODULE__{} = pause), do: "paused by #{who(pause)}: #{pause.reason}"

  @doc "Who paused it: the person's name, or the agent's label on their token."
  def who(%__MODULE__{} = pause) do
    name =
      case pause.paused_by do
        %{name: name} when is_binary(name) and name != "" -> name
        %{email: email} when is_binary(email) -> email
        _ -> "someone"
      end

    if pause.agent, do: "#{name} (#{pause.agent})", else: name
  end
end
