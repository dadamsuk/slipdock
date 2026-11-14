defmodule Slipdock.Runners.TranscriptTest do
  @moduledoc """
  A job's live log (#1870): appending what the runner sends in order, a
  resend trimmed and a gap refused, the caps on lines and on the whole log,
  and secrets taken out before anything is stored; and a job handed to a new
  run starting a new segment of its log (#3088).
  """
  use Slipdock.DataCase, async: true

  import Ecto.Query
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

  describe "a job handed to a new run (#3088)" do
    defp expire_lease(job) do
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [lease_expires_at: past])
      assert Runners.sweep() == 1
    end

    defp other_runner(ctx) do
      {:ok, other, _} = Runners.create_runner(board(ctx), %{"name" => "spare", "pool" => "dev"})
      other
    end

    defp board(ctx), do: Slipdock.Boards.get_board!(ctx.card.board_id)

    defp note(job, line) do
      job
      |> Repo.reload!()
      |> Transcript.read(line)
      |> String.split("\n")
      |> hd()
      |> Jason.decode!()
    end

    test "a lease that ran out, taken by another runner: its run's first lines are kept", ctx do
      assert {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..2))
      expire_lease(ctx.job)
      other = other_runner(ctx)
      assert %Job{id: id} = Runners.claim(other)
      assert id == ctx.job.id

      # A note after the first run's lines starts the new segment.
      job = Repo.reload!(ctx.job)
      assert job.transcript_lines == 4

      assert note(job, 3) == %{"type" => "slipdock_run", "attempt" => 2, "runner" => "spare"}

      # The new run's daemon sends from 0: every line is kept, and the
      # answers count from the segment's start.
      assert {:ok, 2} = Transcript.append(other, id, 0, lines(10..11))
      assert {:ok, 4} = Transcript.append(other, id, 2, lines(12..13))
      # A resend is still trimmed, and a gap still refused, within the segment.
      assert {:ok, 4} = Transcript.append(other, id, 1, lines(11..12))
      assert {:gap, 4} = Transcript.append(other, id, 6, lines(16..16))

      job = Repo.reload!(ctx.job)
      assert job.transcript_lines == 8
      log = Transcript.read(job)
      assert String.starts_with?(log, lines(0..2))
      assert String.ends_with?(log, lines(10..13))
      assert Transcript.read(job, 4) == lines(10..13)

      # The runner that lost it is refused, as ever.
      assert {:error, :not_found} = Transcript.append(ctx.runner, id, 3, lines(3..3))
    end

    test "a status=requeue finish claimed again starts a new segment too", ctx do
      assert {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..1))

      assert {:ok, %Job{status: "queued"}} =
               Runners.finish(ctx.runner, ctx.job.id, %{status: "requeue", exit: "1"})

      # The same runner, claiming it from the queue, runs it afresh.
      assert %Job{} = Runners.claim(ctx.runner)
      assert %{"type" => "slipdock_run", "runner" => "box"} = note(ctx.job, 2)
      assert {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(20..22))
      assert Transcript.read(Repo.reload!(ctx.job), 3) == lines(20..22)

      # A third run: its segment starts after the second's.
      assert {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{status: "requeue", exit: "1"})
      assert %Job{} = Runners.claim(ctx.runner)
      assert Repo.reload!(ctx.job).transcript_lines == 7
      assert {:ok, 1} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(30..30))
      assert Transcript.read(Repo.reload!(ctx.job), 7) == lines(30..30)
    end

    test "the runner that held it taking it back carries on in the same segment", ctx do
      assert {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..2))
      expire_lease(ctx.job)

      # Its machine woke (#2817): it heartbeats and sends on from where it was.
      assert {:ok, _} = Runners.heartbeat(ctx.runner, ctx.job.id, "back")
      assert {:ok, 5} = Transcript.append(ctx.runner, ctx.job.id, 3, lines(3..4))
      assert Transcript.read(Repo.reload!(ctx.job)) == lines(0..4)
    end

    test "a first claim, or a job with no log yet, gets no note", ctx do
      assert Repo.reload!(ctx.job).transcript_lines == 0
      expire_lease(ctx.job)
      assert %Job{} = Runners.claim(other_runner(ctx))
      assert Repo.reload!(ctx.job).transcript_lines == 0
      assert Repo.aggregate(TranscriptChunk, :count) == 0
    end

    test "a full log gets no note, and one with no room for it is capped", ctx do
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id),
        set: [transcript_lines: 5, transcript_capped: true]
      )

      job = Repo.reload!(ctx.job)
      assert Transcript.new_run(job, ctx.runner) == job

      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id),
        set: [transcript_capped: false, transcript_bytes: Transcript.max_bytes() - 10]
      )

      job = Transcript.new_run(Repo.reload!(ctx.job), ctx.runner)
      assert job.transcript_capped
      assert job.transcript_lines == 6
      assert {:capped, _} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..0))
    end

    test "a sent line that reads like the note doesn't start a segment", ctx do
      fake = ~s({"type":"slipdock_run","attempt":9,"runner":"x"}\n)
      assert {:ok, 1} = Transcript.append(ctx.runner, ctx.job.id, 0, fake)
      assert Transcript.read(Repo.reload!(ctx.job)) == " " <> fake
      assert {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 1, lines(1..1))
    end

    test "the claim's note is counted in the log's bytes and stamps its time", ctx do
      assert {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..2))
      past = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id), set: [transcript_at: past])
      expire_lease(ctx.job)
      assert %Job{} = Runners.claim(other_runner(ctx))

      job = Repo.reload!(ctx.job)
      text = ~s({"type":"slipdock_run","attempt":2,"runner":"spare"}\n)
      assert Transcript.read(job, 3) == text
      # The first run's bytes plus the note chunk's, so the cap counts it.
      assert job.transcript_bytes == byte_size(lines(0..2)) + byte_size(text)
      assert job.transcript_bytes == Repo.aggregate(TranscriptChunk, :sum, :bytes)
      refute job.transcript_capped
      # The log changed at the claim, not an hour ago.
      assert DateTime.compare(job.transcript_at, past) == :gt
    end

    test "a note that exactly fills the log is written, and one byte less room caps it", ctx do
      text = ~s({"type":"slipdock_run","attempt":#{ctx.job.attempts},"runner":"box"}\n)
      fits = Transcript.max_bytes() - byte_size(text)

      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id),
        set: [transcript_lines: 5, transcript_bytes: fits]
      )

      job = Transcript.new_run(Repo.reload!(ctx.job), ctx.runner)
      refute job.transcript_capped
      assert job.transcript_lines == 6
      assert job.transcript_bytes == Transcript.max_bytes()
      assert Transcript.read(job, 5) == text

      # One byte less room: the note doesn't fit, and the log is capped instead.
      Repo.delete_all(TranscriptChunk)

      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id),
        set: [transcript_lines: 5, transcript_bytes: fits + 1]
      )

      job = Transcript.new_run(Repo.reload!(ctx.job), ctx.runner)
      assert job.transcript_capped
      assert %{"type" => "slipdock_capped"} = note(job, 5)
    end

    test "a capped log answers a second run with its own segment's count", ctx do
      assert {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(0..2))
      assert {:ok, _} = Runners.finish(ctx.runner, ctx.job.id, %{status: "requeue", exit: "1"})
      assert %Job{} = Runners.claim(ctx.runner)
      assert %{"type" => "slipdock_run"} = note(ctx.job, 3)

      # Capped before the new run sent anything: it holds none of its lines.
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id), set: [transcript_capped: true])
      assert {:capped, 0} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(10..11))

      # The new run's own send hits the cap: its lines count as taken, and
      # every later send is answered with that count, not the whole log's.
      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id),
        set: [transcript_capped: false, transcript_bytes: Transcript.max_bytes() - 5]
      )

      assert {:capped, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(10..11))
      assert Repo.reload!(ctx.job).transcript_lines == 6
      assert {:capped, 2} = Transcript.append(ctx.runner, ctx.job.id, 2, lines(12..12))
      assert {:capped, 2} = Transcript.append(ctx.runner, ctx.job.id, 0, lines(10..10))
    end

    test "a sent line one character off the note's type doesn't start a segment", ctx do
      # `_` is any one character in a LIKE pattern unless escaped.
      near = ~s({"type":"slipdock-run","attempt":9,"runner":"x"}\n)
      assert {:ok, 1} = Transcript.append(ctx.runner, ctx.job.id, 0, near)
      assert Transcript.read(Repo.reload!(ctx.job)) == near
      assert {:ok, 2} = Transcript.append(ctx.runner, ctx.job.id, 1, lines(1..1))
      assert {:gap, 2} = Transcript.append(ctx.runner, ctx.job.id, 3, lines(3..3))
    end

    test "only a chunk that is the note alone starts a segment", ctx do
      # A send's chunk can't start with the note (such a line is stored with
      # a space before it), so this one is put in by hand: two lines, the
      # first reading as the note. The segment's start doesn't move.
      body = ~s({"type":"slipdock_run","attempt":2,"runner":"x"}\n) <> lines(1..1)

      Repo.insert!(%TranscriptChunk{
        job_id: ctx.job.id,
        first_line: 0,
        lines: 2,
        bytes: byte_size(body),
        body: body
      })

      Repo.update_all(from(j in Job, where: j.id == ^ctx.job.id),
        set: [transcript_lines: 2, transcript_bytes: byte_size(body)]
      )

      assert {:ok, 3} = Transcript.append(ctx.runner, ctx.job.id, 2, lines(2..2))
      assert {:gap, 3} = Transcript.append(ctx.runner, ctx.job.id, 4, lines(4..4))
    end
  end
end
