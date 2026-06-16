# Guide d'intégration GCP Onboarding (Step-by-Step)

Ce guide détaille toutes les étapes nécessaires pour configurer et déployer votre environnement météo sur Google Cloud Platform (GCP) avec une intégration CI/CD propre via GitHub Actions.

---

## 1. Initialisation locale et branche

Toutes les ressources GCP seront isolées par personne et préfixées par votre nom.

### 1.1 Configurer le fichier `.env`
Faites une copie du fichier `.env.example` :
```bash
cp .env.example .env
```

Mettez à jour les variables suivantes dans le fichier `.env` :
*   `NAME` : votre prénom en minuscules (ex: `willem`).
*   `GITHUB_OWNER` : votre nom d'utilisateur GitHub.
*   `PROJECT_ID` : l'identifiant exact de votre projet bac à sable GCP (ex: `onboarding-de-willem-499614`).
*   `PROJECT_NUMBER` : le numéro de votre projet GCP (disponible sur l'accueil de votre console GCP).

### 1.2 Créer votre branche et initialiser le workflow
Lancez la commande suivante :
```bash
make bootstrap
```
Cette commande :
1. Crée et bascule sur la branche Git locale nommée selon votre `NAME` (ex: `willem`).
2. Génère le fichier de configuration de pipeline `workflows/weather_pipeline.yaml` à partir de vos valeurs d'environnement locales.

### 1.3 Charger les variables dans votre terminal
Pour pouvoir exécuter les commandes GCP du guide par copier-coller, chargez les variables d'environnement dans votre terminal courant :
```bash
set -a; source .env; set +a
```

---

## 2. Authentification GCP & Activation des APIs

### 2.1 Connexion à votre compte GCP
Connectez-vous à votre compte GCP :
```bash
gcloud auth login
gcloud auth application-default login
```

Configurez le projet actif dans le SDK `gcloud` :
```bash
gcloud config set project "$PROJECT_ID"
```

Vérifiez que la configuration est correcte :
```bash
[ "$(gcloud config get-value project 2>/dev/null)" = "$PROJECT_ID" ] && echo "Config OK" || echo "Erreur de configuration"
```

### 2.2 Activer les APIs nécessaires
Activez les APIs requises pour Cloud Run, Artifact Registry, BigQuery, Workflows et l'authentification GitHub :
```bash
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

---

## 3. Création des datasets et tables BigQuery

### 3.1 Créer les datasets (Bronze, Silver, Gold)
```bash
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_SILVER_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_GOLD_DATASET"
```

### 3.2 Créer les tables à partir des schémas JSON
Créez les tables requises pour les différentes couches de données :

```bash
# Couche Bronze
bq mk --table "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STOPS_SNCF_RAW_TABLE" \
  schemas/bigquery/stops_sncf_raw.json

bq mk --table "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STATIONS_WEATHER_RAW_TABLE" \
  schemas/bigquery/stations_weather_raw.json

# Couche Silver
bq mk --table "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_TABLE" \
  schemas/bigquery/station.json

bq mk --table "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_SNCF_TABLE" \
  schemas/bigquery/station_sncf.json

bq mk --table "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_WEATHER_TABLE" \
  schemas/bigquery/station_weather.json

# Couche Gold
bq mk --table "$PROJECT_ID:$BQ_GOLD_DATASET.$BQ_SNCF_WEATHER_STATION_TABLE" \
  schemas/bigquery/sncf_weather_station.json

bq mk --table "$PROJECT_ID:$BQ_GOLD_DATASET.$BQ_SUMMARY_TABLE" \
  schemas/bigquery/summary.json
```

---

## 4. Créer les comptes de service (SAs) & Droits IAM

Nous allons créer trois comptes de service dédiés pour respecter le principe de moindre privilège.

### 4.1 Création des comptes de service
```bash
gcloud iam service-accounts create "${PREFIX}-runtime" \
  --display-name="Runtime SA for weather ingestion"

gcloud iam service-accounts create "${PREFIX}-cicd" \
  --display-name="CI/CD SA for GitHub Actions"

gcloud iam service-accounts create "${PREFIX}-workflow" \
  --display-name="Workflow SA for weather pipeline"
```

### 4.2 Rôles pour le SA Ingestion Python (Runtime)
Ce SA a besoin de lire et écrire des données dans BigQuery :
```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/bigquery.dataEditor"
```

### 4.3 Rôles pour le SA CI/CD (GitHub Actions)
Ce SA a besoin de builder l'image Docker, configurer Cloud Run, déployer le Workflow et gérer les tables BigQuery en intégration continue :
```bash
# Permet de pousser les images Docker
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/artifactregistry.writer"

# Permet de déployer le job Cloud Run
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/run.developer"

# Permet de déployer le workflow
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/workflows.editor"

# Permet de gérer les datasets/tables BigQuery pendant le déploiement
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/bigquery.admin"

# Autorise le SA CI/CD à utiliser les SAs runtime et workflow lors du déploiement
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/iam.serviceAccountUser"

gcloud iam service-accounts add-iam-policy-binding "$WORKFLOW_SA" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/iam.serviceAccountUser"
```

### 4.4 Rôles pour le SA Workflows
Ce SA exécute le pipeline d'orchestration GCP (il doit pouvoir déclencher/suivre le job Cloud Run et lancer les requêtes SQL dans BigQuery) :
```bash
# Permet de lancer et de monitorer le job Cloud Run (LRO)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/run.developer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/bigquery.dataEditor"
```

---

## 5. Configuration d'Artifact Registry

Créez le dépôt Artifact Registry pour stocker vos conteneurs Docker :
```bash
gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Docker images for weather GCP onboarding" \
  --project="$PROJECT_ID"
```

Configurez l'authentification Docker locale :
```bash
gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

---

## 6. Configuration de la Workload Identity Federation (WIF)

WIF évite d'utiliser des clés de compte de service à longue durée de vie dans GitHub.

### 6.1 Créer le pool et le provider OIDC
```bash
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

### 6.2 Lier la WIF au SA CI/CD
Autorisez votre dépôt GitHub à impersoner le compte de service de CI/CD :
```bash
gcloud iam service-accounts add-iam-policy-binding "$CICD_SA" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_OWNER}/${GITHUB_REPO}"
```

### 6.3 Créer l'agent de service Workflows
Si l'agent de service pour Workflows n'existe pas encore dans votre projet, initialisez-le :
```bash
gcloud beta services identity create \
  --service=workflows.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet
