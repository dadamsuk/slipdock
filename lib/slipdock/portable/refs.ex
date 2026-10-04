defmodule Slipdock.Portable.Refs do
  @moduledoc """
  Refs, the names things go by inside a portable document, and the work of
  turning them back into rows.

  On the way out every board, list, card and page gets a ref in place of its
  id, and whatever points at something else — a tag on a card, a blocker, a
  sub-board, an assignee — points at a ref or an email address instead. On
  the way in the arrow turns round: an address becomes somebody here or
  nobody, a dependency between two refs is checked as one made by hand would
  be, and page codes, page parents and backlinks are settled once every
  imported row exists. Kept apart from `Slipdock.Portable.Export` and
  `Slipdock.Portable.Import` because these are the rules about what a
  reference means, and both directions have to agree on them.
  """
  import Ecto.Query, warn: false

  alias Slipdock.Accounts.User
  alias Slipdock.Boards.{Board, Card, Comment, StatusUpdate}
  alias Slipdock.Repo
  alias Slipdock.Wiki.{Links, Page, Revision}

  ## Out: ids to refs ------------------------------------------------------------

  @doc false
  def numbered(records, prefix) do
    records
    |> Enum.with_index(1)
    |> Map.new(fn {record, index} -> {record.id, "#{prefix}#{index}"} end)
  end

  # Lead first, then the rest in id order — as `Boards.assignee_ids/1` has it.
  @doc false
  def assignee_ids(%Card{id: id, assignee_id: lead}, refs) do
    ids = Map.get(refs.loaded.assignees, id, [])
    if lead in ids, do: [lead | List.delete(ids, lead)], else: Enum.sort(ids)
  end

  @doc false
  def tag_refs(card_id, refs) do
    refs.loaded.tags
    |> Map.get(card_id, [])
    |> Enum.map(&refs.tags[&1])
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def dependency_refs(card_id, refs) do
    refs.loaded.blockers
    |> Map.get(card_id, [])
    |> Enum.map(&refs.cards[&1])
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def link_refs(card_id, refs) do
    refs.loaded.links
    |> Map.get(card_id, [])
    |> Enum.map(&%{kind: &1.kind, to: refs.cards[&1.to_id]})
    |> Enum.reject(&is_nil(&1.to))
  end

  @doc false
  def email_of(nil, _refs), do: nil
  def email_of(user_id, refs), do: refs.loaded.emails[user_id]

  ## In: refs to ids --------------------------------------------------------------

  @doc false
  def dependency_refusal(blocked, blocker, blocks, ids) do
    blocked_id = ids.cards[blocked[:ref]]
    blocker_id = ids.cards[blocker[:ref]]

    cond do
      blocked_id == blocker_id -> {:refused, "a card cannot depend on itself"}
      blocked[:board] != blocker[:board] -> {:refused, "the two cards are on different boards"}
      reaches?(blocks, blocked_id, blocker_id) -> {:refused, "it would make a circle"}
      true -> :ok
    end
  end

  # Does `from` block `target`, directly or down a chain?
  defp reaches?(blocks, from, target), do: reaches?(blocks, [from], target, MapSet.new())

  defp reaches?(_blocks, [], _target, _seen), do: false
  defp reaches?(_blocks, [target | _], target, _seen), do: true

  defp reaches?(blocks, [id | rest], target, seen) do
    if MapSet.member?(seen, id),
      do: reaches?(blocks, rest, target, seen),
      else: reaches?(blocks, Map.get(blocks, id, []) ++ rest, target, MapSet.put(seen, id))
  end

  @doc false
  def fresh_page_code do
    highest =
      Repo.one(from(p in Page, select: max(fragment("CAST(substr(?, 3) AS INTEGER)", p.code))))

    Page.code_for((highest || 0) + 1)
  end

  @doc false
  def fresh_page_number(board_id) do
    {1, _} = Repo.update_all(from(b in Board, where: b.id == ^board_id), inc: [page_seq: 1])
    Repo.one!(from(b in Board, where: b.id == ^board_id, select: b.page_seq))
  end

  # `[[W-31]]` in an imported body means the page that was W-31 on the server
  # the document came from, which is a different page here (or none). The
  # document says which page had which code, so the rewrite is exact.
  @doc false
  def remap_page_links!(pages, ids) do
    renames =
      for doc <- pages,
          old = doc[:code],
          # Only something shaped like a code: a blank one would make the
          # pattern below match at every word boundary in every page.
          is_binary(old) and Page.code?(old),
          new_id = ids.pages[doc[:ref]],
          into: %{} do
        {old, Repo.one!(from(p in Page, where: p.id == ^new_id, select: p.code))}
      end

    if renames != %{} do
      # Only where the code stands as a reference — `[[W-31]]` or a bare `W-31`
      # on a word boundary — so prose that happens to contain the letters is
      # left alone. One pattern for every code, so each body is read once and a
      # new code is never itself rewritten by a later rename.
      alternatives = renames |> Map.keys() |> Enum.map_join("|", &Regex.escape/1)
      pattern = Regex.compile!("\\b(?:#{alternatives})\\b")

      for doc <- pages, page_id = ids.pages[doc[:ref]] do
        page = Repo.get!(Page, page_id)
        rewritten = Regex.replace(pattern, page.body || "", &Map.fetch!(renames, &1))

        if rewritten != page.body do
          page
          |> Ecto.Changeset.change(body: rewritten, content_hash: Page.hash(rewritten))
          |> Repo.update!()
        end
      end
    end

    :ok
  end

  # What writing a page or a comment by hand does besides the insert, done once
  # every imported page has its final body: a first revision, so the page has
  # a history to diff against, and its links, so `[[Other page]]` shows up in
  # that page's backlinks — the same for comments and status updates, whose
  # links can point at a page imported after their card.
  @doc false
  def settle_writing!(user, ids, opts) do
    page_ids = Map.values(ids.pages)
    card_ids = Map.values(ids.cards)
    pages = Repo.all(from(p in Page, where: p.id in ^page_ids))
    via = if opts[:via] in Revision.vias(), do: opts[:via], else: "web"

    for page <- pages do
      %Revision{}
      |> Revision.changeset(%{
        "page_id" => page.id,
        "title" => page.title,
        "body" => page.body,
        "summary" => "Imported",
        "via" => via,
        "author_id" => user.id
      })
      |> Repo.insert!()

      Links.reconcile(page)
    end

    owned = fn query ->
      Repo.all(from(r in query, where: r.card_id in ^card_ids or r.page_id in ^page_ids))
    end

    Enum.each(owned.(Comment), &Links.reconcile_comment/1)
    Enum.each(owned.(StatusUpdate), &Links.reconcile_status/1)
  end

  @doc false
  def link_pages!(pages, ids) do
    for doc <- pages, parent_ref = doc[:parent], parent_id = ids.pages[parent_ref] do
      Page
      |> Repo.get!(ids.pages[doc[:ref]])
      |> Ecto.Changeset.change(parent_id: parent_id)
      |> Repo.update!()
    end

    :ok
  end

  # Whoever an address names, they can be put on an imported card only if
  # they can open it — the rule `Slipdock.Boards.resolve_assignees/3` keeps
  # everywhere else. An imported tree is new and the importer's alone, so that
  # is the importer and nobody else; anyone else comes in unassigned, to be
  # shared with and assigned again. Nobody is not an error — the alternative is
  # an import that dies on the last card because somebody left.
  @doc false
  def user_id_for(email, %User{} = user) when is_binary(email) do
    if Slipdock.Email.normalize(email) == Slipdock.Email.normalize(user.email), do: user.id
  end

  def user_id_for(_, _user), do: nil

  # Everybody on a card, lead first. `assignees` is how a card with several
  # people comes; a document written before there could be more than one has
  # only `assignee`.
  defp assignee_emails(doc), do: List.wrap(doc[:assignees] || doc[:assignee])

  @doc false
  def assignee_ids_for(doc, user),
    do:
      doc
      |> assignee_emails()
      |> Enum.map(&user_id_for(&1, user))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

  # The same words whether or not the address has an account on this server:
  # the report is not a way of finding out who does.
  @doc false
  def missing_people(doc, user) do
    assignee_emails(doc)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.reject(&user_id_for(&1, user))
    |> Enum.map(&"#{&1} can't see this board yet, so what was theirs came in unassigned.")
  end

  @doc false
  def signed(body, author, %User{} = user)
      when is_binary(body) and is_binary(author) and author != "" do
    if user_id_for(author, user), do: body, else: "*#{author}*\n\n#{body}"
  end

  def signed(body, _author, _user), do: body
end
