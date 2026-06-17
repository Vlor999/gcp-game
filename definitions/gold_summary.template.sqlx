config {
  type: "table",
  schema: "${BQ_GOLD_DATASET}",
  name: "${BQ_SUMMARY_TABLE}",
  description: "KPIs météo de crise"
}

SELECT
  time,
  COUNTIF(temperature < -5.0 OR temperature > 40.0) AS temperature_crisis_count,
  COUNTIF(snow > 5.0) AS snow_crisis_count,
  COUNTIF(wind > 100.0) AS wind_crisis_count
FROM ${ref("${BQ_STATION_WEATHER_TABLE}")}
GROUP BY time
