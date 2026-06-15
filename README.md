# GCP Game

Petit projet Python d'exploration autour de Google Cloud Platform.

Ce dépôt sert de base d'onboarding : chaque personne travaille sur sa propre branche et déploie ses propres ressources GCP préfixées par son nom.

## Objectif

L'objectif du projet est de construire pas à pas un petit jeu ou exercice pratique autour de GCP, en gardant une structure simple et facile à faire évoluer.

Le projet contient :

- un point d'entrée Python dans `app/main.py` ;
- une configuration projet dans `pyproject.toml` ;
- un environnement géré avec `uv` ;
- des dépendances runtime séparées des dépendances de développement ;
- un template de workflow GCP dans `workflows/weather_pipeline.template.yaml` ;
- un script de génération dans `scripts/render-workflow.sh`.

## Prérequis

- Python `3.11` ou plus récent
- `uv`
- Un compte Google Cloud Platform
- Le SDK Google Cloud (`gcloud`) configuré localement si le projet doit interagir avec GCP

## Installation

Depuis la racine du projet :

```bash
uv sync
```

Cette commande installe les dépendances déclarées dans `pyproject.toml` en utilisant le fichier de verrouillage `uv.lock`.

Pour installer uniquement les dépendances runtime, comme en déploiement :

```bash
uv sync --frozen --no-dev --no-install-project
```

## Démarrage

### 1. Configurer `.env`

Copie l'exemple :

```bash
cp .env.example .env
```

Puis mets à jour au minimum :

```bash
NAME=<prenom>
GITHUB_OWNER=<ton-username-github>
GITHUB_REPO=gcp-game
PROJECT_ID=onboarding-de
```

`NAME` doit suivre la convention suivante :

```text
minuscules, chiffres, tirets ou underscores
```

Exemples valides :

```bash
willem
paul
marie
```

### 2. Créer la branche et générer le workflow

Lance :

```bash
make bootstrap
```

Cette commande :

- lit `NAME` depuis `.env` ;
- vérifie que ce nom n'est pas déjà utilisé par une autre branche locale ou distante ;
- crée la branche si elle n'existe pas ;
- accepte le cas où tu es déjà sur cette branche ;
- génère `workflows/weather_pipeline.yaml` depuis `workflows/weather_pipeline.template.yaml`.

Par exemple, avec `NAME=willem`, cela produit :

```text
willem-meteo-ingest
willem-meteo-pipeline
willem_bronze
willem_silver
willem_gold
```

Tu peux aussi lancer les étapes séparément :

```bash
make branch
make render-workflow
```

### 3. Lancer le script localement

Authentifie-toi auprès de GCP :

```bash
gcloud auth application-default login
```

Puis lance l'ingestion :

```bash
make run
```

## Suite du guide

Continue ensuite avec [temp.md](temp.md), qui détaille les étapes GCP : APIs, BigQuery, service accounts, Artifact Registry, Workload Identity Federation, Cloud Run Jobs, Workflows et CI/CD GitHub Actions.

## Structure du projet

```text
.
├── app/
│   └── main.py
├── scripts/
│   └── render-workflow.sh
├── workflows/
│   ├── weather_pipeline.template.yaml
│   └── weather_pipeline.yaml
├── Dockerfile
├── Makefile
├── pyproject.toml
├── README.md
└── uv.lock
```

## Configuration GCP

Avant d'ajouter des interactions avec GCP, vérifier que le SDK Google Cloud est installé et authentifié :

```bash
gcloud auth login
gcloud config set project "$PROJECT_ID"
gcloud config list
```
