# RFC-009 — `/ots` Opponent-Resolution Refactor

- **Status:** 📝 Drafted (not yet implemented)
- **Implementation order:** 9 of 10 (v3.0) — depends on RFC-007 (cache table
  shapes) and RFC-008 (populates them); depends transitively on all of v2.0
- **Complexity:** High (the sole High-complexity v3.0 feature, F32)
- **Features covered:** F32, F33, F34
- **Grounding:** `knowledge/PRD.md` §17, §18.3, §20 (Journeys F/G/H), §24
  (items 4, 6, 7) (v3.0 addendum); `knowledge/FEATURES.md`
  §"v3.0 — Challonge Integration" §J
- **Builds upon:** RFC-007 (`challonge_participants_cache`,
  `challonge_matches_cache`), RFC-003/005 (`fetch_active_player`,
  `normalize_name`, `_escape_ilike` — reused, not reimplemented)
- **Built upon by:** RFC-010 (E2E checklist + release validate this
  end-to-end; the staleness backstop, F36, extends the read path this RFC adds)

---

## 1. Summary

Rewrite `/ots`'s command semantics: the single argument **changes meaning**
from "the player to look up" to "your own username." The bot resolves the
caller's **current opponent** via RFC-007's Challonge cache tables and returns
the **opponent's** OTS — using the exact same embed/delivery mechanics as
v2.0. This is a confirmed, intentional **one-time behavior break** (PRD §17,
§24 item 4), not a regression to soften with a fallback mode.

A new async helper, `fetch_current_opponent`, does the resolution: active
tournament → Challonge-link check → requester's cached participant id →
their `open` match → the opponent's cached participant id → the opponent's
name. The **final step — opponent name to `team_text`, verbatim** — reuses
v2.0's existing `fetch_active_player` unchanged; this is the one piece of
v2.0 logic this addendum does not touch (PRD §18.3, RFC-007 §5).

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F32** | Given the caller's normalized username, resolve their `challonge_participant_id`, find the `state = 'open'` match involving them, and resolve the *other* side's id back to a name. |
| **F33** | Expanded fail-soft: (at least) seven distinct French outcomes, replacing v2.0's three; updated slash-command description reflecting "type your own name." |
| **F34** | If the active tournament's `challonge_tournament_id IS NULL`, `/ots` hard-fails with a distinct message — no fallback to v2.0's arbitrary-lookup behavior. |

## 3. Technical approach

### 3.1 Outcome model — six failure branches + success

`fetch_current_opponent(normalized_own_name)` returns
`(status, player | None)`, mirroring `fetch_active_player`'s shape exactly,
with `status` one of:

```
"no_active"          -- zero active tournaments                         (PRD outcome 1)
"no_challonge_link"  -- active tournament has challonge_tournament_id IS NULL (outcome 2)
"requester_not_found"-- caller's name absent from the cached participants (outcome 3)
"no_current_match"   -- caller found, but no 'open' match involves them  (outcome 4)
"opponent_no_ots"    -- opponent resolved, but no players.team_text row  (outcome 5)
"unavailable"        -- any Supabase read failure/timeout                (outcome 6)
"ok"                 -- opponent resolved; player dict is their OTS row  (success)
```

