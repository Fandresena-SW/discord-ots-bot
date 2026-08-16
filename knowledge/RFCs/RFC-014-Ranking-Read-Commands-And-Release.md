# RFC-014 — Ranking Read Commands, Runbook §9 & Release

- **Status:** 📝 Draft — not started
- **Implementation order:** 14 of 14 (v4.0) — the closing RFC; depends on
  RFC-011, RFC-012 and RFC-013, and on all of v2.0/v3.0
- **Complexity:** Medium
- **Features covered:** F62, F63, F64, F65, F70 (render contract), F73, F75
- **Grounding:** `knowledge/PRD.v4.final.md` §31.8, §31.9, §32, §34, §41;
  `knowledge/FEATURES.md` §S, §T, §U
- **Builds upon:** RFC-004 (`render_team_text`'s char-budget discipline —
  F70 is its second occurrence), RFC-011 (`season_standings`, `current_season`),
  RFC-012 (the rows both commands read), RFC-013 (`is_organizer`, profile
  resolution, the `.env` pattern for a non-secret var)
- **Built upon by:** — (release)

This RFC mirrors RFC-006's and RFC-010's role exactly: the last two features
plus the documentation, the release gate, and the sign-off.

---

## 1. Summary

Ship the two French read commands that make the ranking visible — a public
season leaderboard and an ephemeral personal history — restricted to one
configured channel, then close the release: runbook §9, `E2E-CHECKLIST-v4.md`,
the deployment notes for two new env vars, and the four status-tracker updates
`CLAUDE.md` requires.

The one genuinely hard thing here is **F70's render contract**. The leaderboard
is only the second place in this project that emits variable-length text into a
Discord embed, and an oversized description is **rejected by Discord outright**
— which presents to a player as the command silently failing. That makes the
4096-character cap a correctness requirement, not presentation polish, and puts
F70 in the same category as F14 rather than in the "formatting" category it
looks like.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F62** | `/standings` — season leaderboard: profiles *and* unbound players ranked by summed `awarded_points` in the current season. |
| **F70** | The render contract: ordering and tie-break, shared rank numbers on equal points, unbound players shown by name with no mention, no participation floor, top 25, a French total-count footer, and a hard 4096-char cap. |
| **F63** | `/profile` — per-player history: one row per tournament entered this season (event name, date, placement, points). **Self-only in v4.0**, no target-user argument. Replies **ephemerally**. |
| **F64** | *(P1)* Per-tournament standings — same table, different filter. |
| **F75** | Both ranking commands work **only** in the channel named by `RANKING_CHANNEL_ID`; elsewhere they refuse with their own French message. `/standings` replies publicly within it. **`/ots` is unaffected and must stay unaffected.** |
| **F65** | *(P1)* Every ranking command fails soft in French on the same outcomes the rest of the bot handles, and **never raises** — new failure modes get new named statuses, not exceptions. |
| **F73** | `E2E-CHECKLIST-v4.md` — the primary release gate, 36 scenarios, French, must pass in full before deploy. |

## 3. Technical approach

### 3.1 `/standings` (F62, F70)

```python
@tree.command(name="classement",
              description="Classement de la saison en cours",
              guild=discord.Object(id=GUILD_ID))
@app_commands.describe(tournament="Facultatif : classement d'un tournoi précis de la saison")
async def standings(interaction: discord.Interaction, tournament: str | None = None):
    await interaction.response.defer()          # PUBLIC in the ranking channel
    if not in_ranking_channel(interaction): ...  # F75, refuse ephemerally
```

Reads RFC-011's `season_standings` view in **one indexed query**:

```
GET /rest/v1/season_standings
    ?season_id=eq.<current>
    &order=total_points.desc,events_played.desc,best_rank.asc,standing_key.asc
    &limit=26        # 25 + 1, to know whether to show the truncation footer
    &select=standing_key,profile_id,ingame_name,total_points,events_played,best_rank
```

plus a `count=exact` header (or a second `select=standing_key&limit=1` HEAD) to
get the **total ranked count** the footer needs when truncated.

**The ordering, and why it is counter-intuitive (F70).**
`sum(awarded_points)` desc → **most events played** desc → best single
`final_rank` asc → `standing_key` asc (stability only, never player-visible).
**Turnout breaks ties before peak performance**, so a player who attended more
and won nothing can outrank an event winner on equal points. That is
intentional, and RUNBOOK §9 states it plainly so the organizer can answer for it
when asked.

**Rank numbers are decided by points alone.** Equal points always display the
**same rank number**; the sort keys decide row order only. Competition-style, so
two players tied at rank 2 are followed by rank 4.

