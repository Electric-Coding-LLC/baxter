#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/rc-validation-summary.sh --summary-json /path/to/summary.json --output /path/to/summary.md

Renders RC validation JSON into a markdown summary for workflow step output.
EOF
}

summary_json_path=""
output_path=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary-json)
      summary_json_path="${2:-}"
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

if [ -z "$summary_json_path" ] || [ -z "$output_path" ]; then
  usage
  exit 1
fi

if [ ! -f "$summary_json_path" ]; then
  echo "summary json not found: $summary_json_path" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_path")"

SUMMARY_JSON_PATH="$summary_json_path" OUTPUT_PATH="$output_path" python3 <<'PY'
import json
import os
from pathlib import Path

summary_path = Path(os.environ["SUMMARY_JSON_PATH"])
output_path = Path(os.environ["OUTPUT_PATH"])
summary = json.loads(summary_path.read_text(encoding="utf-8"))

def fmt_status(value: str) -> str:
    mapping = {
        "pass": "pass",
        "fail": "fail",
        "pending": "pending",
    }
    return mapping.get(value, value or "unknown")

lines = [
    "## RC Validation Summary",
    "",
    f"- version: `{summary.get('version', '')}`",
    f"- date (UTC): `{summary.get('validation_date_utc', '')}`",
    f"- environment: `{summary.get('environment', '')}`",
    f"- install + first backup: `{fmt_status(summary.get('install_and_first_backup', ''))}`",
    f"- upgrade path: `{fmt_status(summary.get('upgrade_path', ''))}`",
    f"- rollback path: `{fmt_status(summary.get('rollback_path', ''))}`",
    f"- overall result: `{fmt_status(summary.get('overall_result', ''))}`",
]

failed_step = summary.get("failed_step")
if failed_step:
    lines.append(f"- first failing step: `{failed_step}`")

output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
