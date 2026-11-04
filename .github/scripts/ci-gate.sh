#!/usr/bin/env bash
# The CI gate: one answer for the whole run. Fails when classification failed,
# when any job failed or was cancelled, or when a job classification selected
# was skipped anyway (a skip because a dependency broke is not a pass). A job
# classification did not select may skip.
#
# Inputs (env):
#   NEEDS     toJSON(needs) from the workflow
#   SELECTED  space-separated jobs classification may skip when not selected,
#             each as <job>=<true|false>
set -Eeuo pipefail
: "${NEEDS:?}"

bad=0
classify=$(jq -r '.classify.result // "missing"' <<<"$NEEDS")
if [ "$classify" != success ]; then
  echo "::error title=CI gate::Classify changes: $classify"
  bad=1
fi

while IFS=$'\t' read -r job result; do
  selected=true
  for s in ${SELECTED:-}; do
    if [ "${s%%=*}" = "$job" ]; then selected=${s#*=}; fi
  done
  case "$result" in
    success) echo "ok       $job" ;;
    skipped)
      if [ "$selected" = true ]; then
        echo "::error title=CI gate::$job was skipped but this change needs it"
        bad=1
      else
        echo "skipped  $job (not affected by this change)"
      fi
      ;;
    *)
      echo "::error title=CI gate::$job: $result"
      bad=1
      ;;
  esac
done < <(jq -r 'to_entries[] | select(.key != "classify") | [.key, .value.result] | @tsv' <<<"$NEEDS")

exit "$bad"
