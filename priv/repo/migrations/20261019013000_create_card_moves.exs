defmodule Slipdock.Repo.Migrations.CreateCardMoves do
  use Ecto.Migration

  # The movement ledger (#1112, see `Slipdock.Boards.CardMove`): one row each
  # time a card changes list, is created, archived or restored, snapshotting
  # both lists' names and categories so renames and deleted lists keep the
  # history readable.
  def up do
    create table(:card_moves) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :from_board_id, references(:boards, on_delete: :nilify_all)
      add :from_column_id, references(:columns, on_delete: :nilify_all)
      add :from_column_name, :string
      add :from_category, :string
      add :to_column_id, references(:columns, on_delete: :nilify_all)
      add :to_column_name, :string
      add :to_category, :string
      add :actor_kind, :string
      add :via, :string
      add :user_id, references(:users, on_delete: :nilify_all)
      add :agent, :string
      add :job_id, references(:runner_jobs, on_delete: :nilify_all)
      add :backfilled, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:card_moves, [:board_id, :inserted_at])
    create index(:card_moves, [:card_id, :inserted_at])
    create index(:card_moves, [:from_board_id])
    create index(:card_moves, [:from_column_id])
    create index(:card_moves, [:to_column_id])
    create index(:card_moves, [:user_id])
    create index(:card_moves, [:job_id])

    flush()

    Enum.each(backfill_sql(), &execute/1)
  end

  def down do
    drop table(:card_moves)
  end

  @doc """
  The history already in the activity log, recovered where it parses
  unambiguously, for every card with no ledger rows yet (so it can run again,
  and the backfill test runs it on its own cards):

    * a move line is `moved “<title>” to <list>`; the list is the text after
      the last `” to `, since a title can hold one too, matched against the
      current names of the board's lists. A name two lists share, or one no
      list has any more, is not a match, and that move is dropped;
    * a move from another board is the arriving line, `moved “<title>” in
      from <board> › <list>`, on the destination board, paired with the
      leaving line on the board it left (no card, `moved “<title>” to
      <board> › <list>`, within a few seconds), which names where it went;
    * a move's source is the list the line before it moved the card to, and
      none when that line was dropped: a stay that can't be seen ending is
      left open rather than stretched over the gap;
    * each card gets a `created` row at its own `inserted_at`, in the list its
      `added “…” to <list>` line names, else its current list when the log
      has no move of it at all, else no list;
    * `archived` and `restored` lines name the list the card was in.

  Every recovered row is `backfilled` and has no actor. Stand-ins get none.
  """
  def backfill_sql do
    [
      """
      INSERT INTO card_moves (card_id, kind, board_id, from_board_id,
        from_column_id, from_column_name, from_category,
        to_column_id, to_column_name, to_category, backfilled, inserted_at)
      WITH targets AS (
        SELECT c.id, c.board_id, c.column_id, c.inserted_at FROM cards c
        WHERE c.stand_in_for_id IS NULL
          AND NOT EXISTS (SELECT 1 FROM card_moves m WHERE m.card_id = c.id)
      ),
      named AS (
        SELECT col.id, col.board_id, col.name FROM columns col
        WHERE NOT EXISTS (
          SELECT 1 FROM columns o
          WHERE o.board_id = col.board_id AND o.name = col.name AND o.id <> col.id)
      ),
      lines AS (
        SELECT a.id, a.card_id, a.board_id, a.inserted_at, a.message,
          substring(a.message FROM '^moved “(.*)” to ') AS to_title,
          substring(a.message FROM '^moved “(.*)” in from ') AS in_title
        FROM activities a JOIN targets t ON t.id = a.card_id
        WHERE a.kind = 'card'
          AND (a.message LIKE 'moved “%' OR a.message ~ '^(archived|restored) “.*”$')
      ),
      moves AS (
        SELECT l.*,
          l.in_title IS NOT NULL
            AND (l.to_title IS NULL OR length(l.in_title) > length(l.to_title)) AS crossed
        FROM lines l
        WHERE l.message LIKE 'moved “%'
      ),
      parsed AS (
        SELECT m.card_id, m.id, m.inserted_at, m.board_id, m.crossed,
          CASE WHEN m.crossed THEN arrived.id ELSE here.id END AS loc,
          CASE WHEN m.crossed THEN leaving.board_id END AS src_board,
          CASE WHEN m.crossed THEN came_from.id END AS src
        FROM moves m
        LEFT JOIN named here
          ON NOT m.crossed AND here.board_id = m.board_id
            AND here.name = substr(m.message, length(m.to_title) + 13)
        LEFT JOIN LATERAL (
          SELECT l2.board_id,
            substr(l2.message, length('moved “' || m.in_title || '” to ' || tb.name || ' › ') + 1)
              AS list_name
          FROM activities l2 JOIN boards tb ON tb.id = m.board_id
          WHERE m.crossed AND l2.card_id IS NULL AND l2.kind = 'card'
            AND l2.inserted_at BETWEEN m.inserted_at - interval '5 seconds'
              AND m.inserted_at + interval '5 seconds'
            AND starts_with(l2.message, 'moved “' || m.in_title || '” to ' || tb.name || ' › ')
          ORDER BY abs(extract(epoch FROM l2.inserted_at - m.inserted_at)), l2.id
          LIMIT 1
        ) leaving ON true
        LEFT JOIN named arrived
          ON arrived.board_id = m.board_id AND arrived.name = leaving.list_name
        LEFT JOIN boards fb ON fb.id = leaving.board_id
        LEFT JOIN named came_from
          ON came_from.board_id = leaving.board_id
            AND starts_with(substr(m.message, length(m.in_title) + 18), fb.name || ' › ')
            AND came_from.name =
              substr(substr(m.message, length(m.in_title) + 18), length(fb.name) + 4)
      ),
      events AS (
        SELECT t.id AS card_id, 'created' AS kind, 0 AS phase, t.inserted_at AS at,
          0::bigint AS line_id, false AS crossed,
          CASE WHEN added.column_id IS NOT NULL THEN added.board_id ELSE t.board_id END
            AS board_id,
          COALESCE(added.column_id,
            CASE WHEN NOT EXISTS (SELECT 1 FROM moves m WHERE m.card_id = t.id)
              THEN t.column_id END) AS loc,
          NULL::bigint AS src_board, NULL::bigint AS src
        FROM targets t
        LEFT JOIN LATERAL (
          SELECT a.board_id, n.id AS column_id
          FROM activities a
          LEFT JOIN named n
            ON n.board_id = a.board_id
              AND n.name = substr(a.message,
                length(substring(a.message FROM '^added “(.*)” to ')) + 13)
          WHERE a.card_id = t.id AND a.kind = 'card' AND a.message LIKE 'added “%” to %'
          ORDER BY a.inserted_at, a.id
          LIMIT 1
        ) added ON true
        UNION ALL
        SELECT card_id, 'moved', 1, inserted_at, id, crossed, board_id, loc, src_board, src
        FROM parsed
        UNION ALL
        SELECT card_id, CASE WHEN message LIKE 'archived%' THEN 'archived' ELSE 'restored' END,
          1, inserted_at, id, false, board_id, NULL, NULL, NULL
        FROM lines
        WHERE message NOT LIKE 'moved “%'
      ),
      grouped AS (
        SELECT e.*,
          count(*) FILTER (WHERE e.kind IN ('created', 'moved'))
            OVER (PARTITION BY e.card_id ORDER BY e.phase, e.at, e.line_id) AS grp
        FROM events e
      ),
      stays AS (
        SELECT card_id, grp, loc FROM grouped WHERE kind IN ('created', 'moved')
      ),
      placed AS (
        SELECT g.card_id, g.kind, g.board_id, g.at, g.phase, g.line_id, g.src_board,
          CASE
            WHEN g.kind = 'moved' AND g.crossed THEN g.src
            WHEN g.kind = 'moved' THEN prev.loc
            WHEN g.kind = 'archived' THEN cur.loc
          END AS from_id,
          CASE
            WHEN g.kind IN ('created', 'moved') THEN g.loc
            WHEN g.kind = 'restored' THEN cur.loc
          END AS to_id
        FROM grouped g
        LEFT JOIN stays cur ON cur.card_id = g.card_id AND cur.grp = g.grp
        LEFT JOIN stays prev ON prev.card_id = g.card_id AND prev.grp = g.grp - 1
        WHERE NOT (g.kind = 'moved' AND g.loc IS NULL)
      )
      SELECT p.card_id, p.kind, p.board_id,
        CASE WHEN p.kind IN ('moved', 'archived') THEN COALESCE(fc.board_id, p.src_board, p.board_id) END,
        fc.id, fc.name, fc.category, tc.id, tc.name, tc.category, true, p.at
      FROM placed p
      LEFT JOIN columns fc ON fc.id = p.from_id
      LEFT JOIN columns tc ON tc.id = p.to_id
      -- In the log's order, so ids break ties between lines logged in the
      -- same second the way the log does.
      ORDER BY p.card_id, p.phase, p.at, p.line_id
      """
    ]
  end
end
