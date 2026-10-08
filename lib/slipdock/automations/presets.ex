defmodule Slipdock.Automations.Presets do
  @moduledoc """
  Ready-made automations: the rules most boards want, picked from a list and
  filled in with a short form instead of written as a sentence. No model is
  involved — each preset is a function from a few form values to an ordinary
  spec (see `Slipdock.Automations.Spec`), stored and run like any other rule,
  so a preset works on a server with no AI key and can be read, switched off
  or deleted like anything written by hand.

  A preset is described by data (`all/0`) so the web form, the API and the
  CLI all draw the same fields: each one has a `name`, a `label`, a `type`
  (`column`, `tag`, `flag`, `field`, `priority`, `person`, `notify`, `email`,
  `number`, `url`, `card`, `text`) and whether it is `required`. `build/3` turns the
  values into rule attributes, or says which one is wrong.
  """

  alias Slipdock.Automations.Spec
  alias Slipdock.Boards.Board

  @flags ~w(blocked waiting review flagged starred)
  @card_fields ~w(title description priority due_date start_date percent_complete assignee flags color)

  # How a "tell me" preset tells you.
  @notify_options [
    {"alert", "Alert in the header bar"},
    {"email", "Email"},
    {"alert_email", "Alert and email"},
    {"assignees", "Email whoever the card is assigned to"}
  ]

  @notify %{
    name: "notify",
    label: "Tell me by",
    type: "notify",
    required: true,
    default: "alert"
  }
  @email %{
    name: "email",
    label: "Email to",
    type: "email",
    required: false,
    hint: "for email; defaults to you"
  }

  @presets [
    %{
      key: "follow_board",
      group: "Follow",
      title: "Follow this board",
      description: "Hear about every new card added to the board.",
      fields: [@notify, @email]
    },
    %{
      key: "follow_list",
      group: "Follow",
      title: "Follow a list",
      description:
        "Hear about every card that arrives in a list, whether added there or moved in.",
      fields: [
        %{name: "column", label: "List", type: "column", required: true},
        @notify,
        @email
      ]
    },
    %{
      key: "follow_card",
      group: "Follow",
      title: "Follow a card",
      description:
        "Hear about anything that happens to one card: changes, moves, comments, tags, archiving.",
      fields: [
        %{name: "card", label: "Card number", type: "card", required: true},
        @notify,
        @email
      ]
    },
    %{
      key: "watch_comments",
      group: "Follow",
      title: "Comments",
      description: "Hear about every new comment, optionally only on one person's cards.",
      fields: [
        %{
          name: "assignee",
          label: "Only on cards assigned to",
          type: "person",
          required: false
        },
        @notify,
        @email
      ]
    },
    %{
      key: "watch_field",
      group: "Follow",
      title: "A field changes",
      description:
        "Hear when a card's priority, due date, assignee or another field is changed — or any of them.",
      fields: [
        %{name: "field", label: "Field", type: "field", required: false, hint: "blank for any"},
        @notify,
        @email
      ]
    },
    %{
      key: "assigned",
      group: "Follow",
      title: "Assigned to someone",
      description: "Hear when a card is assigned to a person — yourself, usually.",
      fields: [
        %{
          name: "assignee",
          label: "Person",
          type: "person",
          required: false,
          hint: "blank for you"
        },
        @notify,
        @email
      ]
    },
    %{
      key: "flagged",
      group: "Follow",
      title: "A card is flagged",
      description: "Hear when a card is flagged blocked, waiting or for review.",
      fields: [
        %{name: "flag", label: "Flag", type: "flag", required: true, default: "blocked"},
        @notify,
        @email
      ]
    },
    %{
      key: "due_soon",
      group: "Remind",
      title: "Due soon",
      description: "A reminder when a card's due date is near.",
      fields: [
        %{name: "hours", label: "Hours before", type: "number", required: true, default: 24},
        @notify,
        @email
      ]
    },
    %{
      key: "overdue",
      group: "Remind",
      title: "Overdue",
      description: "A warning once a card's due date has passed.",
      fields: [@notify, @email]
    },
    %{
      key: "stale",
      group: "Remind",
      title: "Gone quiet",
      description: "A nudge when a card has not been touched for a number of days.",
      fields: [
        %{name: "days", label: "Days untouched", type: "number", required: true, default: 7},
        %{name: "column", label: "Only in list", type: "column", required: false},
        @notify,
        @email
      ]
    },
    %{
      key: "complete_in_done",
      group: "Tidy",
      title: "Complete cards in Done",
      description: "Tick a card off when it lands in the done list, so nobody has to do both.",
      fields: [
        %{name: "column", label: "Done list", type: "column", required: true, prefill: "done"}
      ]
    },
    %{
      key: "archive_done",
      group: "Tidy",
      title: "Archive finished work",
      description: "Archive cards that have sat in the done list for a while.",
      fields: [
        %{name: "column", label: "Done list", type: "column", required: true, prefill: "done"},
        %{name: "days", label: "After days", type: "number", required: true, default: 14}
      ]
    },
    %{
      key: "tag_priority",
      group: "Tidy",
      title: "Tag sets priority",
      description: "Raise a card's priority when it is given a tag, such as urgent.",
      fields: [
        %{name: "tag", label: "Tag", type: "tag", required: true},
        %{
          name: "priority",
          label: "Priority",
          type: "priority",
          required: true,
          default: "critical"
        }
      ]
    },
    %{
      key: "webhook",
      group: "Connect",
      title: "Call a URL on every change",
      description:
        "POST the card to another system whenever anything happens to a card on the board.",
      fields: [%{name: "url", label: "URL", type: "url", required: true}]
    },
    %{
      key: "send_to_runner",
      group: "Connect",
      title: "Send cards to a runner",
      description:
        "When a card arrives in a list, queue it for a runner on your own machine, which works " <>
          "it with Claude Code or whatever its config says the kind of job means.",
      fields: [
        %{name: "column", label: "List", type: "column", required: true},
        %{name: "pool", label: "Runner pool", type: "text", required: true, default: "default"},
        %{name: "kind", label: "Kind of job", type: "text", required: false, default: "claude"}
      ]
    }
  ]

  @keys Enum.map(@presets, & &1.key)

  @doc "Every preset, in the order the gallery shows them."
  def all, do: Enum.map(@presets, &with_options/1)

  @doc "The preset keys."
  def keys, do: @keys

  @doc "One preset by key, or nil."
  def get(key), do: Enum.find(all(), &(&1.key == to_string(key)))

  @doc "The ways a preset can tell someone, as `{value, label}`."
  def notify_options, do: @notify_options

  @doc "The fields a `card_updated` trigger can name."
  def card_fields, do: @card_fields

  @doc "The flags a preset can watch for."
  def flags, do: @flags

  defp with_options(preset) do
    fields =
      Enum.map(preset.fields, fn field ->
        case field.type do
          "notify" -> Map.put(field, :options, Enum.map(@notify_options, &elem(&1, 0)))
          "field" -> Map.put(field, :options, @card_fields)
          "flag" -> Map.put(field, :options, @flags)
          "priority" -> Map.put(field, :options, ~w(low medium high critical))
          _ -> field
        end
      end)

    %{preset | fields: fields}
  end

  @doc """
  The form's starting values: each field's default, and for a field marked
  `prefill: "done"` the board's done list. A map of field name to value.
  """
  def defaults(%{} = preset, %Board{} = board) do
    done = Enum.find(board.columns || [], &(&1.category == "done"))

    Map.new(preset.fields, fn field ->
      value =
        cond do
          Map.has_key?(field, :default) -> field.default
          field[:prefill] == "done" and done -> done.name
          true -> nil
        end

      {field.name, value}
    end)
  end

  @doc """
  Turns a preset and its form values into the attributes of a rule
  (`"name"`, `"spec"`, `"scope"`), ready for `Slipdock.Automations.create_rule/2`.
  `opts[:user]` is who "me" is: the default email and the default assignee.
  """
  @spec build(String.t(), map, keyword) :: {:ok, map} | {:error, String.t()}
  def build(key, params, opts \\ []) do
    case get(key) do
      nil ->
        {:error, "unknown preset “#{key}” — one of #{Enum.join(@keys, ", ")}"}

      preset ->
        params = Map.merge(field_defaults(preset), present(normalise(params)))

        with :ok <- required(preset, params),
             {:ok, name, trigger, conditions, actions} <- spec(key, params, opts),
             spec = %{"trigger" => trigger, "conditions" => conditions, "actions" => actions},
             {:ok, spec} <- Spec.validate(spec) do
          {:ok, %{"name" => name, "spec" => spec, "scope" => "board"}}
        end
    end
  end

  defp normalise(params) do
    Map.new(params || %{}, fn {k, v} ->
      {to_string(k), if(is_binary(v), do: String.trim(v), else: v)}
    end)
  end

  # What a caller leaves out takes the field's default, so `{"column": "Doing"}`
  # is enough for "follow a list".
  defp field_defaults(preset) do
    for field <- preset.fields,
        Map.has_key?(field, :default),
        into: %{},
        do: {field.name, field.default}
  end

  defp present(params), do: Map.reject(params, fn {_, v} -> blank?(v) end)

  defp required(preset, params) do
    missing =
      for field <- preset.fields, field.required, blank?(params[field.name]), do: field.label

    if missing == [],
      do: :ok,
      else: {:error, "#{preset.title} needs #{Enum.join(missing, ", ")}"}
  end

  ## The presets --------------------------------------------------------------

  defp spec("follow_board", p, opts) do
    notify(p, opts, "Followed: new cards on the board", %{"type" => "card_created"}, [],
      title: "New card: {{card.title}}"
    )
  end

  defp spec("follow_list", p, opts) do
    column = p["column"]

    notify(p, opts, "Followed: #{column}", %{"type" => "card_entered", "column" => column}, [],
      title: "In #{column}: {{card.title}}"
    )
  end

  defp spec("follow_card", p, opts) do
    case card_id(p["card"]) do
      nil ->
        {:error, "Card number must be a number, like 129"}

      id ->
        notify(
          p,
          opts,
          "Followed: card ##{id}",
          %{"type" => "card_activity"},
          [%{"field" => "card", "op" => "is", "value" => id}],
          title: "{{card.title}}: {{event}}"
        )
    end
  end

  defp spec("watch_comments", p, opts) do
    {name, conditions} =
      case p["assignee"] do
        blank when blank in [nil, ""] ->
          {"Followed: comments", []}

        person ->
          {"Followed: comments on #{person}'s cards",
           [%{"field" => "assignee", "op" => "is", "value" => person}]}
      end

    notify(p, opts, name, %{"type" => "comment_added"}, conditions,
      title: "New comment on {{card.title}}"
    )
  end

  defp spec("watch_field", p, opts) do
    case p["field"] do
      blank when blank in [nil, ""] ->
        notify(p, opts, "Followed: card changes", %{"type" => "card_updated"}, [],
          title: "Changed: {{card.title}}"
        )

      field ->
        if Enum.member?(@card_fields, field) do
          label = String.replace(field, "_", " ")

          notify(
            p,
            opts,
            "Followed: #{label} changes",
            %{"type" => "card_updated", "field" => field},
            [],
            title: "#{String.capitalize(label)} changed: {{card.title}}"
          )
        else
          {:error, "Field must be one of #{Enum.join(@card_fields, ", ")}"}
        end
    end
  end

  defp spec("assigned", p, opts) do
    person = blank_or(p["assignee"], opts[:user] && opts[:user].email)
    trigger = %{"type" => "card_assigned", "assignee" => person}
    name = if person, do: "Followed: cards assigned to #{person}", else: "Followed: assignments"

    notify(p, opts, name, trigger, [], title: "Assigned: {{card.title}}")
  end

  defp spec("flagged", p, opts) do
    flag = p["flag"]

    if Enum.member?(@flags, flag) do
      notify(p, opts, "Followed: #{flag} cards", %{"type" => "flag_added", "flag" => flag}, [],
        title: "Flagged #{flag}: {{card.title}}",
        severity: "warning"
      )
    else
      {:error, "Flag must be one of #{Enum.join(@flags, ", ")}"}
    end
  end

  defp spec("due_soon", p, opts) do
    with {:ok, hours} <- positive(p["hours"], "Hours before") do
      notify(
        p,
        opts,
        "Reminder: due within #{hours} hours",
        %{"type" => "card_due_soon", "within_hours" => hours},
        [%{"field" => "completed", "op" => "is", "value" => false}],
        title: "Due soon: {{card.title}}",
        severity: "warning"
      )
    end
  end

  defp spec("overdue", p, opts) do
    notify(
      p,
      opts,
      "Reminder: overdue cards",
      %{"type" => "card_overdue"},
      [%{"field" => "completed", "op" => "is", "value" => false}],
      title: "Overdue: {{card.title}}",
      severity: "urgent"
    )
  end

  defp spec("stale", p, opts) do
    with {:ok, days} <- positive(p["days"], "Days untouched") do
      trigger =
        %{"type" => "card_stale", "days" => days}
        |> put_present("column", p["column"])

      where = if blank?(p["column"]), do: "", else: " in #{p["column"]}"

      notify(
        p,
        opts,
        "Reminder: untouched for #{days} days#{where}",
        trigger,
        [%{"field" => "completed", "op" => "is", "value" => false}],
        title: "Gone quiet: {{card.title}}"
      )
    end
  end

  defp spec("complete_in_done", p, _opts) do
    column = p["column"]

    {:ok, "Complete cards in #{column}", %{"type" => "card_entered", "column" => column},
     [%{"field" => "completed", "op" => "is", "value" => false}], [%{"type" => "complete_card"}]}
  end

  defp spec("archive_done", p, _opts) do
    column = p["column"]

    with {:ok, days} <- positive(p["days"], "After days") do
      {:ok, "Archive what has sat in #{column} for #{days} days",
       %{"type" => "card_stale", "days" => days, "column" => column}, [],
       [%{"type" => "archive_card"}]}
    end
  end

  defp spec("tag_priority", p, _opts) do
    tag = p["tag"]
    priority = p["priority"]

    if Enum.member?(~w(low medium high critical), priority) do
      {:ok, "Tagged #{tag} means #{priority} priority", %{"type" => "tag_added", "tag" => tag},
       [], [%{"type" => "set_priority", "priority" => priority}]}
    else
      {:error, "Priority must be low, medium, high or critical"}
    end
  end

  defp spec("webhook", p, _opts) do
    url = p["url"]

    if is_binary(url) and String.match?(url, ~r{\Ahttps?://\S+\z}) do
      {:ok, "Call #{webhook_host(url)} on every change", %{"type" => "card_activity"}, [],
       [%{"type" => "webhook", "url" => url, "method" => "post"}]}
    else
      {:error, "URL must start with http:// or https://"}
    end
  end

  defp spec("send_to_runner", p, _opts) do
    column = p["column"]
    pool = p["pool"] |> to_string() |> String.downcase()
    kind = p["kind"] |> blank_or("claude") |> to_string() |> String.downcase()

    {:ok, "Send #{column} to the #{pool} runners",
     %{"type" => "card_entered", "column" => column}, [],
     [%{"type" => "runner", "pool" => pool, "kind" => kind}]}
  end

  # The rule is named after the host alone: a long URL in full would run past
  # the 120 characters a rule's name may have.
  defp webhook_host(url) do
    host =
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) and host != "" -> host
        _ -> url
      end

    String.slice(host, 0, 90)
  end

  ## Telling someone ----------------------------------------------------------

  defp notify(p, opts, name, trigger, conditions, message) do
    with {:ok, actions} <- notify_actions(p, opts, message) do
      {:ok, name, trigger, conditions, actions}
    end
  end

  defp notify_actions(p, opts, message) do
    title = message[:title]
    alert = %{"type" => "alert", "title" => title, "severity" => message[:severity] || "info"}
    email = blank_or(p["email"], opts[:user] && opts[:user].email)

    case blank_or(p["notify"], "alert") do
      "alert" ->
        {:ok, [alert]}

      "email" ->
        with {:ok, to} <- address(email), do: {:ok, [email_action(to, title)]}

      "alert_email" ->
        with {:ok, to} <- address(email), do: {:ok, [alert, email_action(to, title)]}

      "assignees" ->
        {:ok, [%{"type" => "notify_assignee", "subject" => title}]}

      other ->
        {:error,
         "“#{other}” isn't a way to tell anyone — one of " <>
           Enum.map_join(@notify_options, ", ", &elem(&1, 0))}
    end
  end

  defp email_action(to, title),
    do: %{"type" => "email", "to" => to, "subject" => title, "body" => "{{card.url}}"}

  defp address(nil), do: {:error, "Email to is needed to send an email"}

  # The same test the notifier makes before sending, so a rule that saves is
  # one whose email can go.
  defp address(email) do
    cond do
      Slipdock.Automations.Notifier.valid_email?(email) -> {:ok, email}
      is_binary(email) -> {:error, "“#{email}” isn't an email address"}
      true -> {:error, "Email to must be an email address"}
    end
  end

  ## Helpers ------------------------------------------------------------------

  defp positive(value, label) do
    case value do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "#{label} must be a whole number above 0"}
        end

      _ ->
        {:error, "#{label} must be a whole number above 0"}
    end
  end

  defp card_id(n) when is_integer(n) and n > 0, do: n

  defp card_id(s) when is_binary(s) do
    case Integer.parse(String.trim_leading(s, "#")) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp card_id(_), do: nil

  defp blank_or(value, default), do: if(blank?(value), do: default, else: value)

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