**Note on the PRD's "seven outcomes":** the PRD's list of seven (§18.3)
includes a 7th — cache staleness > 48h — that is **not** a branch this
function returns. It is a passive, orthogonal server-side log check (F36,
RFC-010's responsibility) that runs alongside a successful resolution, never
changing the returned status. Six fail-soft statuses + one success status is
the complete branching surface this RFC implements; do not try to force a
7th status value out of this function.

### 3.2 Resolution sequence (F32)

1. `normalized = normalize_name(username)` — same `trim()`+`lower()` as
   v2.0, applied to the **caller's own** name now, not an opponent's.
2. **Active tournament + Challonge link** — one query, extended from v2.0's
   shape to also select the link column:
   ```
   GET {SUPABASE_URL}/rest/v1/tournaments
     ?is_active=eq.true&select=id,challonge_tournament_id&limit=1
   ```
   - Empty → `("no_active", None)`.
   - Row found, `challonge_tournament_id IS NULL` → `("no_challonge_link", None)`
     — checked **before** any further resolution runs (F34).
   - **Do not reuse `_fetch_active_tournament_id` for this** — that helper's
     `select=id` is deliberately narrower for `fetch_active_player`'s own
     purposes; add a small sibling helper (or inline this one query) rather
     than widening a v2.0 function's contract for a v3.0-only need.
3. **Resolve the requester's cached participant id:**
   ```
   GET {SUPABASE_URL}/rest/v1/challonge_participants_cache
     ?tournament_id=eq.{id}
     &ingame_name=ilike.{_escape_ilike(normalized)}
     &select=challonge_participant_id&limit=1
   ```
   (Reuse `_escape_ilike` verbatim — same injection-hardening contract as
   v2.0's player lookup.) Empty → `("requester_not_found", None)`.
4. **Find the caller's current match:**
   ```
   GET {SUPABASE_URL}/rest/v1/challonge_matches_cache
     ?tournament_id=eq.{id}&state=eq.open
     &or=(player1_challonge_id.eq.{pid},player2_challonge_id.eq.{pid})
     &select=player1_challonge_id,player2_challonge_id,round
     &order=round.desc&limit=1
   ```
   Empty → `("no_current_match", None)`. The `order=round.desc&limit=1` is
   the deliberate, defensive tie-break for the (schema-unprevented, shouldn't
   happen) case of more than one `open` row for the same participant (F32
   edge case) — pick the highest round, don't surface an ambiguity error to
   the player.
5. **Determine the opponent's id:** whichever of `player1_challonge_id` /
   `player2_challonge_id` is **not** `pid`. If that side is `null` (a
   malformed/defensive case — an `open` match with only one side fed in,
   which a well-formed bracket should never produce) → treat as
   `("no_current_match", None)` rather than crash or return a nonsensical
   opponent.
6. **Resolve the opponent's name:**
   ```
   GET {SUPABASE_URL}/rest/v1/challonge_participants_cache
     ?tournament_id=eq.{id}&challonge_participant_id=eq.{opponent_id}
     &select=ingame_name&limit=1
   ```
   This should always find a row given RFC-007's FK/write contract (both
   cache tables are refreshed together by RFC-008 on every trigger). An empty
   result here indicates a **cache-consistency bug**, not a normal fail-soft
   case the PRD enumerates — log it distinctly server-side (e.g. `"cache
   inconsistency: match references unknown participant id"`) and return
   `("unavailable", None)` to the player, so a data-integrity bug is
   diagnosable but never surfaces as a confusing player-facing message.
7. **Final step — reuse v2.0 verbatim (PRD §18.3, RFC-007 §5):**
   `status, player = await fetch_active_player(normalize_name(opponent_name))`.
   - `"ok"` → return `("ok", player)` — the resolved opponent's OTS.
   - `"not_found"` → return `("opponent_no_ots", None)` (the name-sync gap,
     outcome 5) — **must be logged server-side distinguishably from
     `requester_not_found`** (F33 edge case), even though both may read
     similarly apologetic to a player.
   - `"no_active"` → defensively map to `("unavailable", None)` with a
     distinct log line (shouldn't happen — the tournament was already
     confirmed active in step 2 — but the active tournament could in theory
     be deactivated between steps 2 and 7 mid-request; treat as a transient
     unavailability, not a crash).
   - `"unavailable"` → propagate as `("unavailable", None)` (already logged
     by `fetch_active_player` itself).

### 3.3 Command handler

```
1. defer(ephemeral=True)                                    # unchanged, F18
2. status, player = await fetch_current_opponent(normalize_name(username))
3. branch on status -> one of 6 French fail-soft messages, or:
4. "ok": build embed exactly as v2.0 (RULES §15), EXCEPT:
     title = f"OTS de {player['ingame_name']}"
```

**Title deviation from v2.0, explained:** RFC-005 echoed the caller's *raw
input* in the title (`OTS de {username}`) because the input *was* the name
being displayed. Here the caller typed their **own** name — the title must
instead show the **opponent's** canonical stored name
(`player["ingame_name"]`, as returned by `fetch_active_player`), since the
raw input is never the right thing to display. This is a deliberate,
necessary deviation from RFC-005's precedent, not an inconsistency to "fix"
back to matching v2.0's echo behavior.

Everything else in the embed (description via `render_team_text`, color
`0x3B4CCA`, optional `url` from `pokepaste_url`, DM + ephemeral-fallback
delivery) is **unchanged from v2.0 §5** (RULES §5/§15) — do not touch that
code path.

### 3.4 Updated command metadata (F33)

```python
@tree.command(
    name="ots",
    description="Découvrez l'OTS de votre adversaire actuel",
    guild=discord.Object(id=GUILD_ID),
)
@app_commands.describe(username="Votre propre nom d'utilisateur dans le tournoi (pas celui de votre adversaire)")
```
The Discord-visible copy must no longer imply "the player you want to look
up" (F33 acceptance criterion) — finalize exact wording during
implementation, matching existing French tone/emoji conventions.

### 3.5 French copy (six branches — all French, RULES §13)

- **no_active** (unchanged from v2.0):
  `⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard.`
- **no_challonge_link** (new, F34):
  `❌ Ce tournoi n'est pas relié à Challonge. Impossible de déterminer votre adversaire actuel.`
- **requester_not_found** (new):
  `❌ Aucun participant nommé **{username}** trouvé dans le bracket Challonge de ce tournoi.`
- **no_current_match** (new — covers bye/eliminated/not-started with one
  generic message, PRD §24 item 7, a taken default, not separately confirmed):
  `ℹ️ Vous n'avez pas de match en cours pour le moment.`
- **opponent_no_ots** (new — the name-sync gap):
  `⚠️ Votre adversaire a été trouvé, mais son OTS n'est pas encore enregistré. Contactez l'organisateur.`
- **unavailable** (unchanged from v2.0):
  `⚠️ Service momentanément indisponible. Réessayez dans un instant.`

Finalize exact wording during implementation; keep friendly, French, and
consistent with existing ✅/⚠️/❌ conventions (RULES §13).

## 4. Data models / schema changes

None — this RFC only **reads** RFC-007's tables via the existing
PostgREST/`aiohttp` seam. No `schema.sql` changes.

## 5. Interfaces / contracts exposed

- **`fetch_current_opponent(normalized_own_name) -> (status, player | None)`**
  — the new seam the command handler consumes; never raises (same contract
  discipline as `fetch_active_player`).
- **Reused verbatim, unmodified:** `normalize_name`, `_escape_ilike`,
  `fetch_active_player`, `render_team_text`.
- **The `/ots` behavioral contract changes** — this is the release's
  player-facing surface change, validated end-to-end in RFC-010.

## 6. Acceptance criteria

- [ ] **F32:** Against RFC-007's seed fixtures (giovlacouture ↔ zou open
      match; koloina pending/no-opponent), `/ots giovlacouture` resolves and
      returns zou's OTS (and vice versa); `/ots koloina` yields
      `no_current_match`; a name absent from the seed set yields
      `requester_not_found`.
