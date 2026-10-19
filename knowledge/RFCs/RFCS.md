# RFCS — OTS Bot (implementation roadmap)

Master index for every RFC in the project: v2.0's Supabase-backed backoffice
(RFC-001–006), v3.0's Challonge integration (RFC-007–010, both shipped), and
v4.0's ranking system and `/ots` identity binding (RFC-011–014, specified, not
yet built). Sources: `knowledge/PRD.md` (v2.0 §1–13, v3.0 §14–26),
`knowledge/PRD.v4.final.md` (v4.0), `knowledge/FEATURES.md`, `.claude/RULES.md`.

> **Implementation is strictly sequential.** Each RFC is fully implementable only
> after **all** lower-numbered RFCs are complete. There is no parallel work. Follow
> the `implementation-prompt-RFC-00N.md` two-phase prompt for each (plan → approval →
> implement).

---

## RFCs in implementation order

| # | RFC | Features | Complexity | PRD §9 day |
|---|-----|----------|-----------|-----------|
| **001** ✅ | [Supabase Schema, Constraints, Indexes & Trigger](RFC-001-Supabase-Schema.md) | F1, F2, F3, F4, F5, F6 | Medium | Day 1 |
| **002** ✅ | [Organizer Runbook (Studio Workflows)](RFC-002-Organizer-Runbook.md) | F7, F8, F9, F10 | Low–Med | Day 2 |
| **003** ✅ | [Configuration & PostgREST Data-Access Seam](RFC-003-Config-And-Data-Access.md) | F19, F23, F17(mech) | Medium | Day 2 |
| **004** ✅ | [Pure Logic: Normalization & Render-Safety](RFC-004-Pure-Logic-Normalization-Render-Safety.md) | F12(logic), F14 | High | Day 3–4 |
| **005** ✅ | [`/ots` Command Refactor: Live Read & Fail-Soft](RFC-005-OTS-Command-Refactor.md) | F11, F13, F15, F16, F17(route), F18, F22(code), F24(code) | High | Day 3–4 |
| **006** ✅ | [Reliability, Contingency & Release](RFC-006-Reliability-And-Release.md) | F20, F21, F22(docs), F24(backup), E2E, dry-run, deploy | Medium | Day 5–7 |

All six RFCs are now ✅ complete — the v2.0 Supabase-backed backoffice release
is shipped. See RFC-006's Completion record for the live E2E checklist,
dry-run, and deploy-verification sign-off.

**Won't-have (F25 a–g)** — not covered by any RFC by design (RULES §9): multiple
active tournaments, cross-tournament identities, custom web app/auth/roles, player
self-submission, pairings / hidden-until-reveal, pokepaste scraping, content
validation, caching, multi-guild, non-French localization.

---

## v3.0 — Challonge Integration (RFC-007–010)

