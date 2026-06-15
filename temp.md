Oui. Le chemin le plus propre pour ton “sous-projet” est de **rester dans le projet GCP existant** et de créer des ressources préfixées, par exemple `willem-meteo-*`. GCP ne fait pas vraiment de “projet dans un projet” ; soit tu crées un nouveau project GCP sous une folder, soit tu namespaces proprement dans `onboarding-de`. Je pars sur cette deuxième option.

J’ai essayé de retrouver un repo `onboarding-de` / `onboarding-de` via le connecteur GitHub installé, mais je n’ai rien trouvé, donc je te donne une procédure générique.

## 0. Architecture cible

Tu vas construire ce flux :

`GitHub perso` → `GitHub Actions CI/CD` → `Artifact Registry` → `Cloud Run Job Python` → `BigQuery bronze` → `Workflows` → `BigQuery silver/gold` → `Looker Studio`

GitHub Actions sera ton pipeline CI/CD : un workflow est un fichier YAML dans `.github/workflows` qui se déclenche sur push, manuellement ou selon un schedule. ([GitHub Docs][1])
Pour l’auth GitHub → GCP, on utilisera **Workload Identity Federation**, pas de clé JSON longue durée : Google recommande cette approche pour éviter la gestion de clés de service account, et l’action officielle `google-github-actions/auth` supporte WIF. ([Google Cloud][2])

---

## 1. Variables de base

Dans Cloud Shell ou ton terminal avec `gcloud` configuré :

You have those informations on your [.env.example](.env.example).
You have to copy them on your .env and update them.
```bash
PYTHONPATH=.

NAME=your-name
GITHUB_OWNER=your-github-username
GITHUB_REPO=gcp-game

PROJECT_ID=onboarding-de

REGION=europe-west1

PREFIX=${NAME}-meteo

BQ_LOCATION=EU
JOB_NAME=${PREFIX}-ingest
WORKFLOW_NAME=${PREFIX}-pipeline
AR_REPO=${PREFIX}-docker
BQ_DATASET=${NAME}
BQ_STOPS_SNCF_RAW_TABLE=stops_sncf_raw
BQ_STATIONS_WEATHER_RAW_TABLE=stations_weather_raw
BQ_STATION_TABLE=station
BQ_STATION_SNCF_TABLE=station_sncf
BQ_STATION_WEATHER_TABLE=station_weather
BQ_SNCF_WEATHER_STATION_TABLE=sncf_weather_station
BQ_SUMMARY_TABLE=summary
RUNTIME_SA=${PREFIX}-runtime@${PROJECT_ID}.iam.gserviceaccount.com
CICD_SA=${PREFIX}-cicd@${PROJECT_ID}.iam.gserviceaccount.com
WORKFLOW_SA=${PREFIX}-workflow@${PROJECT_ID}.iam.gserviceaccount.com
```

---

### 1.1 Login to GCP
You have to login to your google account using your theodo email address using :

```bash
gcloud auth login
```

Then you have to set the project : 
```bash
gcloud config set project "$PROJECT_ID"
```

if you have issues like :
```log
ERROR: (gcloud.auth.application-default.set-quota-project) There was a problem refreshing your current auth tokens: ('invalid_grant: Account has been deleted', {'error': 'invalid_grant', 'error_description': 'Account has been deleted'})
Please run:

  $ gcloud auth application-default login

to obtain new credentials.
```
Then follow the explained steps.
At the end verify everything has been properly set with : 
```bash
gcloud auth list
```
and
```bash
gcloud config get-value project
# or 
[ "$(gcloud config get-value project 2>/dev/null)" = "$PROJECT_ID" ] && echo true || echo false
```
You must see either your project id or True

## 2. Activer les APIs GCP

```bash
gcloud config set project "$PROJECT_ID"

gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  bigquery.googleapis.com \
  workflows.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  dataform.googleapis.com
```

You'll have something like:
```txt
Operation "operations/..." finished successfully.
```

Artifact Registry sert à stocker tes images Docker privées ; la doc Google montre ce flow “create repository → authenticate → push image”. ([Google Cloud][3])
Cloud Run Jobs est adapté ici parce que ton ingestion météo est un batch, pas une API HTTP. Pour créer des jobs, Google documente notamment les rôles `Cloud Run Developer`, `Service Account User`, et `Artifact Registry Reader`. ([Google Cloud][4])

