defmodule Slipdock.Findings.Finding do
  @moduledoc """
  One thing a pass learned, or the system saw go wrong (see `Slipdock.Findings`).

    * `board` – the root board of the tree it was found in
    * `card`, `comment`, `job` – where it came from, whichever apply
    * `kind` – `gotcha`, `rule` (a rule candidate), `handbook-wrong`, `tooling`
      or `process`
    * `source` – who noticed: `agent` (a `Findings:` block in a comment), or the
      system's own signals: `rejection`, `requeue`, `timeout`, `lane`, `merge`,
      `audit`, `health`
    * `status` – `open` until triaged: `promoted` (it became a handbook rule or
      section, said in `note`), `dismissed`, or `merged` into another finding
      (`merged_into`, which takes its count)
    * `cause` – for the system's findings, what repeats are matched on: the same
      card, source and cause adds to `count` rather than making another
    * `by` – who recorded it, in words; `user` when a person's account wrote it
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(gotcha rule handbook-wrong tooling process)
  @sources ~w(agent rejection requeue timeout lane merge audit health)
  @statuses ~w(open promoted dismissed merged)
  @max_text_len 2000

  schema "findings" do
    field :kind, :string
    field :source, :string
    field :status, :string, default: "open"
    field :text, :string
    field :cause, :string
    field :by, :string
    field :note, :string
    field :count, :integer, default: 1

    belongs_to :board, Slipdock.Boards.Board
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :comment, Slipdock.Boards.Comment
    belongs_to :job, Slipdock.Runners.Job
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :merged_into, __MODULE__

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def sources, do: @sources
  def statuses, do: @statuses

  @doc "The most a finding's text keeps."
  def max_text, do: @max_text_len

  @doc """
  A new finding. Where it came from (`board_id`, `card_id`, `comment_id`,
  `job_id`, `user_id`) is set by `Slipdock.Findings` on the struct, never cast.
  """
  def changeset(finding, attrs) do
    finding
    |> cast(attrs, [:kind, :source, :text, :cause, :by])
    |> update_change(:text, &cut/1)
    |> validate_required([:board_id, :kind, :source, :text])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:cause, max: 255)
    |> validate_length(:by, max: 255)
  end

  @doc "A status change: `status` and `note`; `merged_into` is given by `Slipdock.Findings`."
  def triage_changeset(finding, attrs, merged_into_id \\ nil) do
    finding
    |> change(merged_into_id: merged_into_id)
    |> cast(attrs, [:status, :note])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:note, max: 2000)
  end

  defp cut(nil), do: nil
  defp cut(text), do: text |> String.trim() |> String.slice(0, @max_text_len)
end
