defmodule Slipdock.Boards.Wait do
  @moduledoc """
  Waiting on a person (#1114): what a card needs, who it waits on (a person,
  or anyone when `on_user_id` is nil), since when, and optionally a short
  list of answers to pick from. A card has at most one open wait.

      open → answered | withdrawn | card_completed | archived

  Unlike a handoff a wait has a lifecycle: it is opened, then closed once,
  by a conditional update on `closed_at IS NULL`, so of two answers racing
  one wins and the other is told who beat it. While it is open the card is
  flagged `waiting`; `set_flag` says whether the wait put the flag there,
  and so whether closing it takes the flag off again.

  Who opened it is kept as `Slipdock.Actor` has it (`kind`, `via`, `agent`
  label), with the runner job it was asked from when there is one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @reasons ~w(answered withdrawn card_completed archived)
  @requeue_states ~w(none queued pending failed skipped)
  @max_choices 10

  schema "card_waits" do
    field :needs, :string
    field :choices, {:array, :string}, default: []
    field :kind, :string
    field :via, :string
    field :agent, :string
    field :set_flag, :boolean, default: false
    field :closed_at, :utc_datetime
    field :close_reason, :string
    field :answer, :string
    field :choice, :integer
    field :requeue_state, :string, default: "none"
    field :requeue_note, :string

    belongs_to :card, Slipdock.Boards.Card
    belongs_to :on_user, Slipdock.Accounts.User
    belongs_to :opened_by, Slipdock.Accounts.User
    belongs_to :closed_by, Slipdock.Accounts.User
    belongs_to :job, Slipdock.Runners.Job
    # The fresh job the answer started (#1115).
    belongs_to :requeue_job, Slipdock.Runners.Job

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def close_reasons, do: @reasons
  def requeue_states, do: @requeue_states

  def changeset(wait, attrs) do
    wait
    |> cast(attrs, [:needs, :choices, :on_user_id, :job_id])
    |> update_change(:needs, &String.trim/1)
    |> update_change(:choices, &clean_choices/1)
    |> validate_required([:needs], message: "can't be blank: say what you need")
    |> validate_length(:needs, max: 1000)
    |> validate_length(:choices, max: @max_choices, message: "at most %{count}")
    |> validate_change(:choices, fn :choices, choices ->
      if Enum.any?(choices, &(String.length(&1) > 100)),
        do: [choices: "must each be at most 100 characters"],
        else: []
    end)
    |> unique_constraint(:card_id,
      name: :card_waits_one_open,
      message: "already has an open wait"
    )
  end

  @doc "Whether the wait is still open."
  def open?(%__MODULE__{closed_at: nil}), do: true
  def open?(_), do: false

  @doc "The text of choice `n` (counted from 1), or nil."
  def choice_text(%__MODULE__{choices: choices}, n) when is_integer(n) and n > 0,
    do: Enum.at(choices, n - 1)

  def choice_text(_, _), do: nil

  @doc "Who it waits on, in words: their name, or anyone."
  def on_name(%__MODULE__{on_user: %Slipdock.Accounts.User{} = u}),
    do: Slipdock.Accounts.User.display_name(u)

  def on_name(_), do: "anyone"

  defp clean_choices(choices) do
    choices
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
  end
end