- [ ] **F32:** More than one `open` match for the same participant (contrived
      test data) resolves deterministically (highest `round`) rather than
      erroring.
- [ ] **F33:** Each of the six fail-soft branches (§3.5) produces its own
      distinct French message; no unhandled exception ever reaches the
      interaction response.
- [ ] **F33:** `opponent_no_ots` and `requester_not_found` are distinguishable
      in **server-side logs**, even though their player-facing copy is
      similarly apologetic.
- [ ] **F33:** The command's Discord-visible description/argument help text
      no longer implies "the player you want to look up."
- [ ] **F34:** A tournament with `challonge_tournament_id IS NULL` hard-fails
      with the distinct message from the moment it's activated — no code
      path falls back to v2.0's arbitrary-name-lookup behavior.
- [ ] **Embed:** title reads `OTS de {opponent's stored ingame_name}` (not the
      caller's raw input); description/color/optional-URL/delivery unchanged
      from v2.0.

## 7. Implementation details

- **File:** `bot.py` only. Add `fetch_current_opponent` (+ any small private
  helpers, e.g. the tournament+link query) alongside the existing
  `fetch_active_player` family; rewrite the `ots` command body to call it.
- **Do not modify** `fetch_active_player`, `_fetch_active_tournament_id`, or
  `_fetch_player_in_tournament` — RFC-009 adds a sibling read path, it does
  not widen v2.0's existing one (§3.2 step 2's explicit note).
