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
4. Génère le fichier de configuration de workflow `workflows/weather_pipeline.yaml` à partir de `workflows/weather_pipeline.template.yaml` en injectant vos variables d'environnement locales.

### 1.3 Charger les variables dans votre terminal
Pour pouvoir exécuter les commandes GCP du guide par simple copier-coller dans votre session de terminal, chargez les variables d'environnement locales :
```bash
set -a; source .env; set +a
```
*   `set -a` : exporte automatiquement toutes les variables qui seront définies ou modifiées par la suite.
*   `source .env` : exécute le fichier `.env` dans le shell courant.
*   `set +a` : désactive l'exportation automatique.

---

## 2. Authentification GCP & Activation des APIs

### 2.1 Connexion à votre compte GCP
Connectez-vous à votre compte GCP via le SDK `gcloud` :
```bash
gcloud auth login
gcloud auth application-default login
```
*   `gcloud auth login` : authentifie votre CLI `gcloud` pour les déploiements d'infrastructure.
*   `gcloud auth application-default login` : génère des identifiants locaux (Application Default Credentials - ADC) utilisés par le script Python en local pour interagir avec BigQuery sans clé de compte de service.

Configurez le projet actif dans le SDK `gcloud` :
```bash
gcloud config set project "$PROJECT_ID"
```

Vérifiez que la configuration est correcte :
```bash
[ "$(gcloud config get-value project 2>/dev/null)" = "$PROJECT_ID" ] && echo "Config OK" || echo "Erreur de configuration"
```

### 2.2 Activer les APIs GCP nécessaires
Pour interagir avec les services managés, vous devez activer les APIs correspondantes sur votre projet GCP :
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
*   `run.googleapis.com` : pour exécuter le script d'ingestion sous forme de Job Cloud Run.
*   `artifactregistry.googleapis.com` : pour héberger l'image Docker de votre application.
*   `bigquery.googleapis.com` : pour le stockage des données (Bronze, Silver, Gold).
*   `workflows.googleapis.com` : pour orchestrer le pipeline de données.
*   `iamcredentials.googleapis.com` & `sts.googleapis.com` : requis pour la fédération d'identité OIDC avec GitHub (WIF).
*   `dataform.googleapis.com` : pour industrialiser les transformations SQL.

---

## 3. Création des datasets et tables BigQuery

### 3.1 La convention de nommage BigQuery
BigQuery utilise une structure d'adresse stricte à trois niveaux : `projet.dataset.table`. 
Il est donc impossible de créer des sous-niveaux d'organisation comme `onboarding-de.willem.bronze.table`.

Pour isoler les données de chaque utilisateur tout en conservant les couches de l'architecture médaillon (Bronze, Silver, Gold), la convention suivante est adoptée :
*   `willem_bronze` (Données brutes, copie conforme de la source).
*   `willem_silver` (Données dédoublées, nettoyées et typées).
*   `willem_gold` (Données agrégées, prêtes pour le reporting).

### 3.2 Créer les datasets (Bronze, Silver, Gold)
```bash
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_SILVER_DATASET"
bq --location="$BQ_LOCATION" mk --dataset "$PROJECT_ID:$BQ_GOLD_DATASET"
```
*   `--location` : définit l'emplacement géographique de stockage (ex: `EU`). Choisir la bonne région à la création est critique car elle ne peut pas être modifiée ultérieurement [5].

### 3.3 Créer les tables à partir des schémas JSON
Nous créons les tables en spécifiant leur schéma structuré défini sous forme de fichier JSON dans le dossier `schemas/bigquery/` :