**Unbound players are shown and ranked**, by in-game name with **no Discord
mention** — the leaderboard is correct from day one, and nothing is published
that the Challonge bracket does not already show. Bound profiles render as a
mention (`<@{discord_user_id}>`), which means the render needs the
`discord_user_id`, not just the `profile_id`: resolve it with one extra
`profiles?id=in.(…)&select=id,discord_user_id` read, or embed `profiles` on the
view. **No participation floor** — one event is enough to appear.

### 3.2 The render, pure and tested (F70)

The same discipline as `render_team_text`, and for the same reason:

```python
DISCORD_DESC_LIMIT = 4096          # existing constant, reused
STANDINGS_LIMIT = 25

def render_standings(rows: list[dict], total_count: int) -> str:
    """Pure (no I/O): rows already ordered per F70 -> an embed description
    that is NEVER longer than DISCORD_DESC_LIMIT. Assigns shared rank numbers
    on equal total_points, renders bound entries as mentions and unbound ones
    as plain names, and appends the French footer when truncated."""
```

**The character budget has three claimants, all counted against 4096:**
the rows, the truncation footer, and the "unbound players → see the organizer"
line. The PRD is explicit that the footer "carries two things, both counting
against the budget."

Budget algorithm — drop rows, never truncate mid-row:

```
footer = build_footer(shown, total_count)      # French, both messages
budget = DISCORD_DESC_LIMIT - len(footer)
emit rows in order while the running length stays within budget
if any row was dropped for budget (not just for the top-25 cap),
    the footer already states the total, so the reader knows
```

A single row can never itself exceed the budget in practice (a name plus a
number), but the function must still be total: if even one row does not fit,
return the footer alone rather than an oversized description.

**Format** — plain text in the description, not a table; Discord's proportional
font makes column alignment unreliable and every alignment character is budget:

```
**1.** <@123456789012345678> — 480 pts · 3 événements
**2.** zou — 300 pts · 2 événements
**2.** koloina — 300 pts · 2 événements
**4.** giovlacouture — 150 pts · 1 événement
```

Embed title `Classement — {season name}`, color `0x3B4CCA` (reuse the existing
constant; do not introduce a second brand color).

### 3.3 `/profile` (F63)

```python
@tree.command(name="profil",
              description="Votre historique de la saison en cours",
              guild=discord.Object(id=GUILD_ID))
async def profile(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True)   # EPHEMERAL, unlike /standings
```

