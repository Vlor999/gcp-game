import datetime as dt
import os

import requests
from google.api_core.exceptions import NotFound
from google.cloud import bigquery


PROJECT_ID = os.environ["PROJECT_ID"]

# Support both the onboarding variable names and the generic fallback names
# used by local runs / existing Cloud Run job deployments.
BQ_DATASET = os.environ.get("BQ_BRONZE_DATASET") or os.environ.get(
    "BQ_DATASET", "willem_bronze"
)
BQ_TABLE = os.environ.get("BQ_STATIONS_WEATHER_RAW_TABLE") or os.environ.get(
    "BQ_TABLE", "stations_weather_raw"
)

CITY = os.environ.get("CITY", "Paris")
LAT = float(os.environ.get("LAT", "48.8566"))
LON = float(os.environ.get("LON", "2.3522"))
LEVEL = int(os.environ.get("LEVEL", "0"))


def ensure_table(client: bigquery.Client, table_id: str) -> None:
    schema = [
        bigquery.SchemaField("stop_name", "STRING"),
        bigquery.SchemaField("stop_lat", "FLOAT"),
        bigquery.SchemaField("stop_lon", "FLOAT"),
        bigquery.SchemaField("level", "INTEGER"),
        bigquery.SchemaField("temperature", "FLOAT"),
        bigquery.SchemaField("snowfall", "FLOAT"),
        bigquery.SchemaField("wind_speed", "FLOAT"),
        bigquery.SchemaField("is_fetched", "BOOLEAN"),
        bigquery.SchemaField("timestamp", "STRING"),
    ]

    try:
        client.get_table(table_id)
        print(f"Table already exists: {table_id}")
    except NotFound:
        table = bigquery.Table(table_id, schema=schema)
        client.create_table(table)
        print(f"Created table: {table_id}")


def fetch_weather() -> list[dict]:
    url = "https://api.open-meteo.com/v1/forecast"
    params = {
        "latitude": LAT,
        "longitude": LON,
        "current": "temperature_2m,snowfall,wind_speed_10m",
        "timezone": "auto",
    }

    response = requests.get(url, params=params, timeout=30)
    response.raise_for_status()
    payload = response.json()

    current = payload["current"]
    timestamp = current.get("time") or dt.datetime.now(dt.timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S" 
    )

    return [
        {
            "stop_name": CITY,
            "stop_lat": LAT,
            "stop_lon": LON,
            "level": LEVEL,
            "temperature": current.get("temperature_2m"),
            "snowfall": current.get("snowfall"),
            "wind_speed": current.get("wind_speed_10m"),
            "is_fetched": True,
            "timestamp": timestamp.replace("T", " "),
        }
    ]


def main() -> None:
    client = bigquery.Client(project=PROJECT_ID)
    table_id = f"{PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"

    ensure_table(client, table_id)

    rows = fetch_weather()
    errors = client.insert_rows_json(table_id, rows)

    if errors:
        raise RuntimeError(f"BigQuery insert errors: {errors}")

    print(f"Inserted {len(rows)} rows into {table_id}")


if __name__ == "__main__":
    main()
