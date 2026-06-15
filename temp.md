GitHub Actions sera ton pipeline CI/CD : un workflow est un fichier YAML dans `.github/workflows` qui se déclenche sur push, manuellement ou selon un schedule. ([GitHub Docs][1])
Pour l’auth GitHub → GCP, on utilisera **Workload Identity Federation**, pas de clé JSON longue durée : Google recommande cette approche pour éviter la gestion de clés de service account, et l’action officielle `google-github-actions/auth` supporte WIF. ([Google Cloud][2])

---

## 1. Variables de base

Dans Cloud Shell ou ton terminal avec `gcloud` configuré :
##### télécharger gcloud 

You have those informations on your [.env.example](.env.example).
You have to copy them on your .env and update them.
```bash
cp .env.example .env
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

## 3. Créer les datasets et les tables BigQuery

```bash
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_SILVER_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_GOLD_DATASET"
# or
bq --location="$BQ_LOCATION" mk --dataset "$BQ_BRONZE_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$BQ_SILVER_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$BQ_GOLD_DATASET"
```
L'utilisation de `$PROJECT_ID` permet de'éviter les erreurs silencieuses et d'être sur que nous créeons au bon endroits.

BigQuery utilise la structure `project.dataset.table`. Il n'est donc pas possible de créer un chemin à quatre niveaux comme `onboarding-de.willem.bronze.stops_sncf_raw`.

Le modèle retenu consiste donc à mettre le nom et la couche dans le dataset :

```md
# Bronze layer
onboarding-de.<name>_bronze.stops_sncf_raw
onboarding-de.<name>_bronze.stations_weather_raw
# Silver layer
onboarding-de.<name>_silver.station
onboarding-de.<name>_silver.station_sncf
onboarding-de.<name>_silver.station_weather
# Gold layer
onboarding-de.<name>_gold.sncf_weather_station
onboarding-de.<name>_gold.summary
```

Les schémas JSON sont dans `schemas/bigquery/`. Ils suivent la structure documentée dans [tables.md](tables.md).

Pour créer les tables avec ces schémas JSON :

[!Note]
`bq` permet d'intéragir avec bigquery, en particulier, le flag `mk` permet 

```bash
# Bronze
bq mk --table "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STOPS_SNCF_RAW_TABLE" \
  schemas/bigquery/stops_sncf_raw.json

bq mk --table "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STATIONS_WEATHER_RAW_TABLE" \
  schemas/bigquery/stations_weather_raw.json

# Silver
bq mk --table "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_TABLE" \
  schemas/bigquery/station.json

bq mk --table "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_SNCF_TABLE" \
  schemas/bigquery/station_sncf.json

bq mk --table "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_WEATHER_TABLE" \
  schemas/bigquery/station_weather.json

# Gold
bq mk --table "$PROJECT_ID:$BQ_GOLD_DATASET.$BQ_SNCF_WEATHER_STATION_TABLE" \
  schemas/bigquery/sncf_weather_station.json

bq mk --table "$PROJECT_ID:$BQ_GOLD_DATASET.$BQ_SUMMARY_TABLE" \
  schemas/bigquery/summary.json