Picks up **F25(e)** (real-time pairings, previously deferred) via a Supabase-cached
read of an organizer-managed Challonge bracket. Full context: `FEATURES.md`
§"v3.0 — Challonge Integration". Strictly sequential, same as v2.0 — each RFC
depends on all lower-numbered RFCs (v2.0's included).

| # | RFC | Features | Complexity | Status |
|---|-----|----------|-----------|--------|
| **007** ✅ | [Challonge Schema & Cache Tables](RFC-007-Challonge-Schema.md) | F26–F29 | Low–Medium | ✅ Complete |
| **008** ✅ | [Challonge Sync Edge Function (manual trigger)](RFC-008-Challonge-Sync-Edge-Function.md) | F30–F31 | Medium | ✅ Complete |
| **009** ✅ | [`/ots` Opponent-Resolution Refactor](RFC-009-OTS-Opponent-Resolution.md) | F32–F34 | High | ✅ Complete |
| **010** ✅ | [Runbook, Staleness Backstop & Release](RFC-010-Runbook-Staleness-Release.md) | F35–F37 | Medium | ✅ Complete — live E2E 9/9 `PASS`, signed off 2026-07-31 |

All four v3.0 RFCs are now ✅ complete — the Challonge integration release is
shipped. The F37 release gate (`knowledge/E2E-CHECKLIST-v3.md`) was executed
live by the organizer during a real event the week of 2026-07-20 and signed off
**2026-07-31**: 9/9 `PASS`. See RFC-010's Completion record.

One correction landed alongside this release, after RFC-009 shipped: Challonge
keeps a participant's **group-stage id and top-level id live simultaneously**
once a final bracket is generated (group matches key off `group_player_ids[0]`,
bracket matches off the top-level `id`). Storing only one silently breaks
opponent resolution for whichever phase doesn't use it. Both are now stored
(`challonge_participants_cache.challonge_group_player_id`) and matched against
(`participant_candidate_ids()` → `pick_opponent_id()`).

### Key v3.0 decisions locked (see FEATURES.md for full rationale)
- Sync job is a **Supabase Edge Function** (TypeScript/Deno), not `pg_cron`/`pg_net`
  — correctness/debuggability of JSON handling outweighs the minimal-runtime ethos
  here; still Supabase-native infra, not a "custom web app" (F25c stays Won't-have).
- Refresh is **organizer-triggered** (manual `curl`, secret-protected), not polled —
  eliminates the Challonge free-tier (500 req/month) cadence-tuning problem entirely.
- `bot.py` still never talks to Challonge directly — only Supabase, unchanged from
  the v2.0 locked decision (PRD §11.5).
- No fallback to v2.0's arbitrary-lookup `/ots` behavior when a tournament has no
  Challonge link — `/ots` hard-fails distinctly instead (F34).

### Dependency table (v3.0 additions)

| RFC | Depends on | Enables |
|-----|-----------|---------|
| 007 | 001–006 | 008, 009 |
| 008 | 007 | 009 |
| 009 | 007, 008 | 010 |
| 010 | 007–009 | — (release) |

### Dependency graph (textual, v3.0)

```
007 (challonge_tournament_id, cache tables, RLS, seed data)
 └─► 008 (Edge Function: manual-trigger full-refresh sync, writes the cache)
       └─► 009 (/ots: own-name -> opponent resolution via the cache;
                 reuses fetch_active_player verbatim for the final read)
             └─► 010 (runbook + 48h staleness log + deploy docs + E2E release)
```

### Feature → RFC coverage map (v3.0)

| Feature | RFC | Feature | RFC |
|---------|-----|---------|-----|
| F26 `challonge_tournament_id` link | 007 | F32 opponent-resolution query | 009 |
| F27 `challonge_participants_cache` | 007 | F33 expanded fail-soft (6+1 outcomes) | 009 |
| F28 `challonge_matches_cache` | 007 | F34 no-link hard-fail | 009 |
| F29 RLS + seed/test fixtures | 007 | F35 runbook: linking + trigger | 010 |
| F30 full-refresh Edge Function | 008 | F36 48h staleness warning | 010 |
| F31 secret-protected invocation | 008 | F37 E2E checklist, release | 010 |

### Roadmap notes (v3.0)

- **Critical path:** 007 → 008 → 009 is the backbone (cache schema → writer →
  reader), same shape as v2.0's 001 → 003 → 005. 010 is the closing
  documentation/verification/release RFC, mirroring 006's role exactly.
- **Highest technical risk:** **F32** (RFC-009's multi-step resolution chain —
  tournament → link → participant → match → opponent → team_text) is the
  deepest read path this project has built, and the sole High-complexity
  v3.0 feature. **F30**'s all-or-nothing write ordering (RFC-008) is the
  second-highest risk — a bug there silently corrupts the data RFC-009 reads.
- **RFC-007 seed fixtures de-risk RFC-009 the same way RFC-002's seed data
  de-risked RFC-005:** giovlacouture ↔ zou (happy path) and koloina
  (no-current-match) are available before any live Challonge account is
  needed, so RFC-009 can be built and tested against known-good/known-bad
  inputs in isolation.
- **Locked decisions honored throughout:** Edge Function over `pg_cron`/`pg_net`;
  manual trigger over polling; `bot.py` never calls Challonge directly; no
  fallback to v2.0's arbitrary-lookup `/ots` behavior; staleness is a log,
  never a gate. (PRD §24 / RULES v3.0 Addendum.)

---

## v4.0 — Ranking System & `/ots` Identity Binding (RFC-011–014)

Adds the **across-event dimension** (a persistent, season-scoped ranking) *and*
closes a **team-sheet scouting leak** found during v3.0. Full context:
`knowledge/PRD.v4.final.md` — the authoritative v4.0 spec, fully specified and
decided 2026-07-31, with §31.7 the section to read first and §37 the
locked-decision table. Strictly sequential, same as v2.0/v3.0 — each RFC
depends on all lower-numbered RFCs.

> ⚠️ **v4.0 is not an additive release.** `/ots` loses its argument and infers
> the caller from a bound Discord profile, which makes the `players`↔Discord
> binding an **authorization boundary**, not bookkeeping. Break-glass
> (redeploying the previous `bot.py`) restores `/ots <name>` **and the scouting
> leak with it** — accept that trade knowingly, not under pressure.

| # | RFC | Features | Complexity | Status |
|---|-----|----------|-----------|--------|
| **011** ✅ | [Ranking Schema: Profiles, Seasons, Tiers & Frozen Results](RFC-011-Ranking-Schema.md) | F38–F50, F66, F67, + DDL halves of F60/F69/F70 | Medium | ✅ Complete and **live** 2026-08-16 — schema-only; two-pass idempotency verified fresh, v2.0/v3.0-seeded, and against real synced data; F49's anon/service-key matrix proven through real PostgREST locally, then confirmed on the live project. Delivered by `db push` after the migration cutover, not hand-applied |
| **012** ✅ | [Points Engine & Sync Freeze](RFC-012-Points-Engine-And-Sync-Freeze.md) | F51–F57, F68, F72, F74 | High | ✅ Complete (Round 4, 2026-08-17) — `points.ts`/`mapping.ts`/`index.ts` shipped, 35/35 Deno tests green, the staged live group-stage walkthrough (§10.2) ran against a real Challonge tournament (`18374775`) synced through a local Supabase stack (F68's group-stage boundary held, raw `/tournaments/{id}.json` body captured, plus F55/F56/F57/F67/F72/F74 all live-confirmed), and Round 4 deployed `challonge-sync` to the actual hosted Supabase project and confirmed it with a live trigger against a real production tournament (`Open Swiss 2`, id 3): `{"status":"ok","participants_synced":14,"matches_synced":35,"freeze":{"status":"no_season",...}}` — the expected F55 outcome for a pre-RFC-011 tournament with no season. See the RFC's Round 4 Completion record for full evidence |
| **013** ✅ | [Identity Binding, `/ots` Refactor & Debug Lookup](RFC-013-Identity-Binding-And-OTS-Refactor.md) | F58–F61, F69 (cmd), F71, F76, F77, F78 | High | ✅ Complete (Round 2, 2026-08-18) — full in-guild verification against the real Discord bot/guild (local Supabase for writes): all nine `/ots` statuses, every F58/F59/F60/F61/F71 branch of `/link-organizer` (including F60's forward auto-link trigger), `/unlink`'s full round-trip, boot validation, and the release's security-gate pair — **E2E 25** (`/ots` truly takes no argument) and **E2E 29** (`/ots-organizer`/`/link-organizer` refused for *and* invisible to a non-organizer, confirmed on a real second account) — all `PASS`. Deployed to production the same day: `main` fast-forwarded with RFC-012+013, pushed, `./deploy.sh` run on the VM, service confirmed `active (running)`. One item explicitly not exercised: the DMs-closed fallback (low risk — code path unchanged from v3.0). See the RFC's Round 2 Completion record for full evidence |
| **014** | [Ranking Read Commands, Runbook & Release](RFC-014-Ranking-Read-Commands-And-Release.md) | F62–F65, F70, F73, F75 | Medium | 📝 Draft |

**Nothing is blocked.** Every decision this design needs is in PRD §37, and
Step 0 (the live Challonge `final_rank` verification, F54/F74) completed
2026-07-31 — **do not re-derive those facts from first principles.**

### Key v4.0 decisions locked (PRD §37 is authoritative)

- **Points are a fixed placement table × a tier multiplier** — 100/70/50/30/15/5,
  bucket edges at 1/2/3/5/9/17. Aligned to single-elim elimination rounds so
  Challonge's tied ranks pay their members equally. **Not** a linear formula.
- **Event weight is a `tournament_tiers` lookup**, and frozen results snapshot
  the **resolved multiplier**, never `tier_id` — so repricing a tier never
  restates history.
- **The freeze lives in the Edge Function** (TypeScript), because that is where
  `final_rank` arrives.
- **Completion is never derived from cached matches alone** — a conditional
  third Challonge call confirms it (F68). This **amends** the flat "exactly 2
  calls" invariant in RULES §18 / PRD §21, which RFC-012 must reword.
- **The default freeze is one-way**; corrections require an explicit
  `refreeze: true` flag, recorded via `frozen_at` + `freeze_count`.
- **The bracket, not the roster, decides who earned a result** —
  `(tournament_id, challonge_participant_id)`, `player_id` nullable.
- **Binding is organizer-only, one-time per person**, with forward auto-link by
  normalized name. **No self-service claim command.**
- **`/ots` takes no argument**; typed-name lookup survives only as
  `/ots-organizer`, a separate organizer-gated command — **never** an
  optional argument on `/ots` (an optional parameter puts the leak one faulty
  conditional away from every player; a separate command fails closed).
- **Authorization is a single `ORGANIZER_DISCORD_ID`** plus
  `default_member_permissions`. No Discord role model.
- **Season-points ties break on turnout first**, then best finish.
- **Two new env vars**, both non-secret: `ORGANIZER_DISCORD_ID` (RFC-013) and
  `RANKING_CHANNEL_ID` (RFC-014).
- **Command and parameter names are English; every user-facing string stays
  French** *(decided 2026-08-16, superseding the PRD's French working names)*.
  The full surface: `/ots`, `/ots-organizer`, `/link-organizer`, `/unlink`,
  `/standings`, `/profile`, with parameters `name`, `user`, `confirm_rebind`,
  `confirm`, `tournament`. Same split RULES §3 already draws — internal
  identifiers English, user-visible copy French — extended to the command
  surface. `ots` is itself English (*open team sheet*).

### Dependency table (v4.0 additions)

| RFC | Depends on | Enables |
|-----|-----------|---------|
| 011 | 001–010 | 012, 013, 014 |
| 012 | 011 | 013 (rows to backfill), 014 (rows to read) |
| 013 | 011, 012 | 014 |
| 014 | 011–013 | — (release) |

### Dependency graph (textual, v4.0)

```
011 (schema: profiles, seasons, tiers, tournament_results, views,
     auto-link trigger, RLS — ALL v4.0 DDL lands here)
 └─► 012 (points.ts + the one-way freeze in the Edge Function;
           conditional 3rd Challonge call gates completion)
       └─► 013 (binding commands + /ots refactor + /ots-organizer;
                 bot.py gains its first write path)
             └─► 014 (/standings + /profile + runbook §9 + E2E-v4 + release)
```

### Feature → RFC coverage map (v4.0)

| Feature | RFC | Feature | RFC |
|---------|-----|---------|-----|
| F38 `profiles` | 011 | F58 `/link-organizer` | 013 |
| F39 `players.profile_id` | 011 | F59 binding conflict rules | 013 |
| F40 one slot per person per event | 011 | F60 backfill (cmd) / auto-link (DDL) | 013 / 011 |
| F41 `seasons` | 011 | F61 rebind by command | 013 |
| F42 non-overlapping seasons | 011 | F62 `/standings` | 014 |
| F43 `event_date` | 011 | F63 `/profile` | 014 |
| F44 `season_id` | 011 | F64 per-tournament standings | 014 |
| F45 `tournament_tiers` + `tier_id` | 011 | F65 ranking fail-soft | 014 |
| F46 `completed_at` | 011 | F66 current-season concept | 011 |
| F47 `tournament_results` | 011 | F67 snapshot every points input | 011 |
| F48 `on delete restrict` | 011 | F68 conditional 3rd Challonge call | 012 |
| F49 RLS on new tables + views | 011 | F69 erasure (DDL / cmd) | 011 / 013 |
| F50 deliberate correction only | 011 | F70 leaderboard render (DDL / render) | 011 / 014 |
| F51 placement table × multiplier | 012 | F71 binding not scoped to active event | 013 |
| F52 pure `points.ts` | 012 | F72 two-mode freeze (`refreeze`) | 012 |
| F53 `formula_version` | 012 | F73 `E2E-CHECKLIST-v4.md` | 014 |
| F54 `final_rank` (ties + gaps) | 012 | F74 never filter on `active` | 012 |
| F55 freeze requires `season_id` | 012 | F75 ranking channel restriction | 014 |
| F56 default freeze is one-way | 012 | F76 `/ots` takes no argument | 013 |
| F57 bracket entrants without a roster row | 012 | F77 organizer authorization | 013 |
| | | F78 `/ots-organizer` | 013 |

### Roadmap notes (v4.0)

- **Critical path:** 011 → 012 → 013 is the backbone (schema → writer →
  reader/commands), the same shape as v2.0's 001 → 003 → 005 and v3.0's
  007 → 008 → 009. 014 is the closing documentation/verification/release RFC,
  mirroring 006's and 010's role exactly.
- **All v4.0 DDL lands in RFC-011**, including F60's auto-link trigger and
  F70's `season_standings` view, using PRD §40's own `F69 (DDL)` convention.
  RFC-012/013/014 own only behavior, and `schema.sql` is touched once this
  release. *(A breakdown decision, recorded in RFC-011 §2.)*
- **`bot.py` gains its first write path in RFC-013.** F58/F69 require
  `POST`/`PATCH`/`DELETE`, so PRD §31.4's "`bot.py` has no write path at all"
  stops being literally true. The locked decision to keep the freeze in
  TypeScript still stands (that is where `final_rank` arrives, and the freeze is
  a bulk write over third-party data), but the writes must go through **one
  small seam**, the write-side twin of RULES §2's read seam. *(Flagged in
  RFC-013 §3.1.)*
- **Highest technical risk, in order:**
  1. **F68** (RFC-012, the group-stage completion boundary) — in a group-stage
     tournament the final bracket's matches don't exist in `matches.json` until
     the group stage is finalized, so "all cached matches complete" fires while
     half the event is unplayed. Under F56 that freeze is **one-way**. E2E
     scenario 11 is the single most important row in the release gate.
  2. **F76** (RFC-013) — the only player-facing contract change, with no
     operational fallback: pairings can be announced by hand, team sheets cannot.
  3. **F60** (RFC-013) — the one operation that can silently move another
     player's results *and* another player's team-sheet access. Bounded to the
     current season, filtered on `profile_id is null`, and mandatorily logged.
  4. **F56/F72** (RFC-012) — two opposing write semantics in one Edge Function
     (caches refresh constantly; results are write-once). That seam is where
     bugs will live.
  5. **F70** (RFC-014) — F14's char-budget failure mode, second occurrence. An
     oversized embed description is rejected by Discord outright and presents
     as the command silently failing.
- **Two live-verified traps that must not be re-derived:** `final_rank` has
  **ties and gaps** (`1,2,3,3,5,5,5,5,9…` — ranks 4, 6, 7, 8 don't exist), and
  `participants[].active` is **false for every group-stage non-qualifier**, so
  the natural "skip inactive participants" filter drops 43 % of the field —
  precisely the players the participation floor exists to reward.
- **RFC-011's seed fixtures de-risk RFC-012** the same way RFC-007's did
  RFC-009: a season and a freezable test tournament exist before any live
  Challonge account or real season is needed. Note that freezing the test
  tournament makes it **undeletable** under F48 — deliberate, and exactly the
  trap RUNBOOK §9 has to teach.
- **Documents this release amends** (not just adds to): RULES §18 + PRD §21
  (call count, RFC-012); `E2E-CHECKLIST-v3.md` (typed-`/ots` scenarios struck,
  RFC-013); RULES §15 (the opponent-resolution entry point, RFC-013); RUNBOOK
  (new §9) and DEPLOYMENT (two env vars, RFC-014); FEATURES F25(b), whose
  "cross-tournament identities" Won't-have is deliberately **reopened**.
- **Announcing the `/ots` change is a release requirement**, as v3.0's was —
  the one item on this list that no RFC will remind anyone about. It is written
  into RFC-014's deliverables for that reason.

---

## Infrastructure — Self-hosted Supabase (RFC-015, RFC-016)

An operational RFC outside the v4.0 feature chain: move the database from the
hosted Supabase project to a self-hosted stack on the production VPS. No
`F`-numbered feature and no expected `bot.py` change; independent of RFC-014
(depends only on RFC-001–013's schema).

| # | RFC | Complexity | Status |
|---|-----|-----------|--------|
| **015** | [Self-Hosted Supabase on the Production VPS](RFC-015-Self-Hosted-Supabase.md) | Medium–High | 🚧 Cut over 2026-10-19; soak until 2026-10-26 — reboot test ✅; `/link-organizer` write path (needs an active tournament) and provider-snapshot check still open |
| **016** | [Shared Public Edge for Multiple Self-Hosted Supabase Stacks](RFC-016-Shared-Edge-For-Multiple-Supabase-Stacks.md) | Medium | 🚧 Implemented 2026-10-19 (~4 s public gap, cert preserved); edge reboot test and the first second-project join still open |

Open questions resolved 2026-10-19: backups rely on the VPS provider's
auto-backups plus a nightly `pg_dump`; a new `deploy/` folder is approved; the
hosted project soaks for 7 days after cutover. VPS capacity is confirmed
sufficient (7.8 GiB RAM, 4 vCPU, 94 GB free). **Implemented and cut over
2026-10-19**; see the RFC's Completion record for the open acceptance items.

---

## Dependency table

| RFC | Depends on (predecessors) | Enables (successors) |
|-----|---------------------------|----------------------|
| 001 | — | 002, 003, 005 |
| 002 | 001 | 003 (seed data), 006 (runbook base) |
| 003 | 001, 002 | 005 |
| 004 | 001 (contract) | 005 |
| 005 | 003, 004 | 006 |
| 006 | 001–005 | — (release) |

### Dependency graph (textual)

```
001 (DB schema/constraints/indexes/trigger)
 ├─► 002 (Studio runbook + seeded test data)
 │     └─► 003 (config + PostgREST read helper) ◄─┐
 ├─────────────────────────────────────────────────┘
 └─► 004 (pure logic: normalize + render-safety)   (mirrors 001's normalization contract)
                   │                │
       003 ────────┴──────► 005 (/ots atomic swap: live read, embed, fail-soft, cleanup)
       004 ───────────────►  │
                             └─► 006 (reliability docs, E2E gate, dry-run, deploy)
```

---

## Feature → RFC coverage map

| Feature | RFC(s) | Feature | RFC(s) |
|---------|--------|---------|--------|
| F1 tournaments table | 001 | F13 embed build | 005 |
| F2 players table | 001 | F14 render-safety | 004 (logic) → 005 (use) |
| F3 single-active index | 001 | F15 fail-soft (3 French) | 005 |
| F4 name trim+CI-unique | 001 | F16 improved not-found copy | 005 |
| F5 Studio defaults/order | 001 | F17 bounded timeout | 003 (mech) → 005 (route) |
| F6 indexed read path | 001 | F18 mandatory deferral | 005 |
| F7 create/activate | 002 | F19 env config + validation | 003 |
| F8 two-step switch | 002 | F20 pre-event pre-flight | 006 |
| F9 player CRUD | 002 | F21 keep-alive (optional) | 006 |
| F10 20-player fast setup | 002 (recipe) → 006 (timed) | F22 break-glass + degradation | 003/005 (code) → 006 (docs) |
| F11 live Supabase read | 005 | F23 PostgREST over aiohttp | 003 |
| F12 trimmed CI lookup | 004 (logic) → 005 (integrate) | F24 migration/cleanup | 005 (code) → 006 (backup docs) |
| | | F25 out-of-scope (a–g) | — (not built) |

---

## Roadmap notes

- **Critical path:** 001 → 003 → 005 is the backbone (data → access → command). 002
  and 004 are prerequisites that slot in without extending the critical path (002
  supplies test data; 004 supplies the pure functions 005 wires in).
- **Highest technical risk:** **F11** (RFC-005, the sole command-path refactor) and
  **F14** (RFC-004, char-accounting + fence escaping). RFC-004 deliberately precedes
  RFC-005 to de-risk F14 in isolation with unit tests.
- **Release gates (RULES §8/§9):** the RFC-004 `unittest` suite must be green, and the
  RFC-006 E2E in-guild checklist + timed 20-player dry-run must pass, before the
  RFC-006 deploy. Zero player-facing regression vs. v1 is non-negotiable (PRD §6/G3).
- **Locked decisions honored throughout:** DB-level single-active + CI-unique;
  service key worker-only; raw PostgREST over `aiohttp` (no `supabase-py`); team text
  trusted-as-is but render-hardened; improved not-found copy. (PRD §11 / RULES.)

## Tracked follow-ups

- **`CLAUDE.md`'s "What this is" / "Key mechanics" sections described the v2.0
  `/ots` contract (arbitrary-name lookup) — flagged during RFC-010.
  ✅ Resolved 2026-07-31.** RFC-009 changed `/ots`'s argument meaning to
  "your own username → your current opponent's OTS" (an intentional,
  confirmed one-time break, PRD §17/§24 item 4), but `CLAUDE.md` (last
  touched by RFC-006, per `git log -- CLAUDE.md`) was never updated to match
  — it documented `fetch_active_player` as the live `/ots` read path and
  didn't mention `fetch_current_opponent`, the Challonge cache tables, or the
  v3.0 fail-soft outcomes at all. RFC-010's own file list
  (`knowledge/RUNBOOK.md`, `knowledge/DEPLOYMENT.md`,
  `knowledge/E2E-CHECKLIST-v3.md`, `.claude/RULES.md`, `bot.py`) didn't
  include `CLAUDE.md`, so that RFC didn't fix it. **Fixed 2026-07-31**, right
  after the v3.0 sign-off: "What this is" and "Key mechanics" now describe
  `fetch_current_opponent` and its seven statuses; a new "Key mechanics
  (`challonge-sync` Edge Function)" section was added; "Planned direction
  (v2.0)" became a "Release history" plus a draft-marked v4.0 section; and the
  group-stage/final-bracket dual-id trap is called out explicitly so the next
  reader doesn't reduce the candidate set back to a single id. A convention was
  also added — update all four status trackers (the RFC's Completion record,
  `RFCS.md`, `PRD.md`, `CLAUDE.md`) on release — so this drift doesn't recur.
  *(Surfaced during RFC-010, 2026-07-20; resolved 2026-07-31.)*

- **RLS enablement on `tournaments` / `players` — owner: RFC-003. ✅ Resolved
  2026-07-18.** RFC-001 creates the tables but deliberately scopes RLS *out* (the
  worker's service key bypasses RLS anyway). However, Supabase grants the `anon`
  role default SELECT on public-schema tables unless RLS is enabled, and PRD §6
  states tables must not be exposed via a public anon endpoint without RLS. Assigned
  to **RFC-003** (the config/data-access seam) and closed there: `schema.sql` now
  enables RLS on both tables with a deny-by-default posture (no policies — only the
  service key needs access), added during RFC-003's round 2 fix after its own
  reviewer flagged the gap as blocking. *(Surfaced during RFC-001 review, Round 1;
  fixed during RFC-003 review, Round 2 — see RFC-003 § Completion record.)*

- **`.claude/agents/{coder,planner,reviewer,explorer,tester}.md` and the
  `/rfc` skill were templated for an unrelated Flutter/Supabase project
  ("Atelier Hub") — flagged during RFC-007. ✅ Resolved 2026-08-16.** They
  referenced `flutter analyze`, `build_runner`, `ccc search`,
  Dart/`freezed`/Riverpod conventions, `supabase/migrations/`, routes/widgets,
  `.claude/CLAUDE.md` and `.claude/rules/` — none of which exist here. RFC-007
  was implemented directly (no orchestration) to avoid the mismatch, and
  RFC-008–010 hit the same issue. **Rewritten 2026-08-16 for this repo's actual
  stack** ahead of RFC-011: Python/discord.py + hand-applied `schema.sql`
  (no migrations folder) + the Deno Edge Function; `python -m unittest test_bot`
  (with the venv caveat) and `deno test` as the verification commands;
  `CLAUDE.md` at the repo root and `.claude/RULES.md` as a single file; `grep`
  and `Read` instead of `ccc`. The reviewer's dimensions were re-cut around
  what actually breaks here (fail-soft/never-raise, render safety, schema
  idempotency, RLS including `security_invoker` on views, untested pure logic).
  Two structural changes beyond translation: the four `.claude/commands/rfc/*`
  slash commands are now **thin wrappers pointing at the agent definitions**
  rather than second copies of the same instructions, and the orchestrator
  gained a **mandatory plan-approval gate** (Phase 0.5) so the flow matches the
  two-phase approach every `implementation-prompt-RFC-*.md` already mandates.
  *(Surfaced during RFC-007, 2026-07-20; resolved 2026-08-16.)*

- **`RUNBOOK.md` §1's "create a tournament via Studio's Table Editor" procedure
  is now stale — owner: RFC-014. Open, tracked here pending that RFC.**
  RFC-011 made `tournaments.tier_id` `not null` with no default, but §1 still
  documents filling only `name` and leaving every other field at default; doing
  that against the live schema now fails with a not-null violation on
  `tier_id`. Until RFC-014 rewrites §1, any organizer creating a tournament
  through the Table Editor must manually pick a `tier_id` (e.g. Hebdo) at
  insert time. RFC-011 could not fix this itself — `RUNBOOK.md` belongs to
  RFC-014 — so it is disclosed here and in RFC-011's own Completion record
  instead. *(Surfaced during RFC-011 review, Round 2, 2026-08-16; owed to
  RFC-014.)*

## Structural decisions (low-risk defaults, flagged in the RFCs)

- **`schema.sql` at repo root** (operational DDL asset, not a `knowledge/` doc; no new
  Python folder — RULES §2). *(RFC-001)*
- **Tests in a single root-level `test_bot.py` using stdlib `unittest`** — no new
  folder, no new dependency (RULES §1/§2/§8). *(RFC-004)*
- **`if __name__ == "__main__":` guard** added so `import bot` is side-effect-free for
  testing. *(RFC-004, used by RFC-005)*

Each is a minimal, reversible choice; if the maintainer prefers otherwise it's a
trivial move noted in the relevant RFC.

---

## Schema delivery moved to migrations (2026-08-16)

**A locked decision was reopened and replaced, with explicit approval.** The
hand-applied, idempotent root `schema.sql` — the contract since RFC-001 — is
retired. The schema now lives in `supabase/migrations/` and is applied with
`supabase db push` (production) or `supabase db reset` (local, which also runs
`supabase/seed.sql`). `schema.sql` is a redirect stub and **must not be
applied**. Recorded in `.claude/RULES.md` §25 and `CLAUDE.md`.

**Timing:** done immediately after RFC-011 was verified and *before* it reached
production, so RFC-011's DDL became the first migration ever pushed rather than
the last thing pasted into the SQL editor.

**What forced it.** Applying RFC-011 to a database holding real synced Challonge
data aborted under `ON_ERROR_STOP=1` at RFC-007's participant seed: its
placeholder ids collided with synced rows on `lower(ingame_name)`, a conflict
its `on conflict` target did not cover, and the apply died **before creating a
single v4.0 object**. Three prior verification passes missed it because a
container seeded only from `schema.sql` can never reproduce the collision. The
root cause was test fixtures living inside the applied schema — which the split
now prevents structurally.

**Two further defects surfaced during the cutover, both pre-existing:**

1. **The schema never granted anything**, relying on a Supabase platform default
   that no longer holds. A current CLI provisions `public` with no `SELECT` for
   the PostgREST roles, so rebuilding from the schema produced a database
   returning HTTP 403 to the bot's service key while RLS and the key were both
   correct. Production predates the change and still carries the old implicit
   grants, so it was only ever *accidentally* working. Fixed by
   `..._explicit_service_role_grants.sql`: `service_role` gets DML and sequence
   usage, `anon`/`authenticated` get nothing, explicitly.
2. **Fixtures could not survive the reordering.** Under the monolith the
   tournament fixture ran *before* the v4.0 block added the not-null `tier_id`;
   with migrations all DDL precedes all seed, so the fixture had to supply
   `tier_id` — the same trap that makes RUNBOOK §1 stale.

**Live as of 2026-08-16.** Production was baselined with `supabase migration
repair --status applied` and RFC-011's DDL delivered by `supabase db push`;
the operator reports the anon/service-key matrix sane and `/ots` intact. The
cutover is complete, not merely prepared.

**Tracked follow-up — owner: RFC-014.** RUNBOOK carries a banner for both stale
procedures (hand-applying the schema, and §1's tournament creation) but its nine
`schema.sql` references still need rewriting. Historical RFCs, plans and
implementation prompts deliberately keep their original wording.