```bash
# Couche Bronze (Données d'ingestion SNCF et Météo brutes)
bq mk --table "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STOPS_SNCF_RAW_TABLE" \
  schemas/bigquery/stops_sncf_raw.json

bq mk --table "$PROJECT_ID:$BQ_BRONZE_DATASET.$BQ_STATIONS_WEATHER_RAW_TABLE" \
  schemas/bigquery/stations_weather_raw.json

# Couche Silver (Données nettoyées et modélisées)
bq mk --table "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_TABLE" \
  schemas/bigquery/station.json

bq mk --table "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_SNCF_TABLE" \
  schemas/bigquery/station_sncf.json

bq mk --table "$PROJECT_ID:$BQ_SILVER_DATASET.$BQ_STATION_WEATHER_TABLE" \
  schemas/bigquery/station_weather.json

# Couche Gold (Données agrégées et KPIs de crise météo)
bq mk --table "$PROJECT_ID:$BQ_GOLD_DATASET.$BQ_SNCF_WEATHER_STATION_TABLE" \
  schemas/bigquery/sncf_weather_station.json

bq mk --table "$PROJECT_ID:$BQ_GOLD_DATASET.$BQ_SUMMARY_TABLE" \
  schemas/bigquery/summary.json
```
*   *Note sur les contraintes* : BigQuery n'applique pas nativement de contraintes strictes d'intégrité (clés primaires/étrangères forcées) lors d'un `bq mk`. Ces contraintes, documentées dans [tables.md](tables.md), devront être gérées par vos requêtes de transformation SQL [7].

---

## 4. Créer les comptes de service (SAs) & Droits IAM

Pour sécuriser l'architecture, nous séparons les privilèges en trois comptes de service distincts.

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
Ce compte de service exécute le script Python dans Cloud Run. Il a besoin d'insérer des lignes dans BigQuery :
```bash
# Permet de lancer des requêtes et des jobs d'insertion
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/bigquery.jobUser"

# Permet d'écrire des données dans les datasets BigQuery
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/bigquery.dataEditor"
```

### 4.3 Rôles pour le SA CI/CD (GitHub Actions)
Ce compte de service est utilisé par GitHub Actions pour provisionner l'infrastructure et déployer le code :
```bash
# Permet de pousser les images Docker dans Artifact Registry
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/artifactregistry.writer"

# Permet de créer, modifier et configurer le Job Cloud Run
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/run.developer"

# Permet de déployer le workflow d'orchestration
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/workflows.editor"

# Permet de modifier ou créer les datasets BigQuery lors du CI/CD
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/bigquery.admin"

# Autorise le SA CI/CD à attacher les SAs runtime et workflow aux ressources créées
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/iam.serviceAccountUser"

gcloud iam service-accounts add-iam-policy-binding "$WORKFLOW_SA" \
  --member="serviceAccount:${CICD_SA}" \
  --role="roles/iam.serviceAccountUser"
```

### 4.4 Rôles pour le SA Workflows
Ce compte de service exécute les étapes orchestrées par Cloud Workflows. Il doit lancer le Job Cloud Run et exécuter les requêtes de transformation SQL (Silver/Gold) dans BigQuery :
```bash
# Requis pour lancer le Job Cloud Run et suivre son état (Operations LRO)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/run.developer"

# Requis pour exécuter des requêtes de transformation SQL
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/bigquery.jobUser"

# Requis pour écrire les résultats des transformations SQL dans Silver et Gold
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${WORKFLOW_SA}" \
  --role="roles/bigquery.dataEditor"
```

---

## 5. Configuration d'Artifact Registry

Créez le dépôt d'images Docker privé dans Artifact Registry :
```bash
gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Docker images for weather GCP onboarding" \
  --project="$PROJECT_ID"
```

Configurez l'authentification de votre démon Docker local pour l'autoriser à interagir avec le registre GCP :
```bash
gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

---

## 6. Configuration de la Workload Identity Federation (WIF)

La fédération d'identité de charge de travail (WIF) permet à GitHub Actions d'échanger un jeton OIDC de courte durée contre des informations d'identification GCP temporaires [2]. Cela évite d'avoir à stocker et à renouveler des clés JSON secrètes dans GitHub.

### 6.1 Créer le pool d'identité et le fournisseur OIDC
Créez le pool de ressources WIF et configurez le fournisseur pour valider les jetons émis par GitHub :
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
*   `--attribute-mapping` : mappe les métadonnées fournies par l'assertion GitHub (dépôt, utilisateur, branche) sur des attributs Google Cloud IAM.
*   `--attribute-condition` : **Condition de sécurité critique**. Elle restreint l'authentification uniquement aux requêtes provenant de votre propre dépôt GitHub.

### 6.2 Lier la WIF au SA CI/CD
Autorisez votre dépôt GitHub à impersonner (emprunter l'identité de) votre compte de service de CI/CD :
```bash
gcloud iam service-accounts add-iam-policy-binding "$CICD_SA" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_OWNER}/${GITHUB_REPO}"
```

### 6.3 Créer l'agent de service Workflows
Initialisez l'identité interne de service pour Cloud Workflows dans votre projet. Cette étape est indispensable pour que GCP configure correctement les communications de bas niveau entre Workflows et les autres APIs :
```bash
gcloud beta services identity create \
  --service=workflows.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet
