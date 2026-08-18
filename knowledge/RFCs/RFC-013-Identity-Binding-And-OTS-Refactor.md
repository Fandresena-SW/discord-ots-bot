# RFC-013 — Identity Binding, `/ots` Refactor & Organizer Debug Lookup

- **Status:** 📝 Draft — not started
- **Implementation order:** 13 of 14 (v4.0) — depends on RFC-011 and RFC-012,
  and on all of v2.0/v3.0
- **Complexity:** High
- **Features covered:** F58, F59, F60 (command half), F61, F69 (command half),
  F71, F76, F77, F78
- **Grounding:** `knowledge/PRD.v4.final.md` §31.6, §31.7, §31.9, §37, §38;
  `knowledge/FEATURES.md` §Q, §R
- **Builds upon:** RFC-003 (config validation, the PostgREST seam), RFC-004
  (`normalize_name`, `render_team_text`), RFC-005 (embed, DM delivery,
  fail-soft), RFC-009 (`fetch_current_opponent` and its whole resolution
  chain), RFC-011 (`profiles`, `players.profile_id`, the auto-link trigger),
  RFC-012 (`tournament_results` rows for backfill to attribute)
- **Built upon by:** RFC-014 (`/profile` resolves the caller's profile;
  `/standings` renders bound profiles as mentions)

---

## 1. Summary

This RFC carries **the release's only breaking change and its entire security
goal**.

`/ots` loses its argument. The caller is inferred from a Discord account the
organizer bound once, and the command can only ever reveal *that caller's own*
opponent. This closes a real leak found during v3.0: because `/ots <name>`
returns *that person's opponent's* team sheet, any player could walk the roster
and scout the whole field before being paired.

Everything else here exists to make that possible or survivable:

- **`/link-organizer`** (F58) — the organizer binds a Discord account to an
  in-game name, once per human, ever.