---

## 3. Créer le dataset et les tables BigQuery

```bash
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_DATASET"
```

BigQuery utilise la structure `project.dataset.table`. Avec les variables ci-dessus, tu obtiens donc :

```text
onboarding-de.willem.stops_sncf_raw
onboarding-de.willem.stations_weather_raw
onboarding-de.willem.station
onboarding-de.willem.station_sncf
onboarding-de.willem.station_weather
onboarding-de.willem.sncf_weather_station
onboarding-de.willem.summary
```

Les schemas JSON sont dans `schemas/bigquery/`. Ils suivent la structure documentée dans [tables.md](tables.md).

Pour créer les tables avec ces schemas JSON :

```bash
bq mk --table "$PROJECT_ID:$BQ_DATASET.$BQ_STOPS_SNCF_RAW_TABLE" \
  schemas/bigquery/stops_sncf_raw.json

bq mk --table "$PROJECT_ID:$BQ_DATASET.$BQ_STATIONS_WEATHER_RAW_TABLE" \
  schemas/bigquery/stations_weather_raw.json

bq mk --table "$PROJECT_ID:$BQ_DATASET.$BQ_STATION_TABLE" \
  schemas/bigquery/station.json

bq mk --table "$PROJECT_ID:$BQ_DATASET.$BQ_STATION_SNCF_TABLE" \
  schemas/bigquery/station_sncf.json

bq mk --table "$PROJECT_ID:$BQ_DATASET.$BQ_STATION_WEATHER_TABLE" \
  schemas/bigquery/station_weather.json

bq mk --table "$PROJECT_ID:$BQ_DATASET.$BQ_SNCF_WEATHER_STATION_TABLE" \
  schemas/bigquery/sncf_weather_station.json

bq mk --table "$PROJECT_ID:$BQ_DATASET.$BQ_SUMMARY_TABLE" \
  schemas/bigquery/summary.json
```

Note : BigQuery ne force pas les clés primaires et étrangères avec un simple fichier de schema JSON `bq mk`. Les contraintes documentées dans `tables.md` doivent donc être appliquées dans les transformations SQL, les tests de qualité ou via des `ALTER TABLE ... ADD PRIMARY KEY / FOREIGN KEY NOT ENFORCED` si tu veux les déclarer explicitement.

Tu peux vérifier la création avec :

```bash
bq ls "$PROJECT_ID:$BQ_DATASET"
```

### 3.1 Supprimer une table si besoin

Si tu veux supprimer une table précise, utilise `bq rm -t` :

```bash
bq rm -f -t "$PROJECT_ID:$BQ_DATASET.$BQ_STOPS_SNCF_RAW_TABLE"
```

Même logique pour les autres tables :

```bash
bq rm -f -t "$PROJECT_ID:$BQ_DATASET.$BQ_STATIONS_WEATHER_RAW_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_DATASET.$BQ_STATION_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_DATASET.$BQ_STATION_SNCF_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_DATASET.$BQ_STATION_WEATHER_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_DATASET.$BQ_SNCF_WEATHER_STATION_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_DATASET.$BQ_SUMMARY_TABLE"
```

Si tu veux supprimer tout le dataset et toutes ses tables, utilise `bq rm -r -d` :

```bash
bq rm -r -f -d "$PROJECT_ID:$BQ_DATASET"
```


BigQuery recommande de choisir la localisation du dataset à la création, car elle ne peut pas être changée ensuite ; `bq mk --dataset --location` est la commande prévue pour ça. ([Google Cloud][5])

---

## 4. Créer les service accounts

```bash
gcloud iam service-accounts create "${PREFIX}-runtime" \
  --display-name="Runtime SA for weather ingestion"

gcloud iam service-accounts create "${PREFIX}-cicd" \
  --display-name="CI/CD SA for GitHub Actions"

gcloud iam service-accounts create "${PREFIX}-workflow" \
  --display-name="Workflow SA for weather pipeline"
```

