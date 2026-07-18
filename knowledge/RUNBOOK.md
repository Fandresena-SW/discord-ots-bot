# Runbook Organisateur — Workflows Supabase Studio

- **Status:** RFC-002 sections (§0–§4) complete ; §5 (pré-vol), §6
  (contingence / break-glass) et §7 (sauvegarde du roster) complétés par RFC-006.
- **Features couvertes:** F7, F8, F9, F10 (RFC-002) ; F20, F22, F24-backup
  (RFC-006).
- **PRD refs:** §5.2, §7 (Journey A & B), §8 (G2), §9 (Day 2 / Day 5 / Day 6),
  §11.1, §12.
- **S'appuie sur:** RFC-001 (`schema.sql` — tables, contrainte, trigger,
  index) ; RFC-003/005 (dégradation gracieuse déjà implémentée, vérifiée ici).
- **Complété par:** RFC-006 a ajouté §5–§7 ci-dessous (dernière section du
  runbook — release RFC-006 = clôture v2.0).

---

## But de ce document

Ce runbook est le **mode d'emploi de l'organisateur** pour gérer le backoffice
Supabase sans jamais toucher au code ni redéployer le bot (objectif G1 du PRD).
Il documente, dans l'ordre où on les utilise :

0. Le **bootstrap** unique du projet Supabase (une seule fois par environnement).
1. **Créer et activer** un tournoi (F7).
2. Le **switch d'activation en deux temps** (F8) — et pourquoi l'erreur qu'on
   obtient en cas d'erreur d'une étape n'est **pas un bug**.
3. **Ajouter / modifier / supprimer** des joueurs sans redéploiement (F9).
4. La **saisie rapide de ~20 joueurs** (F10).
5. Le **pré-vol avant événement** (F20).
6. La **contingence / procédure de secours** ("break-glass", F22).
7. La **sauvegarde du roster de référence** (F24-backup).

Toutes les procédures ci-dessous ont été rédigées à partir du contenu exact de
`schema.sql` (racine du dépôt) — noms d'objets, comportement du trigger, texte
d'erreur — et sont donc **exactes vis-à-vis du schéma** (aucune identité, aucun
comportement de contrainte/trigger inventé). En revanche, le **déroulé
click-par-click dans Studio** (libellés exacts des boutons, formulation des
toasts d'erreur, temps de saisie réel) n'a **pas encore été validé par une
exécution humaine dans Studio** — cette validation interactive reste à faire
par l'organisateur (voir §9 Risk Areas du plan d'implémentation ; le
chronométrage F10 lui-même est explicitement différé au dry-run du Jour 6,
RFC-006, §4 ci-dessous). Les captures d'écran / formulations exactes de
l'interface Studio n'engagent que la version de Studio utilisée au moment de
la rédaction ; en cas de divergence, `schema.sql` reste la source de vérité.

---

## §0 — Premier démarrage : appliquer `schema.sql` (bootstrap, une seule fois)

Cette étape est le préalable à tous les workflows suivants. À faire **une fois
par environnement** (dev, puis à nouveau si un nouveau projet Supabase est créé
pour la prod).

