defmodule Slipdock.Machines.TrustContract do
  @moduledoc """
  The trust contract (W-2544 §9): what a Slipdock server can and cannot make
  a machine running the runner daemon do, and what nothing here bounds.

  There is one text, `daemon/internal/contract/contract.md`. The daemon embeds
  it (Go's `embed` reaches only files inside its module, so it lives there)
  and `slipdock-runner show` prints it after the machine's own limits; this
  module reads the same file at compile time, for the Machines page, the
  agents help page and the API guide. The manual carries a copy between
  `copy_start/0` and `copy_end/0`, held equal to it by
  `test/slipdock/trust_contract_test.exs`.

  The production image copies the file into the build before `mix compile`
  (`Dockerfile`); without it this module doesn't compile.
  """

  @source "daemon/internal/contract/contract.md"
  @path Path.expand("../../../" <> @source, __DIR__)
  @external_resource @path
  @text File.read!(@path)

  @doc "The contract, in Markdown."
  @spec markdown() :: String.t()
  def markdown, do: @text

  @doc "Where the one text lives, from the repository's root."
  @spec source() :: String.t()
  def source, do: @source

  @doc "The line that opens a copy of the contract in a Markdown document."
  def copy_start, do: "<!-- trust-contract: a copy of #{@source}; edit that, then this -->"

  @doc "The line that closes it."
  def copy_end, do: "<!-- /trust-contract -->"

  @doc """
  The copy of the contract in a Markdown document, between `copy_start/0` and
  `copy_end/0`: `{:ok, copy}`, or `:error` when the document has no copy (or
  more than one).
  """
  @spec copy_in(String.t()) :: {:ok, String.t()} | :error
  def copy_in(document) do
    with [_, rest] <- String.split(document, copy_start() <> "\n"),
         [copy, _] <- String.split(rest, "\n" <> copy_end()) do
      {:ok, copy}
    else
      _ -> :error
    end
  end

  @doc "Whether the document carries the contract as it is now, word for word."
  @spec carried?(String.t()) :: boolean
  def carried?(document) do
    case copy_in(document) do
      {:ok, copy} -> String.trim(copy) == String.trim(@text)
      :error -> false
    end
  end
end
