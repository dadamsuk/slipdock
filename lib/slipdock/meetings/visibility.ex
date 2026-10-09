defmodule Slipdock.Meetings.Visibility do
  @moduledoc """
  What a capture shows of cards and pages, to the person looking (G12).

  A capture is read alongside what its *sender* can open — on a sub-board,
  with its parent board too when asked. Somebody who reviews it may be able
  to open less: a member of the sub-board alone cannot read the parent
  board. So wherever a capture is shown — the review, the preview, the API,
  MCP — the cards and pages its findings and questions name are checked
  against the viewer, and any they cannot open are shown only as that: *a
  card you can't open*, with no title, summary, list or people.
  """
  alias Slipdock.{Access, Repo}
  alias Slipdock.Boards.Card
  alias Slipdock.Meetings.{Finding, Question}
  alias Slipdock.Wiki.Page

  @hidden "a card you can't open"

  @doc "Findings with what `user` can't open left out of their links, knowledge and effect."
  def findings(findings, user) do
    can = can(user)
    Enum.map(findings, &finding(&1, can))
  end

  @doc "Questions with cards `user` can't open left out of their words."
  def questions(questions, user) do
    can = can(user)
    Enum.map(questions, &question(&1, can))
  end

  @doc "A change set with the cards and pages `user` can't open named only as that."
  def change_set(%{"changes" => changes} = set, user) do
    can = can(user)

    Map.put(
      set,
      "changes",
      Enum.map(changes, fn c ->
        cond do
          c["op"] in ["update_card", "comment"] and not can.(:card, c["card_id"]) ->
            Map.merge(c, %{"title" => @hidden, "ref" => nil, "fields" => %{}, "body" => nil})

          true ->
            c
        end
      end)
    )
  end

  def change_set(set, _user), do: set

  defp finding(%Finding{} = f, can) do
    hidden_link? = fn l -> not can.(kind(l["type"]), l["id"]) end

    links =
      Enum.map(f.links || [], fn l ->
        if hidden_link?.(l),
          do: %{
            "type" => l["type"],
            "hidden" => true,
            "title" => @hidden,
            "strength" => l["strength"]
          },
          else: l
      end)

    known =
      Enum.reject(f.known || [], fn k ->
        k["type"] in ["card", "page"] and not can.(kind(k["type"]), k["id"])
      end)

    effect =
      case f.effect do
        %{"type" => "card_change", "card_id" => id} = e ->
          if can.(:card, id), do: e, else: Map.merge(e, %{"card_title" => @hidden, "ref" => ""})

        e ->
          e
      end

    %{f | links: links, known: known, effect: effect}
  end

  defp question(%Question{} = q, can) do
    options =
      Enum.map(q.options || [], fn
        %{"value" => "card:" <> id} = o ->
          case Integer.parse(id) do
            {n, ""} ->
              if can.(:card, n),
                do: o,
                else: Map.merge(o, %{"label" => @hidden, "effect" => "change that card"})

            _ ->
              o
          end

        o ->
          o
      end)

    hidden? =
      Enum.any?(q.options || [], &match?(%{"value" => "card:" <> _}, &1)) and options != q.options

    prompt =
      if hidden? and q.kind == "existing_or_new",
        do: "Is this an existing card — one you can't open — or new work?",
        else: q.prompt

    %{q | options: options, prompt: prompt}
  end

  defp kind("page"), do: :page
  defp kind(_), do: :card

  # Whether `user` can open a card or page by id. A capture names a handful,
  # so each is simply asked.
  defp can(user) do
    fn
      _kind, nil -> true
      kind, id -> readable?(user, kind, id)
    end
  end

  defp readable?(nil, _kind, _id), do: false

  defp readable?(user, :card, id) do
    case Repo.get(Card, id) do
      nil -> true
      card -> Access.can_read?(Access.card_permission(user, card))
    end
  end

  defp readable?(user, :page, id) do
    case Repo.get(Page, id) do
      nil -> true
      page -> Access.can_read?(Access.page_permission(user, page))
    end
  end
end
