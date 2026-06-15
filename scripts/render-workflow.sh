#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${1:-$ROOT_DIR/workflows/weather_pipeline.template.yaml}"
OUTPUT="${2:-$ROOT_DIR/workflows/weather_pipeline.yaml}"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

required_vars=(
  PROJECT_ID
  REGION
  JOB_NAME
  BQ_BRONZE_DATASET
  BQ_SILVER_DATASET
  BQ_GOLD_DATASET
  BQ_STATIONS_WEATHER_RAW_TABLE
  BQ_STATION_WEATHER_TABLE
  BQ_SUMMARY_TABLE
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 1
  fi
done

python - "$TEMPLATE" "$OUTPUT" <<'PY'
import os
import re
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
content = template_path.read_text()

def replace(match: re.Match[str]) -> str:
    name = match.group(1)
    try:
        return os.environ[name]
    except KeyError as exc:
        raise SystemExit(f"Missing required environment variable: {name}") from exc

rendered = re.sub(r"\$\{([A-Z0-9_]+)\}", replace, content)
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(rendered)
PY

echo "Rendered ${OUTPUT}"
