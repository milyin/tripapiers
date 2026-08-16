#!/usr/bin/env bash

# Équivalent pédagogique et non transactionnel de `tripapiers sort`.

set -u

documents=$(tripapiers "$@" inbox) || exit $?
failed=0

while IFS= read -r path; do
  [[ -n $path ]] || continue

  name=${path##*/}
  added_date=$(date +%F)

  if ! tripapiers "$@" take "$path" \
    --name "$name" --date "$added_date" --quarantine-on-error; then
    failed=1
  elif ! tripapiers "$@" extract \
    --name "$name" --date "$added_date" --quarantine-on-error; then
    failed=1
  elif ! tripapiers "$@" classify \
    --name "$name" --date "$added_date" --quarantine-on-error; then
    failed=1
  fi
done <<<"$documents"

exit "$failed"
