#!/usr/bin/env bash

# Non-transactional reference implementation of `tripapiers sort`.
# It intentionally composes the public take/extract/classify commands.

set -uo pipefail

tripapiers_bin=${TRIPAPIERS_BIN:-tripapiers}
declare -a global_args=()

usage() {
  printf '%s\n' 'Usage: sort-reference.sh [--config <path>] [--root <path>]'
}

while (($# > 0)); do
  case $1 in
    --config|--root)
      if (($# < 2)); then
        usage >&2
        exit 2
      fi
      global_args+=("$1" "$2")
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

config_output=$(
  "$tripapiers_bin" "${global_args[@]}" config show --format shell
) || exit $?

inbox_dir=
quarantine_dir=
documents_dir=
ocr_dir=
tags_dir=

while IFS='=' read -r key value; do
  case $key in
    paths.inbox) inbox_dir=$value ;;
    paths.quarantine) quarantine_dir=$value ;;
    paths.documents) documents_dir=$value ;;
    paths.ocr) ocr_dir=$value ;;
    paths.tags) tags_dir=$value ;;
  esac
done <<<"$config_output"

for required_path in \
  "$inbox_dir" \
  "$quarantine_dir" \
  "$documents_dir" \
  "$ocr_dir" \
  "$tags_dir"; do
  if [[ -z $required_path ]]; then
    printf '%s\n' 'Incomplete path configuration from `config show --format shell`.' >&2
    exit 2
  fi
done

if [[ ! -d $inbox_dir ]]; then
  printf 'INBOX directory does not exist: %s\n' "$inbox_dir" >&2
  exit 3
fi

yaml_string() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}

short_sha() {
  local path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" | cut -c1-12
  else
    shasum -a 256 -- "$path" | cut -c1-12
  fi
}

quarantine_available() {
  local phase=$1
  local exit_code=$2
  local filename=$3
  local added_date=$4
  shift 4

  local first_existing=
  local candidate
  for candidate in "$@"; do
    if [[ -f $candidate ]]; then
      first_existing=$candidate
      break
    fi
  done

  if [[ -z $first_existing ]]; then
    printf 'Nothing available to quarantine for %s.\n' "$filename" >&2
    return 1
  fi

  local year=${added_date%%-*}
  local remainder=${added_date#*-}
  local month=${remainder%%-*}
  local day=${added_date##*-}
  local digest
  digest=$(short_sha "$first_existing") || return 1

  local destination="$quarantine_dir/$year/$month/$day/$filename--$digest"
  if [[ -e $destination ]]; then
    destination="$destination--$(date +%s)-$$"
  fi
  mkdir -p -- "$destination" || return 1

  for candidate in "$@"; do
    if [[ -f $candidate ]]; then
      mv -- "$candidate" "$destination/" || return 1
    fi
  done

  {
    printf '%s\n' 'schema_version: 1'
    printf 'phase: %s\n' "$(yaml_string "$phase")"
    printf 'exit_code: %s\n' "$exit_code"
    printf 'filename: %s\n' "$(yaml_string "$filename")"
    printf 'added_date: %s\n' "$(yaml_string "$added_date")"
  } >"$destination/report.yml" || return 1

  printf 'Quarantined %s after %s failure: %s\n' \
    "$filename" "$phase" "$destination" >&2
}

batch_failed=0

while IFS= read -r -d '' source_path; do
  filename=${source_path##*/}

  case $filename in
    *.ocr.yml|*.tag.yml)
      printf 'Ignoring reserved artifact suffix in INBOX: %s\n' "$source_path" >&2
      continue
      ;;
  esac

  added_date=$(date +%F)
  year=${added_date%%-*}
  remainder=${added_date#*-}
  month=${remainder%%-*}
  day=${added_date##*-}

  document_path="$documents_dir/$year/$month/$day/$filename"
  ocr_path="$ocr_dir/$year/$month/$day/$filename.ocr.yml"
  tag_path="$tags_dir/$year/$month/$day/$filename.tag.yml"

  if "$tripapiers_bin" "${global_args[@]}" \
    take "$source_path" --name "$filename" --date "$added_date"; then
    :
  else
    command_exit=$?
    quarantine_available take "$command_exit" "$filename" "$added_date" \
      "$source_path" || batch_failed=1
    batch_failed=1
    continue
  fi

  if "$tripapiers_bin" "${global_args[@]}" \
    extract --name "$filename" --date "$added_date"; then
    :
  else
    command_exit=$?
    quarantine_available extract "$command_exit" "$filename" "$added_date" \
      "$document_path" "$ocr_path" || batch_failed=1
    batch_failed=1
    continue
  fi

  if "$tripapiers_bin" "${global_args[@]}" \
    classify --name "$filename" --date "$added_date"; then
    :
  else
    command_exit=$?
    quarantine_available classify "$command_exit" "$filename" "$added_date" \
      "$document_path" "$ocr_path" "$tag_path" || batch_failed=1
    batch_failed=1
    continue
  fi
done < <(find "$inbox_dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)

exit "$batch_failed"
