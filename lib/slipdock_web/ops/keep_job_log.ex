defmodule SlipdockWeb.Ops.KeepJobLog do
  @moduledoc """
  Keep this log (#1872), defined once (#3188): writes an ended runner job's
  live log as a page in its card's folder, `Pass <card> (<date>)`, links it
  from the job and stops the log expiring. Keeping it again answers the
  same page. Needs write access to the card.

  Before it, REST answered `{job, page}` with the whole page (its body the
  log) and MCP the job's log header (`job_log`'s `{job, from, next,
  capped}`) with the page's id, code and title: now both answer `{job,
  page}`, the job in full and the page without its body (the log it was
  kept to hand back, which `read_page` reads).
  """
  @behaviour SlipdockWeb.Ops.Op

  import SlipdockWeb.Ops.Shared, only: [via: 1]

  alias Slipdock.{Boards, Runners}
  alias Slipdock.Runners.TranscriptRetention
  alias SlipdockWeb.API.Authorize
  alias SlipdockWeb.API.JSON, as: V

  @impl true
  def definition do
    %{
      name: "keep_job_log",
      title: "Keep a runner job's log",
      summary:
        "Keeps an ended runner job's live log, which otherwise expires: writes it as a page " <>
          "Pass <card> (<date>) in the card's folder and links it from the job. Again gives " <>
          "the same page.",
      verb: :post,
      path: "/api/jobs/:id/keep",
      permission: {:card, :write},
      writes?: true,
      params: [
        %{
          name: "job",
          type: :integer,
          required: true,
          in_path: "id",
          doc: "The job's id (get_card's jobs, slipdock jobs)."
        }
      ],
      cli: %{command: "job --keep", positional: ["job"], flags: %{}}
    }
  end

  @impl true
  def run(%{"job" => id}, auth) do
    with %{} = job <- Runners.get_job(id) || {:error, :not_found, "job"},
         %{} = card <- Boards.Cards.get_card(job.card_id) || {:error, :not_found, "job"},
         :ok <- Authorize.card(auth, card, :write),
         {:ok, page, job} <- keep(job, auth) do
      {:ok, %{job: V.job(job), page: V.page_summary(page)}}
    end
  end

  defp keep(job, auth) do
    case TranscriptRetention.keep(job, auth.assigns.current_user, via: via(auth)) do
      {:ok, page, job} -> {:ok, page, job}
      {:error, %Slipdock.Policy.Refused{}} = refused -> refused
      {:error, {:payment_required, code, message}} -> {:error, :payment_required, code, message}
      {:error, reason} -> {:error, :unprocessable_entity, TranscriptRetention.refusal(reason)}
    end
  end
end