- **Minor accepted inefficiency:** the active tournament row is queried twice
  per invocation — once here for the Challonge-link check, once again inside
  the reused `fetch_active_player` call for the final `team_text` lookup.
  This is intentional: it keeps the v2.0 helper untouched and "reused
  verbatim" per PRD §18.3/RFC-007 §5, rather than refactoring its signature
  to thread the tournament id through. At this project's hobby scale, the
  extra PostgREST round-trip is not a performance concern.
- **Pure-logic extraction, optional but recommended (mirrors RFC-004):** the
  "pick the current match, then pick the other side's id" logic (steps 4–5)
  has no network dependency once the candidate rows are in hand — consider
  factoring it into a small pure function (e.g.
  `pick_opponent_id(own_id, matches: list[dict]) -> int | None`) so it can be
  unit-tested directly against RFC-007-shaped fixture dicts, the same way
  `normalize_name`/`render_team_text` are tested. Do not over-extract beyond
  this one seam.

## 8. Edge cases & risks

- **The highest-risk item in this addendum (F32):** the multi-step
  resolution chain (tournament → link → participant → match → opponent →
  team_text) is the deepest read-path this project has built. Mitigation:
  RFC-007's seed fixtures give concrete, known-good/known-bad inputs to test
  every branch against before any live Challonge data is involved.
- **Self-referential/degenerate match rows** (both sides equal, or the
  "other side" resolving back to the requester) shouldn't occur in a
  well-formed bracket and are not schema-prevented — treat defensively as
  `no_current_match` rather than returning a player their own OTS.
- **Bye represented as `open`** with one null side: per §3.2 step 5, treated
  as `no_current_match` (a defensive default; RFC-007's seed data models a
  bye as `pending`, not `open`, so this path is a hardening measure against
  unexpected Challonge/RFC-008 data shapes, not the documented normal case).
- **48h staleness (outcome 7) is explicitly NOT this RFC's scope** — do not
  add the `fetched_at` comparison/log here. RFC-010 (F36) adds it as a
  small, additive extension on top of this RFC's read path; structure the
  cache queries so `fetched_at` is trivially addable to the existing
  `select=` clauses later (no redesign needed), but do not implement the
  check itself now.
- **Empty/whitespace-only input** → normalizes to `""` → `requester_not_found`
  (never a crash), same defensive shape as v2.0.

## 9. Applicable rules (RULES.md)

- **v3.0 Addendum §15** (the full opponent-resolution contract this RFC
  implements). **§17** (six fail-soft outcomes, each distinct French copy,
  server-side distinguishability for `opponent_no_ots` vs.
  `requester_not_found`). **§13** (French user strings; English
  identifiers). **§14** (reuse RFC-007's normalization contract; no new
  reconciliation logic for name mismatches). **§12** (`bot.py` still never
  calls Challonge directly — this RFC only ever reads Supabase). **§20**
  (the `/ots` behavior change is confirmed, not a regression to hedge; the
  no-link hard-fail must not gain a fallback).

## 10. Testing strategy

- **Unit tests (if the pure seam from §7 is extracted):** add a new test
  class to the existing `test_bot.py` (RULES: single root-level file, no new
  test folder) covering `pick_opponent_id`-style logic against
  RFC-007-shaped fixture dicts — the open-match case, the multiple-open-match
  tie-break, the null-other-side defensive case.
- **Manual/live testing against RFC-007's seed fixtures** (once RFC-007/008
  are actually applied to a real Supabase project): `giovlacouture` ↔ `zou`
  happy path (both directions); `koloina` → `no_current_match`; an
  unseeded name → `requester_not_found`; a tournament with
  `challonge_tournament_id IS NULL` → `no_challonge_link`; no active
  tournament → `no_active`; a forced Supabase outage → `unavailable`.
- **`opponent_no_ots` specifically** needs a fixture where a Challonge
  participant has no corresponding `players` row in the same tournament —
  construct this deliberately (seed a 4th Challonge participant with no
  matching `players` entry) to exercise the name-sync-gap branch.
- The consolidated pass/fail sign-off is **RFC-010's expanded E2E checklist**
  — the primary release gate for this addendum, mirroring RFC-006's role for
  v2.0.
