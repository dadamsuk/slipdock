defmodule Slipdock.Inbound.Email do
  @moduledoc """
  One message the inbound endpoint has decided about: a row of
  `inbound_emails`. Unique on `(message_id, recipient)`, which is what makes a
  repeated delivery a no-op. `user` is whose log it shows in: the account the
  address belongs to once that is known, else the account the sender claims
  to be. `card`, `page` and `comment` are whatever it created.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @outcomes ~w(accepted rejected)
  @kinds ~w(card page add reply unknown)

  schema "inbound_emails" do
    field :message_id, :string
    field :recipient, :string
    field :sender, :string
    field :subject, :string
    field :kind, :string
    field :outcome, :string
    field :reason, :string
    field :size, :integer, default: 0
    belongs_to :user, Slipdock.Accounts.User
    belongs_to :card, Slipdock.Boards.Card
    belongs_to :page, Slipdock.Wiki.Page
    belongs_to :comment, Slipdock.Boards.Comment
    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(email, attrs) do
    email
    |> cast(attrs, [
      :message_id,
      :recipient,
      :sender,
      :subject,
      :kind,
      :outcome,
      :reason,
      :size,
      :user_id,
      :card_id,
      :page_id,
      :comment_id
    ])
    |> validate_required([:message_id, :recipient, :kind, :outcome])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_inclusion(:kind, @kinds)
    |> update_change(:subject, &truncate(&1, 500))
    |> update_change(:sender, &truncate(&1, 320))
    |> update_change(:reason, &truncate(&1, 500))
    |> update_change(:message_id, &truncate(&1, 998))
    |> unique_constraint([:message_id, :recipient])
  end

  defp truncate(nil, _), do: nil
  defp truncate(value, max), do: String.slice(value, 0, max)
end
