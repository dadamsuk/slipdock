defmodule SlipdockWeb.OAuth.AuthorizeHTML do
  @moduledoc "The OAuth consent page, and what it says when it cannot ask."
  use SlipdockWeb, :html

  embed_templates "authorize_html/*"

  @doc "Where an approval would be sent, as a person would read it."
  def destination(uri) do
    case URI.parse(uri) do
      %URI{scheme: "http", host: host} when host in ~w(localhost 127.0.0.1 ::1) ->
        "an app on this computer (#{host})"

      %URI{host: host} ->
        host
    end
  end
end
