#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
  WORKFLOW_SA
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 1
  fi
done

# If template and output paths are specified as CLI arguments, use them.
# Otherwise, render all default Dataform and workflow templates.
TEMPLATE="${1:-}"
OUTPUT="${2:-}"

if [[ -n "${TEMPLATE}" && -n "${OUTPUT}" ]]; then
  files_to_render=("${TEMPLATE}:${OUTPUT}")
else
  files_to_render=(
    "workflows/weather_pipeline.template.yaml:workflows/weather_pipeline.yaml"
    "workflow_settings.template.yaml:workflow_settings.yaml"
    "templates/silver_station_weather.sqlx:definitions/silver_station_weather.sqlx"
    "templates/gold_summary.sqlx:definitions/gold_summary.sqlx"
  )
fi

python - "${files_to_render[@]}" <<'PY'
import os
import re
import sys
from pathlib import Path

def replace(match: re.Match[str]) -> str:
    name = match.group(1)
    try:
        return os.environ[name]
    except KeyError as exc:
        raise SystemExit(f"Missing required environment variable: {name}") from exc

for arg in sys.argv[1:]:
    template_str, output_str = arg.split(":")
    template_path = Path(template_str)
    output_path = Path(output_str)
    
    if not template_path.exists():
        print(f"Warning: Template file {template_path} does not exist. Skipping.")
        continue
        
    content = template_path.read_text()
    rendered = re.sub(r"\$\{([A-Z0-9_]+)\}", replace, content)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered)
    print(f"Rendered {output_path}")
PY
