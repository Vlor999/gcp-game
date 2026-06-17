# Guide d'intégration GCP Onboarding (Step-by-Step)

Ce guide détaille toutes les étapes nécessaires pour configurer et déployer votre environnement météo sur Google Cloud Platform (GCP) avec une intégration CI/CD propre via GitHub Actions.

Il a été conçu pour servir de parcours pédagogique d'onboarding : chaque collaborateur déploie ses propres ressources isolées dans son sandbox GCP, tout en utilisant un dépôt GitHub commun.

---

## 1. Initialisation locale et branche

Toutes les ressources GCP seront isolées par personne et préfixées par votre nom d'utilisateur (variable `NAME`).

### 1.1 Configurer le fichier `.env`
Le fichier `.env` contient toutes les variables de configuration utilisées par les scripts locaux et le générateur de templates. Créez-le à partir de l'exemple fourni :
```bash
cp .env.example .env
```

Mettez à jour les variables suivantes dans le fichier `.env` :
*   `NAME` : votre prénom en minuscules, sans espaces ni caractères spéciaux (ex: `willem`).
*   `GITHUB_OWNER` : votre nom d'utilisateur GitHub (qui possède le fork ou le dépôt principal).
*   `GITHUB_REPO` : le nom du dépôt GitHub (par défaut `gcp-game`).
*   `PROJECT_ID` : l'identifiant exact de votre projet bac à sable GCP (ex: `onboarding-de-willem-499614`).
*   `PROJECT_NUMBER` : le numéro de votre projet GCP (disponible sur l'accueil de votre console GCP).

### 1.2 Créer votre branche et initialiser le workflow
Lancez la commande suivante :
```bash
make bootstrap
```
Cette commande :
1. Lit la variable `NAME` depuis votre fichier `.env`.
2. Vérifie qu'aucune branche locale ou distante ne porte déjà ce nom.
3. Crée et bascule sur la branche Git locale nommée selon votre `NAME` (ex: `willem`).
4. Génère localement le fichier de configuration de workflow `workflows/weather_pipeline.yaml` ainsi que les fichiers Dataform de transformation SQL (`workflow_settings.yaml`, `definitions/silver_station_weather.sqlx`, `definitions/gold_summary.sqlx`) à partir des templates locaux.

### 1.3 Charger les variables dans votre terminal
Pour pouvoir exécuter les commandes GCP du guide par simple copier-coller dans votre session de terminal, chargez les variables d'environnement locales :
```bash
set -a; source .env; set +a
```

---

## 2. Authentification GCP & Activation des APIs

### 2.1 Connexion à votre compte GCP
Connectez-vous à votre compte GCP via le SDK `gcloud` :
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

### 2.2 Activer les APIs GCP nécessaires
Activez les APIs requises pour Cloud Run, Artifact Registry, BigQuery, Workflows, Dataform et l'authentification GitHub :
```bash
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  bigquery.googleapis.com \
  workflows.googleapis.com \
  dataform.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com
```

---

## 3. Création des datasets et des tables d'ingestion

### 3.1 La convention de nommage BigQuery
BigQuery utilise une structure d'adresse stricte à trois niveaux : `projet.dataset.table`. 
Pour isoler les données de chaque utilisateur tout en conservant l'architecture médaillon, la convention suivante est adoptée :
*   `willem_bronze` (Données brutes, copie conforme de la source).
*   `willem_silver` (Données dédoublées, nettoyées et typées par Dataform).
*   `willem_gold` (Données agrégées, prêtes pour le reporting par Dataform).

### 3.2 Créer les datasets (Bronze, Silver, Gold)
Créez les trois datasets dans votre région cible :
```bash
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_SILVER_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_GOLD_DATASET"
```

### 3.3 Créer les tables de la couche Bronze
Les tables de la couche **Bronze** doivent être créées manuellement car elles sont alimentées en streaming JSON par notre script d'ingestion Python (qui requiert que la table cible existe déjà) :
```bash
bq mk --table "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STOPS_SNCF_RAW_TABLE" \
  schemas/bigquery/stops_sncf_raw.json

bq mk --table "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STATIONS_WEATHER_RAW_TABLE" \
  schemas/bigquery/stations_weather_raw.json
```
*   *Note sur les couches Silver et Gold* : **Ne créez pas les tables des couches Silver et Gold**. Contrairement aux étapes précédentes, c'est **Dataform** qui va créer et écraser dynamiquement ces tables lors de l'exécution du pipeline d'orchestration GCP !

---

## 4. Créer les comptes de service (SAs) & Droits IAM

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
```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/bigquery.dataEditor"
```

### 4.3 Rôles pour le SA CI/CD (GitHub Actions)
```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/run.developer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/workflows.editor"

# Requis pour accorder les droits sur les tables et exécuter BigQuery dans le pipeline
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/bigquery.admin"

# Requis pour gérer ou tester le dépôt Dataform
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/dataform.admin"

gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/iam.serviceAccountUser"

gcloud iam service-accounts add-iam-policy-binding "$WORKFLOW_SA" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/iam.serviceAccountUser"
```

### 4.4 Rôles pour le SA Workflows
```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/run.developer"

# Requis pour compiler et appeler le pipeline Dataform
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/dataform.editor"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/bigquery.dataEditor"
```

---

## 5. Configuration d'Artifact Registry

```bash
gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Docker images for weather GCP onboarding" \
  --project="$PROJECT_ID"

gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

---

## 6. Configuration de la Workload Identity Federation (WIF)

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

Autorisez le dépôt GitHub à usurper l'identité du SA CI/CD :
```bash
gcloud iam service-accounts add-iam-policy-binding "$CICD_SA" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_OWNER}/${GITHUB_REPO}"
```

Initialisez l'agent de service interne de GCP Workflows :
```bash
gcloud beta services identity create \
  --service=workflows.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet
```

---

## 7. Configuration de Dataform sur la console GCP

Comme l'API Dataform nécessite une connexion authentifiée et sécurisée à votre dépôt Git pour compiler vos scripts SQLX, vous devez créer et lier le dépôt via la console GCP.

### 7.1 Créer le dépôt Dataform
1. Rendez-vous sur la console GCP, dans l'outil **BigQuery** puis dans le menu **Dataform** (à gauche).
2. Cliquez sur **Créer un dépôt** (*Create repository*).
3. Renseignez l'ID du dépôt : saisissez la valeur de votre variable `${PREFIX}-dataform` (ex: `willem-meteo-dataform`).
4. Choisissez la région de déploiement : `europe-west1` (doit être identique à la variable `${REGION}`).

### 7.2 Connecter le dépôt à votre dépôt Git (GitHub)
1. Dans la liste des dépôts Dataform, cliquez sur le dépôt que vous venez de créer.
2. Cliquez sur **Se connecter à Git** (*Connect to Git*).
3. Choisissez le protocole **HTTPS** :
   *   Saisissez l'URL de votre dépôt Git : `https://github.com/ton-username-github/gcp-game.git`
   *   Saisissez le nom de la branche par défaut : votre variable `${NAME}` (ou `main` si vous poussez directement dessus).
4. Pour l'authentification Git :
   *   Générez un **Personal Access Token (PAT)** sur GitHub avec les droits `repo` en lecture/écriture.
   *   Enregistrez ce token sous forme de secret GCP Secret Manager et associez-le dans la configuration de connexion Git sur Dataform.

---

## 8. Configuration de GitHub avec le CLI `gh`

```bash
gh auth status
```

Configurez automatiquement les variables d'intégration de votre dépôt GitHub :
```bash
gh variable set GCP_PROJECT_ID --body "$PROJECT_ID"
gh variable set GCP_PROJECT_NUMBER --body "$PROJECT_NUMBER"
gh variable set GCP_SERVICE_ACCOUNT --body "$CICD_SA"
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --body "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"
```

---

## 9. Développement & Lancement local

### 9.1 Installer les dépendances
```bash
uv sync
```

### 9.2 Exécuter l'ingestion localement
```bash
make run
```

---

## 10. Premier Push & Déploiement CI/CD

Ajoutez vos modifications (y compris les fichiers générés de configuration de workflow et les scripts Dataform `.sqlx`), commitez-les, et poussez votre branche vers GitHub :
```bash
git add .
git commit -m "feat: use Dataform for SQL transformations and orchestrate weather pipeline"
git push -u origin "$NAME"
```

L'intégration continue va automatiquement configurer le Job Cloud Run et déployer le fichier d'orchestration dans GCP Workflows.

---

## 11. Exécution & Validation du pipeline de données

### 11.1 Lancer le workflow GCP
```bash
gcloud workflows run "$WORKFLOW_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID"
```
Ce workflow effectue désormais les actions suivantes :
1. Déclenche le job Cloud Run pour écrire les lignes brutes dans la table **Bronze** BigQuery.
2. Interroge l'API Dataform pour compiler vos scripts `.sqlx` présents sur votre branche Git.
3. Exécute le graphe de transformation SQL (Dataform va automatiquement créer la table **Silver** avec les filtres de nettoyage, puis la table **Gold** avec les KPI de crise).

### 11.2 Valider le flux de données dans BigQuery
Vérifiez le bon fonctionnement de l'ensemble de la chaîne de données :

```bash
# Vérifier la table Bronze (brute)
bq query --use_legacy_sql=false "SELECT COUNT(*) as count FROM \`${PROJECT_ID}.${BQ_BRONZE_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}\`"

# Vérifier la table Silver (nettoyée par Dataform)
bq query --use_legacy_sql=false "SELECT COUNT(*) as count FROM \`${PROJECT_ID}.${BQ_SILVER_DATASET}.${BQ_STATION_WEATHER_TABLE}\`"

# Vérifier la table Gold (KPI consolidés par Dataform)
bq query --use_legacy_sql=false "SELECT * FROM \`${PROJECT_ID}.${BQ_GOLD_DATASET}.${BQ_SUMMARY_TABLE}\` ORDER BY time DESC LIMIT 10"
```

### 11.3 Visualiser sur un Tableau de Bord (Looker Studio)
Connectez-vous à Looker Studio, créez une source de données BigQuery pointant sur votre table Gold (`onboarding-de-willem-xxxxxx.willem_gold.summary`) et configurez vos rapports météo.

---

## 12. Nettoyage

Si vous souhaitez supprimer l'ensemble de vos ressources de test créées sur GCP pour éviter des coûts inutiles de stockage ou de calcul :
```bash
gcloud workflows delete "$WORKFLOW_NAME" --location="$REGION" --project="$PROJECT_ID"
gcloud run jobs delete "$JOB_NAME" --region="$REGION" --project="$PROJECT_ID"
gcloud artifacts repositories delete "$AR_REPO" --location="$REGION" --project="$PROJECT_ID"
bq rm -r -f -d "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq rm -r -f -d "$PROJECT_ID:$BQ_SILVER_DATASET"
bq rm -r -f -d "$PROJECT_ID:$BQ_GOLD_DATASET"
```

*Note : Pour détruire le dépôt Dataform, allez sur la console GCP sous BigQuery ➡️ Dataform et supprimez-le manuellement.*

---

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
