defmodule SlipdockCLI.VerifiedDashTest do
  @moduledoc """
  A bare `-` as a completion's evidence (#2091) on the CLI: `done --evidence
  -` sends what stdin holds, so a dash there reaches the server as the
  evidence, which refuses it with a 422 saying why. A refusal ends in
  `System.halt/1`, so it is covered as the value `done` halts on; the
  server's side is in `Slipdock.VerifiedDashTest`. Evidence piped in that
  merely starts with a dash goes through as written.
  """
  # Sync: sets HOME and the SLIPDOCK_* variables, which are one environment
  # for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SlipdockCLI.{Boards, FakeServer, HTTP}

  @refusal %{
    "error" => "validation failed",
    "details" => %{
      "evidence" => [
        "was a bare '-', which is no evidence: a client that doesn't read stdin sends the " <>
          "dash itself. Pass the text itself (--evidence \"…\", complete_card evidence) or " <>
          "pipe it with --evidence - from a CLI that reads stdin"
      ]
    }
  }

  @card ~s({"card":{"id":12,"title":"Work","column":"Done","board_id":3,"priority":"none","flags":[],"tags":[],"comments":[],"checklist":{"done":0,"total":0,"items":[]}}})

  setup do
    home = Path.join(System.tmp_dir!(), "slipdock-dash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    saved = Map.new(~w(HOME SLIPDOCK_URL SLIPDOCK_TOKEN KANBAN_TOKEN), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    System.put_env("SLIPDOCK_TOKEN", "test-token")
    System.delete_env("KANBAN_TOKEN")

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf!(home)
    end)
  end

  defp serve(responses), do: System.put_env("SLIPDOCK_URL", FakeServer.start(responses))

  test "a dash as the evidence is the server's 422, which says it was a bare dash" do
    serve([{422, JSON.encode!(@refusal)}])

    assert {:error, 422, %{"details" => %{"evidence" => [message]}}} =
             HTTP.patch("/cards/12", %{"completed" => true, "evidence" => "-"})

    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"completed" => true, "evidence" => "-"}
    assert message =~ "bare '-'"
    assert message =~ "--evidence - from a CLI that reads stdin"
  end

  test "--evidence - sends what stdin holds, a leading dash and all" do
    serve([{200, @card}])
    piped = "- Handbook: no change\n- Findings: none\n"

    out =
      capture_io([input: piped], fn ->
        Boards.run("done", ["12"], evidence: "-")
      end)

    assert out =~ "completed"
    assert_received {:request, "PATCH", "/api/cards/12", body}
    assert JSON.decode!(body) == %{"completed" => true, "evidence" => piped}
  end
end
