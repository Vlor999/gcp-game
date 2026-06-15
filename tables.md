## Bronze tables

### stops_sncf_raw

| Column Name | Data Type | Description |
| --- | --- | --- |
| `stop_name` | `TEXT` | Raw name of the railway station |
| `stop_lat` | `REAL` | Latitude of the railway station stop |
| `stop_lon` | `REAL` | Longitude of the railway station stop |
| `country_code` | `TEXT` | Country ISO code (e.g., `FR`, `DE`, `ES`) |

### stations_weather_raw

| Column Name | Data Type | Description |
| --- | --- | --- |
| `stop_name` | `TEXT` | Raw name of the railway station |
| `stop_lat` | `REAL` | Latitude of the weather coordinate |
| `stop_lon` | `REAL` | Longitude of the weather coordinate |
| `level` | `INTEGER` | Partition grid level (coarse-to-fine multi-resolution) |
| `temperature` | `REAL` | Temperature metric (measured or interpolated) in Celsius |
| `snowfall` | `REAL` | Snowfall amount (measured or interpolated) |
| `wind_speed` | `REAL` | Wind speed amount (measured or interpolated) |
| `is_fetched` | `BOOLEAN` | `1` if fetched from Open-Meteo in the current batch, `0` otherwise |
| `timestamp` | `TEXT` | YYYY-MM-DD HH:MM:SS timestamp of the data snapshot |

## Silver tables

### station

| Column Name | Data Type | Constraints | Description |
| --- | --- | --- | --- |
| `id` | `TEXT` | `PRIMARY KEY` | Deterministic slugified ID |
| `lat` | `REAL` | `NOT NULL` | Averaged latitude coordinates |
| `long` | `REAL` | `NOT NULL` | Averaged longitude coordinates |

### **station_sncf**

| Column Name | Data Type | Constraints | Description |
| --- | --- | --- | --- |
| `id` | `TEXT` | `FOREIGN KEY` references `station(id)` | Clean station identifier |
| `name` | `TEXT` | `NOT NULL` | Display name of the railway station |

### station_weather

| Column Name | Data Type | Constraints | Description |
| --- | --- | --- | --- |
| `id` | `TEXT` | `FOREIGN KEY` references `station(id)` | Clean station identifier |
| `time` | `TEXT` | `NOT NULL` | Snapshot timestamp (`timestamp`) |
| `temperature` | `REAL` | — | Temperature in Celsius |
| `snow` | `REAL` | — | Snowfall metric |
| `wind` | `REAL` | — | Wind speed metric |
| — | — | `PRIMARY KEY (id, time)` | Composite primary key |

## Gold layer

### sncf_weather_station

| Column Name | Data Type | Extreme Weather Rule | Description |
| --- | --- | --- | --- |
| `name` | `TEXT` | — | Displays the railway station name |
| `time` | `TEXT` | — | YYYY-MM-DD HH:MM:SS snapshot time |
| `lat` | `REAL` | — | Station latitude |
| `long` | `REAL` | — | Station longitude |
| `is_temperature_extreme` | `BOOLEAN` | `temperature < -5.0 OR temperature > 40.0` | Flagged if temperature is extreme |
| `is_snow_extreme` | `BOOLEAN` | `snow > 5.0` | Flagged if snowfall is extreme |
| `is_wind_extreme` | `BOOLEAN` | `wind > 100.0` | Flagged if wind speed is extreme |

### summary

| Column Name | Data Type | Aggregation Rule | Description |
| --- | --- | --- | --- |
| `time` | `TEXT` | — | Snapshot interval timestamp |
| `temperature_crisis_count` | `INTEGER` | `SUM(is_temperature_extreme)` | Count of stations under extreme temperature |
| `snow_crisis_count` | `INTEGER` | `SUM(is_snow_extreme)` | Count of stations under extreme snow |
| `wind_crisis_count` | `INTEGER` | `SUM(is_wind_extreme)` | Count of stations under extreme wind |