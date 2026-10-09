defmodule SlipdockCLI.Meetings do
  @moduledoc false

  # `slipdock meetings` and `slipdock capture …`: meeting capture, which an
  # admin turns on per server. While it is off the server answers 404 with
  # "meeting mode is off on this server", and that sentence is what is printed.

  import SlipdockCLI.Util

  alias SlipdockCLI.HTTP

  @commands ~w(meetings)

  @doc "The command names this module answers to; `SlipdockCLI` routes on it."
  def commands, do: @commands

  def run("meetings", [], o), do: HTTP.get("/meetings") |> out(o, &render_mode/1)
  def run(cmd, _args, _o), do: bad_usage(cmd)

  defp render_mode(%{"meetings" => m}) do
    where =
      case m["visibility"] do
        "every_board" -> "on every board"
        _ -> "on boards that have had a capture (elsewhere, in the board's … menu)"
      end

    IO.puts("""
    Meeting mode: on
    Shown:        #{where}
    Hideable:     #{if m["hideable"], do: "yes#{if m["hidden"], do: " (you have hidden it)"}", else: "no"}\
    """)
  end
end
