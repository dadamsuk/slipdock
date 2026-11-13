#!/bin/sh
# Where a release.yml run failed on its way to production (#2820), from the
# results of the jobs on that path: prints build, test, merge, deploy or
# health, or nothing when nothing on the path failed (the deploy went out,
# or only a job off the path failed). The record-failure job records it.
#
#   CLI_BUILD, CLI_SIGN, BUILD, TEST, MERGE, DEPLOY  each job's result
#   DEPLOY_STAGE  the deploy job's own word on it: deploy or health
#
# A cancelled job failed too (#3009): the runner was never acquired, or the
# job ran out of time. The record-failure job doesn't run when a person
# cancelled the run.
set -eu

failed() { [ "${1:-}" = failure ] || [ "${1:-}" = cancelled ]; }

if [ "${DEPLOY:-}" = success ]; then
  exit 0
elif failed "${CLI_BUILD:-}" || failed "${CLI_SIGN:-}" || failed "${BUILD:-}"; then
  echo build
elif failed "${TEST:-}"; then
  echo test
elif failed "${MERGE:-}"; then
  echo merge
elif failed "${DEPLOY:-}"; then
  case ${DEPLOY_STAGE:-} in
    health) echo health ;;
    *) echo deploy ;;
  esac
fi
