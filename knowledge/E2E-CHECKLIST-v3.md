# E2E Checklist v3.0 — Release Gate (RFC-010)

- **Status:** Artefact de preuve de release pour l'addendum v3.0 (Challonge
  integration, RFC-007–010) ; toutes les lignes doivent passer **avant
  annonce/release** de ce comportement (RULES §18/§19, v3.0 addendum §21).
- **Périmètre:** vérifie (sans le modifier) le comportement du `/ots` v3.0
  livré par RFC-009 — l'argument signifie désormais **« votre propre nom »**,
  et la réponse est l'**OTS de votre adversaire actuel** (rupture de
  comportement intentionnelle et confirmée, PRD §17/§24 item 4 — pas une
  régression à corriger). Ce fichier **n'écrase pas et ne complète pas**
  `knowledge/E2E-CHECKLIST.md` (RFC-006) — ce dernier reste le registre
  historique clos de la release v2.0 ; celui-ci documente le contrat `/ots`
  *changé* de v3.0.
- **Pré-requis avant exécution:** sanity check automatisé —
  ```bash
  python -m unittest test_bot
  ```
  Les 61 tests (`normalize_name`, `render_team_text`,
  `participant_candidate_ids`, `pick_opponent_id`, `is_cache_stale`, et depuis
  RFC-013 `validate_config`, `is_organizer`, `resolve_binding_conflict`,
  `pick_season_roster_row`, `OTS_STATUS_MESSAGES`) doivent passer. Ils
  couvrent la logique pure (F12/F14, RFC-009 §7, RFC-010 §3.2/F36, RFC-013
  §7.2) que ce checklist exerce ensuite en conditions réelles bout-en-bout.
- **Comment lire ce document:** chaque ligne est un scénario avec les étapes
  exactes à jouer, le résultat attendu, et une colonne **Résultat** à remplir
  (`PASS` / `FAIL` / `PENDING`) au moment de l'exécution réelle. Une ligne
  non exécutée reste `PENDING` — ne jamais marquer `PASS` sans l'avoir
  réellement joué dans le serveur/Supabase/Challonge (RULES §10, pas de
  demi-implémentation silencieuse). **Toutes les lignes ci-dessous sont
  désormais `PASS`** — elles étaient `PENDING` à la rédaction de ce document
  (implémentation code + docs de RFC-010, 2026-07-20), puis exécutées en
  conditions live lors d'un événement réel la semaine du 2026-07-20 et
  confirmées par l'organisateur le **2026-07-31**. La même répartition des
  rôles que pour RFC-006 a été suivie : code/docs par l'assistant, exécution
  live par l'organisateur (voir le § Sign-off en bas de ce fichier).
- **Convention de lecture (RFC-013):** depuis RFC-013, `/ots` n'accepte plus
  aucun argument — l'appelant est déduit du compte Discord relié à un joueur
  par l'organisateur (F76). Dans les lignes 2, 3, 5, 6, 7, 8 et 9 ci-dessous,
  lire `/ots <joueur>` comme « `/ots` exécuté par le compte Discord relié à
  `<joueur>` » ; ces lignes restent valides sous cette lecture. Les lignes 1 et
  4 sont en revanche devenues impossibles à rejouer telles quelles et sont
  **struck** ci-dessous (voir leur colonne Notes) — re-testées par
  `E2E-CHECKLIST-v4.md` (RFC-014), scénarios 24–28.
- **Fixtures utilisées:** les lignes 1, 4, 5, 6 s'appuient sur les fixtures
  de seed de RFC-007 (`schema.sql` §6 — tournoi `RFC-001 Test Tournament`,
  lié à `challonge_tournament_id = 'rfc007-test-tournament'`, avec
  `giovlacouture` ↔ `zou` en match `open` et `koloina` en `pending` sans
  adversaire). Les lignes 2, 3, 7, 8, 9 nécessitent une manipulation
  ponctuelle (désactivation du lien, backdating, panne simulée, tournoi
  Challonge réel lié) — notée par ligne. Indiquer dans la colonne **Notes**
  laquelle des deux sources (seed RFC-007 ou tournoi Challonge réel lié) a
  été utilisée pour chaque ligne, comme demandé par RFC-010 §3.4.