1. **Créer un projet Supabase** : sur [supabase.com](https://supabase.com) →
   **New project**. Choisir une organisation, un nom de projet, une région, et
   un mot de passe de base de données.
   - ⚠️ Stocker ce mot de passe dans le gestionnaire de mots de passe de
     l'organisateur — **jamais dans le dépôt Git**.
2. **Appliquer le schéma** : dans **Studio → SQL Editor → New query**, coller
   l'intégralité du contenu de `schema.sql` (racine du dépôt), puis **Run**.
   - Le script est **idempotent** : le relancer ne produit aucune erreur ni
     doublon (un deuxième passage affiche des `NOTICE: ... already exists,
     skipping` — c'est normal).
3. **Vérifier que les objets existent** : dans **Table Editor**, les tables
   `tournaments` et `players` doivent apparaître, avec les données de départ :
   - 1 tournoi actif (`RFC-001 Test Tournament`, `is_active = true`) ;
   - 3 joueurs (`giovlacouture`, `zou`, `koloina`), dont `koloina` a
     `pokepaste_url = NULL` (cas volontaire du lien optionnel absent).
   - Optionnel : dérouler le **bloc de vérification commenté** en bas de
     `schema.sql` (section 6) pour re-tester soi-même les invariants F3/F4/F6.
4. **Récupérer les deux valeurs `.env`** (consommées à partir de RFC-003, voir
   `.env.example`) :
   - **Project Settings → API → Project URL** → variable `SUPABASE_URL`.
   - **Project Settings → API Keys → clé « secret »** (format `sb_secret_…` ;
     sur un projet non migré, l'ancien JWT `service_role`) → variable
     `SUPABASE_SERVICE_KEY`.
   - ⚠️ **Ne pas** utiliser la clé « publishable » (`sb_publishable_…`, ancien
     `anon`) : celle-ci respecte la RLS et ne lira plus rien une fois la RLS
     activée en deny-by-default (suivi RFC-003). La clé secrète **contourne la
     RLS** et est réservée au worker uniquement — ne jamais la committer ni
     l'exposer côté client (RULES §6, PRD §11.2).

**Résultat attendu :** deux tables, un trigger, deux index, et les données de
seed sont en place sur le nouveau projet ; `SUPABASE_URL` et
`SUPABASE_SERVICE_KEY` sont prêtes à être copiées dans `.env`.

---

## §1 — Créer et activer un tournoi (F7)

1. Dans **Table Editor → tournaments**, cliquer **Insert row**.
2. Renseigner `name` (ex. `Tournoi Aout 2026`). Laisser `is_active = false`
   pour l'instant — voir la note ci-dessous si un tournoi est déjà actif.
3. Si **aucun** tournoi n'est actif actuellement, éditer la ligne créée et
   passer `is_active` à `true`.
4. **Confirmer** : `/ots <nom d'un joueur connu>` dans le serveur Discord
   résout désormais contre ce tournoi.

> Si un tournoi est **déjà actif**, ne pas activer directement le nouveau —
> suivre le switch en deux temps ci-dessous (§2).

---

## §2 — Switch d'activation en deux temps (F8)

**Contexte :** `schema.sql` impose qu'**un seul** tournoi puisse avoir
`is_active = true` à la fois, via l'index `tournaments_one_active_idx`
(index unique partiel sur `is_active` où `is_active = true`). C'est une
décision verrouillée du PRD (§11.1) — voir aussi RULES §4.

**Procédure correcte (deux étapes, dans cet ordre) :**

1. **Étape 1 — désactiver l'ancien** : ouvrir le tournoi actuellement actif,
   passer `is_active` à `false`.
2. **Étape 2 — activer le nouveau** : ouvrir le nouveau tournoi, passer
   `is_active` à `true`.

**Erreur attendue si l'ordre n'est pas respecté** (tentative d'activer le
nouveau tournoi *avant* d'avoir désactivé l'ancien) — Studio affiche une
erreur de contrainte unique. Le corps d'erreur PostgREST typique contient ces
trois fragments (transcrits tels que Postgres les émet, verbatim, code
SQLSTATE `23505`) :

```
code: "23505"
message: duplicate key value violates unique constraint "tournaments_one_active_idx"
details: Key (is_active)=(true) already exists.
```

**⚠️ C'est le comportement attendu, pas un bug.** Cette contrainte protège
l'intégrité des données : elle garantit qu'il n'existe jamais deux tournois
actifs en même temps, ce qui rendrait la résolution `/ots` ambiguë. **Ne
jamais** tenter de "corriger" cette erreur en supprimant l'index
`tournaments_one_active_idx` — reprendre simplement la procédure en deux
temps ci-dessus (désactiver, puis activer).

---

## §3 — Ajouter / modifier / supprimer des joueurs sans redéploiement (F9)

Toutes les opérations ci-dessous se font dans **Table Editor → players**, et
prennent effet dès le **prochain** `/ots` — sans redéploiement du bot.

> ⚠️ Toujours vérifier que `tournament_id` correspond au tournoi **actif**
> avant d'ajouter ou de modifier une ligne, pour ne pas éditer par erreur le
> roster d'un ancien tournoi (voir §8 du RFC-002 — cas piège documenté).

### Ajouter un joueur
1. **Insert row** dans `players`.
2. Renseigner `tournament_id` = l'id du tournoi actif.
3. Coller `ingame_name` et `team_text` (l'export Showdown, tel quel — le
   contenu est **conservé sans validation**, RULES §4).
4. Optionnel : renseigner `pokepaste_url`. Laisser vide si aucun lien
   pokepast.es n'existe pour ce joueur — c'est un cas normal, pas une erreur.

### Modifier un joueur (Journey B — correction en cours de tournoi)
1. Ouvrir la ligne du joueur concerné, éditer `team_text` (par exemple après
   qu'un joueur ait corrigé son équipe).
2. Sauvegarder. Le **prochain** `/ots <nom du joueur>` renvoie immédiatement
   la version à jour — aucun redéploiement nécessaire.

### Supprimer un joueur
1. Sélectionner la ligne dans `players`, **Delete row**.
2. Le joueur n'est plus trouvable via `/ots` (réponse "introuvable").

### Note sur le trigger de nettoyage des noms (F4)
- Les noms collés avec des espaces parasites en début/fin (ex. `"  Zou  "`)
  sont automatiquement nettoyés au moment de l'écriture (trigger
  `players_trim_ingame_name`, fonction `trim_ingame_name()` — `btrim()` sur
  `ingame_name`). Le nom stocké est donc toujours propre, quel que soit le
  copier-coller d'origine.
- Un nom qui devient **vide après ce nettoyage** (ex. que des espaces) est
  **rejeté** avec l'erreur exacte :
  ```
  ingame_name must not be empty after trimming
  ```

### Note sur le nom déjà pris dans le tournoi (index `players_tournament_name_idx`)
- Ajouter un joueur avec un `ingame_name` déjà utilisé dans **le même tournoi**
  (comparaison insensible à la casse) déclenche une violation de contrainte
  unique — typiquement en réinscrivant un joueur déjà présent. Studio affiche
  un corps d'erreur PostgREST avec ces fragments (SQLSTATE `23505`) :
  ```
  code: "23505"
  message: duplicate key value violates unique constraint "players_tournament_name_idx"
  ```
- **⚠️ C'est le comportement attendu, pas un bug** (même logique que le switch
  d'activation en §2) : deux joueurs identiques dans un même tournoi
  rendraient la résolution `/ots` ambiguë. Ne pas contourner en désactivant
  l'index — soit **modifier** la ligne existante du joueur (§3 « Modifier un
  joueur ») plutôt que d'en insérer une nouvelle, soit vérifier l'orthographe
  du nom si la collision est inattendue.

---

## §4 — Saisie rapide de ~20 joueurs (F10)

**Recette recommandée**, en s'appuyant sur l'ordre des colonnes configuré
côté Studio (F5, `schema.sql` §1 — `ingame_name`, `team_text`,
`pokepaste_url` en premier, puis `tournament_id`, puis les colonnes système
`id` / `created_at` en dernier) :

1. Préparer la liste des ~20 joueurs dans l'app de notes de l'organisateur
   (nom + export Showdown + lien pokepast.es optionnel par joueur).
2. Dans **Table Editor → players**, saisir les lignes séquentiellement :
   pour chaque joueur, **Insert row**, renseigner `tournament_id` (tournoi
   actif), `ingame_name`, `team_text`, et `pokepaste_url` si disponible.
3. **Transform à documenter selon l'app de notes utilisée** : si l'app de
   notes permet un export tabulaire (colonnes séparées par tabulation), tester
   un collage multi-lignes dans la grille Studio (comportement de collage de
   type tableur) plutôt qu'une saisie ligne par ligne — cela peut réduire
   nettement le temps total. Si le format de l'app de notes ne se colle pas
   proprement (ex. l'export Showdown contient des retours à la ligne internes
   qui perturbent un collage multi-colonnes), rester en saisie ligne par
   ligne : ouvrir une ligne à la fois et coller chaque champ séparément.
4. **Temps observé** : à consigner ici lors du prochain passage réel de cette
   recette (ex. `20 joueurs — MM:SS — [date] — [organisateur]`).

> ⚠️ La **preuve chronométrée < 5 min** (F10, gate quantitatif de l'objectif
> G2) est réalisée et actée lors du **dry-run du Jour 6** (RFC-006). Cette
> section documente la recette ; elle ne remplace pas ce test minuté.

---

## §5 — Pré-vol avant événement (F20)

À dérouler **avant chaque événement**, dans l'ordre, sans exception. Ne pas
ouvrir l'événement (ne pas annoncer `/ots` disponible aux joueurs) tant que
les trois items ne sont pas cochés.

1. **Le projet Supabase est actif (non mis en pause).**
   - Ouvrir **Supabase Studio** sur le projet de production.
   - Le **free tier met en pause un projet après ~7 jours d'inactivité API**
     (aucune requête PostgREST reçue). Si le projet est pausé, Studio affiche
     un bandeau/écran d'état indiquant le projet en pause plutôt que le
     tableau de bord habituel.
   - **Scénario projet pausé (à traiter, pas à improviser) :** cliquer sur
     **Resume** (ou **Restore**, selon la version de Studio) et attendre que
     le projet redémarre complètement (le tableau de bord redevient
     accessible, les tables réapparaissent dans Table Editor) avant de passer
     à l'item suivant. Prévoir quelques minutes de marge avant l'heure de
     l'événement pour ce cas précisément — ne pas faire ce pré-vol à la
     dernière minute.
2. **Exactement un tournoi, le bon, a `is_active = true`.**
   - **Table Editor → tournaments** : vérifier qu'une seule ligne a
     `is_active = true`, et que c'est bien celle de l'événement du jour (pas
     un tournoi précédent oublié actif, ni aucun tournoi actif).
   - Si un changement est nécessaire, **ne pas activer directement** — suivre
     le **switch en deux temps** (§2 ci-dessus) : désactiver l'ancien, puis
     activer le nouveau.
3. **Un `/ots` de test renvoie un joueur connu.**
   - Dans le serveur Discord, lancer `/ots <joueur du roster réel ou du seed>`
     (ex. un joueur déjà saisi pour l'événement, ou `koloina` sur
     l'environnement de test — voir §0 pour le seed).
   - Confirmer un embed correct : titre `OTS de {username}`, contenu
     `team_text` lisible dans un bloc de code, lien cliquable si
     `pokepaste_url` est renseigné.
4. **Cocher les trois items ci-dessus** avant d'annoncer l'événement ouvert.
   Si un seul échoue, résoudre (résumer le projet, corriger le tournoi actif,
   ou investiguer le résultat du test `/ots`) avant de continuer — ne jamais
   ouvrir un événement sur un pré-vol partiellement passé.

### Note — keep-alive automatique (F21, non construit)

Un ping périodique automatique qui empêcherait le projet Supabase de se
mettre en pause a été envisagé (F21, priorité *Could*) mais **n'est pas
construit dans cette release** : le pré-vol ci-dessus (item 1, avec son étape
Resume) est jugé suffisant comme mitigation. Cette fonctionnalité reste
**off par défaut**. Si le pré-vol s'avère insuffisant en pratique (ex. pause
survenant en plein événement malgré un pré-vol récent), la solution à
privilégier reste un **planificateur externe** (tâche planifiée de la
plateforme d'hébergement, ou un pinger externe qui interroge une lecture
PostgREST triviale à une cadence tenant dans la fenêtre ~7 jours) —
**aucun changement de `bot.py` ni de dépendance** n'est nécessaire pour cette
approche. Un scheduler in-process nécessiterait une justification explicite
au regard du PRD avant d'être ajouté (RULES §1/§10) ; ne pas l'ajouter "juste
au cas où".

---

## §6 — Contingence / procédure de secours ("break-glass") (F22)

### (a) Dégradation gracieuse (déjà implémentée, RFC-003/005) — à vérifier, pas à construire

Le bot **échoue déjà proprement** en cas de panne Supabase (RFC-003/005,
RULES §7) : sur toute erreur réseau, timeout (~5s) ou statut non-200 côté
Supabase, l'utilisateur reçoit un message français amical et distinct
("⚠️ Service momentanément indisponible. Réessayez dans un instant.") — jamais
un crash ni une trace d'erreur brute. Côté opérateur, chaque échec est loggé
côté serveur (`print(...)` dans `fetch_active_player` / les helpers internes,
visible dans les logs du process).

**Ce que l'organisateur doit vérifier pendant l'événement (pas construire) :**
- Si un joueur signale que `/ots` répond "indisponible", vérifier le log
  opérateur en direct :
  ```bash
  journalctl -u discord-ots-bot -f
  ```
  (voir `knowledge/DEPLOYMENT.md` §10 — un message
  `fetch_active_player: request error: ...` ou
  `... query failed (status ...)` doit apparaître au moment de l'échec.)
- Confirmer qu'**aucun crash ni traceback Python** n'a atteint le joueur — le
  process reste en vie (`systemctl status discord-ots-bot` reste
  `active (running)`) et seule la réponse Discord change.
- Si les logs sont silencieux (aucune ligne au moment de l'incident), c'est
  un signe que le problème n'est **pas** côté Supabase (ex. token Discord
  invalide, process arrêté) — creuser du côté `systemctl status` /
  `journalctl` plutôt que côté Supabase.

### (b) Break-glass : redéployer le bot v1 (carte codée en dur) pour un seul événement

**À utiliser uniquement si** Supabase est en panne (pas seulement en pause —
voir §5 pour la pause, qui se résout par **Resume**, pas par ce break-glass)
**et** ne peut pas être rétabli à temps avant l'événement.

**Références git exactes (ne pas paraphraser, ne pas re-dériver) :**
- Le chemin v1 (`USERNAME_URLS` codé en dur + scraper `fetch_pokepaste`) a
  été **supprimé de l'arborescence de travail dans le commit `a79bdfb`**
  (RFC-005 : "RFC-005: /ots command refactor to live Supabase read &
  fail-soft").
- **Dernier commit où le chemin v1 complet existe encore : `184216b`**
  (RFC-004 : "RFC-004: Pure logic normalization and render-safety") — à ce
  commit, `USERNAME_URLS` est défini à `bot.py:72` et `fetch_pokepaste()` à
  `bot.py:129`.

**Étapes de récupération (documentées ici ; à exécuter uniquement en cas de
besoin réel, depuis la VM de production) :**
1. Sur la VM de production, créer une branche jetable pour ne pas perdre le
   `bot.py` v2 actuel :
   ```bash
   cd discord-ots-bot
   git checkout -b break-glass-temp
   ```
2. Restaurer uniquement `bot.py` à sa version v1 (commit `184216b`) :
   ```bash
   git checkout 184216b -- bot.py
   ```
3. **Éditer `USERNAME_URLS` à la main** (autour de la ligne 72 du fichier
   restauré) pour y saisir le roster de l'événement, à partir de la
   **sauvegarde du roster de référence** (§7 ci-dessous) — cette version v1
   n'a **aucune dépendance Supabase**, elle lit uniquement ce dictionnaire.
4. Commiter localement sur la branche jetable (pas de push nécessaire) :
   ```bash
   git add bot.py
   git commit -m "break-glass: v1 hardcoded roster for single event"
   ```
5. Redémarrer le service — un `deploy.sh` classique ferait un `git pull` qui
   écraserait ce changement local ; utiliser plutôt un simple redémarrage
   systemd (le fichier `bot.py` local sur la VM est déjà celui qu'on veut) :
   ```bash
   sudo systemctl restart discord-ots-bot
   sudo systemctl status discord-ots-bot   # confirmer "active (running)"
   ```
6. **C'est une mesure temporaire, pour un seul événement.** Une fois Supabase
   rétabli, revenir immédiatement au chemin v2 :
   ```bash
   git checkout main -- bot.py
   git branch -D break-glass-temp
   ./deploy.sh
   ```

⚠️ Ce chemin de secours **exige que le roster ait été ressaisi à la main**
dans `USERNAME_URLS` — d'où l'importance que la sauvegarde du roster (§7)
soit **à jour** au moment où ce break-glass est déclenché.

---

## §7 — Sauvegarde du roster de référence (F24-backup)

Le roster (joueurs + `team_text` + `pokepaste_url`) **vit uniquement dans
Supabase** — il n'existe aucune copie automatique. La sauvegarde de référence
repose sur deux sources, en pratique complémentaires :

1. **Les notes source de l'organisateur** — la liste dans l'app de notes
   utilisée pour la saisie rapide (§4 : nom + export Showdown + lien
   pokepast.es optionnel par joueur). C'est déjà la source qui alimente la
   saisie Studio ; il suffit de la conserver après la saisie plutôt que de la
   supprimer.
2. **Un export CSV depuis Studio** de la table `players` :
   **Table Editor → players → Export → CSV** (bouton d'export du menu de la
   table). Cet export capture l'état réel en base, y compris toute
   correction faite après la saisie initiale (Journey B, §3 « Modifier un
   joueur »).

**Quand rafraîchir cette sauvegarde :**
- **Une première fois** juste après avoir finalisé le roster (fin de la
  saisie rapide, §4).
- **Une seconde fois, obligatoirement, juste avant chaque événement** — pour
  capturer toute correction de dernière minute (nom corrigé, équipe mise à
  jour) faite entre la saisie initiale et le jour J.

Cette sauvegarde est ce qui alimente le dictionnaire `USERNAME_URLS` du
break-glass (§6b) si celui-ci doit être déclenché — une sauvegarde périmée
rend le break-glass inutile pour les joueurs ajoutés/modifiés après le
dernier export.

---

## Références

- `schema.sql` (racine du dépôt) — source de vérité pour les noms d'objets,
  le comportement du trigger, et les textes d'erreur cités ci-dessus.
- `.env.example` — noms exacts des variables (`SUPABASE_URL`,
  `SUPABASE_SERVICE_KEY`).
- `knowledge/PRD.md` — §5.2 (Backoffice Studio), §7 (Journey A & B), §8 (G2),
  §11.1 (décision verrouillée : application au niveau base de données).
- `knowledge/FEATURES.md` — F7, F8, F9, F10 (RFC-002) ; F20, F22, F24-backup
  (RFC-006).
- `.claude/RULES.md` — §2 (docs dans `knowledge/`), §4 (contrainte
  d'activation attendue, jamais "corrigée"), §5 (contrat comportemental),
  §7 (fail-soft à l'utilisateur, loud à l'opérateur), §10 (garder la
  documentation synchronisée).
- `knowledge/RFCs/RFC-001-Supabase-Schema.md` — schéma, contraintes, index,
  trigger.
- `knowledge/RFCs/RFC-006-Reliability-And-Release.md` — complète ce runbook
  avec le pré-vol, la contingence, et la sauvegarde du roster.
- `knowledge/DEPLOYMENT.md` — déploiement VM OCI (systemd, `deploy.sh`,
  `journalctl`) référencé par §6(a)/(b) ci-dessus.
- `knowledge/E2E-CHECKLIST.md` — grille de release-gate exécutée avant
  déploiement (RFC-006, RULES §8).
