defmodule SlipdockWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.

  An error is a page of the app like any other: the app's styles and theme,
  what happened in words, and a way back to the boards — not a bare line of
  text on a white page. It is rendered without the app's layout (the request
  may have failed before anything a layout needs was loaded), so it carries
  its own head.
  """
  use SlipdockWeb, :html

  def render(template, assigns) do
    status = template |> String.split(".") |> hd()

    error_page(
      Map.merge(assigns, %{
        status: status,
        title: Phoenix.Controller.status_message_from_template(template),
        message: message(status)
      })
    )
  end

  defp message("404"),
    do:
      "There is nothing here — or it is not yours to see. Check the address, or go back to your boards."

  defp message("500"),
    do:
      "This page hit an error on our side. It has been logged, and nothing you did was lost. Try again in a moment, or go back to your boards."

  defp message(_status),
    do: "The request could not be completed. Go back to your boards and try again."

  defp error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title} · Slipdock</title>
        <link rel="icon" href={~p"/favicon.ico"} sizes="any" />
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
        <script src={~p"/assets/js/theme.js"}>
        </script>
      </head>
      <body class="min-h-screen bg-base-200 text-base-content">
        <main class="mx-auto flex min-h-screen max-w-lg flex-col items-center justify-center gap-4 px-6 text-center">
          <p class="font-mono text-sm text-base-content/50">{@status}</p>
          <h1 class="text-2xl font-semibold">{@title}</h1>
          <p class="text-base-content/70">{@message}</p>
          <a href={~p"/"} class="btn btn-primary btn-sm mt-2">Back to your boards</a>
        </main>
      </body>
    </html>
    """
  end
end