```

Note : BigQuery ne force pas les clés primaires et étrangères avec un simple fichier de schéma JSON `bq mk`. Les contraintes documentées dans `tables.md` doivent donc être appliquées dans les transformations SQL, les tests de qualité ou via des `ALTER TABLE ... ADD PRIMARY KEY / FOREIGN KEY NOT ENFORCED` si tu veux les déclarer explicitement.

Tu peux vérifier la création avec :

```bash
bq ls "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq ls "$PROJECT_ID:$BQ_SILVER_DATASET"
bq ls "$PROJECT_ID:$BQ_GOLD_DATASET"
# or 
bq ls "$BQ_BRONZE_DATASET"
bq ls "$BQ_SILVER_DATASET"
bq ls "$BQ_GOLD_DATASET"
```

### 3.1 Supprimer une table si besoin

Si tu veux supprimer une table précise, utilise `bq rm -t` :

```bash
bq rm -f -t "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STOPS_SNCF_RAW_TABLE"
```

Même logique pour les autres tables :

```bash
bq rm -f -t "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STATIONS_WEATHER_RAW_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_SNCF_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_WEATHER_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_GOLD_DATASET.$BQ_SNCF_WEATHER_STATION_TABLE"
bq rm -f -t "$PROJECT_ID:$BQ_GOLD_DATASET.$BQ_SUMMARY_TABLE"
```

Si tu veux supprimer tout le dataset et toutes ses tables, utilise `bq rm -r -d` :

```bash
bq rm -r -f -d "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq rm -r -f -d "$PROJECT_ID:$BQ_SILVER_DATASET"
bq rm -r -f -d "$PROJECT_ID:$BQ_GOLD_DATASET"
```


BigQuery recommande de choisir la localisation du dataset à la création, car elle ne peut pas être changée ensuite ; `bq mk --dataset --location` est la commande prévue pour ça. ([Google Cloud][5])

---

## 4. Créer les service accounts
### max
######## renaming et documentation entre les deux objets
######## ⚠️ permissions
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
######### doc qu'est ce que c'est que ça

```bash
gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

La doc Artifact Registry montre cette commande `gcloud artifacts repositories create ... --repository-format=docker`, puis `gcloud auth configure-docker REGION-docker.pkg.dev` pour pousser des images. ([Google Cloud][3])

---

## 6. Créer sa branche de travail

Le dépôt GitHub existe déjà. Chaque personne doit créer sa propre branche depuis ce dépôt, avec un nom qui correspond à la variable `NAME` dans `.env`.

Convention recommandée :

```text
<prenom>
```

Exemples :

```text
willem
paul
marie
```

Après avoir copié `.env.example` vers `.env`, mets à jour au minimum :

```bash
NAME=<prenom>
GITHUB_OWNER=<ton-username-github>
GITHUB_REPO=gcp-game
PROJECT_ID=onboarding-de
```

Ensuite lance :

```bash
make bootstrap
```

Cette commande :

1. lit `NAME` depuis `.env` ;
2. vérifie que ce nom n'est pas déjà utilisé par une autre branche locale ou distante ;
3. crée la branche si elle n'existe pas ;
4. génère `workflows/weather_pipeline.yaml` depuis le template.

Par exemple, avec `NAME=willem`, les ressources suivront cette convention :

```text
willem-meteo-ingest
willem-meteo-pipeline
willem-meteo-docker
willem_bronze
willem_silver
willem_gold
```

Structure cible du dépôt :

```text
weather-gcp-game/
  app/
    main.py
  scripts/
    render-workflow.sh
  workflows/
    weather_pipeline.template.yaml
    weather_pipeline.yaml
  .github/
    workflows/
      deploy.yml
  Dockerfile
  Makefile
  pyproject.toml
  uv.lock
  README.md
```

---

## 7. Ajouter le script Python d’ingestion

Les dépendances Python sont gérées uniquement avec `uv`.

Ajoute les dépendances dans `pyproject.toml` :

```toml
[project]
dependencies = [
  "google-cloud-bigquery>=3.25.0,<4",
  "requests>=2.32.0,<3",
]

[dependency-groups]
dev = [
  "ruff>=0.13.0",
]
```

Puis mets à jour le lockfile :

```bash
uv lock
```

Pour installer l'environnement local de développement :

```bash
uv sync
```

Pour installer uniquement les dépendances runtime, comme dans le conteneur de déploiement :

```bash
uv sync --frozen --no-dev --no-install-project
```

Le fichier `app/main.py` ingère une ligne météo courante depuis Open-Meteo et l'insère dans la table bronze `stations_weather_raw`.

Il doit produire des lignes compatibles avec le schéma `schemas/bigquery/stations_weather_raw.json` :

```text
stop_name
stop_lat
stop_lon
level
temperature
snowfall
wind_speed
is_fetched
timestamp
```

Le code utilise `insert_rows_json`, qui est l’appel Python documenté par Google pour insérer des lignes JSON dans une table BigQuery. ([Google Cloud][7])

