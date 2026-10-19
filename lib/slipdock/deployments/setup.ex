defmodule Slipdock.Deployments.Setup do
  @moduledoc """
  "Track deployments" (#1134): the answers to three questions turned into
  exactly what to paste — which CI runs the deploy (`github`, `gitlab` or
  `shell`), which environments it deploys to, and how its commit messages
  name cards — following `Slipdock.Runners.Setup`.

  One generator behind the board-settings wizard, `POST
  /api/boards/:board/deployments/setup` and `slipdock deploy setup`, so the
  three can't tell people different things. `generate/2` writes text and
  nothing else; `connect/3` is what turns the board's delivery metrics on
  and issues its deploy token, which the text shows once.

  `prompt/2` is the other way in: a prompt to paste into Claude Code in the
  repository, which states the contract and points at the worked examples
  served from `/deploy/examples/`, and has the agent find the deploy step,
  wrap it and try it with `--dry-run`. The same prompt is the guide's
  *Deployments* section, so an agent with the MCP tools can do it all.
  """

  alias Slipdock.{Boards, Deployments}
  alias Slipdock.Boards.Board

  @cis ~w(github gitlab shell)
  @examples %{
    "github" => "github-actions.yml",
    "gitlab" => "gitlab-ci.yml",
    "shell" => "deploy.sh"
  }
  @curl_example "curl.sh"

  @defaults %{"ci" => "github", "environments" => "production", "card_ref_pattern" => ""}

  @token_placeholder "sdd_YOUR_DEPLOY_TOKEN"
  @secret "SLIPDOCK_DEPLOY_TOKEN"

  def cis, do: @cis
  def defaults, do: @defaults
  def token_placeholder, do: @token_placeholder
  def secret_name, do: @secret

  @doc "Every worked example, as served under `/deploy/examples/`."
  def example_files, do: Map.values(@examples) ++ [@curl_example]

  @doc "What each CI is called in the wizard."
  def label("github"), do: "GitHub Actions"
  def label("gitlab"), do: "GitLab CI"
  def label("shell"), do: "Another CI, or a shell script"

  @doc """
  The answers, checked and filled in: `{:ok, answers}` with `environments`
  as a list, or `{:error, message}`. Keys and values are strings, as a form
  sends them.
  """
  def normalise(answers) do
    a =
      for {k, v} <- answers || %{}, Map.has_key?(@defaults, to_string(k)), into: @defaults do
        {to_string(k), if(is_binary(v), do: String.trim(v), else: v)}
      end

    envs =
      case a["environments"] do
        list when is_list(list) -> list
        text -> String.split(to_string(text), ~r/[\s,]+/, trim: true)
      end
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    pattern = to_string(a["card_ref_pattern"] || "")
    pattern_check = Board.changeset(%Board{}, %{"card_ref_pattern" => pattern})

    cond do
      a["ci"] not in @cis ->
        {:error, "ci must be one of: #{Enum.join(@cis, ", ")}"}

      envs == [] ->
        {:error, "name at least one environment, such as production"}

      Enum.any?(envs, &(not Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._\/-]{0,59}$/, &1))) ->
        {:error, "environments are letters, digits, dots, slashes, hyphens or underscores"}

      Keyword.has_key?(pattern_check.errors, :card_ref_pattern) ->
        {msg, _} = Keyword.fetch!(pattern_check.errors, :card_ref_pattern)
        {:error, "card_ref_pattern #{msg}"}

      true ->
        {:ok, %{a | "environments" => envs, "card_ref_pattern" => pattern}}
    end
  end

  @doc """
  Turns `board`'s delivery metrics on (with its card pattern, when one is
  given) and issues it a new deploy token, replacing any it had: `{:ok,
  board, generated}` with the token in the text, once.
  """
  def connect(%Board{} = board, params, base_url) do
    with {:ok, a} <- normalise(params),
         {:ok, board} <-
           Boards.update_board(
             board,
             %{"delivery_metrics" => true}
             |> then(
               &if(a["card_ref_pattern"] != "",
                 do: Map.put(&1, "card_ref_pattern", a["card_ref_pattern"]),
                 else: &1
               )
             )
           ),
         {:ok, token, board} <- Deployments.issue_token(board) do
      {:ok, board, generate(a, %{board: board, base_url: base_url, token: token})}
    end
  end

  @doc """
  What to paste: `%{text, snippet, prompt, example_urls}`. `ctx` has the
  `board`, the server's `base_url` and the new `token` (nil writes a
  placeholder: the token is only ever shown when it is issued).
  """
  def generate(a, ctx) do
    base = String.trim_trailing(ctx.base_url, "/")
    token = ctx[:token] || @token_placeholder
    env = hd(a["environments"])

    %{
      text: text(a, ctx.board, base, token),
      snippet: snippet(a["ci"], env),
      prompt: prompt(a, %{board: ctx.board, base_url: base}),
      example_urls: example_urls(a["ci"], base)
    }
  end

  defp text(a, board, base, token) do
    env = hd(a["environments"])

    """
    Track deployments for #{board.name} (#{board.code}) from #{label(a["ci"])}

    1. Keep this deploy token as the secret #{@secret} (it is shown this once; it records deploys for this board and can do nothing else):

       #{token}

       #{where_secret(a["ci"])}

    2. Set SLIPDOCK_URL to #{base}.

    3. Wrap the deploy step:

    #{indent(snippet(a["ci"], env), 3)}

    #{more_envs(a["environments"])}4. Try it from a checkout first — it checks the token and shows the commits and cards it would record, and records nothing:

       SLIPDOCK_URL=#{base} #{@secret}=… slipdock deploy run --env #{env} --dry-run -- true

    The board shows the first deploy as soon as it arrives. A worked example: #{hd(example_urls(a["ci"], base))}
    """
  end

  defp where_secret("github"),
    do:
      "GitHub: Settings → Secrets and variables → Actions → New repository secret; and SLIPDOCK_URL as a variable."

  defp where_secret("gitlab"),
    do: "GitLab: Settings → CI/CD → Variables, masked; and SLIPDOCK_URL as a plain variable."

  defp where_secret("shell"),
    do: "In the environment the deploy runs in, never in the script itself."

  defp more_envs([_]), do: ""

  defp more_envs([_ | rest]),
    do:
      "   Deploys to #{Enum.join(rest, ", ")} are the same step with --env #{Enum.join(rest, " / --env ")}.\n\n"

  @doc "The deploy step for a CI, wrapped."
  def snippet("github", env) do
    """
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0          # the whole history: the commits since the last deploy
    - uses: erlef/setup-beam@v1
      with:
        otp-version: "27"
    - run: |
        curl -fsSL "$SLIPDOCK_URL/cli/slipdock.escript" -o "$RUNNER_TEMP/slipdock"
        chmod +x "$RUNNER_TEMP/slipdock" && echo "$RUNNER_TEMP" >> "$GITHUB_PATH"
      env:
        SLIPDOCK_URL: ${{ vars.SLIPDOCK_URL }}
    - name: Deploy
      run: slipdock deploy run --env #{env} --tag "$TAG" -- ./deploy.sh "$TAG"
      env:
        SLIPDOCK_URL: ${{ vars.SLIPDOCK_URL }}
        SLIPDOCK_DEPLOY_TOKEN: ${{ secrets.SLIPDOCK_DEPLOY_TOKEN }}
    """
  end

  def snippet("gitlab", env) do
    """
    deploy:
      image: erlang:27
      variables:
        GIT_DEPTH: "0"          # the whole history: the commits since the last deploy
      script:
        - curl -fsSL "$SLIPDOCK_URL/cli/slipdock.escript" -o /usr/local/bin/slipdock
        - chmod +x /usr/local/bin/slipdock
        - slipdock deploy run --env #{env} --tag "$CI_COMMIT_SHORT_SHA" -- ./deploy.sh
    """
  end

  def snippet("shell", env) do
    """
    # a full clone (not shallow), Erlang installed, SLIPDOCK_URL and SLIPDOCK_DEPLOY_TOKEN set
    curl -fsSL "$SLIPDOCK_URL/cli/slipdock.escript" -o ~/.local/bin/slipdock && chmod +x ~/.local/bin/slipdock
    slipdock deploy run --env #{env} --tag "$TAG" -- ./deploy.sh "$TAG"
    """
  end

  defp example_urls(ci, base),
    do: [
      "#{base}/deploy/examples/#{@examples[ci]}",
      "#{base}/deploy/examples/#{@curl_example}"
    ]

  @doc """
  The prompt to paste into Claude Code in the repository: the contract, the
  worked examples, and what to do — find the deploy step, wrap it, name the
  secret to add, try it with `--dry-run`. No token in it: the person adds
  the secret themselves. `ctx` has `base_url` and, when there is one, the
  `board`.
  """
  def prompt(a, ctx) do
    base = String.trim_trailing(ctx.base_url, "/")
    board = ctx[:board]
    envs = Enum.join(a["environments"], ", ")

    pattern =
      if a["card_ref_pattern"] in [nil, ""],
        do: "#123",
        else: "the regex #{a["card_ref_pattern"]}"

    """
    Make this repository record its deploys on the Slipdock board #{if board, do: "#{board.code} ", else: ""}at #{base}, so the board can show its delivery (DORA) metrics.

    The contract:
    - Deploys are recorded by wrapping the existing deploy command: `slipdock deploy run --env <environment> [--tag <version>] -- <deploy command…>`. It asks the board for the environment's last deployed commit, sends the commits since then (git log), records the deploy started, runs the command with its output passed through, records it succeeded or failed from the exit code, and exits with that code. A board that can't be reached never stops the deploy.
    - Where the deploy isn't one command, `slipdock deploy start --env E` prints an id before it and `slipdock deploy finish --id ID --status succeeded|failed` records how it ended — run the finish even when an earlier step failed.
    - The job needs the full git history (GitHub Actions: `fetch-depth: 0` on actions/checkout; GitLab: `GIT_DEPTH: "0"`), Erlang for the CLI (erlef/setup-beam, or an erlang image), and the CLI itself: `curl -fsSL "$SLIPDOCK_URL/cli/slipdock.escript" -o slipdock && chmod +x slipdock`. Where none of that can go, #{base}/deploy/examples/#{@curl_example} does the same with curl, git and jq.
    - Two settings: SLIPDOCK_URL=#{base} (a plain variable), and SLIPDOCK_DEPLOY_TOKEN, a secret — the board's deploy token, which records deploys and can do nothing else. Never write the token into a file.
    - Environments deployed to: #{envs}. Commits name cards as #{pattern}, in the subject or body; nothing else in the commit needs to change.

    Worked examples to start from:
    #{Enum.map_join(@cis, "\n", &"- #{label(&1)}: #{base}/deploy/examples/#{@examples[&1]}")}

    What to do:
    1. Find where this repository deploys (#{label(a["ci"])} most likely) — the step or job that puts a release on each of: #{envs}. If there is more than one candidate, ask me which.
    2. Wrap that step as above, keeping the deploy command exactly as it is, and add the history, Erlang and CLI install it needs. Don't touch build or test jobs.
    3. Tell me the secret to add (SLIPDOCK_DEPLOY_TOKEN) and where, and the SLIPDOCK_URL variable. The token comes from the board's settings (Delivery metrics → Set up) or `slipdock deploy token #{if board, do: board.code, else: "<board>"}`.
    4. Check it: with SLIPDOCK_DEPLOY_TOKEN set, run `slipdock deploy run --env #{hd(a["environments"])} --dry-run -- true` in this checkout, show me the commit range and cards it found, and fix anything it complains about (a shallow clone, a missing token).
    """
  end

  defp indent(text, n) do
    pad = String.duplicate(" ", n)
    text |> String.trim_trailing() |> String.split("\n") |> Enum.map_join("\n", &(pad <> &1))
  end
end
