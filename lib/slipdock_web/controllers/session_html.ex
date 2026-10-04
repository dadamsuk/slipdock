defmodule SlipdockWeb.SessionHTML do
  @moduledoc "The page a sign-in link opens: one button, which signs in."
  use SlipdockWeb, :html

  embed_templates "session_html/*"
end
