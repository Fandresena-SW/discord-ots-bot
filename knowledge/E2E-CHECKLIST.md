# E2E Checklist — Release Gate (RFC-006)

- **Status:** Artefact de preuve de release ; toutes les lignes doivent
  passer **avant déploiement** (RULES §8/§9, PRD §9 Day 5).
- **Périmètre:** vérifie (sans le modifier) le comportement du `/ots` v2
  livré par RFC-005, en conditions réelles dans le serveur Discord de
  production/test.
- **Pré-requis avant exécution:** sanity check automatisé —
  ```bash
  python -m unittest test_bot
  ```
  Les 12 tests (`normalize_name`, `render_team_text`) doivent passer. Ils
  couvrent la logique pure (F12/F14) que ce checklist exerce ensuite en
  conditions réelles bout-en-bout.
- **Comment lire ce document:** chaque ligne est un scénario avec les étapes
  exactes à jouer, le résultat attendu, et une colonne **Résultat** à remplir
  (`PASS` / `FAIL` / `PENDING`) au moment de l'exécution réelle. Une ligne
  non exécutée reste `PENDING` — ne jamais marquer `PASS` sans l'avoir
  réellement joué dans le serveur (RULES §10, pas de demi-implémentation
  silencieuse).

---

## Grille des scénarios

| # | Scénario | Étapes | Attendu | Résultat | Notes |
|---|----------|--------|---------|----------|-------|
| 1 | Happy path — joueur **avec** `pokepaste_url` | `/ots giovlacouture` (ou `/ots zou`) dans le serveur, tournoi actif contenant ce joueur | DM reçu avec embed : titre `OTS de giovlacouture` **cliquable** (lien = `pokepaste_url`), description = `team_text` dans un bloc de code, couleur `0x3B4CCA` | PASS | Nécessite un tournoi actif avec ce joueur seedé/saisi. |
| 2 | Happy path — joueur **sans** `pokepaste_url` | `/ots koloina` (seed avec `pokepaste_url = NULL`) | DM reçu, embed **sans** lien cliquable sur le titre, description rendue normalement | PASS | Utiliser le joueur seed `koloina` explicitement pour ce cas NULL. |
| 3 | **Introuvable** (F16) | `/ots un_nom_qui_nexiste_pas` | Réponse éphémère française : `❌ Aucun joueur nommé **un_nom_qui_nexiste_pas** dans le tournoi en cours.` (mention explicite du périmètre tournoi) | PASS | Vérifier le nom exact tapé est répété dans le message (pas le nom normalisé). |
| 4 | **Aucun tournoi actif** (F15b) | Désactiver temporairement le tournoi actif (`is_active = false`, aucun autre actif), puis `/ots <joueur>` | Réponse éphémère française : `⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard.` | PASS | Réactiver le tournoi immédiatement après le test (ne pas laisser aucun tournoi actif). |
| 5 | **Supabase indisponible / timeout** (F15c/F22) | Simuler une panne (ex. couper temporairement l'accès réseau du worker à Supabase, ou pointer `SUPABASE_URL` vers une valeur invalide sur un environnement de test), puis `/ots <joueur>` | Réponse éphémère française : `⚠️ Service momentanément indisponible. Réessayez dans un instant.` **et** une ligne de log opérateur visible via `journalctl -u discord-ots-bot -f` (ex. `fetch_active_player: request error: ...`) | PASS | Ne pas exécuter ce test contre la production réelle sans fenêtre de maintenance — utiliser un environnement de test si possible. |
| 6 | **Repli DM fermés** | Fermer ses DMs serveur (Paramètres de confidentialité du serveur), puis `/ots <joueur>` | `discord.Forbidden` intercepté ; réponse éphémère **dans le salon** avec le message `⚠️ Je n'ai pas pu vous envoyer un DM. Voici votre OTS :` et l'embed complet joint | PASS | Rouvrir les DMs après le test. |
| 7 | **`team_text` surdimensionné** (F14) | Saisir temporairement un joueur de test avec un `team_text` > 4096 caractères, puis `/ots <ce joueur>` | Embed valide (Discord n'a pas rejeté le message), description tronquée avec le marqueur français `… (équipe tronquée)` visible en fin de bloc, longueur totale ≤ 4096 | PASS | Supprimer la ligne de test après vérification pour ne pas polluer le roster réel. |
| 8 | **`team_text` avec backticks** (F14) | Saisir un joueur de test avec un `team_text` contenant une séquence de 3+ backticks consécutifs (ex. \`\`\` au milieu du texte), puis `/ots <ce joueur>` | Le bloc de code rendu ne se referme pas prématurément ; le contenu entier reste visible à l'intérieur d'un unique bloc de code, sans "cassure" ni contenu qui s'échappe hors du bloc | PASS | Supprimer la ligne de test après vérification. |
| 9 | **Variantes casse/espaces** (F12) | `/ots ZOU`, `/ots   zou  `, `/ots Zou` — trois variantes du même joueur | Les trois résolvent vers le **même** joueur, avec un embed identique | PASS | Confirme que la normalisation bot (`trim`+`lower`) correspond exactement à l'index `lower(ingame_name)` + trigger `trim_ingame_name()`. |

---

## Sign-off

- **Toutes les lignes ci-dessus doivent être `PASS`** avant tout déploiement
  de ce code en production (RULES §9 — seuils de qualité qualité avant
  déploiement).
- Toute ligne restant `PENDING` bloque le déploiement — elle doit être
  exécutée et son résultat réel consigné (pas de `PASS` fabriqué).

| Date | Organisateur / exécutant | Résultat global |
|------|--------------------------|------------------|
| 2026-07-18 | Fandresena RANDRIA | PASS — les 9 scénarios ont été exécutés en conditions réelles (serveur Discord + Supabase Studio de production) et sont tous passés. |

---

## Références

- `.claude/RULES.md` §8 (E2E = release gate primaire), §9 (seuils qualité
  avant déploiement).
- `knowledge/RFCs/RFC-006-Reliability-And-Release.md` §3.3 (liste des
  scénarios mandatés).
- `knowledge/RUNBOOK.md` §5 (pré-vol) et §6 (contingence) — ce checklist
  vérifie en conditions réelles ce que ces sections documentent en procédure.
- `knowledge/DEPLOYMENT.md` §10 (commandes `journalctl` / `systemctl` citées
  au scénario 5).
- `test_bot.py` — sanity check automatisé pré-requis (`python -m unittest
  test_bot`).