### Permissions runtime Python

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/bigquery.dataEditor"
```

### Permissions CI/CD

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/run.developer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/workflows.developer"

gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/iam.serviceAccountUser"

gcloud iam service-accounts add-iam-policy-binding "$WORKFLOW_SA" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/iam.serviceAccountUser"
```

### Permissions Workflows

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/run.invoker"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/bigquery.dataEditor"
```

Pour un vrai contexte client/prod, tu restreindrais les permissions au niveau dataset/repository/job. Pour ton onboarding, c’est volontairement simple.

---

## 5. Créer Artifact Registry

```bash
gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Docker images for weather GCP onboarding" \
  --project="$PROJECT_ID"
```

```bash
gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

La doc Artifact Registry montre cette commande `gcloud artifacts repositories create ... --repository-format=docker`, puis `gcloud auth configure-docker REGION-docker.pkg.dev` pour pousser des images. ([Google Cloud][3])

---

## 6. Créer ton repo GitHub perso

Avec GitHub CLI :

```bash
mkdir weather-gcp-game
cd weather-gcp-game
git init -b main

gh repo create "$GITHUB_OWNER/$GITHUB_REPO" \
  --private \
  --source=. \
  --remote=origin
```

Ou via l’UI GitHub : **New repository**, owner = ton compte perso, nom = `weather-gcp-game`, visibilité private. GitHub permet de créer un repo dans ton compte personnel si tu as les permissions nécessaires, et documente aussi l’option GitHub CLI. ([GitHub Docs][6])

Structure cible :

```text
weather-gcp-game/
  app/
    main.py
  workflows/
    weather_pipeline.yaml
  .github/
    workflows/
      deploy.yml
  Dockerfile
  requirements.txt
  README.md
```

---

## 7. Ajouter le script Python d’ingestion

Crée `requirements.txt` :

```txt
google-cloud-bigquery>=3.25.0,<4
requests>=2.32.0,<3
```

Crée `app/main.py` :

```python
import datetime as dt
import os
import uuid

import requests
from google.api_core.exceptions import NotFound
from google.cloud import bigquery


PROJECT_ID = os.environ["PROJECT_ID"]
BQ_DATASET = os.environ.get("BQ_DATASET", "willem")
BQ_TABLE = os.environ.get("BQ_TABLE", "stations_weather_raw")

CITY = os.environ.get("CITY", "Paris")
LAT = float(os.environ.get("LAT", "48.8566"))
LON = float(os.environ.get("LON", "2.3522"))
DAYS_BACK = int(os.environ.get("DAYS_BACK", "7"))

RUN_ID = os.environ.get("RUN_ID", str(uuid.uuid4()))


def ensure_table(client: bigquery.Client, table_id: str) -> None:
    schema = [
        bigquery.SchemaField("run_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("city", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("latitude", "FLOAT", mode="REQUIRED"),
        bigquery.SchemaField("longitude", "FLOAT", mode="REQUIRED"),
        bigquery.SchemaField("weather_date", "DATE", mode="REQUIRED"),
        bigquery.SchemaField("temperature_2m_max", "FLOAT"),
        bigquery.SchemaField("temperature_2m_min", "FLOAT"),
        bigquery.SchemaField("precipitation_sum", "FLOAT"),
        bigquery.SchemaField("source", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("ingestion_ts", "TIMESTAMP", mode="REQUIRED"),
    ]

    try:
        client.get_table(table_id)
        print(f"Table already exists: {table_id}")
    except NotFound:
        table = bigquery.Table(table_id, schema=schema)
        table.time_partitioning = bigquery.TimePartitioning(
            type_=bigquery.TimePartitioningType.DAY,
            field="weather_date",
        )
        client.create_table(table)
        print(f"Created table: {table_id}")


def fetch_weather() -> list[dict]:
    url = "https://api.open-meteo.com/v1/forecast"
    params = {
        "latitude": LAT,
        "longitude": LON,
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_sum",
        "timezone": "auto",
        "past_days": DAYS_BACK,
        "forecast_days": 1,
    }

    response = requests.get(url, params=params, timeout=30)
    response.raise_for_status()
    payload = response.json()

    daily = payload["daily"]
    now = dt.datetime.now(dt.timezone.utc).isoformat()

    rows = []
    for i, weather_date in enumerate(daily["time"]):
        rows.append(
            {
                "run_id": RUN_ID,
                "city": CITY,
                "latitude": LAT,
                "longitude": LON,
                "weather_date": weather_date,
                "temperature_2m_max": daily["temperature_2m_max"][i],
                "temperature_2m_min": daily["temperature_2m_min"][i],
                "precipitation_sum": daily["precipitation_sum"][i],
                "source": "open-meteo",
                "ingestion_ts": now,
            }
        )

    return rows


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
```

