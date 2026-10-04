defmodule Slipdock.EgressStub do
  @moduledoc """
  DNS for tests (see `config/test.exs`): every name is a public address,
  except the few that exist to be refused.
  """

  @public {93, 184, 216, 34}

  def public, do: @public

  def resolve("intranet.test"), do: [{10, 0, 0, 5}]
  def resolve("tailnet.test"), do: [{100, 101, 102, 103}]
  def resolve("metadata.test"), do: [{169, 254, 169, 254}]
  # Half public, half not: one bad answer is enough to refuse it.
  def resolve("split.test"), do: [@public, {127, 0, 0, 1}]
  def resolve("nowhere.test"), do: []
  def resolve(_host), do: [@public]
end
