defmodule Slipdock.MeetingCaptureDataMigrationTest do
  @moduledoc """
  The migration that deletes what meeting capture left behind (W-2330,
  #1819): the `provenance` search embeddings, and the capture audio under
  the uploads folder, once and idempotently. Nothing else is touched.
  """
  use Slipdock.DataCase, async: true

  import Slipdock.Fixtures

  alias Slipdock.Repo
  alias Slipdock.Search.Embedding

  [{migration, _}] =
    Code.require_file("priv/repo/migrations/20261106202622_remove_meeting_capture_data.exs")

  @migration migration

  defp embedding(card, kind) do
    Repo.insert!(%Embedding{
      kind: kind,
      source_id: card.id,
      card_id: card.id,
      board_id: card.board_id,
      body: "said in a meeting",
      content_hash: "h-#{kind}",
      model: "test",
      dimensions: 1,
      vector: <<0::32>>
    })
  end

  test "deletes provenance embeddings and keeps every other kind" do
    board = board_fixture(%{"name" => "Calls"})
    card = card_fixture(hd(board.columns), %{"title" => "From a call"})

    gone = embedding(card, "provenance")
    kept = embedding(card, "card")
    transcript = embedding(card, "transcript")

    Repo.query!(@migration.delete_provenance())

    refute Repo.get(Embedding, gone.id)
    assert Repo.get(Embedding, kept.id)
    assert Repo.get(Embedding, transcript.id)
  end

  describe "the capture audio" do
    setup do
      dir = Path.join(System.tmp_dir!(), "capture-purge-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "goes, with its folders; the rest of the uploads stay", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "captures/2026/10"))
      File.write!(Path.join(dir, "captures/2026/10/call.wav"), "RIFF")
      File.write!(Path.join(dir, "captures/loose.m4a"), "m4a")
      File.mkdir_p!(Path.join(dir, "attachments"))
      File.write!(Path.join(dir, "attachments/keep.pdf"), "%PDF")

      assert @migration.purge_audio(dir) == :ok

      refute File.exists?(Path.join(dir, "captures"))
      assert File.read!(Path.join(dir, "attachments/keep.pdf")) == "%PDF"
    end

    test "is the same answer run again, or with no captures ever", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "captures"))
      File.write!(Path.join(dir, "captures/a.wav"), "RIFF")

      assert @migration.purge_audio(dir) == :ok
      assert @migration.purge_audio(dir) == :ok
      refute File.exists?(Path.join(dir, "captures"))

      # A server that never had a capture, or no uploads folder yet.
      assert @migration.purge_audio(Path.join(dir, "never-made")) == :ok
    end
  end

  test "can't be rolled back" do
    assert_raise Ecto.MigrationError, ~r/can't be put back/, fn -> @migration.down() end
  end

  describe "the schema drop (20261106210000)" do
    [{drop, _}] =
      Code.require_file("priv/repo/migrations/20261106210000_drop_meeting_capture_tables.exs")

    @drop drop

    defp names(sql, params) do
      %{rows: rows} = Repo.query!(sql, params)
      List.flatten(rows)
    end

    test "the 11 capture tables are gone" do
      tables = Enum.map(@drop.tables(), &Atom.to_string/1)
      assert length(tables) == 11

      assert names(
               "SELECT table_name FROM information_schema.tables " <>
                 "WHERE table_schema = 'public' AND table_name = ANY($1)",
               [tables]
             ) == []
    end

    test "no meetings or chat capture column is left, and the kept ones are there" do
      for {table, cols} <- @drop.columns() do
        assert names(
                 "SELECT column_name FROM information_schema.columns " <>
                   "WHERE table_schema = 'public' AND table_name = $1 AND column_name = ANY($2)",
                 [Atom.to_string(table), Enum.map(cols, &Atom.to_string/1)]
               ) == []
      end

      # Nothing named for meetings or capture anywhere, bar wiki history's
      # `via` values, which are data, not columns.
      assert names(
               "SELECT table_name || '.' || column_name FROM information_schema.columns " <>
                 "WHERE table_schema = 'public' AND " <>
                 "(column_name LIKE '%meeting%' OR column_name LIKE '%capture%')",
               []
             ) == []

      # What transcription kept from it (#1817) stays.
      assert names(
               "SELECT column_name FROM information_schema.columns " <>
                 "WHERE table_name = 'users' AND column_name = 'transcription_access'",
               []
             ) == ["transcription_access"]
    end

    test "can't be rolled back" do
      assert_raise Ecto.MigrationError, ~r/can't be put back/, fn -> @drop.down() end
    end
  end
end