Le code utilise `insert_rows_json`, qui est l’appel Python documenté par Google pour insérer des lignes JSON dans une table BigQuery. ([Google Cloud][7])

---

## 8. Ajouter le Dockerfile

Crée `Dockerfile` :

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

CMD ["python", "main.py"]
```

Test local possible :

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

gcloud auth application-default login

PROJECT_ID="$PROJECT_ID" \
BQ_DATASET="$BQ_DATASET" \
BQ_TABLE="$BQ_STATIONS_WEATHER_RAW_TABLE" \
python app/main.py
```

Puis vérifie :

```bash
bq query --use_legacy_sql=false "
SELECT *
FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}\`
LIMIT 10
"
```

---

## 9. Créer Workload Identity Federation pour GitHub Actions

```bash
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export WIF_POOL="github-pool"
export WIF_PROVIDER="github-provider"

gcloud iam workload-identity-pools create "$WIF_POOL" \
  --project="$PROJECT_ID" \
  --location="global" \
  --display-name="GitHub Actions pool"

gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$WIF_POOL" \
  --display-name="GitHub Actions provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.actor=assertion.actor" \
  --attribute-condition="assertion.repository=='${GITHUB_OWNER}/${GITHUB_REPO}'"
```

Autorise uniquement ce repo GitHub à impersonate le service account CI/CD :

```bash
gcloud iam service-accounts add-iam-policy-binding "$CICD_SA" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_OWNER}/${GITHUB_REPO}"
```

Garde cette valeur, elle ira dans GitHub Actions :

```bash
echo "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"
```

---

## 10. Ajouter le workflow GCP Workflows

Crée `workflows/weather_pipeline.yaml` :

```yaml
main:
  steps:
    - run_ingestion:
        call: googleapis.run.v2.projects.locations.jobs.run
        args:
          name: projects/PROJECT_ID/locations/REGION/jobs/JOB_NAME
          body: {}
        result: ingestion_result

    - build_silver:
        call: googleapis.bigquery.v2.jobs.query
        args:
          projectId: PROJECT_ID
          body:
            useLegacySql: false
            query: |
              CREATE OR REPLACE TABLE `PROJECT_ID.willem.station_weather` AS
              SELECT
                LOWER(REGEXP_REPLACE(stop_name, r'[^a-zA-Z0-9]+', '_')) AS id,
                timestamp AS time,
                temperature,
                snowfall AS snow,
                wind_speed AS wind
              FROM `PROJECT_ID.willem.stations_weather_raw`
              QUALIFY ROW_NUMBER() OVER (
                PARTITION BY stop_name, timestamp
                ORDER BY level DESC
              ) = 1;

    - build_gold:
        call: googleapis.bigquery.v2.jobs.query
        args:
          projectId: PROJECT_ID
          body:
            useLegacySql: false
            query: |
              CREATE OR REPLACE TABLE `PROJECT_ID.willem.summary` AS
              SELECT
                time,
                COUNTIF(temperature < -5.0 OR temperature > 40.0) AS temperature_crisis_count,
                COUNTIF(snow > 5.0) AS snow_crisis_count,
                COUNTIF(wind > 100.0) AS wind_crisis_count
              FROM `PROJECT_ID.willem.station_weather`
              GROUP BY time;

    - done:
        return: "Pipeline completed"
```

Workflows sait appeler directement Cloud Run Jobs via `googleapis.run.v2.projects.locations.jobs.run`, et ce connecteur attend le nom complet du job `projects/{project}/locations/{location}/jobs/{job}`. ([Google Cloud][8])

---

## 11. Ajouter la CI/CD GitHub Actions

Crée `.github/workflows/deploy.yml` :

