defmodule SlipdockCLI.RenderTemplatesTest do
  @moduledoc "`slipdock templates`: built-ins are told apart from one's own (#856)."
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SlipdockCLI.Render

  defp template(id, name, system) do
    %{"id" => id, "name" => name, "system" => system, "columns" => [%{"name" => "Done"}]}
  end

  test "each template says whether it is built in or the caller's" do
    out =
      capture_io(fn ->
        Render.templates([template(1, "Simple", true), template(9, "Hiring", false)])
      end)

    assert out =~ "OWNER"
    assert [simple] = Regex.run(~r/^.*Simple.*$/m, out)
    assert simple =~ "built-in"
    assert [hiring] = Regex.run(~r/^.*Hiring.*$/m, out)
    assert hiring =~ "you"
    refute hiring =~ "built-in"
  end

  test "a server that doesn't say (older than #856) marks nothing either way" do
    out = capture_io(fn -> Render.templates([%{"id" => 1, "name" => "Old", "columns" => []}]) end)
    [old] = Regex.run(~r/^.*Old.*$/m, out)
    refute old =~ "built-in"
    refute old =~ "you"
  end
end