---

## 8. Ajouter le Dockerfile

Crée `Dockerfile` :

```dockerfile
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY app/ ./app/

CMD [".venv/bin/python", "-m", "app.main"]
```

Test local possible :

```bash
uv sync

gcloud auth application-default login

PROJECT_ID="$PROJECT_ID" \
BQ_DATASET="$BQ_BRONZE_DATASET" \
BQ_TABLE="$BQ_STATIONS_WEATHER_RAW_TABLE" \
uv run python -m app.main
```

Puis vérifie :

```bash
bq query --use_legacy_sql=false "
SELECT *
FROM \`${PROJECT_ID}.${BQ_BRONZE_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}\`
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

Le workflow GCP est généré depuis le template :

```text
workflows/weather_pipeline.template.yaml
```

Pour générer `workflows/weather_pipeline.yaml` localement avec les valeurs de `.env` :

```bash
bash scripts/render-workflow.sh
```

En CI/CD, le même script génère `/tmp/weather_pipeline.yaml` avec les variables dérivées du nom de branche.

Workflows sait appeler directement Cloud Run Jobs via `googleapis.run.v2.projects.locations.jobs.run`, et ce connecteur attend le nom complet du job `projects/{project}/locations/{location}/jobs/{job}`. ([Google Cloud][8])

---

## 11. Ajouter la CI/CD GitHub Actions

Le fichier `.github/workflows/deploy.yml` déploie sur chaque branche.

Chaque personne peut donc créer sa branche et obtenir des ressources isolées. Le nom du déploiement est dérivé du nom de branche :

```text
branche willem
  -> Artifact Registry: willem-meteo-docker
  -> Cloud Run Job: willem-meteo-ingest
  -> Workflow: willem-meteo-pipeline
  -> BigQuery: willem_bronze, willem_silver, willem_gold
```

Le workflow peut aussi être lancé manuellement avec `workflow_dispatch` et un input `name`.

La CI/CD :

1. calcule les variables propres à la branche ;
2. s'authentifie à GCP avec Workload Identity Federation ;
3. crée le dépôt Artifact Registry s'il n'existe pas ;
4. crée les datasets et tables BigQuery s'ils n'existent pas ;
5. build l'image Docker ;
6. pousse l'image dans Artifact Registry ;
7. crée ou met à jour le Cloud Run Job ;
8. génère le workflow GCP avec `scripts/render-workflow.sh` ;
9. déploie le workflow avec `gcloud workflows deploy`.

Il faut créer une variable GitHub repository-level nommée `WIF_PROVIDER`, avec une valeur comme :

```text
projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/providers/github-provider
```

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
FROM \`${PROJECT_ID}.${BQ_BRONZE_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}\`
LIMIT 10
"
```

```bash
bq query --use_legacy_sql=false "
SELECT *
FROM \`${PROJECT_ID}.${BQ_SILVER_DATASET}.${BQ_STATION_WEATHER_TABLE}\`
LIMIT 10
"
```

```bash
bq query --use_legacy_sql=false "
SELECT *
FROM \`${PROJECT_ID}.${BQ_GOLD_DATASET}.${BQ_SUMMARY_TABLE}\`
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
  schema: "willem_silver",
  name: "station_weather"
}

SELECT
  LOWER(REGEXP_REPLACE(stop_name, r'[^a-zA-Z0-9]+', '_')) AS id,
  timestamp AS time,
  temperature,
  snowfall AS snow,
  wind_speed AS wind
FROM `${dataform.projectConfig.defaultDatabase}.willem_bronze.stations_weather_raw`
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY stop_name, timestamp
  ORDER BY level DESC
) = 1
```

Exemple `definitions/gold_summary.sqlx` :

```sql
config {
  type: "table",
  schema: "willem_gold",
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
onboarding-de.willem_gold.summary
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

bq rm -r -f "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq rm -r -f "$PROJECT_ID:$BQ_SILVER_DATASET"
bq rm -r -f "$PROJECT_ID:$BQ_GOLD_DATASET"
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