```yaml
name: Deploy weather pipeline

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

env:
  PROJECT_ID: onboarding-de
  REGION: europe-west1
  AR_REPO: willem-meteo-docker
  JOB_NAME: willem-meteo-ingest
  WORKFLOW_NAME: willem-meteo-pipeline
  BQ_DATASET: willem
  BQ_TABLE: stations_weather_raw
  RUNTIME_SA: willem-meteo-runtime@onboarding-de.iam.gserviceaccount.com
  WORKFLOW_SA: willem-meteo-workflow@onboarding-de.iam.gserviceaccount.com

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v3
        with:
          project_id: ${{ env.PROJECT_ID }}
          workload_identity_provider: projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider
          service_account: willem-meteo-cicd@onboarding-de.iam.gserviceaccount.com

      - name: Setup gcloud
        uses: google-github-actions/setup-gcloud@v3

      - name: Configure Docker auth
        run: gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

      - name: Build and push image
        run: |
          IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${JOB_NAME}:${GITHUB_SHA}"
          echo "IMAGE=${IMAGE}" >> "$GITHUB_ENV"

          docker build -t "${IMAGE}" .
          docker push "${IMAGE}"

      - name: Create or update Cloud Run Job
        run: |
          if gcloud run jobs describe "${JOB_NAME}" \
            --region="${REGION}" \
            --project="${PROJECT_ID}" >/dev/null 2>&1; then

            gcloud run jobs update "${JOB_NAME}" \
              --image="${IMAGE}" \
              --region="${REGION}" \
              --project="${PROJECT_ID}" \
              --service-account="${RUNTIME_SA}" \
              --set-env-vars="PROJECT_ID=${PROJECT_ID},BQ_DATASET=${BQ_DATASET},BQ_TABLE=${BQ_TABLE},CITY=Paris,LAT=48.8566,LON=2.3522,DAYS_BACK=7"
          else
            gcloud run jobs create "${JOB_NAME}" \
              --image="${IMAGE}" \
              --region="${REGION}" \
              --project="${PROJECT_ID}" \
              --service-account="${RUNTIME_SA}" \
              --set-env-vars="PROJECT_ID=${PROJECT_ID},BQ_DATASET=${BQ_DATASET},BQ_TABLE=${BQ_TABLE},CITY=Paris,LAT=48.8566,LON=2.3522,DAYS_BACK=7" \
              --max-retries=0
          fi

      - name: Deploy Workflows pipeline
        run: |
          sed \
            -e "s/PROJECT_ID/${PROJECT_ID}/g" \
            -e "s/REGION/${REGION}/g" \
            -e "s/JOB_NAME/${JOB_NAME}/g" \
            workflows/weather_pipeline.yaml > /tmp/weather_pipeline.yaml

          gcloud workflows deploy "${WORKFLOW_NAME}" \
            --location="${REGION}" \
            --project="${PROJECT_ID}" \
            --service-account="${WORKFLOW_SA}" \
            --source=/tmp/weather_pipeline.yaml
```

Remplace dans ce fichier :

```yaml
PROJECT_NUMBER
onboarding-de
```

par les vraies valeurs si besoin.

---

## 12. Commit et push

```bash
git add .
git commit -m "Initial weather GCP onboarding pipeline"
git push -u origin main
```

Le push sur `main` déclenche GitHub Actions, qui build l’image Docker, la pousse dans Artifact Registry, crée ou met à jour le Cloud Run Job, puis déploie le workflow.

---

## 13. Lancer la pipeline

Après le premier déploiement :

```bash
gcloud workflows run "$WORKFLOW_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID"
```

Vérifie les exécutions Cloud Run :

```bash
gcloud run jobs executions list \
  --job="$JOB_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID"
```

Vérifie les tables BigQuery :

```bash
bq query --use_legacy_sql=false "
SELECT *
FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}\`
LIMIT 10
"
```

```bash
bq query --use_legacy_sql=false "
SELECT *
FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_STATION_WEATHER_TABLE}\`
LIMIT 10
"
```

```bash
bq query --use_legacy_sql=false "
SELECT *
FROM \`${PROJECT_ID}.${BQ_DATASET}.${BQ_SUMMARY_TABLE}\`
"
```

---

## 14. Ajouter Dataform ensuite