- **Propagation** (F60) — backfill this season's history on bind; forward
  auto-link (RFC-011's trigger) is what makes binding one-time.
- **`/unlink`** (F69) — the player's own erasure path, which also revokes their
  `/ots`.
- **`/ots-organizer`** (F78) — typed-name lookup survives *only* here,
  organizer-gated, so the organizer can reproduce a complaint instead of taking
  the player's word for it.

> ⚠️ **The binding is an authorization boundary, not leaderboard bookkeeping.**
> A false binding buys silent, instant access to a team sheet the holder is not
> entitled to, and no after-the-fact correction can un-see it. That is why
> binding is organizer-established with **no self-service claim command**, and
> why F77 gates on *both* Discord permissions and an explicit id check.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F76** | `/ots` takes **no argument** and infers the caller from their bound profile. Two new fail-soft statuses (`not_linked`, `not_in_tournament`) bring the total to **nine**. The typed-name form is removed entirely — not hidden behind an optional argument. |
| **F78** | *(P1)* `/ots-organizer <ingame_name>` — organizer-only debug lookup resolving an arbitrary player's current opponent, ephemeral, never DM, not channel-restricted, bypassing the binding requirement, every invocation logged. |
| **F58** | `/link-organizer <ingame_name> <@user>` — organizer-only. The account arrives as a **native user mention**; no Discord id is ever typed. Creates the profile if needed, sets `profile_id` on the roster row. One-time per person, not per event. |
| **F59** | Five conflict rules, each with distinct French copy addressed to the organizer. |
| **F60** (cmd) | Backfill on bind across `players` and `tournament_results`, **bounded to the current season**; every propagation logged server-side. |
| **F61** | Rebinding is the same command plus an explicit confirmation — runnable from a phone in ten seconds, never a Studio procedure. |
| **F71** | Binding is **not** scoped to the active tournament: search the active roster first, then any roster in the current season. |
| **F69** (cmd) | `/unlink` — player-run erasure. Clears `profile_id` from their `players` rows, **anonymizes** (never deletes) their `tournament_results`, deletes the `profiles` row. Explicit French confirmation naming the `/ots` consequence. |
| **F77** | Organizer authorization for F58, F61 and F78: `default_member_permissions` **and** an explicit `interaction.user.id == ORGANIZER_DISCORD_ID` check, from a new env var validated at boot per F19. |

## 3. Technical approach

### 3.1 The architectural fact this RFC must state out loud

**`bot.py` gains its first write path.** Every version until now has been
read-only against Supabase; F58 and F69 require `POST`, `PATCH` and `DELETE`.

This is worth naming because PRD §31.4 justifies putting the freeze in
TypeScript partly on the grounds that "`bot.py` has no write path at all." After
this RFC, that is no longer literally true — but the locked decision stands and
should not be reopened. The distinction that survives is real:

| | The freeze (RFC-012) | Binding (this RFC) |
|---|---|---|
| Shape | bulk, whole-field, derived from a third-party API | one row, one column, organizer-initiated |
| Source of truth | Challonge | a human selecting an account |
| Runtime it belongs to | where `final_rank` arrives | where the Discord mention arrives |

**Requirement:** all writes go through **one small seam** —
`_supabase_write(session, method, path, params, json)` — mirroring RULES §2's
"data access is a thin, single seam" for reads. Not a repository pattern; one
function, the write-side twin of the existing `_fetch_*` helpers. Add this to
the RULES v4.0 addendum.

### 3.2 Refactor shape: extract the core, add two thin entry points

F78 makes this refactor cheaper than it looks. v3.0's `normalize_name`
resolution is **retained, not deleted** — it becomes the organizer command's
entry point — so the existing `test_bot.py` name-path coverage keeps its
meaning.

```
                       ┌─ /ots (F76) ──────────────┐
                       │  discord_user_id          │
                       ▼                           │
        fetch_opponent_for_profile(discord_user_id)│
                       │                           │
          profiles ──► players(profile_id) ──► ingame_name
                       │                           │
                       ▼                           ▼
              _resolve_opponent(session, tournament, normalized_name)
                       ▲          [ v3.0 chain, verbatim ]
                       │
        fetch_current_opponent(normalized_name)
                       ▲
                       └─ /ots-organizer (F78)
```

**Everything from `participant_candidate_ids()` downward is reused verbatim** —
the dual-id handling, `pick_opponent_id()`, the staleness warning, the embed,
DM delivery with ephemeral fallback, `render_team_text()` hardening. Do not
touch that code.

`fetch_current_opponent()` keeps its exact public shape and its seven statuses,
so `/ots-organizer` is a near-drop-in of v3.0's `/ots` handler.
`fetch_opponent_for_profile()` is new and returns the same tuple contract with
two additional statuses.

### 3.3 `/ots` (F76)

```python
@tree.command(name="ots",
              description="Découvrez l'OTS de votre adversaire actuel",
              guild=discord.Object(id=GUILD_ID))
async def ots(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True)
    status, player = await fetch_opponent_for_profile(str(interaction.user.id))
    ...
```

No parameter, no `@app_commands.describe`. **Discord itself must reject
`/ots zou`** — the command signature is the proof, not a runtime check (E2E
scenario 25: "the command accepts no argument at all — not 'rejects it'").

`fetch_opponent_for_profile(discord_user_id)` resolution order, inside one
bounded 5s session, never raising:

1. Active tournament + Challonge link → `no_active` / `no_challonge_link`.
   **The link check stays first**, unchanged from RULES §15.1.
2. `profiles?discord_user_id=eq.<id>&select=id&limit=1` → empty →
   **`not_linked`**.
3. `players?tournament_id=eq.X&profile_id=eq.<pid>&select=ingame_name&limit=1`
   → empty → **`not_in_tournament`**.
4. `_resolve_opponent(session, tournament, normalize_name(ingame_name))` — the
   v3.0 chain.

`discord_user_id` is compared as **text** (RFC-011 stores it as text; snowflakes
exceed 2^53). Always `str(interaction.user.id)`.

**The nine statuses, and their French copy.** v3.0's seven are unchanged except
`requester_not_found`, whose message must change: it can no longer echo a name
the player typed, because they typed nothing. In the `/ots` path it now means
"your roster name is missing from the Challonge bracket" — an organizer-side
name-discipline gap, and the message must say so.

| Status | New? | French copy |
|---|---|---|
| `no_active` | — | ⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard. |
| `no_challonge_link` | — | ❌ Ce tournoi n'est pas relié à Challonge. Impossible de déterminer votre adversaire actuel. |
| **`not_linked`** | **new** | ❌ Votre compte Discord n'est pas encore relié à un joueur. Contactez l'organisateur pour être enregistré. |
| **`not_in_tournament`** | **new** | ℹ️ Vous n'êtes pas inscrit au tournoi en cours. |
| `requester_not_found` | **reworded** | ⚠️ Votre nom de joueur est introuvable dans le bracket Challonge de ce tournoi. Contactez l'organisateur. |
| `no_current_match` | — | ℹ️ Vous n'avez pas de match en cours pour le moment. |
| `opponent_no_ots` | — | ⚠️ Votre adversaire a été trouvé, mais son OTS n'est pas encore enregistré. Contactez l'organisateur. |
| `unavailable` | — | ⚠️ Service momentanément indisponible. Réessayez dans un instant. |
| `ok` | — | ✅ Je vous ai envoyé le lien en message privé ! *(or the DMs-closed fallback)* |

Each of `not_linked` and `requester_not_found` also emits a server-side log line
(RULES §7: fail-soft, never fail-silent), because both point at an organizer
action and the organizer will be asked "why doesn't it work for me?"

### 3.4 `/ots-organizer` (F78)

```python
@tree.command(name="ots-organizer",
              description="[Organisateur] Voir l'adversaire actuel d'un joueur",
              guild=discord.Object(id=GUILD_ID))
@app_commands.default_permissions(manage_guild=True)
@app_commands.describe(name="Nom du joueur dans le tournoi")
async def ots_organizer(interaction: discord.Interaction, name: str):
```

- **A separate command, never an optional argument on `/ots`.** The reason is
  fail-direction: an optional parameter puts the typed-name path one faulty
  conditional away from every player, whereas a separate command guarded at
  registration **fails closed** — a broken auth check costs the organizer their
  debug tool and nothing else. A visible-but-unusable parameter on `/ots` would
  also undo the ergonomic win. **Do not "simplify" these into one command.**
- **Ephemeral reply, never DM, never public** — a diagnostic, not a delivery.
- **Not channel-restricted** — debugging happens wherever the problem is
  reported.
- **Bypasses the binding requirement by design** (E2E 31): it calls
  `fetch_current_opponent(normalize_name(nom))` directly, so it works on unbound
  players — which is its main use.
- **Every invocation logged** with caller id, queried name, and resolved status.
- Reports the resolved status verbatim rather than dressing it up: the organizer
  needs to see `requester_not_found` versus `no_current_match`, because those
  point at different fixes.

### 3.5 Organizer authorization (F77)

Belt and braces, justified because these commands grant team-sheet access:

```python
ORGANIZER_DISCORD_ID = os.getenv("ORGANIZER_DISCORD_ID")  # validated at boot

def is_organizer(interaction: discord.Interaction) -> bool:
    """Pure-ish, testable: compares as text — snowflakes exceed 2^53."""
    return str(interaction.user.id) == ORGANIZER_DISCORD_ID
```

1. `@app_commands.default_permissions(manage_guild=True)` — Discord **hides**
   the command from ordinary members (E2E 7, 29, 35).
2. An explicit `is_organizer(interaction)` check as the first statement of the
   handler body, before any I/O, refusing with a French message.

No Discord role model is introduced. **A single id is the whole authorization
model**, matching the "just me" persona (PRD §37).

`validate_config()` grows a fifth parameter: `ORGANIZER_DISCORD_ID` must be
present and must parse as an integer (stored and compared as text). PRD §38:
"a bot that starts with a wrong organizer id has silently locked its operator
out of the only commands that can unblock a player mid-event" — F19 catches
malformed, not valid-but-wrong, which is why pre-flight runs `/link-organizer`
once idempotently on an already-bound player.

`.env.example` gains `ORGANIZER_DISCORD_ID=` with a placeholder and a comment
noting it is **not a secret** (a Discord snowflake, safe in logs and docs) —
the first such var in the file, so say so.

> **Deploy note:** adding a required env var means the RFC-013 deploy fails
> fast unless it is set first. Call this out in the deploy step; do not make it
> optional to dodge the problem.

### 3.6 `/link-organizer` (F58, F59, F61, F71)

```python
@tree.command(name="link-organizer",
              description="[Organisateur] Relier un compte Discord à un joueur",
              guild=discord.Object(id=GUILD_ID))
@app_commands.default_permissions(manage_guild=True)
@app_commands.describe(
    name="Nom du joueur dans le tournoi",
    user="Compte Discord à relier (sélectionnez-le dans la liste)",
    confirm_rebind="Cochez pour remplacer une liaison existante vers un autre compte",
)
async def link_organizer(interaction, name: str, user: discord.User,
                         confirm_rebind: bool = False):
```

`user: discord.User` is what makes G14 true: Discord supplies the account
object through the native picker and **no id is ever typed** — the organizer
*selects*.

**Resolution order (F71).** Binding is not scoped to the active tournament, so
a player sitting out the current event — or being bound ahead of one they are
about to enter — can still be bound:

1. the **active** tournament's roster, by normalized name;
2. failing that, any roster in a tournament whose `season_id` is the
   **current season** (`current_season` view → tournaments in it → players by
   normalized name), most recent `event_date` first;
3. failing that → reject (F59a).

**Conflict rules (F59)** — evaluated against the resolved roster row and the
mentioned account, each with distinct French copy, all addressed to the
organizer:

| # | Condition | Outcome | French copy |
|---|---|---|---|
| a | Name found on no searched roster | reject | ❌ Aucun joueur nommé **{name}** dans le tournoi actif ni dans la saison en cours. |
| b | Name already bound to a **different** account, `confirm_rebind` false | reject | ⚠️ **{name}** est déjà relié à {mention}. Relancez la commande avec `confirm_rebind` pour remplacer cette liaison. |
| b′ | Same, `confirm_rebind` **true** | rebind + log | ✅ **{name}** est désormais relié à {mention} (liaison précédente remplacée). |
| c | Name already bound to **this same** account | **idempotent success** | ✅ **{name}** est déjà relié à {mention}. Rien à changer. |
| d | This account already bound to a **different** name in this tournament (F40) | reject | ❌ {mention} est déjà relié à **{other_name}** dans ce tournoi. |
| e | No active tournament / no current season / Supabase unavailable | fail-soft | ⚠️ Service momentanément indisponible. Réessayez dans un instant. *(distinct copy per cause)* |

Rule **c is a success, not an error** (E2E 3) — and it is load-bearing
operationally: PRD §38 makes an idempotent re-run of `/link-organizer` the
pre-flight probe that proves `ORGANIZER_DISCORD_ID` is right.

**The write sequence**, in order:

1. `GET profiles?discord_user_id=eq.<id>` → if absent,
   `POST profiles {discord_user_id, display_name}` with
   `Prefer: return=representation` to get the new `id` in one round trip.
   `display_name` is a **snapshot for Studio readability only** — never resolve
   identity through it (RFC-011 comments this at the column).
2. `PATCH players?id=eq.<row>` setting `profile_id`.
3. Backfill (§3.7).
4. Log, then reply.

### 3.7 Propagation — backfill on bind (F60, command half)

**Bounded to the current season**, so a binding recovers recent history without
a name collision costing years of it:

```
season      = GET current_season                     -> zero rows: skip backfill, still bind
tournaments = GET tournaments?season_id=eq.<sid>&select=id
players     PATCH ?tournament_id=in.(<ids>)&ingame_name=ilike.<escaped>&profile_id=is.null
                  {"profile_id": pid}
results     PATCH tournament_results?season_id=eq.<sid>
                  &ingame_name=ilike.<escaped>&profile_id=is.null
                  {"profile_id": pid}
```

Both PATCHes filter on `profile_id=is.null`, so backfill **never steals a row
already attributed to someone else**. Both use `Prefer: return=representation`
(or `count=exact`) so the row counts are known and can be logged.

Reuse `_escape_ilike()` verbatim for the name filter — a crafted `ingame_name`
must not widen an `ilike` into a wildcard match, and here that would move
*another player's* results and team-sheet access.

**Every propagation is logged server-side** — profile id, normalized name,
season id, row counts per table, tournament ids touched. This is not optional
polish: F60 is *the one operation in v4.0 that can silently move another
player's results and another player's team-sheet access*, and F61's rebind is
useless without a record of what moved.

```
link-organizer: profile 12 <- 'sen' (season 2): players +3 [t7,t8,t9],
                tournament_results +2 [t7,t8], rebind_from=profile 9
```

**Forward auto-link is not implemented here** — it is RFC-011's
`players_autolink_profile` trigger, because roster rows are created in Studio
where no bot code runs. This RFC only **verifies** it (E2E 9).

### 3.8 `/unlink` (F69, command half)

```python
@tree.command(name="unlink",
              description="Supprimer la liaison entre votre compte Discord et votre profil joueur",
              guild=discord.Object(id=GUILD_ID))
@app_commands.describe(
    confirm="Confirmez : cela désactivera aussi votre commande /ots"
)
async def unlink(interaction: discord.Interaction, confirm: bool):
```

- **Player-runnable, and it must stay that way** (F69): erasure of your own
  personal data cannot require asking someone else. **No organizer gate.**
- **`confirm` is a required boolean**, not a button view — this repo has no
  UI-component machinery and this RFC will not add any. `confirm=False`
  refuses with the warning text and changes nothing.
- The confirmation **must name the `/ots` consequence explicitly**, otherwise a
  curious player disables themselves mid-event and blames the bot:

  > ⚠️ **Attention :** supprimer votre liaison désactivera aussi la commande
  > `/ots` — vous ne pourrez plus voir l'OTS de votre adversaire tant que
  > l'organisateur ne vous aura pas relié à nouveau. Relancez la commande avec
  > `confirm` si c'est bien ce que vous voulez.

**Write sequence** (order matters; RFC-011's `on delete set null` makes it safe
either way, but doing it explicitly is what produces the log):

1. `GET profiles?discord_user_id=eq.<id>` → absent → French "rien à supprimer",
   not an error.
2. `PATCH players?profile_id=eq.<pid>` → `{"profile_id": null}` — **all**
   tournaments, not just the current season. Erasure is unbounded; backfill is
   bounded. These are different operations with different reasons.
3. `PATCH tournament_results?profile_id=eq.<pid>` → `{"profile_id": null}`.
   **Anonymized, never deleted** — deletion is blocked by F48 anyway and would
   corrupt other players' historical context. The `ingame_name` snapshot is
   retained, so the row keeps counting on the leaderboard under that name
   (E2E 33).
4. `DELETE profiles?id=eq.<pid>`.
5. Log the counts; confirm in French, restating that `/ots` now needs the
   organizer.

**Retention posture** (G17, to be restated in RUNBOOK §9 by RFC-014):
`discord_user_id` is held as long as the profile exists and is erasable by the
player at any time. In-game names in frozen results are **tournament records**,
retained indefinitely.

### 3.9 Command registration (§31.9)

After this RFC `on_ready` syncs **four** commands — `/ots`, `/ots-organizer`,
`/link-organizer`, `/unlink` — with RFC-014's two making the final six. Two of the
final six must be invisible to non-organizers. Guild-scoped sync means changes
appear immediately, including the **removal of `/ots`'s parameter**.

## 4. Data models / schema changes

**None.** RFC-011 owns all v4.0 DDL, including the auto-link trigger this RFC's
F60 half depends on. If this RFC needs a column, that is a signal RFC-011 was
under-specified — raise it rather than appending DDL here.

## 5. Interfaces exposed

- **Player-facing:** `/ots` (no argument), `/unlink <confirm>`.
- **Organizer-facing:** `/link-organizer <name> <user> [confirm_rebind]`,
  `/ots-organizer <name>`.
- **Python, to RFC-014:** `is_organizer(interaction)`;
  `_supabase_write(...)`; a `fetch_profile_id(session, discord_user_id)` helper
  (`/profile` needs the same profile resolution); and the existing
  `_headers()`/timeout conventions.
- **Unchanged and reused verbatim:** `normalize_name`, `_escape_ilike`,
  `render_team_text`, `fetch_active_player`, `participant_candidate_ids`,
  `pick_opponent_id`, `is_cache_stale`, `_warn_if_stale`.
- **Config:** `ORGANIZER_DISCORD_ID`, validated at boot.

## 6. Acceptance criteria

- [ ] **F76 (the security goal):** `/ots` declares **no parameter**; Discord
      rejects `/ots zou` at the client, and no code path in `bot.py` accepts a
      caller-supplied name for the `/ots` command. A `grep` proves the typed-name
      form is absent from `/ots`.
- [ ] **F76:** a bound player with an open match receives their opponent's OTS
      by DM — v3.0's happy path through the new entry point, with an unchanged
      embed (title `OTS de {opponent}`, color `0x3B4CCA`, URL only when present)
      and an unchanged DMs-closed ephemeral fallback.
- [ ] **F76:** `not_linked` and `not_in_tournament` each produce their own
      distinct French message; **all nine** statuses are reachable, each has its
      own message, and none raises.
- [ ] **F76:** `fetch_current_opponent()` keeps its signature and its seven
      statuses; everything from `participant_candidate_ids()` down is
      byte-for-byte unchanged.
- [ ] **F58:** `/link-organizer` with a valid name and a mentioned user creates
      the profile if needed, sets `profile_id`, and confirms in French.
- [ ] **F58/G14:** the Discord account arrives as a native mention — no command
      accepts a typed Discord id anywhere in this RFC.
- [ ] **F59:** all five conflict branches produce their distinct French copy;
      the same-account repeat is an **idempotent success**, not an error.
- [ ] **F61:** a name bound to another account is refused without
      `confirm_rebind` and rebound with it; the rebind is logged with both
      the old and new profile.
- [ ] **F71:** a player absent from the active event but present on an earlier
      roster **in the current season** binds successfully.
- [ ] **F60:** binding attributes that player's prior in-season
      `tournament_results`; rows already carrying another `profile_id` are
      untouched; the propagation log names the profile, normalized name, season,
      per-table row counts and tournament ids.
- [ ] **F60 (forward, RFC-011's trigger — verified here):** after binding, a
      roster row created for the same name in a **new** tournament auto-links,
      and `/ots` works for them without rebinding.
- [ ] **F69:** `/unlink` with `confirm=False` changes nothing and warns that
      `/ots` would stop working; with `confirm=True` it clears `players`,
      anonymizes `tournament_results` (rows survive and still count), deletes
      the profile, and `/ots` then returns `not_linked`. `/link-organizer`
      restores access in one command.
- [ ] **F77:** both organizer commands are hidden from ordinary members **and**
      refuse a non-organizer who reaches them; the bot refuses to start when
      `ORGANIZER_DISCORD_ID` is missing or non-numeric.
- [ ] **F78:** `/ots-organizer` returns an arbitrary player's current
      opponent ephemerally, **works on unbound players**, is refused for and
      hidden from non-organizers, and logs caller + queried name + status.
- [ ] **Regression:** `python -m unittest test_bot` is green, including every
      pre-existing v2.0/v3.0 test.
- [ ] **Docs:** `E2E-CHECKLIST-v3.md`'s scenarios keyed to a typed `/ots`
      argument are **struck** (see §7.1).

## 7. Implementation details

### 7.1 Inherited documentation obligation

**Strike the superseded scenarios in `knowledge/E2E-CHECKLIST-v3.md`** as part
of this RFC, not RFC-014. The moment `/ots` loses its argument, those scenarios
become impossible to execute; leaving them "silently failing" is exactly the
doc/code drift `CLAUDE.md` warns about, and RFC-014's scenario 1 re-runs that
checklist *minus* them. Strike them in place with a one-line note pointing at
F76 — do not delete the rows, so the supersession is legible.

### 7.2 File structure

`bot.py` only (plus `test_bot.py`, `.env.example`). The single-file ethos holds:
this RFC adds roughly four command handlers and a write seam, not a module
layout. Suggested order in the file, matching the existing top-down flow:

```
config + validate_config (extended)          ~ existing block
is_organizer()                                new, pure-ish
_supabase_write()                             new, the write seam
resolve_binding_conflict()                    new, PURE — the F59 decision table
fetch_profile_id()                            new
fetch_opponent_for_profile()                  new  (F76 entry point)
fetch_current_opponent()                      existing, unchanged  (F78 entry point)
_resolve_opponent()                           extracted from the above
bind/backfill/unlink helpers                  new
@tree.command handlers                        /ots (rewritten), /ots-organizer,
                                              /link-organizer, /unlink
```

### 7.3 Keep the decision logic pure and tested

The repo's discipline (RULES §8/§18, RFC-004 precedent) is that decisions are
pure functions and network paths stay thin around them. The natural extraction
here is **F59's conflict table**:

```python
def resolve_binding_conflict(roster_row: dict | None,
                             existing_profile_id: int | None,
                             target_profile_id: int | None,
                             account_slot_taken_by: str | None,
                             confirm_rebind: bool) -> str:
    """Pure: returns one of 'not_found', 'rebind_needs_confirm', 'rebind',
    'already_bound_same', 'account_slot_taken', 'bind'. No I/O."""
```

Every F59 branch then gets a unit test with no network, and the handler becomes
a dispatch over the returned string — the same shape as `/ots`'s status
dispatch. `is_organizer()` is likewise trivially testable with a stub
interaction.

### 7.4 Error handling

- **Never let any of the four commands raise** (RULES §7/§17, extended). New
  failure modes get **new named statuses**, not exceptions.
- **Defer immediately, before any I/O**, on all four (F18 is not `/ots`-specific
  — PRD §32 says so explicitly). `/ots` and `/unlink` defer ephemeral;
  `/ots-organizer` and `/link-organizer` defer ephemeral too (both are
  organizer diagnostics/administration, not announcements).
- **Bounded 5s timeout** on every session, matching the existing helpers.
- **Fail-soft to the player, loud to the operator.** Every new failure path logs
  server-side with enough detail to diagnose. Never log a `team_text`, never log
  a token or service key. Discord ids **may** be logged — they are not secrets
  (PRD §31.9) — and must be, for F60's propagation record.

## 8. Edge cases & risks

- **An unbound player cannot use `/ots` at all.** That is the point, but it
  moves the failure to **round 1 of a live event**, which is why G16 (100 % of
  roster rows bound before round 1) and pre-flight are load-bearing rather than
  advisory. `/link-organizer` must be genuinely runnable from a phone in ten
  seconds — resist any design that needs Studio.
- **No operational fallback exists if the refactor proves unworkable mid-event.**
  Pairings can be announced by hand; team sheets cannot. Break-glass is
  redeploying the previous `bot.py` from git — which **restores `/ots <name>`
  and the scouting leak with it.** Accept that trade knowingly rather than
  discovering it under pressure (PRD §38).
- **The `/ots` change must be announced.** It is a release requirement (PRD
  §36), it is the one item no RFC will remind anyone about, and some players
  were actively using the old lookup.
- **Backfill can move another person's history.** Two people who used the same
  in-game name in the same season is the failure case. Bounded to the current
  season, filtered on `profile_id is null`, and fully logged — those three
  together are the mitigation. Do not widen the season bound "for
  convenience."
- **`_escape_ilike` is now security-relevant, not just correctness-relevant.**
  In v2.0 a crafted name could widen a *read*. Here it can widen a **write**
  that grants team-sheet access. Reuse the existing function; do not hand-roll
  a filter string anywhere in this RFC.
- **`ORGANIZER_DISCORD_ID` wrong in production** loses both organizer surfaces
  at once, since they share one gate. F19 catches malformed, not
  valid-but-wrong. Pre-flight's idempotent `/link-organizer` probe is the
  answer.
- **`discord.User` vs `discord.Member`.** Use `discord.User` so the picker also
  resolves an account that is not currently a guild member; do not depend on
  member-only attributes.
- **Snowflake precision.** Compare and store ids as **text** everywhere. An
  `int()` round-trip through JSON in any future tooling loses precision above
  2^53.
- **Two `open` matches for one participant** — unchanged v3.0 defensive
  behavior (highest `round` wins). Do not revisit.
- **A frozen tournament may still be active** (F46), in which case `/ots`
  returns `no_current_match`. That is v3.0's existing, correct answer — do not
  add a "tournament is over" status.
- **`/unlink` during an event** is self-inflicted denial of service. The
  confirmation copy is the only mitigation and must not be softened.

## 9. Applicable rules (RULES.md)

- **§1 (dependency policy):** zero new Python dependencies. `discord.User`,
  `app_commands.default_permissions` and `aiohttp` verbs are all already
  available.
- **§2 (architecture):** stays in `bot.py`. **Amendment:** the read seam gains a
  write twin (§3.1) — one function, not a layer. Record it in the RULES v4.0
  addendum.
- **§3 (naming/French):** every user-facing string is French, matching the
  existing ✅/⚠️/❌ tone. Internal identifiers, logs and column names stay
  English.
- **§4 (DB contract):** trim+lower normalization is reused via
  `normalize_name`, never reimplemented — now on a third axis (binding), where
  it also governs authorization.
- **§5 (the `/ots` path):** steps 4–6 (embed, render-safety, DM delivery with
  ephemeral fallback) are preserved verbatim. Only the entry point changes.
- **§6 (security):** `ORGANIZER_DISCORD_ID` is a new env var but **not a
  secret** — first of its kind in `.env`; say so in `.env.example`. No secret is
  added, logged, or committed.
- **§7/§17 (fail-soft, expanded):** seven statuses become nine, and three new
  commands join the never-raise rule.
- **§15 (v3.0 opponent-resolution contract):** **amended by this RFC.** §15.1's
  no-link-first ordering and §15.2–5's resolution chain survive unchanged; only
  §15.2's "normalize the caller's own input" becomes "resolve the caller's
  bound profile" for `/ots`, with the typed-name form retained under F78.
  Update §15 rather than leaving it describing a command that no longer exists.
- **§20 (the `/ots` behavior change is confirmed and intentional):** still true,
  now for the second time and in the opposite direction — v3.0 changed what the
  argument *meant*; v4.0 removes it. If asked to "also support looking up any
  name" on `/ots`, that is a scope change back toward the leak (PRD §37).
- **§9 / F25(b):** cross-tournament identities, a v2.0 Won't-have, are
  deliberately reopened here with PRD authority.

## 10. Testing strategy

### 10.1 Unit tests (`test_bot.py`, stdlib `unittest`)

The 30 existing tests must stay green — including the name-path tests, which
keep their meaning because F78 retains that resolution path.

New, all pure and network-free:

- `resolve_binding_conflict` — one test per F59 branch, plus
  `confirm_rebind` both ways;
- `is_organizer` — match, mismatch, and an id above 2^53 compared as text;
- `validate_config` — missing `ORGANIZER_DISCORD_ID`, non-numeric value, valid
  value; and confirm the existing four-var failures still behave;
- the `/ots` status-dispatch mapping — a table test asserting all **nine**
  statuses produce a distinct, non-empty French message and that no status is
  unhandled (guard against a future tenth status silently falling through to
  the embed path).

### 10.2 Manual / in-guild verification

Network-dependent branches are verified in-guild against RFC-011's seed
fixtures and a real Discord account, mirroring RFC-005/RFC-009's posture. These
map onto E2E scenarios 2–9 and 24–32:

- bind, re-bind same, re-bind different (both with and without confirmation),
  unknown name, out-of-active-but-in-season name;
- bind then check history attribution; bind then create a new tournament's
  roster row in Studio and confirm the trigger auto-links;
- `/ots` happy path, `not_linked`, `not_in_tournament`, DMs closed;
- `/ots-organizer` as organizer, as non-organizer, on an unbound player;
- `/unlink` unconfirmed, confirmed, then `/ots`, then organizer restore;
- boot with `ORGANIZER_DISCORD_ID` missing and malformed;
- confirm the command list a non-organizer sees contains neither organizer
  command.

### 10.3 The one test that proves the release's security goal

**E2E scenarios 25 and 29 together.** PRD §34: "a suite passing with either
failing means the release's security goal was not met." Scenario 25 is not
"`/ots zou` is rejected" — it is "**the command accepts no argument at all**",
verified in the Discord client. Scenario 29 is "`/ots-organizer` is refused
for *and absent from the command list of* a non-organizer."

---

## Completion record

**Round 1 — 2026-08-17. Status: code + unit tests complete; in-guild
verification NOT yet performed (no live Discord/Supabase access available this
round). Do not read this round as release-ready.**

### Deliverables shipped this round

- `bot.py`: `validate_config` extended to five params (`ORGANIZER_DISCORD_ID`,
  parsed as int, stored as text); `OTS_STATUS_MESSAGES`; pure functions
  `is_organizer`, `resolve_binding_conflict`, `pick_season_roster_row`; the
  write seam `_service_session` + `_supabase_write`; `fetch_profile_id`; the
  roster/profile read helpers (`_fetch_roster_row_for_profile`,
  `_fetch_roster_row_by_name`, `_fetch_current_season_id`,
  `_fetch_season_tournament_ids`, `_fetch_roster_rows_in_tournaments`,
  `_fetch_profile_slot_in_tournament`, `_fetch_profile_discord_id`);
  `_resolve_opponent` (extracted verbatim from the old `fetch_current_opponent`
  body — a pure code move, byte-identical logic); `fetch_current_opponent`
  rewritten as a thin wrapper over it (signature and seven statuses
  unchanged); `fetch_opponent_for_profile` (F76's new entry point, nine
  statuses); `run_binding` (F58/F59/F60/F61/F71) and `run_unlink` (F69); the
  four command handlers — `/ots` (argument removed), `/ots-organizer` (F78),
  `/link-organizer` (F58/F59/F61), `/unlink` (F69).
- `test_bot.py`: `ORGANIZER_DISCORD_ID` added to the import-safety fixture
  (deliberately above 2^53); five new test classes (`ValidateConfigTests`,
  `IsOrganizerTests`, `ResolveBindingConflictTests`, `PickSeasonRosterRowTests`,
  `OtsStatusMessagesTests`), 31 new tests. **61/61 green**, including all 30
  pre-existing tests unchanged.
- `.env.example`: `ORGANIZER_DISCORD_ID` added with the required non-secret
  callout.
- `.claude/RULES.md`: new §26 ("Write path, authorization and the amended
  `/ots` entry point"), plus one-line pointers at §2's data-access bullet and
  §15's heading.
- `knowledge/E2E-CHECKLIST-v3.md`: rows 1 and 4 struck (`~~…~~`) with an
  explicit supersession note pointing at F76/RFC-014; a reading-convention
  line added for rows 2/3/5/6/7/8/9; the test-count line updated to 61.
- `CLAUDE.md`: minimal correction only (per this RFC's own scope) — "What this
  is" + the OWN-name warning block, the `/ots` bullets under "Key mechanics",
  the Config section (five vars), and one Locked-decisions line for the write
  seam. Version banner and the four release-status trackers left untouched
  for RFC-014, as scoped.
- `knowledge/RFCs/RFCS.md`: RFC-013's row updated from `📝 Draft` to a Round-1
  in-progress marker (not `✅ Complete` — that would misstate the unverified
  state).
- No `schema.sql` / migration changes (none needed — confirmed against
  RFC-011's DDL, see below). No `supabase/functions/` changes.

### Verification actually performed this round

- `python -m unittest test_bot -v`: **61/61 PASS** (30 pre-existing + 31 new),
  run against a throwaway venv with `requirements.txt` installed (this
  environment has no pre-existing project venv).
- `python -c "import bot"` with all five env vars set: **import-safe**, no
  side effects at import time.
- `grep -n "username" bot.py`: **zero matches** — confirms the `/ots` command
  signature carries no name parameter anywhere.
- `grep -rn "TODO\|FIXME\|XXX" bot.py schema.sql supabase/functions/`: **zero
  matches**.
- `python -m py_compile bot.py`: **clean**.
- Manually re-read the full diff against `bot.py`'s existing conventions
  (log prefixes, French copy tone, `_escape_ilike` on every new filter,
  fail-soft dispatch) and against RFC-011's migration for the exact
  `profiles`/`players`/`current_season`/`tournament_results` shapes this RFC
  reads and writes — no missing column or grant found; RFC-011's explicit
  `service_role` grants already cover every table/view this RFC touches, so
  **no new migration was added**, matching the RFC's own scope limit.

### NOT performed this round (tracked as open, per RULES §10 — no fabricated PASS)

**This is the largest gap in this round.** Every network-dependent branch is
implemented but unverified end-to-end, listed exactly per RFC §10.2/§10.3 and
the plan's §7.3 in-guild checklist:

- `/link-organizer`: bind; idempotent re-bind (`already_bound_same`, zero
  writes); rebind without/with `confirm_rebind`; unknown name; F71's
  out-of-active-but-in-season name; `account_slot_taken`; a non-organizer
  attempt; the propagation log's exact line shape against real data.
- F60 forward auto-link verification (RFC-011's trigger) after a bind.
- `/ots`: happy path (DM), `not_linked`, `not_in_tournament`,
  `requester_not_found`, `no_current_match`, `opponent_no_ots`, DMs-closed
  fallback.
- `/ots-organizer`: as organizer, as non-organizer, on an unbound player;
  the command-list visibility check.
- `/unlink`: unconfirmed → confirmed → `/ots` returns `not_linked` →
  organizer restores in one command.
- Boot with `ORGANIZER_DISCORD_ID` missing/malformed (unit-tested in
  isolation via `validate_config`, but not exercised via an actual process
  boot/exit this round).
- **The release's two security-gate scenarios, E2E 25 and 29, are
  `PENDING`.** E2E 25 (`/ots` accepts no argument at all, verified in a
  resynced Discord client) and E2E 29 (`/ots-organizer` refused for *and*
  absent from the command list of a non-organizer) are exactly PRD §34's "a
  suite passing with either failing means the release's security goal was
  not met" pair — **do not treat this round as meeting that goal** until both
  are run live and recorded here.
- `deno test` was not re-run (no Edge Function file touched this round;
  `mapping_test.ts`/`points_test.ts` are unaffected by this RFC's scope, per
  the RFC's own §6 "N/A — zero Challonge traffic added").

### Deviations from the plan (all within RULES/RFC bounds)

1. **`/link-organizer`'s French-reply dispatch is an `if/elif` chain, not a
   `.get(status, …)` dict**, unlike `/ots`'s `OTS_STATUS_MESSAGES` table. The
   plan's §5.3 suggested mirroring `/ots`'s dict dispatch; the reply strings
   here need per-call interpolation (`details['name']`, `user.mention`,
   `details['other_name']`, …) that a flat string-keyed dict can't hold
   without an extra layer of indirection (lambdas/format templates) — which
   would be more structure, not less, for a six-branch chain that already
   ends in a catch-all `else`. Functionally equivalent (every status handled,
   nothing falls through); flagged here rather than done silently, and easy
   to revisit if a reviewer prefers the literal table shape.
2. **The propagation log tracks `players`- and `tournament_results`-touched
   tournament ids as two separate lists**, not the single shared
   `tournament_ids` the plan's `details` dict sketch implies. The RFC's own
   §3.7 example log line shows *different* id lists for the two tables
   (`players +3 [t7,t8,t9]` vs `tournament_results +2 [t7,t8]`), which a
   single shared list cannot reproduce faithfully — the implementation
   follows the RFC's example over the plan's dict shorthand. `details` still
   exposes a merged `tournament_ids` (union of both) for any future caller
   that only wants "what changed," alongside the per-table counts.
3. **`CLAUDE.md`'s pre-existing v4.0 warning block used the French command
   spelling `/ots-organisateur`.** Corrected to the actual shipped identifier,
   `/ots-organizer` (English, per RULES §3: internal identifiers/commands are
   English) — the RFC and plan both specify `ots-organizer` throughout.

### Tracked follow-ups (not this RFC's scope — noted, not implemented)

- `/standings`, `/profile`, `RANKING_CHANNEL_ID`, `RUNBOOK.md` §9,
  `E2E-CHECKLIST-v4.md`, and `DEPLOYMENT.md`'s env-var section all remain
  RFC-014's, untouched here, per the implementation prompt's Scope
  Limitation.
- The `/ots` behavior change still needs to be **announced** to players
  (PRD §36) — a release requirement no RFC will remind anyone about on its
  own; carried forward as an open item for whoever runs the release.
- Break-glass (redeploying the previous `bot.py`) still restores the v3.0
  scouting leak — accepted knowingly per PRD §38, restated here so it is not
  rediscovered under pressure.

### Next round

Round 2 must run the full §7.3/§10.2 in-guild checklist above (including E2E
25 and 29) against a live Discord server and Supabase project seeded per
RFC-011, record real outcomes (no fabricated `PASS`), and only then flip
`RFCS.md`'s row to `✅ Complete`.
