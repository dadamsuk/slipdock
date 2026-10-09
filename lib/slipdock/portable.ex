defmodule Slipdock.Portable do
  @moduledoc """
  Board trees out as one JSON document, and back in again.

  This is not the same thing as `Slipdock.AccountExport`, which answers "let
  me leave with my data" and writes a zip a person reads. That one flattens a
  board to lists of cards and drops subcards, tags, checklists, comments,
  custom fields and dependencies, because nothing is ever going to read it
  back. This one is the opposite promise: **what comes out can go back in**,
  on this server or another one, and come back the same shape.

  Which forces three decisions.

  **The unit is a board tree, not a board.** Tags, custom fields, milestones
  and saved views are stored against the root of a tree and shared by every
  sub-board under it (see `Slipdock.Boards.Board`), and a card's subcards *are*
  a sub-board. Exporting one board of a tree would hand you cards whose tags
  and fields live somewhere you did not export, so a root board always comes
  with its descendants.

  **Nothing inside the document is a database id.** Every board, list, tag,
  field, card and page gets a `ref` — `"k12"`, `"t3"` — unique in the document
  and meaningless outside it. Anything pointing at anything else points at a
  ref. A document is then self-contained: the importer never has to care which
  server wrote it, and two documents can be imported into one server without
  colliding.

  **People are email addresses.** An assignee or a status update's author is
  written as an address, because an id from another server names nobody here.
  On the way back in an address that has no account is simply dropped, and the
  import says so — the alternative is an import that fails on the last card
  because somebody left the company.

  What is deliberately *not* in a document: attachments (bytes, not structure —
  they stay with the server), votes (a person's budget, not a board's content),
  activity and page revision history (a record of this server's past, which
  another server cannot honestly adopt), and public share tokens (a secret
  that would then be valid in two places). Each of those is a decision rather
  than an omission, and `warnings/1` on an export says which of them had
  something to leave behind.

  Meeting captures (see `Slipdock.Meetings`) go *out* with their board, as a
  record — the transcript, what was found, how each question was settled —
  but an import leaves them out: a capture is a record of a commit made on
  this server, and replaying it elsewhere would claim a review that did not
  happen there. The cards it wrote carry their own provenance either way.
  """

  # The work is split three ways: `Slipdock.Portable.Export` writes a tree
  # out, `Slipdock.Portable.Import` reads one back in, and
  # `Slipdock.Portable.Refs` holds what both have to agree on about refs and
  # the people and links behind them. This module is the door to all three.

  alias Slipdock.Portable.{Export, Import}

  @format_version 1

  @doc "The format version this module writes, and the only one it reads."
  def format_version, do: @format_version

  ## Out ------------------------------------------------------------------------

  defdelegate export(user, opts \\ []), to: Export
  defdelegate to_json(user, opts \\ []), to: Export
  defdelegate warnings(user, opts \\ []), to: Export
  defdelegate archived_opts(value), to: Export
  defdelegate root_of(board), to: Export

  ## In -------------------------------------------------------------------------

  defdelegate import(user, document, opts \\ []), to: Import
  defdelegate max_rows, to: Import
  defdelegate row_kind(kind), to: Import
end
