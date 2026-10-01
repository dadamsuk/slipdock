defmodule Slipdock.SavedQueries.SavedQuery do
  @moduledoc """
  One question a person wants to ask again: the text, and which mode of the
  search page it belongs to.

  Deliberately just the text. An answer is a snapshot of a Tuesday; the
  question is the thing with a life longer than one sitting.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @modes ~w(search ask)
  @max_length 300

  schema "saved_queries" do
    field :mode, :string
    field :text, :string

    belongs_to :user, Slipdock.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The modes a query can be saved under."
  def modes, do: @modes

  @doc "The longest a saved query may be."
  def max_length, do: @max_length

  def changeset(query, attrs) do
    query
    |> cast(attrs, [:user_id, :mode, :text])
    |> update_change(:text, &String.trim/1)
    |> validate_required([:user_id, :mode, :text])
    |> validate_inclusion(:mode, @modes)
    |> validate_length(:text, min: 1, max: @max_length)
    |> unique_constraint([:user_id, :mode, :text],
      message: "is already saved",
      name: :saved_queries_user_id_mode_text_index
    )
  end
end