```
*   `--quiet` : désactive les invites interactives et accepte les installations de dépendances de commandes si nécessaires.

---

## 7. Configuration de GitHub avec le CLI `gh`

Pour simplifier et sécuriser la configuration de l'intégration continue, utilisez l'outil de ligne de commande GitHub (`gh`) afin d'injecter directement vos variables dans les paramètres de votre dépôt GitHub.

### 7.1 Vérifier la connexion à GitHub
```bash
gh auth status
```
*(Si vous n'êtes pas connecté localement avec `gh`, lancez `gh auth login` et suivez les instructions de connexion via votre navigateur).*

### 7.2 Configurer les variables du dépôt
Exécutez ces commandes pour configurer automatiquement les variables d'intégration de votre dépôt GitHub Actions :
```bash
gh variable set GCP_PROJECT_ID --body "$PROJECT_ID"
gh variable set GCP_PROJECT_NUMBER --body "$PROJECT_NUMBER"
gh variable set GCP_SERVICE_ACCOUNT --body "$CICD_SA"
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --body "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"
```
*   Ces variables seront lues par le fichier `.github/workflows/deploy.yml` pour authentifier le pipeline avec WIF et cibler votre projet bac à sable GCP.

---

## 8. Développement & Lancement local

### 8.1 Installer les dépendances localement
Le projet utilise `uv` pour la gestion des dépendances Python rapides et reproductibles. Installez-les dans un environnement virtuel local avec :
```bash
uv sync
```

### 8.2 Exécuter l'ingestion localement
Pour tester le script Python en local (en utilisant vos identifiants d'Application Default Credentials) :
```bash
make run
```

### 8.3 Vérifier l'insertion locale
Vérifiez que des lignes de données brutes ont bien été insérées dans votre table Bronze :
```bash
bq query --use_legacy_sql=false "
SELECT *
FROM \`${PROJECT_ID}.${BQ_BRONZE_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}\`
LIMIT 10
"
```
*   `--use_legacy_sql=false` : force l'utilisation de SQL Standard (recommandé) à la place de Legacy SQL.

---

## 9. Premier Push & Déploiement CI/CD

Ajoutez vos modifications, commitez-les, et poussez votre branche vers GitHub :
```bash
git add .
git commit -m "feat: initial weather pipeline infrastructure and scripts"
git push -u origin "$NAME"
```

Cette action va déclencher le workflow GitHub Actions (`.github/workflows/deploy.yml`) qui va effectuer les actions suivantes de manière isolée sur votre profil :
1. Se connecter à GCP via la Workload Identity Federation (WIF).
2. Builder l'image Docker du script Python et la pousser dans votre Artifact Registry.
3. Créer ou mettre à jour le Job Cloud Run `willem-meteo-ingest` configuré pour tourner avec le SA `willem-meteo-runtime`.
4. Rendre le template de workflow avec vos variables spécifiques de branche.
5. Déployer la définition d'orchestration dans GCP Workflows (`willem-meteo-pipeline`) avec le SA `willem-meteo-workflow`.

---

## 10. Exécution & Validation du pipeline de données

Une fois le pipeline déployé avec succès par GitHub Actions, vous pouvez le lancer manuellement.

