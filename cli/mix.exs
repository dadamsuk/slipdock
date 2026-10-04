defmodule SlipdockCLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :slipdock_cli,
      version: "0.1.0",
      elixir: "~> 1.17",
      escript: [main_module: SlipdockCLI, name: "slipdock"],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: []
    ]
  end

  def application, do: [extra_applications: [:inets, :ssl]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
