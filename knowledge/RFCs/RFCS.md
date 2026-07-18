# RFCS — OTS Bot Backoffice v2.0 (implementation roadmap)

Master index for the RFC set that delivers the Supabase-backed backoffice
(`knowledge/PRD.md` v2, `knowledge/FEATURES.md`, `.claude/RULES.md`).

> **Implementation is strictly sequential.** Each RFC is fully implementable only
> after **all** lower-numbered RFCs are complete. There is no parallel work. Follow
> the `implementation-prompt-RFC-00N.md` two-phase prompt for each (plan → approval →
> implement).

---

## RFCs in implementation order

| # | RFC | Features | Complexity | PRD §9 day |
|---|-----|----------|-----------|-----------|
| **001** | [Supabase Schema, Constraints, Indexes & Trigger](RFC-001-Supabase-Schema.md) | F1, F2, F3, F4, F5, F6 | Medium | Day 1 |
| **002** | [Organizer Runbook (Studio Workflows)](RFC-002-Organizer-Runbook.md) | F7, F8, F9, F10 | Low–Med | Day 2 |
| **003** | [Configuration & PostgREST Data-Access Seam](RFC-003-Config-And-Data-Access.md) | F19, F23, F17(mech) | Medium | Day 2 |
| **004** | [Pure Logic: Normalization & Render-Safety](RFC-004-Pure-Logic-Normalization-Render-Safety.md) | F12(logic), F14 | High | Day 3–4 |
| **005** | [`/ots` Command Refactor: Live Read & Fail-Soft](RFC-005-OTS-Command-Refactor.md) | F11, F13, F15, F16, F17(route), F18, F22(code), F24(code) | High | Day 3–4 |
| **006** | [Reliability, Contingency & Release](RFC-006-Reliability-And-Release.md) | F20, F21, F22(docs), F24(backup), E2E, dry-run, deploy | Medium | Day 5–7 |

**Won't-have (F25 a–g)** — not covered by any RFC by design (RULES §9): multiple
active tournaments, cross-tournament identities, custom web app/auth/roles, player
self-submission, pairings / hidden-until-reveal, pokepaste scraping, content
validation, caching, multi-guild, non-French localization.

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

## Structural decisions (low-risk defaults, flagged in the RFCs)

- **`schema.sql` at repo root** (operational DDL asset, not a `knowledge/` doc; no new
  Python folder — RULES §2). *(RFC-001)*
- **Tests in a single root-level `test_bot.py` using stdlib `unittest`** — no new
  folder, no new dependency (RULES §1/§2/§8). *(RFC-004)*
- **`if __name__ == "__main__":` guard** added so `import bot` is side-effect-free for
  testing. *(RFC-004, used by RFC-005)*

Each is a minimal, reversible choice; if the maintainer prefers otherwise it's a
trivial move noted in the relevant RFC.
