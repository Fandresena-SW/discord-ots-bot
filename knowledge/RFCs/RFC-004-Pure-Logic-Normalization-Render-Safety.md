# RFC-004 — Pure Logic: Input Normalization & Render-Safety

- **Status:** ✅ Complete (2026-07-18, 1 review round — see [§ Completion record](#completion-record))
- **Implementation order:** 4 of 6
- **Complexity:** High (correctness-critical char-accounting + escaping)
- **Features covered:** F12 (normalization *logic*), F14 (render-safety)
- **PRD refs:** §5.3, §5.1, §11.4, §11.8, §9 (Day 3–4)
- **Builds upon:** RFC-001 (defines the normalization contract to mirror)
- **Built upon by:** RFC-005 (command handler calls these pure functions)

---

## 1. Summary

Extract the two **pure, correctness-critical** pieces of the read path into small
standalone functions with unit tests, *before* wiring them into the command
handler: (1) **input normalization** — `trim()` then `lower()` — matching RFC-001's
stored-name index exactly (F12); and (2) **render-safety on `team_text`** — code-fence
neutralization + truncation to Discord's 4096-char description limit with a French
marker (F14). These are pure functions of their inputs, so they are cheaply and
deterministically testable (RULES §8 explicitly invites this), and F14 is one of the
two highest-risk items in the release (FEATURES §build-order) — isolating it de-risks
RFC-005.

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F12** (logic) | Apply `trim()` then `lower()` to the user's input so it matches the stored normalized `ingame_name` (RFC-001 F4). Same-case/whitespace variants resolve identically. |
| **F14** | Output hardening (not content validation): **neutralize** fence-breaking sequences (literal ` ``` `) so they can't corrupt the code block; **truncate** so the finished description stays within Discord's 4096-char limit (accounting for the code-fence characters) with a clear **French** truncation marker. |

## 3. Technical approach

Add two module-level pure functions to `bot.py` (single-file ethos — RULES §2). They
take strings and return strings; no I/O, no globals, no Discord objects.

### 3.1 `normalize_name` (F12)

```python
def normalize_name(raw: str) -> str:
    """Normalize user input to match the stored, indexed ingame_name
    (RFC-001: BEFORE-trigger btrim + lower(ingame_name) unique index).
    Must stay in lockstep with the DB index — change one, change both."""
    return raw.strip().lower()
```

- Uses `str.strip()` (leading/trailing Unicode whitespace) + `str.lower()`.
- Preserves internal whitespace (mirrors `btrim`, RFC-001 F4 edge case).
- The result is what RFC-005 passes to `fetch_active_player` (RFC-003).

### 3.2 `render_team_text` (F14)

```python
def render_team_text(team_text: str) -> str:
    """Return a Discord embed description: `team_text` wrapped in a fenced
    code block, hardened so it (a) cannot break out of the fence and
    (b) never exceeds Discord's 4096-char description limit."""
```

Requirements and algorithm:

1. **Fence neutralization.** Any literal triple-backtick (` ``` `) inside
   `team_text` can close the code block early. Neutralize so the content stays
   inside the fence and renders visibly. Chosen approach: insert a zero-width space
   (`​`) between backticks in any run of ≥3 (e.g. ` ``` ` → `` `​`​` ``) — this
   preserves the visible characters while breaking the fence token. *(Alternative
   considered: collapse runs to a placeholder; rejected — alters visible content
   more than necessary. Content is trusted (§11.4); we harden rendering only.)*
   - Handle runs longer than three backticks and multiple runs.

2. **Assemble the fenced block.** Description = `"```\n" + hardened + "\n```"`.

3. **Budget-aware truncation.** Discord's embed **description limit is 4096 chars**.
   The fence wrapper (opening ` ```\n `, closing `\n``` `) and the French truncation
   marker all consume budget. Compute the max room for content so the **final
   assembled string ≤ 4096**, then, if the hardened content exceeds it, cut the
   content and append the marker, then close the fence. The marker is French, e.g.:
   `\n… (équipe tronquée)`.
   - **Off-by-one discipline:** account for wrapper length + marker length + the
     newline(s) exactly. Getting this wrong lets Discord reject the message — the
     precise failure F14 exists to prevent.
   - Truncate on the hardened string (so neutralization can't re-expand length past
     the cut).
   - **Empty `team_text`** → a valid (possibly empty-bodied) fenced block, never a
     crash (RFC-001 makes `team_text` NOT NULL, but defend anyway).
   - **Exactly at the limit** → no truncation, no marker.

Keep both functions boring and readable; add short dev comments only where the
char-accounting is subtle (RULES §3).

### 3.3 Tests (RULES §8)

Add **`test_bot.py` at repo root** using the **stdlib `unittest`** module — **no new
folder, no new dependency** (RULES §1/§2/§8). Import the two functions from `bot.py`.

> **Import-safety note:** `bot.py` currently executes `client.run(TOKEN)` and reads
> env at import time, so importing it in a test would try to start the bot / require
> config. RFC-005 will guard the entrypoint behind `if __name__ == "__main__":`. For
> this RFC, if importing `bot.py` is not yet safe, either (a) land the
> `__main__` guard as part of this RFC (small, safe, and needed anyway), or (b)
> keep the two pure functions trivially importable. **Recommended: add the
> `if __name__ == "__main__":` guard now** so `import bot` is side-effect-free —
> flag it as a deliberate, minimal deviation enabling tests.

Test matrix:
- **normalize_name:** `"NAME"`, `"name"`, `"NaMe"` → same; `"  name  "` → `"name"`;
  internal spaces preserved (`"my name"` → `"my name"`); empty/whitespace-only input.
- **render_team_text:** ordinary short set (unchanged but fenced); text containing
  ` ``` ` renders without breaking out; text with runs of 4+ backticks and multiple
  runs; oversized text (> 4096) → truncated, marker present, **final length ≤ 4096**;
  text exactly at the limit → no marker; empty text → valid block.

## 4. Data models / schema changes

None. Pure functions + tests.

## 5. Interfaces exposed

- `normalize_name(raw: str) -> str` — consumed by RFC-005 before `fetch_active_player`.
- `render_team_text(team_text: str) -> str` — consumed by RFC-005 to build the embed
  description (F13).
- `test_bot.py` — runnable via `python -m unittest test_bot` (no extra deps).

## 6. Acceptance criteria

- [ ] **F12:** `/ots NAME`, `/ots name`, `/ots NaMe` normalize identically; `"  name  "` normalizes to `"name"`; internal whitespace preserved. (Verified by unit tests; end-to-end resolution proven in RFC-005.)
- [ ] **F14:** Oversized `team_text` yields a truncated, valid description whose **total length ≤ 4096** including fence + marker.
- [ ] **F14:** `team_text` containing ` ``` ` (and 4+ runs, multiple runs) renders inside the code block without breaking out.
- [ ] **F14:** Empty `team_text` and exactly-at-limit `team_text` both produce valid output (no marker at exact limit).
- [ ] `test_bot.py` runs green via `python -m unittest` with **no new dependency** and **no new folder**.
- [ ] `import bot` is side-effect-free (entrypoint guarded) so tests can import the functions.

## 7. Implementation details

- **File:** `bot.py` (two functions) + `test_bot.py` (repo root, `unittest`).
- **Constants:** define `DISCORD_DESC_LIMIT = 4096` and the French marker as module
  constants (`UPPER_SNAKE`, RULES §3).
- **Entrypoint guard:** wrap `client.run(TOKEN)` (and any boot-time side effects that
  would fire on import) in `if __name__ == "__main__":` — minimal, enables testing,
  needed by RFC-005 anyway.
- Do **not** add content validation/normalization of `team_text` (locked §11.4) —
  neutralization + truncation only.

## 8. Edge cases & risks

- **Off-by-one in the budget** (wrapper + marker + newlines) — the core risk; cover
  with a test asserting exact `len(result) <= 4096` on oversized input.
- **Backtick run longer than 3** and **multiple runs** — neutralize each.
- **Neutralization increasing length** (zero-width spaces add bytes/chars) — truncate
  *after* neutralizing, and count the added chars against the budget.
- **Unicode whitespace / width** — `strip()` handles Unicode whitespace; treat the
  4096 limit as a character count (Discord counts UTF-16-ish, but char-count with a
  safety margin in the marker is the pragmatic, documented choice — note it).
- **Risk:** normalization drift from RFC-001. Mitigation: comment linking the
  function to the DB index; RFC-005 uses this function, not ad-hoc `.lower()`.

## 9. Applicable rules (RULES.md)

- §2 (functions live in `bot.py`; single file). §3 (PEP8, type hints, `UPPER_SNAKE`
  constants, French user-facing marker, sparse comments). §4 (normalization mirrors
  the DB index exactly; content trusted, rendering hardened). §8 (unit-test the pure
  functions; no test infra beyond `unittest`). §1 (no new dependency). §10 (no stubs;
  flag the `__main__`-guard deviation).

## 10. Testing strategy

Stdlib `unittest` in `test_bot.py`, covering the matrix in §3.3. This is the primary
automated gate in the repo; it must pass before RFC-005 integrates the functions and
before deploy (RULES §8/§9).

---

## Completion record

- **Status:** ✅ Complete — **2026-07-18**, via `/rfc 004` orchestration (explore →
  plan → 1 implementation round → 1 review round, no blocking issues).
- **Delivered:**
  - `bot.py` — added `DISCORD_DESC_LIMIT` and `TRUNCATION_MARKER` (French) module
    constants; added `normalize_name(raw)` (`strip()` + `lower()`, docstring
    explicitly linking it to RFC-001's `btrim`/`lower(ingame_name)` index —
    "change one, change both"); added `render_team_text(team_text)` (neutralizes
    any run of ≥3 backticks via zero-width-space insertion, assembles the fenced
    block, then truncates on the *hardened* content so the final string never
    exceeds 4096 chars, appending the French marker only when truncation actually
    occurs). Promoted the pre-existing local `import re` (from `fetch_pokepaste`)
    to module scope for reuse. The `if __name__ == "__main__":` guard needed for
    import-safety was already in place from RFC-003 — no change required.
  - `test_bot.py` (new, repo root) — stdlib `unittest`, 12 tests covering the full
    RFC §3.3/§6 matrix (normalize: case-insensitivity, trim, internal-whitespace
    preservation, empty/whitespace-only, Unicode whitespace; render: ordinary
    text, single triple-backtick, 4+ and multiple backtick runs, oversized input
    truncated with marker and `len(result) <= 4096`, exactly-at-limit with no
    marker, empty input). Sets four dummy env vars via `os.environ.setdefault(...)`
    before `import bot` so the import stays side-effect-free. All 12 pass via both
    `python -m unittest test_bot` and `python -m unittest discover`. No new
    dependency, no new folder (`requirements.txt` untouched).
- **Verification:** `python -m py_compile bot.py test_bot.py` clean; full test
  suite green; manual boundary-case check confirming a backtick run straddling the
  truncation cut still yields no reintroduced triple-backtick and `len(result) <=
  4096`.
- **Round 1 reviewer verdict:** `BLOCKING ISSUES: None` — no fix round needed.
- **Deferred, non-blocking (reviewer "Should" items, not release gates):**
  - `CLAUDE.md` still described `bot.py` as "~117 lines"; stale after cumulative
    growth across RFC-001/003/004 (now 279 lines). Closed alongside this
    completion record — see `CLAUDE.md`'s "Stack & layout" section.
  - RFC-004's own acceptance-criteria checkboxes in §6 are left unchecked, matching
    this repo's established convention (see RFC-003): completion is recorded here,
    not by retroactively ticking boxes.
- **Does not touch** the `/ots` command handler — these two pure functions are not
  yet wired into the live read path; that integration is RFC-005's explicit scope.
