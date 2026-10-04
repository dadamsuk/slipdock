defmodule Slipdock.Email do
  @moduledoc """
  What counts as an email address here, and the one form it is stored and
  compared in. Every address a person types goes through `normalize/1`
  before it is looked up or saved, so `Ann@Example.com ` and
  `ann@example.com` are the same account.
  """

  @doc "Trimmed and lower-cased. Anything that isn't a string is left alone."
  def normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()
  def normalize(other), do: other

  @doc "Whether `address` looks enough like an email address to send to."
  def valid?(address) when is_binary(address), do: address =~ format()
  def valid?(_), do: false

  @doc "The shape of an address: something, an @, a domain with a dot in it."
  def format, do: ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/

  @doc "`Ecto.Changeset.validate_format/4` for an address field, with the usual message."
  def validate(changeset, field) do
    Ecto.Changeset.validate_format(changeset, field, format(),
      message: "must be a valid email address"
    )
  end
end
