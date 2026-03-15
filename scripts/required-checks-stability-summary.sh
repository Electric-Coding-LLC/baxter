#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/required-checks-stability-summary.sh --input-dir /path/to/attempt-metadata --output /path/to/summary.md

Aggregates required-check stability attempt metadata into a markdown summary.
EOF
}

input_dir=""
output_path=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input-dir)
      input_dir="${2:-}"
      shift 2
      ;;
    --output)
      output_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$input_dir" ] || [ -z "$output_path" ]; then
  usage
  exit 1
fi

if [ ! -d "$input_dir" ]; then
  echo "input directory not found: $input_dir" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed" >&2
  exit 1
fi

metadata_files=()
while IFS= read -r metadata_file; do
  metadata_files+=("$metadata_file")
done < <(find "$input_dir" -type f -name 'attempt-*.json' | LC_ALL=C sort)

if [ "${#metadata_files[@]}" -eq 0 ]; then
  echo "no attempt metadata files found under $input_dir" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_path")"

jobs=()
for metadata_file in "${metadata_files[@]}"; do
  job="$(jq -r '.job' "$metadata_file")"
  job_seen=false
  for existing_job in "${jobs[@]:-}"; do
    if [ "$existing_job" = "$job" ]; then
      job_seen=true
      break
    fi
  done
  if [ "$job_seen" = false ]; then
    jobs+=("$job")
  fi
done

{
  echo "# Required Checks Stability Summary"
  echo
  echo "- Generated at (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo

  total_failures=0
  total_successes=0
  total_skipped=0

  for job in "${jobs[@]}"; do
    total_attempts=0
    successes=0
    failures=0
    skipped=0

    echo "## $job"
    echo

    for metadata_file in "${metadata_files[@]}"; do
      current_job="$(jq -r '.job' "$metadata_file")"
      if [ "$current_job" != "$job" ]; then
        continue
      fi

      total_attempts=$((total_attempts + 1))
      result="$(jq -r '.result' "$metadata_file")"
      case "$result" in
        success)
          successes=$((successes + 1))
          ;;
        failure)
          failures=$((failures + 1))
          ;;
        skipped)
          skipped=$((skipped + 1))
          ;;
        *)
          echo "unexpected result '$result' in $metadata_file" >&2
          exit 1
          ;;
      esac
    done

    total_failures=$((total_failures + failures))
    total_successes=$((total_successes + successes))
    total_skipped=$((total_skipped + skipped))

    echo "- attempts: $total_attempts"
    echo "- success: $successes"
    echo "- failure: $failures"
    echo "- skipped: $skipped"
    echo

    if [ "$failures" -gt 0 ]; then
      echo "### Failure ledger"
      echo
      for metadata_file in "${metadata_files[@]}"; do
        current_job="$(jq -r '.job' "$metadata_file")"
        result="$(jq -r '.result' "$metadata_file")"
        if [ "$current_job" != "$job" ] || [ "$result" != "failure" ]; then
          continue
        fi

        attempt="$(jq -r '.attempt' "$metadata_file")"
        failure_step="$(jq -r '.failure_step' "$metadata_file")"
        artifact_name="$(jq -r '.artifact_name' "$metadata_file")"
        echo "- attempt $attempt: $failure_step (artifact: $artifact_name)"
      done
      echo
    fi
  done

  echo "## Overall"
  echo
  echo "- success: $total_successes"
  echo "- failure: $total_failures"
  echo "- skipped: $total_skipped"
} >"$output_path"