### 10.1 Lancer le workflow GCP
Déclenchez l'exécution de votre orchestrateur de données :
```bash
gcloud workflows run "$WORKFLOW_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID"
```
Ce workflow va appeler le connecteur Cloud Run Job pour ingérer les nouvelles données météo brutes dans Bronze, puis exécuter les requêtes de transformation SQL pour alimenter les tables Silver et Gold.

### 10.2 Valider le flux de données dans BigQuery
Vérifiez que le workflow a bien déclenché l'ingestion (Bronze), nettoyé les données (Silver) et agrégé le résultat final (Gold).

```bash
# 1. Vérifier le volume de la table Bronze (brute)
bq query --use_legacy_sql=false "SELECT COUNT(*) as count FROM \`${PROJECT_ID}.${BQ_BRONZE_DATASET}.${BQ_STATIONS_WEATHER_RAW_TABLE}\`"

# 2. Vérifier la table Silver (nettoyée, typée et dédoublée)
bq query --use_legacy_sql=false "SELECT COUNT(*) as count FROM \`${PROJECT_ID}.${BQ_SILVER_DATASET}.${BQ_STATION_WEATHER_TABLE}\`"

# 3. Consulter les indicateurs de la table Gold (KPIs de crise consolidés)
bq query --use_legacy_sql=false "SELECT * FROM \`${PROJECT_ID}.${BQ_GOLD_DATASET}.${BQ_SUMMARY_TABLE}\` ORDER BY time DESC LIMIT 10"
```

### 10.3 Visualiser sur un Tableau de Bord (Looker Studio)
1. Ouvrez **[Looker Studio](https://lookerstudio.google.com/)**.
2. Créez un rapport vide et ajoutez une source de données **BigQuery**.
3. Sélectionnez votre projet `onboarding-de-willem-xxxxxx`, le dataset `willem_gold`, et la table `summary`.
4. Configurez vos graphes (ex: courbes d'évolution des crises de température ou de vent).

---

## 11. Nettoyage

Si vous souhaitez supprimer l'ensemble de vos ressources de test créées sur GCP pour éviter des coûts inutiles de stockage ou de calcul :
```bash
gcloud workflows delete "$WORKFLOW_NAME" --location="$REGION" --project="$PROJECT_ID"
gcloud run jobs delete "$JOB_NAME" --region="$REGION" --project="$PROJECT_ID"
gcloud artifacts repositories delete "$AR_REPO" --location="$REGION" --project="$PROJECT_ID"
bq rm -r -f -d "$PROJECT_ID:$BQ_BRONZE_DATASET"
bq rm -r -f -d "$PROJECT_ID:$BQ_SILVER_DATASET"
bq rm -r -f -d "$PROJECT_ID:$BQ_GOLD_DATASET"
```
*   `bq rm -r -f -d` : supprime de manière récursive (`-r`) et sans invite de confirmation (`-f`) le dataset spécifié ainsi que toutes ses tables associées.

---

## Références Google Cloud & GitHub
[1] [About Workflows - GitHub Docs](https://docs.github.com/en/actions/writing-workflows/about-workflows)  
[2] [Configure Workload Identity Federation with deployment pipelines - Google Cloud Docs](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines)  
[3] [Quickstart: Store Docker container images in Artifact Registry - Google Cloud Docs](https://cloud.google.com/artifact-registry/docs/docker/store-docker-container-images)  
[4] [Create run jobs - Google Cloud Docs](https://cloud.google.com/run/docs/create-jobs)  
[5] [Create datasets - Google Cloud Docs](https://cloud.google.com/bigquery/docs/datasets)  
[6] [Creating a new repository - GitHub Docs](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository)  
[7] [Streaming insert - Google Cloud Docs](https://cloud.google.com/bigquery/docs/samples/bigquery-table-insert-rows)  
[8] [googleapis.run.v2.projects.locations.jobs/run connector - Google Cloud Docs](https://cloud.google.com/workflows/docs/reference/googleapis/run/v2/projects.locations.jobs/run)  
[9] [Dataform overview - Google Cloud Docs](https://cloud.google.com/dataform/docs/overview)  
[10] [Connect to Google BigQuery - Looker Studio Help](https://support.google.com/looker-studio/answer/6370296)  
