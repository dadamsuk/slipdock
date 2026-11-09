# The base image for slipdock-runner's container executor (#2577): the
# agents (Claude Code and Codex), the slipdock CLI (an escript, so Erlang),
# git, gh and a shell. docs/manual/machines.md (§Container) says how it is
# used. Build it on the machine that runs the jobs, from this server:
#
#   docker build -t slipdock-agent:1 --build-arg SLIPDOCK_URL=https://app.slipdock.us daemon/images/agent
#
# and allow it in the machine's ceiling.json:
#
#   "executors": ["me", "container"], "container_images": ["slipdock-agent:*"]
#
# A project's own toolchain goes in an image built FROM this one (and that
# image's name goes on the allow-list instead).
#
# Nothing secret is in the image. The daemon mounts the agent's and the
# CLI's logins read-only when a job runs, and the machine's own slipdock
# CLI over the one installed here, so the board's drift check reads what
# runs. Jobs run as the daemon's account (--user), with an empty home.
FROM node:22-bookworm-slim AS node

FROM erlang:27-slim
ARG SLIPDOCK_URL=https://app.slipdock.us

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git gh openssh-client less procps ripgrep \
 && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && npm install -g @anthropic-ai/claude-code @openai/codex \
 && npm cache clean --force

# The CLI, checked against the server's SHA256SUMS.
RUN cd /tmp \
 && curl -fsSL "$SLIPDOCK_URL/cli/slipdock.escript" -o slipdock.escript \
 && curl -fsSL "$SLIPDOCK_URL/cli/SHA256SUMS" -o SHA256SUMS \
 && grep ' slipdock.escript$' SHA256SUMS | sha256sum -c - \
 && install -m 0755 slipdock.escript /usr/local/bin/slipdock \
 && rm -f slipdock.escript SHA256SUMS

ENV PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8
CMD ["/bin/sh"]