Dans ton schéma, Dataform est la bonne brique pour industrialiser les transformations bronze → silver → gold. Google décrit Dataform comme un service pour développer, tester, versionner et planifier des workflows de transformation BigQuery, et les fichiers SQLX permettent de définir des tables, dépendances et opérations SQL. ([Google Cloud][9])

Quand le MVP marche, fais évoluer comme ça :

```text
definitions/
  silver_station_weather.sqlx
  gold_summary.sqlx
workflow_settings.yaml
```

Exemple `definitions/silver_station_weather.sqlx` :

```sql
config {
  type: "table",
  schema: "willem",
  name: "station_weather"
}

SELECT
  LOWER(REGEXP_REPLACE(stop_name, r'[^a-zA-Z0-9]+', '_')) AS id,
  timestamp AS time,
  temperature,
  snowfall AS snow,
  wind_speed AS wind
FROM `${dataform.projectConfig.defaultDatabase}.willem.stations_weather_raw`
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY stop_name, timestamp
  ORDER BY level DESC
) = 1
```

Exemple `definitions/gold_summary.sqlx` :

```sql
config {
  type: "table",
  schema: "willem",
  name: "summary"
}

SELECT
  time,
  COUNTIF(temperature < -5.0 OR temperature > 40.0) AS temperature_crisis_count,
  COUNTIF(snow > 5.0) AS snow_crisis_count,
  COUNTIF(wind > 100.0) AS wind_crisis_count
FROM ${ref("station_weather")}
GROUP BY time
```

Tu pourrais alors laisser Workflows faire :

1. exécuter Cloud Run Job ;
2. déclencher Dataform ;
3. éventuellement notifier ou logguer le résultat.

---

## 15. Looker Studio

Dans Looker Studio, connecte une source BigQuery vers :

```text
onboarding-de.willem.summary
```

Le connecteur BigQuery est documenté côté Looker Studio dans la section “Connect to BigQuery”. ([Aide Google][10])

Idées de graphes :

```text
Scorecard: temperature_crisis_count
Scorecard: snow_crisis_count
Scorecard: wind_crisis_count
Line chart: crisis counts par time
```

---

## 16. Nettoyage

Quand tu veux supprimer le jeu :

```bash
gcloud workflows delete "$WORKFLOW_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID"

gcloud run jobs delete "$JOB_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID"

gcloud artifacts repositories delete "$AR_REPO" \
  --location="$REGION" \
  --project="$PROJECT_ID"

bq rm -r -f "$PROJECT_ID:$BQ_DATASET"
```

Le premier objectif est d’obtenir ce run complet : **push GitHub → image Docker → Cloud Run Job → BigQuery bronze → SQL silver/gold → table dashboardable**. Ensuite seulement, ajoute Dataform proprement.

[1]: https://docs.github.com/en/actions/writing-workflows/about-workflows "Workflows - GitHub Docs"
[2]: https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines "Configure Workload Identity Federation with deployment pipelines  |  Identity and Access Management (IAM)  |  Google Cloud Documentation"
[3]: https://cloud.google.com/artifact-registry/docs/docker/store-docker-container-images "Quickstart: Store Docker container images in Artifact Registry  |  Google Cloud Documentation"
[4]: https://cloud.google.com/run/docs/create-jobs "Create jobs  |  Cloud Run  |  Google Cloud Documentation"
[5]: https://cloud.google.com/bigquery/docs/datasets "Create datasets  |  BigQuery  |  Google Cloud Documentation"
[6]: https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository "Creating a new repository - GitHub Docs"
[7]: https://cloud.google.com/bigquery/docs/samples/bigquery-table-insert-rows "Streaming insert  |  BigQuery  |  Google Cloud Documentation"
[8]: https://cloud.google.com/workflows/docs/reference/googleapis/run/v2/projects.locations.jobs/run "Method: googleapis.run.v2.projects.locations.jobs.run  |  Workflows  |  Google Cloud Documentation"
[9]: https://cloud.google.com/dataform/docs/overview "Dataform overview  |  Google Cloud Documentation"
[10]: https://support.google.com/looker-studio/answer/6370296 "Connect to Google BigQuery  |  Looker Studio  |  Google Cloud Documentation"
