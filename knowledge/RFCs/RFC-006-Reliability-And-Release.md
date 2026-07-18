# RFC-006 — Reliability, Contingency & Release

- **Status:** 🟡 Round 1 implemented — docs authored & sanity-tested; **live
  E2E execution, timed dry-run, and deploy verification are explicitly
  pending** (operational steps requiring the live guild / Studio / VM — see
  [§ Completion record](#completion-record)).
- **Implementation order:** 6 of 6 (final)
- **Complexity:** Medium
- **Features covered:** F20, F21 (optional/Could), F22 (docs/verification), F24 (backup docs); plus the E2E checklist, timed dry-run, and deploy
- **PRD refs:** §12, §6, §10, §8, §9 (Day 5–7), §13
- **Builds upon:** RFC-001…005 (a complete, working v2 bot + runbook)
- **Built upon by:** — (release)

---

## 1. Summary

Close out the release: harden and document the **live-event reliability** story that
the backend swap makes necessary (Supabase becomes a single point of failure), then
**verify and ship**. Concretely: add the **pre-event pre-flight ritual** (F20) and the
**break-glass / graceful-degradation** procedures + **roster backup** guidance (F22,
F24-backup) to the organizer runbook; optionally add a **keep-alive ping** (F21, Could,
build only if pre-flight proves insufficient); execute the **E2E in-guild checklist**
(the primary release gate, PRD §9 Day 5); run the **timed 20-player dry-run** (G2/F10,
Day 6); and **deploy** to the Procfile worker and monitor first live use (Day 7).

This RFC is mostly operational/documentation + verification; the only *possible* code
is the optional keep-alive (F21), which should be skipped unless needed.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F20** | Pre-event pre-flight: confirm the Supabase project isn't paused (free-tier ~7-day inactivity), the correct tournament is active, and a test `/ots` returns a known player. |
| **F22** (docs) | Document the break-glass fallback (redeploy v1 hardcoded-map from git history for a single event) + confirm graceful degradation (fail-soft French + server-side log, already in RFC-003/005). |
| **F24** (backup) | Document the roster **backup of record** (organizer's source notes and/or Studio CSV export). |
| **F21** (Could) | Optional lightweight scheduled keep-alive ping to prevent free-tier pause around events. **Build only if F20 proves insufficient.** |
| — | **E2E checklist** (release gate), **timed dry-run** (G2), **deploy + monitor**. |

## 3. Technical approach

### 3.1 Runbook additions (F20, F22, F24-backup)

Extend **`knowledge/RUNBOOK.md`** (started in RFC-002) with three sections:

1. **Pre-event pre-flight (P0 operational, F20):** a checklist run before every event:
   - Open Studio; confirm the project is **active/not paused** (resume if paused).
   - Confirm exactly one, correct tournament has `is_active = true`.
   - Run a test `/ots <known player>` in the guild and confirm a correct embed.
   - Record this as a numbered checklist the organizer ticks through.

2. **Contingency / break-glass (F22):**
   - **Graceful degradation** (already implemented, RFC-003/005): during an outage the
     bot fails soft in French and logs server-side; verify the operator log appears.
   - **Break-glass:** how to redeploy the **v1 hardcoded-map** code for a single event
     if Supabase is down and can't be resumed in time. Include the exact git
     reference/commit range where the v1 `USERNAME_URLS` + `fetch_pokepaste` path
     lives (it was deleted from the working tree in RFC-005 but preserved in history),
     and the steps to check it out, populate the map from the backup roster, and
     deploy to the worker.

3. **Roster backup of record (F24):**
   - The roster lives only in Supabase; document that the **backup** is the
     organizer's source notes and/or a **Studio CSV export** of the `players` table,
     and when to refresh it (e.g. after finalizing a roster, before an event).

### 3.2 Optional keep-alive (F21 — Could, conditional)

Only if the pre-flight proves insufficient in practice. Options, cheapest first:
- An external scheduler (e.g. the hosting platform's scheduled job / a cron pinger)
  hitting a trivial PostgREST read on a cadence within the ~7-day window.
- **Prefer not adding code/deps to `bot.py`** (RULES §1/§2). If a scheduler is
  external, no repo change is needed beyond documentation. If in-process scheduling is
  unavoidable, justify it explicitly against a PRD requirement before adding anything.
- Document that this is optional and off by default.

### 3.3 E2E in-guild checklist (release gate, PRD §9 Day 5 / RULES §8)

Author the checklist (in `knowledge/RUNBOOK.md` or a `knowledge/E2E-CHECKLIST.md`) and
**execute every item**, recording pass/fail:
- Happy path — player **with** `pokepaste_url` (title links).
- Happy path — player **without** URL (renders, no link).
- **Not found** — French, scoped-to-current-tournament copy (F16).
- **No active tournament** — French message (F15b).
- **Supabase down / timeout** — French unavailable message + **operator log present**
  (F15c/F22).
- **DMs-closed fallback** — ephemeral in-channel embed (`discord.Forbidden`).
- **Oversized `team_text`** — truncated valid embed with French marker (F14).
- **Backtick-containing `team_text`** — renders inside the code block, no break-out (F14).
- Case/whitespace variants resolve to the same player (F12).

All items must pass before deploy (RULES §9 quality thresholds).

### 3.4 Timed dry-run (G2/F10, Day 6)

Execute a realistic **20-player setup in Studio, timed**, targeting **< 5 minutes**
from the organizer's notes app. Record the actual time; if over, apply the
column-ordering/paste-recipe fixes from RFC-001 F5 / RFC-002 F10 and re-time. Rehearse
the two-step activation switch (F8) and the §12 resume/contingency.

### 3.5 Deploy & monitor (Day 7)

- Deploy to the **Procfile worker** (`worker: python3 bot.py`) — unchanged target.
- Confirm the new env vars (`SUPABASE_URL`, `SUPABASE_SERVICE_KEY`) are set in the
  production environment (worker-only; not committed).
- Confirm startup env validation passes and the heartbeat + any Supabase error logs
  appear as expected.
- Monitor first live use; keep buffer for fixes.

## 4. Data models / schema changes

None.

## 5. Interfaces exposed

- Final **`knowledge/RUNBOOK.md`** (pre-flight + contingency + backup) — the
  organizer's operating manual.
- **E2E checklist** artifact with recorded results — the release-gate evidence.
- (Optional) documented keep-alive mechanism.

## 6. Acceptance criteria

- [ ] **F20:** A documented pre-flight checklist exists in the runbook and was rehearsed (Day 6); a paused project scenario includes the resume step.
- [ ] **F22:** Break-glass procedure documented (git reference to the v1 path + redeploy steps); graceful degradation verified live (friendly French + operator log, no crash).
- [ ] **F24 (backup):** Roster backup-of-record path (source notes and/or Studio CSV export) documented, with refresh guidance.
- [ ] **F21:** Either explicitly **not built** (pre-flight sufficient) and noted as deferred, or, if built, the project verifiably does not pause across an event window.
- [ ] **E2E checklist:** every item executed and **passing** (zero player-facing regressions vs. v1 — PRD G3/§8).
- [ ] **Dry-run:** 20-player Studio setup timed **< 5 minutes** (G2); two-step switch rehearsed.
- [ ] **Deploy:** running on the production worker by **2026-07-25**; env vars set worker-only; startup validation passes; logs healthy on first live use (G5/G6).

## 7. Implementation details

- **Files:** `knowledge/RUNBOOK.md` (extend) and/or `knowledge/E2E-CHECKLIST.md`.
  No `bot.py` change expected unless F21 is built (and even then, prefer external).
- **Git reference for break-glass:** capture the commit hash where the v1
  `USERNAME_URLS`/`fetch_pokepaste` path last existed (pre-RFC-005 deletion) so
  recovery is one `git checkout`/cherry-pick away.
- **No new dependencies** for the base RFC (RULES §1).

## 8. Edge cases & risks

- **Free-tier pause mid-event** — the headline reliability risk (PRD §6/§10/§12).
  Pre-flight (F20) is the primary mitigation; break-glass (F22) is the backstop.
- **Break-glass roster staleness** — the CSV/notes backup must be current; document
  when to refresh it.
- **Deploy-time missing env vars** — caught by RFC-003's startup validation; verify in
  the production environment specifically.
- **Keep-alive scope creep** — resist adding in-process schedulers/deps; F21 is a
  Could and should stay minimal/external (RULES §1/§10).

## 9. Applicable rules (RULES.md)

- §2 (docs in `knowledge/`; avoid new code — F21 external-first). §1 (no new deps).
  §6/§7 (env vars worker-only; verify loud-to-operator logging live). §8 (E2E
  checklist is the primary release gate; dry-run gate). §9 (quality thresholds before
  deploy: zero regressions, all fail-soft branches, render-safety, no secret
  committed/logged, dict+scraper removed). §10 (don't build Won't-have items; keep
  docs in sync).

## 10. Testing strategy

This RFC **is** the verification stage: manual E2E execution of the full checklist in
the guild, the timed organizer dry-run, contingency rehearsal, and post-deploy
monitoring. The RFC-004 unit tests (`python -m unittest`) are re-run as a pre-deploy
sanity check. Sign-off on the E2E checklist + dry-run time is the go/no-go for deploy.

---

## Completion record

- **Status:** 🟡 Round 1 — docs + sanity check delivered; **live/manual steps
  explicitly pending**, per RULES §10 (no fabricated verification results).
- **Delivered (coder-executable, this round):**
  - `knowledge/RUNBOOK.md` — replaced the reserved §5 placeholder with three
    fully-authored sections: **§5 Pré-vol avant événement (F20)** (numbered
    checklist including the paused-project → Resume scenario), **§6
    Contingence / break-glass (F22)** (graceful-degradation verification
    steps for the organizer, plus the exact-git-reference v1 redeploy
    procedure), and **§7 Sauvegarde du roster de référence (F24-backup)**
    (source-notes + Studio CSV export, with explicit refresh timing). Also
    added an F21 keep-alive deferral note (off-by-default, external-scheduler
    first) inside §5, and updated the doc header/table of contents and
    **Références** block (added `knowledge/DEPLOYMENT.md` and
    `knowledge/E2E-CHECKLIST.md`).
  - `knowledge/E2E-CHECKLIST.md` (new) — the 9-row release-gate artifact (8
    mandated scenarios + the case/whitespace normalization check), each row
    with Scenario/Steps/Expected/Result/Notes columns, all currently
    `PENDING` (not executed by this agent — no live Discord/Studio access),
    plus a sign-off table and references.
  - **Git-reference verification:** independently confirmed by inspection
    (`git show 184216b:bot.py`, `git log --oneline`) that `USERNAME_URLS` is
    at `bot.py:72` and `fetch_pokepaste()` at `bot.py:129` in commit
    `184216b`, and that the v1 path was deleted in `a79bdfb` — matches the
    plan's cited hashes exactly; no paraphrasing.
  - **Pre-deploy sanity check:** `python -m unittest test_bot` — **12/12
    pass** (run in a fresh venv with `requirements.txt` installed, since no
    venv pre-existed in this environment).
- **Explicitly NOT done this round (operational, requires live
  guild/Studio/VM access this agent does not have — left as `PENDING`, not
  fabricated):**
  - E2E in-guild checklist execution (`knowledge/E2E-CHECKLIST.md` rows 1–9).
  - Timed 20-player Studio dry-run (G2/F10) and recording the observed time
    in RUNBOOK §4.
  - Production deployment verification (systemd status, env vars on the VM,
    `journalctl` health check) — DEPLOYMENT.md documents the deployment as
    already having happened 2026-07-18; this round did not re-verify it live.
  - F21 keep-alive: confirmed **not built** (deferred, documented
    off-by-default per RULES §1/§10) — no code change, as scoped.
- **Flag for the organizer:** before shipping, execute
  `knowledge/E2E-CHECKLIST.md` end-to-end in the guild, run the timed
  dry-run, and confirm the production VM's live status per
  `knowledge/DEPLOYMENT.md` §8–§10 — then update both documents' `PENDING`
  markers with real results/timings and flip this RFC's status to Complete.
