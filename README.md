# GCP Game

Petit projet Python d'exploration autour de Google Cloud Platform.

Cette première version contient une base minimale pour lancer un script Python et préparer progressivement l'ajout de ressources GCP.

## Objectif

L'objectif du projet est de construire pas à pas un petit jeu ou exercice pratique autour de GCP, en gardant une structure simple et facile à faire évoluer.

Pour l'instant, le projet contient :

- un point d'entrée Python dans `main.py` ;
- une configuration projet dans `pyproject.toml` ;
- un environnement géré avec `uv` ;
- une dépendance initiale vers `gcloud`.

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

## Lancement

Pour exécuter le script principal :

```bash
uv run python main.py
```

Sortie actuelle :

```text
Hello from gcp-game!
```

## Structure du projet

```text
.
├── main.py
├── pyproject.toml
├── README.md
└── uv.lock
```

## Configuration GCP

Avant d'ajouter des interactions avec GCP, vérifier que le SDK Google Cloud est installé et authentifié :

```bash
gcloud auth login
gcloud config set project <PROJECT_ID>
gcloud config list
```

Remplacer `<PROJECT_ID>` par l'identifiant du projet GCP cible.

## Prochaines étapes possibles

- Définir le concept exact du jeu ou de l'exercice.
- Ajouter une configuration explicite pour le projet GCP cible.
- Remplacer le `Hello from gcp-game!` par une première interaction avec GCP.
- Ajouter des tests automatisés.
- Documenter les commandes utiles au fur et à mesure de l'avancement.
