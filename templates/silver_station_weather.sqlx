config {
  type: "table",
  schema: "${BQ_SILVER_DATASET}",
  name: "${BQ_STATION_WEATHER_TABLE}",
  description: "Nettoyage et dédoublage des données météo"
}

SELECT
  LOWER(REGEXP_REPLACE(stop_name, r'[^a-zA-Z0-9]+', '_')) AS id,
  timestamp AS time,
  temperature,
  snowfall AS snow,
  wind_speed AS wind
FROM `${PROJECT_ID}.${BQ_BRONZE_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}`
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY stop_name, timestamp
  ORDER BY level DESC
) = 1