```

---

## 7. Configuration de GitHub avec le CLI `gh`

Plutôt que d'aller configurer manuellement les variables dans l'interface de GitHub, utilisez l'outil officiel de ligne de commande `gh` pour envoyer vos variables directement à votre dépôt de manière sécurisée.

### 7.1 Vérifier la connexion à GitHub
```bash
gh auth status
```
*(Si vous n'êtes pas connecté, lancez `gh auth login` et suivez les instructions).*

### 7.2 Configurer les variables du dépôt
Exécutez ces commandes pour configurer automatiquement les variables d'intégration de votre dépôt GitHub :
```bash
gh variable set GCP_PROJECT_ID --body "$PROJECT_ID"
gh variable set GCP_PROJECT_NUMBER --body "$PROJECT_NUMBER"
gh variable set GCP_SERVICE_ACCOUNT --body "$CICD_SA"
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --body "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"
```

---

## 8. Développement & Lancement local

### 8.1 Installer les dépendances localement
Le projet utilise `uv` pour la gestion des dépendances. Installez-les avec :
```bash
uv sync
```

### 8.2 Exécuter l'ingestion localement
Pour tester le script Python en local (en utilisant vos identifiants d'Application Default Credentials) :
```bash
make run
```
Vérifiez ensuite que des lignes ont été écrites dans votre table Bronze :
```bash
bq query --use_legacy_sql=false "
SELECT *
FROM \`${PROJECT_ID}.${BQ_BRONZE_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}\`
LIMIT 10
"
```

---

## 9. Premier Push & Déploiement CI/CD

Ajoutez vos modifications, commitez-les, et poussez votre branche vers GitHub :
```bash
git add .
git commit -m "feat: initial weather pipeline infrastructure and scripts"
git push -u origin "$NAME"
```

Cette action va déclencher le workflow GitHub Actions (`.github/workflows/deploy.yml`) qui va :
1. Builder et pousser l'image Docker du script d'ingestion dans votre Artifact Registry.
2. Créer ou mettre à jour le Job Cloud Run.
3. Rendre et déployer le workflow d'orchestration GCP Workflows.

---

## 10. Exécution & Validation du pipeline de données

Une fois le pipeline déployé avec succès par GitHub Actions, vous pouvez le lancer manuellement.

### 10.1 Lancer le workflow GCP
```bash
gcloud workflows run "$WORKFLOW_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID"
```

### 10.2 Valider le flux de données dans BigQuery
Vérifiez que le workflow a bien déclenché l'ingestion (Bronze), nettoyé les données (Silver) et agrégé le résultat final (Gold).

```bash
# Vérifier la table Bronze
bq query --use_legacy_sql=false "SELECT COUNT(*) as count FROM \`${PROJECT_ID}.${BQ_BRONZE_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}\`"

# Vérifier la table Silver
bq query --use_legacy_sql=false "SELECT COUNT(*) as count FROM \`${PROJECT_ID}.${BQ_SILVER_DATASET}.${BQ_STATION_WEATHER_TABLE}\`"

# Vérifier la table Gold
bq query --use_legacy_sql=false "SELECT * FROM \`${PROJECT_ID}.${BQ_GOLD_DATASET}.${BQ_SUMMARY_TABLE}\`"
```

### 10.3 Visualiser (Looker Studio)
Connectez-vous à Looker Studio, créez une source de données BigQuery pointant sur votre table Gold (`onboarding-de-willem-499614.willem_gold.summary`) et configurez vos rapports météo.

---

## 11. Nettoyage

Si vous souhaitez supprimer l'ensemble de vos ressources de test et éviter des coûts inutiles :
```bash
gcloud workflows delete "$WORKFLOW_NAME" --location="$REGION" --project="$PROJECT_ID"
gcloud run jobs delete "$JOB_NAME" --region="$REGION" --project="$PROJECT_ID"
gcloud artifacts repositories delete "$AR_REPO" --location="$REGION" --project="$PROJECT_ID"
bq rm -r -f -d "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq rm -r -f -d "$PROJECT_ID:$BQ_SILVER_DATASET"
bq rm -r -f -d "$PROJECT_ID:$BQ_GOLD_DATASET"
```

[1]: https://docs.github.com/en/actions/writing-workflows/about-workflows
[2]: https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines
[3]: https://cloud.google.com/artifact-registry/docs/docker/store-docker-container-images
[4]: https://cloud.google.com/run/docs/create-jobs
[5]: https://cloud.google.com/bigquery/docs/datasets
[6]: https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository
[7]: https://cloud.google.com/bigquery/docs/samples/bigquery-table-insert-rows
[8]: https://cloud.google.com/workflows/docs/reference/googleapis/run/v2/projects.locations.jobs/run
[9]: https://cloud.google.com/dataform/docs/overview
[10]: https://support.google.com/looker-studio/answer/6370296