**Self-only in v4.0 — no target-user argument.** Resolve the caller via
`interaction.user.id` → `profiles` (reusing RFC-013's `fetch_profile_id`), then:

```
GET /rest/v1/tournament_results
    ?profile_id=eq.<pid>&season_id=eq.<current>
    &select=final_rank,awarded_points,tournaments(name,event_date)
    &order=tournaments(event_date).desc
```

PostgREST resource embedding over the existing `tournament_id` FK gives the
event name and date in one round trip. One row per tournament entered: event
name, date, placement, points; plus a season total.

An **unbound** caller gets the distinct French message pointing at the organizer
(E2E 22) — the same `not_linked` shape `/ots` uses, with its own copy naming
`/profile` rather than `/ots`.

The same render-safety discipline applies, though the risk is far lower (one
player's season, bounded by events-per-season). Reuse the cap; do not assume it
cannot be hit.

### 3.4 Channel restriction (F75)

```python
RANKING_CHANNEL_ID = os.getenv("RANKING_CHANNEL_ID")   # validated at boot

def in_ranking_channel(interaction: discord.Interaction) -> bool:
    """Pure-ish, testable: text comparison — snowflakes exceed 2^53."""
    return str(interaction.channel_id) == RANKING_CHANNEL_ID
```

- Checked **first**, before any I/O, in `/standings` and `/profile` only.
- Refusal is **ephemeral in every case**, even for `/standings`, so a wrong-
  channel invocation does not spam the channel it was not supposed to be in —
  and **leaks no standings** (E2E 19).
- French copy: `ℹ️ Cette commande n'est disponible que dans le salon
  {mention}.` — mention the channel so the player can click through.

> ⚠️ **`/ots` is unaffected and must stay unaffected.** It keeps working
> everywhere and DMs as before. **The channel check must not be implemented
> anywhere the `/ots` path can reach** — not in a shared decorator, not in a
> helper `/ots` calls. Two call sites, both explicit. This is a locked
> requirement (F75), not a style preference.

`RANKING_CHANNEL_ID` joins `validate_config()` as the sixth var (F19). Like
`ORGANIZER_DISCORD_ID` it is **not a secret** — a Discord snowflake, safe in
logs and documentation. `.env.example` gains a placeholder line; `DEPLOYMENT.md`
documents both new vars.

### 3.5 Per-tournament standings (F64, P1)

Implemented as the optional `tournament` argument on `/standings` (§3.1) rather
than an argument on `/profile`. PRD §31.8 explicitly leaves the shape open ("a
third command or an argument to F63"); per-tournament standings are a
*leaderboard*, not a personal history, so they belong on the leaderboard
command. Same view, one extra filter — resolve the name to a tournament in the
current season, then read `tournament_results` for it directly (the view
aggregates a whole season, so the per-tournament path bypasses it).

**P1: cut it before cutting anything else** if the release is running long. It
must not delay F73.

### 3.6 Fail-soft (F65)

Named statuses, French copy, never an exception — the same contract `/ots` has
had since v2.0:

| Status | Cause | French copy |
|---|---|---|
| `wrong_channel` | F75 | ℹ️ Cette commande n'est disponible que dans le salon {mention}. |
| `no_season` | today falls in no season (F66) | ℹ️ Aucune saison en cours pour le moment. |
| `empty_season` | current season, zero frozen results | ℹ️ Aucun résultat enregistré pour l'instant dans la saison **{name}**. Le classement apparaîtra après le premier tournoi clôturé. |
| `not_linked` | `/profile` by an unbound player | ❌ Votre compte Discord n'est pas encore relié à un joueur. Contactez l'organisateur. |
| `no_results` | `/profile`, bound, no results this season | ℹ️ Vous n'avez encore aucun résultat cette saison. |
| `unknown_tournament` | F64 name not found in the season | ❌ Aucun tournoi nommé **{name}** dans la saison en cours. |
| `unavailable` | Supabase timeout / non-200 / parse | ⚠️ Service momentanément indisponible. Réessayez dans un instant. |

**`no_season` and `empty_season` are deliberately distinct** (F66): both are
normal states, not errors, and they call for different organizer action
(create a season vs. wait for the first freeze). An empty leaderboard in the
opening weeks of a season is normal.

**A ranking outage must never affect `/ots`** (PRD §32) — the new commands are
independent read paths sharing only the config and the PostgREST helpers.

## 4. Data models / schema changes

**None.** RFC-011 owns all v4.0 DDL, including `season_standings` and
`current_season`. If a display requirement seems to need a view change, that is
a signal the RFC-011 seam was drawn wrong — raise it rather than adding DDL
here.

## 5. Interfaces exposed

- **Player-facing:** `/standings [tournament]` (public in the ranking channel),
  `/profile` (ephemeral).
- **Python:** `render_standings()` and `in_ranking_channel()` — pure, unit-
  tested, following `render_team_text`'s precedent.
- **Config:** `RANKING_CHANNEL_ID`, validated at boot.
- **Command surface, complete:** `on_ready` guild sync now registers **six**
  commands — `/ots`, `/ots-organizer`, `/link-organizer`, `/unlink`,
  `/standings`, `/profile`. Two of the six are invisible to non-organizers
  (E2E 35).

## 6. Acceptance criteria

- [ ] **F62:** `/standings` in the configured channel returns a public embed
      ranking the current season's competitors by summed points.
- [ ] **F70 (ordering):** ties break on points → most events played → best
      single `final_rank` → stable key; a player with more events and no wins
      outranks an event winner on equal points.
- [ ] **F70 (rank numbers):** equal points display the **same** rank number,
      competition-style; sort keys never change the displayed rank.
- [ ] **F70 (unbound):** unbound players appear and are ranked, by name, with
      no mention; bound profiles render as a mention; no participation floor.
- [ ] **F70 (cap):** capped at top 25 with a French footer stating the **total**
      ranked count when truncated; the rendered description is **never** longer
      than 4096 characters, verified against a synthetic oversized field
      (E2E 18) — no silent failure.
- [ ] **F63:** `/profile` replies **ephemerally** with one row per tournament
      entered this season — event name, date, placement, points — plus a season
      total; no target-user argument exists.
- [ ] **F75:** both commands refuse in any other channel with a distinct French
      message, ephemerally, leaking no standings; `/standings` is public within
      the configured channel; **`/ots` still works in every channel and DMs as
      before**, and no channel check exists on its path.
- [ ] **F65:** every status in §3.6 has its own French message; Supabase
      unreachable produces a French fail-soft with no exception; **no ranking
      command can raise**.
- [ ] **F66:** outside any season, and inside an empty season, each produces its
      own distinct French message and no crash.
- [ ] **F64 (P1):** `/standings tournament:<name>` returns that event's standings;
      an unknown name gets its own French message.
- [ ] **Config:** the bot refuses to start with `RANKING_CHANNEL_ID` missing or
      malformed; `.env.example` and `DEPLOYMENT.md` document both new
      non-secret vars.
- [ ] **F73:** `E2E-CHECKLIST-v4.md` exists, is French, covers all 36 PRD §41
      scenarios, and **passes in full**.
- [ ] **Release:** RUNBOOK §9 written; the four status trackers updated; the
      `/ots` change announced.

## 7. Implementation details

### 7.1 Documentation deliverables (co-equal with the code)

**`knowledge/RUNBOOK.md` §9** — French, matching §1–§8's tone, covering:

1. **Opening a season** (Journey I) — create the row in Studio with **adjacent,
   non-overlapping** bounds. F42 rejects a shared boundary day; show
   `…-12-31` then `…-01-01` so the organizer does not hit it blind.
2. **Setting up an event** — the two new fields, `event_date` and `tier_id`
   (dropdown), plus `season_id`. Timed against G2's 5-minute budget.
3. **Binding a player** (Journey J) — `/link-organizer`, the native picker, the
   rebind confirmation, and the fact that it is **once per person, ever**.
4. **Closing an event** (Journey L) — **nothing new**: the same trigger command
   as v3.0's §8. State that the freeze rides it.
5. **Correcting a bad freeze** (Journey N) — fix the cause first, then
   `"refreeze": true`. Include the exact `curl`, with the secret as a
   placeholder.
6. **Journey O** — forgot `season_id`: nothing is lost, set it and re-trigger.
7. **The freeze takes an explicit `tournament_id`, not the active tournament**
   — organizers will assume otherwise (PRD §31.5).
8. **F48's consequence** — a frozen tournament cannot be deleted; test
   tournaments must either never be frozen (`season_id is null`) or be purged of
   results first. Give the purge SQL.
9. **The tie-break, stated plainly** — turnout before peak finish, so the
   organizer can answer for it.
10. **Retention and erasure** (G17) — what `/unlink` does, what it does not
    delete, and that it also revokes `/ots`.
11. **Pre-flight additions** (§5) — every roster row has a `profile_id` (G16),
    and one idempotent `/link-organizer` on an already-bound player to prove
    `ORGANIZER_DISCORD_ID` is right (PRD §38).

**`knowledge/E2E-CHECKLIST-v4.md`** (F73) — French, one row per PRD §41
scenario, all 36, with a `PASS`/`FAIL` column and a sign-off line, mirroring
`E2E-CHECKLIST-v3.md`'s format exactly. Scenario 1 re-runs the v3 checklist
**minus the typed-`/ots` scenarios RFC-013 struck**.

**`knowledge/DEPLOYMENT.md`** — both new env vars, both flagged non-secret,
plus the note that the RFC-013/014 deploys each fail fast without theirs.

**Four status trackers on sign-off** (`CLAUDE.md`'s convention): this RFC's
Completion record, `RFCS.md`, `PRD.md`, and `CLAUDE.md`. Also update
`FEATURES.md`'s v4.0 status and `.claude/RULES.md`'s v4.0 addendum.

### 7.2 The two scenarios that are the release's security gate

PRD §34 is explicit: **scenarios 25 and 29 together** measure the release's
security goal, and "a suite passing with either failing means the release's
security goal was not met." They belong to RFC-013's code but they are **this**
RFC's gate — do not sign off with either marked anything but `PASS`.

### 7.3 Release announcement

Announcing the `/ots` change is a **release requirement** (PRD §36, G15), as
v3.0's was. It is operational, has no code, and is the one item on this list no
RFC will remind anyone about — so it is written down here, in the last RFC, as
a checklist item.

## 8. Edge cases & risks

- **The 4096-char cap is a correctness bug, not a formatting one.** Discord
  rejects an oversized description outright; the player sees the command
  silently fail. Test it with a synthetic field far larger than the community
  will ever be.
- **The footer competes with the rows for the same budget** and carries two
  messages (the total count, and the unbound-players pointer). Compute the
  footer first, then fill.
- **A shared decorator would leak the channel check onto `/ots`.** The single
  most damaging refactor a future reader could make in this RFC is "DRY up the
  channel check." Two explicit call sites; comment why.
- **Mentions of departed members.** A `<@id>` for someone who left the guild
  renders as a raw id. Accepted — the standings are historical, and resolving
  every id would cost a member lookup per row. Do not add one.
- **`/standings` is public**, so it publishes in-game names and placements.
  PRD §36 records the assumption: already true of the Challonge bracket, but
  v4.0 is the first time this bot republishes it.
- **An empty leaderboard is normal** in the opening weeks and must not read as
  broken. Distinct copy (F66).
- **`current_date` timezone** — `current_season` resolves in the database's
  timezone (UTC). Around a season boundary the answer can flip a day early
  relative to French local time. Documented in RFC-011 §8; do not build
  timezone handling.
- **A leaderboard outage is not an event-blocker.** Ranking is not a live-event
  dependency the way `/ots` is; the correct response is "standings later"
  (PRD §38). Do not add retries or caching for it.
- **`/profile` embedding depends on the `tournament_id` FK.** If the embed
  syntax returns null for a tournament (deleted — impossible under F48, or
  renamed), fall back to the frozen `ingame_name`/rank rather than dropping the
  row.

## 9. Applicable rules (RULES.md)

- **§1 (dependency policy):** zero new Python dependencies.
- **§2 (architecture):** stays in `bot.py`; reuses RFC-013's write seam not at
  all — both commands are **read-only**.
- **§3 (naming/French):** every user-facing string French, matching the ✅/⚠️/❌
  tone. Command names are French (`/standings`, `/profile`); internal
  identifiers stay English.
- **§5 step 5 (render-safety):** F70 is F14's contract applied to a second
  surface. Same rule, same discipline, same tests.
- **§6 (security):** `RANKING_CHANNEL_ID` is a new env var and **not a secret**.
  No secret is added.
- **§7/§17 (fail-soft):** extended to two more commands; new failure modes get
  named statuses, never exceptions.
- **§8/§18 (testing & release gates):** `E2E-CHECKLIST-v4.md` is the primary
  release gate, exactly as the v2.0 checklist was for RFC-006 and the v3.0 one
  for RFC-010. Accessibility/responsive design remain **N/A** — Discord embeds
  only.
- **§10 (keep the docs in sync):** this RFC is where that rule is discharged for
  the whole release — six documents plus the four trackers.

## 10. Testing strategy

### 10.1 Unit tests (`test_bot.py`)

`render_standings` is the RFC's `render_team_text` — pure, budget-critical,
and where the release's second silent-failure mode lives:

- rank numbering — no ties; one tie; a three-way tie; a tie at rank 1;
  competition-style continuation (1, 2, 2, 4);
- ordering — equal points differing on events played; equal on both differing
  on best rank; fully equal falling back to `standing_key`;
- mentions — bound renders `<@id>`, unbound renders the bare name, a mixed
  list;
- the cap — exactly 25 rows, 26 rows (footer appears, states the true total),
  a synthetic field of 500 rows with long names asserting
  `len(result) <= DISCORD_DESC_LIMIT`;
- degenerate input — empty list, a single row, a row with a pathologically long
  name;
- the footer — present only when truncated, and always counted in the budget.

`in_ranking_channel` — match, mismatch, and an id above 2^53 compared as text.
`validate_config` — missing and malformed `RANKING_CHANNEL_ID`, plus a
regression that all six vars are now required.

A status-dispatch table test for each command, asserting every status in §3.6
maps to a distinct non-empty French message and that nothing falls through.

### 10.2 In-guild verification

Against RFC-011's seed season and RFC-012's frozen fixtures:

- `/standings` in and out of the ranking channel; `/profile` in and out;
- `/profile` bound with results, bound without results, unbound;
- both commands with no current season and with an empty season;
- Supabase unreachable (point `SUPABASE_URL` at a dead host) — French fail-soft,
  no traceback;
- **`/ots` in a non-ranking channel, immediately after** — still works, still
  DMs. This is the regression that protects F75's boundary.

### 10.3 The release gate

`E2E-CHECKLIST-v4.md`, all 36 scenarios, executed live in the guild by the
organizer, exactly as `E2E-CHECKLIST-v3.md` was (9/9, signed off 2026-07-31).
**Must pass in full before deploy**, with scenarios 11, 25 and 29 as the three
that cannot be waived:

- **11** — the group-stage boundary freezes nothing (RFC-012's one-way risk);
- **25** — `/ots` accepts no argument at all;
- **29** — `/ots-organizer` is refused for *and hidden from* non-organizers.

---

## Completion record

*(to be filled in on completion — status, deliverables shipped, the E2E
checklist result and sign-off date, deviations, and any tracked follow-ups)*
