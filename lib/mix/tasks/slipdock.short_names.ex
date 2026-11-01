defmodule Mix.Tasks.Slipdock.ShortNames do
  @shortdoc "Gives long-titled cards a short name"
  @moduledoc """
  Gives every long-titled card with no short name one
  (`Slipdock.Boards.ShortNames.backfill/1`). Safe to run again, and with no
  AI key: the systematic name stands then.

      mix slipdock.short_names [--no-model]
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [model: :boolean])
    Mix.Task.run("app.start")

    %{named: named, by_model: by_model} = Slipdock.Boards.ShortNames.backfill(opts)
    Mix.shell().info("#{named} cards named, #{by_model} of them by the model")
  end
end
