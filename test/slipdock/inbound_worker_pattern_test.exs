defmodule Slipdock.InboundWorkerPatternTest do
  @moduledoc """
  The Cloudflare Worker checks each address against its own copy of the
  app's pattern (`LOCAL_PART` in `cloudflare/inbound-email/worker.js`) and
  bounces anything outside it with "No such address here." before the app
  sees it (#1937). The two languages can't share the pattern, so this holds
  the Worker's to `Slipdock.Inbound.kinds/0` and `token_class/0`.
  """
  use ExUnit.Case, async: true

  alias Slipdock.Inbound

  @worker Path.expand("../../cloudflare/inbound-email/worker.js", __DIR__)

  @doc false
  # The Worker's pattern as `{kinds, token_class}`, or :error when its
  # `LOCAL_PART` line isn't there or isn't in the shape this reads.
  def worker_pattern(source) do
    case Regex.run(~r{^const LOCAL_PART = /\^\(([a-z|]+)\)-(\[[^\]]+\])\+\$/$}m, source) do
      [_, kinds, class] -> {String.split(kinds, "|"), class}
      nil -> :error
    end
  end

  @doc false
  # The differences between the app's pattern and the Worker's, [] when they agree.
  def disagreements({kinds, class}, {worker_kinds, worker_class}) do
    [
      for(k <- kinds -- worker_kinds, do: "the Worker rejects #{k}- addresses"),
      for(k <- worker_kinds -- kinds, do: "the Worker accepts #{k}- addresses the app doesn't"),
      if(class != worker_class,
        do: ["token class: app #{class}, Worker #{worker_class}"],
        else: []
      )
    ]
    |> List.flatten()
  end

  defp app, do: {Inbound.kinds(), Inbound.token_class()}

  defp worker do
    pattern = worker_pattern(File.read!(@worker))
    assert pattern != :error, "no `const LOCAL_PART = /^(a|b)-[x]+$/` line in #{@worker}"
    pattern
  end

  test "the Worker's LOCAL_PART has the app's kinds and token class" do
    assert disagreements(app(), worker()) == [],
           "cloudflare/inbound-email/worker.js LOCAL_PART and Slipdock.Inbound disagree: " <>
             Enum.join(disagreements(app(), worker()), "; ")
  end

  test "the app's pattern is built from its kinds" do
    for kind <- Inbound.kinds(), do: assert(Inbound.address("#{kind}-abc9@x") == {kind, "abc9"})
    assert Inbound.address("folder-abc@x") == {"unknown", nil}
    assert Inbound.address("card-ABC@x") == {"unknown", nil}
  end

  describe "the check" do
    test "fails when the app gains a kind the Worker hasn't" do
      {kinds, class} = worker()

      assert disagreements({kinds ++ ["folder"], class}, worker()) ==
               ["the Worker rejects folder- addresses"]
    end

    test "fails when the Worker gains a kind the app hasn't" do
      source =
        String.replace(File.read!(@worker), "(card|page|add|reply)", "(card|page|add|reply|note)")

      assert disagreements(app(), worker_pattern(source)) ==
               ["the Worker accepts note- addresses the app doesn't"]
    end

    test "fails when the token class differs" do
      source = String.replace(File.read!(@worker), "-[a-z0-9]+$/", "-[a-z0-9_]+$/")

      assert disagreements(app(), worker_pattern(source)) ==
               ["token class: app [a-z0-9], Worker [a-z0-9_]"]
    end

    test "ignores the order of the kinds" do
      {kinds, class} = worker()
      assert disagreements({Enum.reverse(kinds), class}, worker()) == []
    end

    test "can't read a pattern in another shape" do
      assert worker_pattern("const LOCAL_PART = new RegExp(KINDS)") == :error
      assert worker_pattern("") == :error
    end
  end
end
