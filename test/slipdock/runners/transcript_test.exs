defmodule Slipdock.Runners.TranscriptTest do
  @moduledoc """
  A job's live log (#1870): appending what the runner sends in order, a
  resend trimmed and a gap refused, the caps on lines and on the whole log,
  and secrets taken out before anything is stored.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.{Repo, Runners}
  alias Slipdock.Runners.{Job, Transcript, TranscriptChunk}

  setup do
    board = board_fixture(%{"name" => "Logs"})
    card = card_fixture(hd(board.columns), %{"title" => "Log me"})
    {:ok, runner, token} = Runners.create_runner(board, %{"name" => "box", "pool" => "dev"})
    {:ok, _} = Runners.queue(card, %{pool: "dev", kind: "claude", prompt: "go"})
    job = Runners.claim(runner)
    %{runner: runner, token: token, job: job, card: card}
  end

  defp lines(range), do: Enum.map_join(range, "", &~s({"n":#{&1}}\n))

  test "sends append in order, and the answer is where the next send starts", ctx do
    assert {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..2))
    assert {:ok, 5} = Transcript.append(ctx.runner, ctx.job.id, 3, lines(3..4))

    job = Repo.reload!(ctx.job)
    assert job.transcript_lines == 5
    assert job.transcript_bytes == byte_size(lines(0..4))
    assert job.transcript_at
    assert Transcript.read(job) == lines(0..4)
    assert Transcript.read(job, 3) == lines(3..4)
    assert Transcript.read(job, 1) == lines(1..4)
    assert Transcript.read(job, 5) == ""
  end

  test "an empty send changes nothing and answers what is held", ctx do
    assert {:ok, 0} = Transcript.append(ctx.runner, ctx.job.id, 0, "")
    assert {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..1))
    assert {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 2, "")
    assert Repo.aggregate(TranscriptChunk, :count) == 1
  end

  test "a send that arrives twice is trimmed to what is new", ctx do
    assert {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..2))
    # The answer was lost, so the runner sends from 0 again, with more.
    assert {:ok, 4} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..3))
    assert {:ok, 4} = Transcript.append(ctx.runner, ctx.job.id, 1, lines(1..2))
    assert Transcript.read(Repo.reload!(ctx.job)) == lines(0..3)
  end

  test "a send past what is held is a gap, and nothing is kept", ctx do
    assert {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..1))
    assert {:gap, 2} = Transcript.append(ctx.runner, ctx.job.id, 5, lines(5..6))
    assert Transcript.read(Repo.reload!(ctx.job)) == lines(0..1)
  end

  test "a last line with no newline was cut off by the send's size, so it waits", ctx do
    assert {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..1) <> ~s({"n":2))
    assert Transcript.read(Repo.reload!(ctx.job)) == lines(0..1)
  end

  test "a line over the line limit is replaced by a line saying so", ctx do
    big = ~s({"tool_result":") <> String.duplicate("x", Transcript.max_line()) <> ~s("})
    assert {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 0, ~s({"n":0}\n#{big}\n{"n":2}\n))

    [first, cut, last, ""] = ctx.job |> Repo.reload!() |> Transcript.read() |> String.split("\n")
    assert first == ~s({"n":0})
    assert last == ~s({"n":2})

    assert Jason.decode!(cut) == %{
             "type" => "slipdock_cut",
             "bytes" => byte_size(big),
             "limit" => Transcript.max_line()
           }
  end

  test "a send that is one line too long for a send is kept as a cut line", ctx do
    huge = String.duplicate("y", Transcript.max_line() + 10)
    assert {:ok, 1} = Transcript.append(ctx.runner, ctx.job.id, 0, huge)
    assert Transcript.read(Repo.reload!(ctx.job)) =~ ~s("type":"slipdock_cut")
  end

  test "the whole log stops at its limit, says so once, and the runner is told", ctx do
    line = ~s({"pad":") <> String.duplicate("z", 30_000) <> ~s("})
    per_send = Enum.map_join(1..50, "", fn _ -> line <> "\n" end)
    sends = div(Transcript.max_bytes(), byte_size(per_send)) + 1

    answers =
      Enum.map(0..sends, fn i -> Transcript.append(ctx.runner, ctx.job.id, i * 50, per_send) end)

    assert {:capped, held} = List.last(answers)
    # The send that hit the cap counts all its lines as taken.
    assert rem(held, 50) == 0 and held <= (sends + 1) * 50

    job = Repo.reload!(ctx.job)
    assert job.transcript_capped
    assert job.transcript_bytes <= Transcript.max_bytes()

    text = Transcript.read(job)
    assert text |> String.split(~s("type":"slipdock_capped")) |> length() == 2

    assert text |> String.split("\n", trim: true) |> List.last() |> Jason.decode!() ==
             %{"type" => "slipdock_capped", "limit" => Transcript.max_bytes()}

    # Once capped, a send is answered as capped and keeps nothing.
    assert {:capped, ^held} = Transcript.append(ctx.runner, ctx.job.id, held, lines(0..1))
    assert Transcript.read(Repo.reload!(ctx.job)) == text
  end

  test "secrets are taken out before anything is stored", ctx do
    api = "AbCdEf0123456789AbCdEf0123456789AbCdEf01234"

    body =
      Enum.map_join(
        [
          ~s({"text":"my runner token is #{ctx.token} ok"}),
          ~s({"text":"export SLIPDOCK_TOKEN=#{api}"}),
          ~s({"text":"curl -H 'Authorization: Bearer #{api}'"}),
          ~s({"text":"aws #{"AK" <> "IA"}ABCDEFGHIJKLMNOP here"}),
          # Put together here so the repository's own secret checks don't take it for one.
          ~s({"text":"gh #{"gh" <> "p_"}abcdefghijklmnopqrstuvwxyz0123456789 there"}),
          ~s({"text":"sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123"}),
          ~s({"text":"-----BEGIN RSA PRIVATE KEY-----\\nMIIEabc\\n-----END RSA PRIVATE KEY-----"}),
          ~s({"text":"{\\"password\\": \\"s3cretPassw0rd99\\"}"}),
          ~s[{"text":"token = Base.url_encode64(:crypto.strong_rand_bytes(32))"}]
        ],
        "",
        &(&1 <> "\n")
      )

    assert {:ok, 9} =
             Transcript.append(ctx.runner, ctx.job.id, 0, body, secrets: [ctx.token])

    text = Transcript.read(Repo.reload!(ctx.job))

    for secret <- [
          ctx.token,
          api,
          "ABCDEFGHIJKLMNOP",
          "ghp_abcdefghij",
          "sk-ant-api03",
          "MIIEabc",
          "s3cretPassw0rd99"
        ] do
      refute text =~ secret, "#{secret} was kept"
    end

    assert text =~ "my runner token is [redacted] ok"
    assert text =~ "Bearer [redacted]"
    assert text =~ ~s(\\"password\\": \\"[redacted]\\")
    # Code that only looks like an assignment is left alone.
    assert text =~ "token = Base.url_encode64(:crypto.strong_rand_bytes(32))"
    # Every line is still JSON.
    for line <- String.split(text, "\n", trim: true), do: assert({:ok, _} = Jason.decode(line))
  end

  test "bytes that aren't UTF-8 are replaced rather than refused", ctx do
    assert {:ok, 1} =
             Transcript.append(ctx.runner, ctx.job.id, 0, <<"{\"t\":\"a", 0xFF, 0, "b\"}\n">>)

    assert Transcript.read(Repo.reload!(ctx.job)) == "{\"t\":\"a�b\"}\n"
  end

  test "another runner's job, a finished job, and a bad id are refused", ctx do
    board = board_fixture(%{"name" => "Other"})
    {:ok, other, _} = Runners.create_runner(board, %{"name" => "other", "pool" => "dev"})
    assert {:error, :not_found} = Transcript.append(other, ctx.job.id, 0, lines(0..0))
    assert {:error, :not_found} = Transcript.append(ctx.runner, "nope", 0, lines(0..0))
    assert {:error, :not_found} = Transcript.append(ctx.runner, ctx.job.id, -1, lines(0..0))

    {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{exit: "0"})
    assert {:error, :ended} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..0))
    assert Repo.reload!(ctx.job).transcript_lines == 0
  end

  test "deleting the job deletes its log", ctx do
    assert {:ok, 1} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..0))
    Repo.delete!(Repo.get!(Job, ctx.job.id))
    assert Repo.aggregate(TranscriptChunk, :count) == 0
  end

  test "each send is broadcast on the job's topic", ctx do
    Phoenix.PubSub.subscribe(Slipdock.PubSub, Transcript.topic(ctx.job.id))
    assert {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..1))
    job_id = ctx.job.id
    assert_receive {:transcript, ^job_id, 2}
  end
end