---

## Grille des scénarios

| # | Scénario | Étapes | Attendu | Résultat | Notes |
|---|----------|--------|---------|----------|-------|
| 1 | ~~**Happy path** — les deux sens du match seedé~~ | `/ots giovlacouture` dans le serveur, tournoi actif = `RFC-001 Test Tournament` ; puis `/ots zou` | `/ots giovlacouture` renvoie l'OTS de **zou** (son adversaire actuel) ; `/ots zou` renvoie l'OTS de **giovlacouture** — embed correct dans les deux cas (titre `OTS de {nom de l'adversaire}`, description = son `team_text`, couleur `0x3B4CCA`) | PASS | Confirme la résolution symétrique du match `open` (fixtures RFC-007). Préciser seed ou tournoi réel utilisé. ⛔ Supersédé par RFC-013 / F76 — `/ots` n'accepte plus d'argument ; re-testé par `E2E-CHECKLIST-v4` (RFC-014), scénarios 24–28. |
| 2 | **`no_active`** (inchangé depuis v2.0) | Désactiver temporairement le tournoi actif (`is_active = false`, aucun autre actif), puis `/ots <joueur>` | Réponse éphémère française : `⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard.` | PASS | Réactiver le tournoi immédiatement après le test. Identique au scénario 4 de `E2E-CHECKLIST.md`. |
| 3 | **`no_challonge_link`** (F34) | Sur un tournoi actif, mettre temporairement `challonge_tournament_id = NULL`, puis `/ots <joueur>` | Réponse éphémère française : `❌ Ce tournoi n'est pas relié à Challonge. Impossible de déterminer votre adversaire actuel.` | PASS | Restaurer la valeur de `challonge_tournament_id` immédiatement après le test. |
| 4 | ~~**`requester_not_found`**~~ | `/ots un_nom_absent_du_cache_challonge` (nom absent de `challonge_participants_cache` pour le tournoi actif) | Réponse éphémère française : `❌ Aucun participant nommé **un_nom_absent_du_cache_challonge** trouvé dans le bracket Challonge de ce tournoi.` | PASS | Vérifier que le nom exact tapé est répété dans le message. ⛔ Supersédé par RFC-013 / F76 — `/ots` n'accepte plus d'argument ; re-testé par `E2E-CHECKLIST-v4` (RFC-014), scénarios 24–28. |
| 5 | **`no_current_match`** | `/ots koloina` (fixture seedée `pending`, sans adversaire) | Réponse éphémère française : `ℹ️ Vous n'avez pas de match en cours pour le moment.` | PASS | Utiliser explicitement `koloina` pour ce cas (fixture RFC-007 dédiée). |
| 6 | **`opponent_no_ots`** | Sur le tournoi actif, ajouter temporairement un participant dans `challonge_participants_cache` sans ligne `players` correspondante, le placer en match `open` face à un joueur normal, puis `/ots <ce joueur normal>` | Réponse éphémère française : `⚠️ Votre adversaire a été trouvé, mais son OTS n'est pas encore enregistré. Contactez l'organisateur.` **et** un log opérateur distinct mentionnant `opponent_no_ots`/le nom de l'adversaire (à distinguer du scénario 4 côté log, RULES §17 point 5) | PASS | Supprimer les lignes de test (`challonge_participants_cache` + `challonge_matches_cache`) après vérification. |
| 7 | **`unavailable`** (inchangé dans son mécanisme depuis v2.0) | Simuler une panne (couper temporairement l'accès réseau du worker à Supabase, ou pointer `SUPABASE_URL` vers une valeur invalide sur un environnement de test), puis `/ots <joueur>` | Réponse éphémère française : `⚠️ Service momentanément indisponible. Réessayez dans un instant.` **et** une ligne de log opérateur visible via `journalctl -u discord-ots-bot -f` | PASS | Ne pas exécuter contre la production réelle sans fenêtre de maintenance. Identique en mécanisme au scénario 5 de `E2E-CHECKLIST.md`, mais désormais sur le chemin `fetch_current_opponent`. |
| 8 | **Log de staleness** (F36, opérateur uniquement) | Dans Supabase Studio, mettre à jour manuellement `fetched_at` d'une ligne `challonge_participants_cache` du tournoi actif à une valeur > 48h dans le passé (ex. `now() - interval '3 days'`), puis `/ots <le joueur correspondant>` | Le log opérateur affiche `fetch_current_opponent: Challonge cache stale for tournament <id>: last refreshed <fetched_at> (>48h ago)` ; **la réponse `/ots` au joueur est inchangée** (même embed/latence que si le cache était frais) — la staleness ne bloque jamais | PASS | ⚠️ Ce backdating manuel de `fetched_at` est **uniquement pour ce test** — jamais une action opérationnelle réelle (RFC-010 §8). Restaurer `fetched_at` à sa vraie valeur (ou re-déclencher §8 du RUNBOOK) après vérification. |
| 9 | **Round-trip du déclencheur** (Journey F, live) | Sur un tournoi réellement lié à Challonge : valider un tour dans Challonge (scores/vainqueur), lancer la commande `curl` documentée (`RUNBOOK.md` §8 étape 4), puis `/ots <un joueur concerné par ce tour>` | La commande `curl` renvoie `{"status":"ok","participants_synced":N,"matches_synced":M}` ; `/ots` reflète **immédiatement** le nouvel adversaire du tour (pas besoin d'attendre/redéployer) | PASS | Nécessite un tournoi Challonge réel lié (pas les fixtures seed, qui n'ont pas de tour à valider). Noter le tournoi utilisé. |

---

## Sign-off

- **Toutes les lignes ci-dessus doivent être `PASS`** avant toute annonce du
  comportement `/ots` v3.0 en production (RULES §19 — seuils de qualité
  avant release).
- Toute ligne restant `PENDING` bloque la release — elle doit être exécutée
  et son résultat réel consigné (pas de `PASS` fabriqué), même si le code et
  la documentation sont par ailleurs complets.

| Date | Organisateur / exécutant | Résultat global |
|------|--------------------------|------------------|
| 2026-07-31 | Fandresena RANDRIA (organisateur) | ✅ **PASS (9/9)** — les 9 scénarios ont été exécutés en conditions live lors d'un événement réel la semaine du 2026-07-20 et confirmés intégralement conformes par l'organisateur le 2026-07-31. Sanity check automatisé au moment de la consignation : `python -m unittest test_bot` → 30/30 (24 au moment de la rédaction de RFC-010, plus 3 `ParticipantCandidateIdsTests` et les cas `pick_opponent_id` ajoutés par le correctif d'espace d'ids group-stage/bracket final), et `deno test supabase/functions/challonge-sync/mapping_test.ts` → 7/7. **Gate de release v3.0 franchie.** |

---

## Références

- `.claude/RULES.md` §18 (checklist v3.0 — sept issues fail-soft + happy
  path), §19 (F37 gate final de release).
- `knowledge/RFCs/RFC-010-Runbook-Staleness-Release.md` §3.4 (liste des
  scénarios mandatés), §8 (edge cases : backdating de test, deux artefacts
  de release-gate distincts).
- `knowledge/RFCs/RFC-009-OTS-Opponent-Resolution.md` §3.1 (les sept issues
  fail-soft d'origine).
- `knowledge/RUNBOOK.md` §8 — procédure de liaison/déclenchement vérifiée en
  conditions réelles par le scénario 9 ci-dessus.
- `knowledge/DEPLOYMENT.md` §12 — déploiement de l'Edge Function
  `challonge-sync` requis avant le scénario 9.
- `knowledge/E2E-CHECKLIST.md` — le registre de release v2.0 (RFC-006),
  distinct et non modifié par ce fichier.
- `test_bot.py` — sanity check automatisé pré-requis (`python -m unittest
  test_bot`).
