# RFC-004 Implementation Plan — Pure Logic: Input Normalization & Render-Safety

> **Stack note:** This project is a single-file **Python 3** Discord bot (`bot.py`),
> not a Flutter app. The standard plan skeleton (Migrations / Dart Models / Providers /
> Screens / Routing / Edge Functions) does **not** map to this RFC. Those sections are
> retained below and marked **N/A** with the reason, following the RFC-003 plan
> convention. The substantive work lives in two Python-specific sections:
> **Pure Functions & Constants** (§4) and **Tests** (§5). The coder must not invent
> Flutter/Supabase-migration artifacts for this RFC.

---

## 1. SCOPE SUMMARY

RFC-004 extracts the two **pure, correctness-critical** pieces of the read path into
standalone, module-level functions in `bot.py`, with stdlib unit tests, **before**
RFC-005 wires them into `/ots`: (a) `normalize_name(raw)` — `strip()` then `lower()`,
kept in exact lockstep with RFC-001's `lower(ingame_name)` unique index and `btrim`
trigger (F12); and (b) `render_team_text(team_text)` — code-fence neutralization plus
budget-aware truncation so the finished fenced code block never exceeds Discord's
4096-char embed-description limit, with a French truncation marker (F14). It also adds
`test_bot.py` at the repo root using stdlib `unittest` (no new dependency, no new
folder), which sets dummy env vars before importing `bot` so the import is
side-effect-free.

**Explicitly out of scope:** wiring these functions into the `/ots` handler, removing
`USERNAME_URLS`/`fetch_pokepaste`, any DB change, any content validation/rewriting of
`team_text` (locked PRD §11.4 — rendering is hardened, content is trusted), and any new
dependency or folder.

---

## 2. DATABASE MIGRATIONS

**N/A.** RFC-004 creates no migrations, tables, columns, RLS policies, indexes,
triggers, or Postgres functions (RFC-004 §4). It only **mirrors** an existing contract:
the RFC-001 `players_tournament_name_idx` unique index on `(tournament_id,
lower(ingame_name))` and the `trim_ingame_name()` trigger (`btrim` + reject empty).
`normalize_name` must apply the same `strip()`+`lower()` transform so bot-side lookups
match stored, indexed names. This is a preserved invariant, not a schema change (see
§8 Risk Areas).

---

## 3. DART MODELS

**N/A.** No Dart, no `@freezed`, no `build_runner`. Both new functions are plain
`str -> str`. No model classes are introduced (RULES §2 forbids structural layers beyond
what the single-file bot needs).

---

## 4. PURE FUNCTIONS & CONSTANTS  *(the substantive deliverable — replaces "Providers")*

All additions go in `/Volumes/Data/Perso/discord-ots-bot/bot.py`, at **module scope**,
placed **above** `_escape_ilike` (i.e. after the `intents`/`client`/`tree` block at
lines 78-80, before `fetch_pokepaste` at line 83) so the pure logic reads top-to-bottom
before the I/O helpers. Both take strings, return strings; no I/O, no globals, no
Discord objects.

### 4.1 Constants (module scope, `UPPER_SNAKE` — RULES §3)

Define near the other module constants (after the config block, ~line 62):

- `DISCORD_DESC_LIMIT = 4096` — Discord embed **description** character limit.
- `TRUNCATION_MARKER = "\n… (équipe tronquée)"` — French marker appended **inside** the
  fence when content is cut. (French user-facing text — RULES §3 / PRD §5.3.)
- Optionally a fence constant; keeping the literals `"```\n"` / `"\n```"` inline inside
  `render_team_text` is acceptable. If factored out, name it `CODE_FENCE = "```"`.

### 4.2 `normalize_name(raw: str) -> str`  (F12)

```python
def normalize_name(raw: str) -> str:
    """Normalize user input to match the stored, indexed ingame_name.

    Mirrors RFC-001 exactly: the players BEFORE-trigger btrim()s ingame_name
    and the unique index is on lower(ingame_name). Bot-side lookups must apply
    the same transform (strip + lower) or the match contract breaks.
    IMPORTANT: change this and the DB index/trigger together — never one alone.
    """
    return raw.strip().lower()
```

- `str.strip()` removes leading/trailing Unicode whitespace (mirrors `btrim`);
  **internal whitespace is preserved** (RFC-001 F4 edge case).
- Then `str.lower()`.
- Empty / whitespace-only input returns `""` — no crash; RFC-005 decides how `""`
  resolves (it will simply not match any player).

### 4.3 `render_team_text(team_text: str) -> str`  (F14)

```python
def render_team_text(team_text: str) -> str:
    """Return an embed description: team_text in a fenced code block, hardened
    so it (a) cannot break out of the fence and (b) never exceeds Discord's
    4096-char description limit (fence + marker counted). Content is trusted;
    only rendering is hardened (PRD §11.4)."""
```

**Algorithm (order is load-bearing):**

1. **Fence neutralization — do this first, on the raw content.**
   Any run of **three or more** literal backticks can close the code block early.
   Insert a zero-width space (U+200B) between every backtick in each run of >=3 so
   no three consecutive backticks survive, while all visible backticks remain:
   ```python
   hardened = re.sub(r"`{3,}", lambda m: "​".join(m.group(0)), team_text)
   ```
   - A run of 3 backticks becomes backtick, ZWSP, backtick, ZWSP, backtick
     (max 1 consecutive backtick anywhere after).
   - Handles runs of 4+ backticks and multiple independent runs (regex is global).
   - Runs of 1-2 backticks are left untouched (they cannot close a triple-backtick fence).

2. **Assemble the full fenced block.**
   ```python
   full = "```\n" + hardened + "\n```"
   ```

3. **Budget check / truncation.**
   - If `len(full) <= DISCORD_DESC_LIMIT`: return `full` unchanged
     (**no truncation, no marker** — this also covers the exactly-at-limit case).
   - Otherwise compute the content budget so the final assembled string is **exactly**
     `DISCORD_DESC_LIMIT` (never over):
     ```python
     opening, closing = "```\n", "\n```"
     max_content = DISCORD_DESC_LIMIT - len(opening) - len(closing) - len(TRUNCATION_MARKER)
     result = opening + hardened[:max_content] + TRUNCATION_MARKER + closing
     return result
     ```
   - `len(result) == len(opening) + max_content + len(TRUNCATION_MARKER) + len(closing)
     == DISCORD_DESC_LIMIT` -> guaranteed `<= 4096`.

**Off-by-one discipline (the core F14 risk):** wrapper (4 + 4) + full marker length are
all subtracted from the budget; the marker sits **inside** the fence (before the closing
newline-plus-triple-backtick) so it renders as visible text, not as content after a
broken fence.

**Why truncate the *hardened* string (RFC-004 §8):** neutralization can only *add*
characters (ZWSP), so cutting after neutralizing guarantees the result cannot re-expand
past the cut. Cutting a backtick/ZWSP/backtick sequence mid-way can at worst leave a lone
backtick or a lone ZWSP — neither can form a triple-backtick fence (a prefix of a
no-3-consecutive-backticks string still has no 3 consecutive backticks).

**Empty input:** `team_text == ""` -> `hardened == ""` -> `full == "```\n\n```"`
(len 8) -> returned unchanged. Valid, non-crashing block (defensive even though RFC-001
makes `team_text` NOT NULL).

**Unicode / UTF-16 note (document inline, RULES §3):** Discord counts the description in
UTF-16 code units; this function counts Python `str` characters. Per RFC-004 §8 the
pragmatic, documented choice is char-count. Because astral-plane characters (some emoji)
count as 2 UTF-16 units, add a one-line comment noting this; the coder MAY reserve a
small safety margin by subtracting a constant (e.g. `- 16`) from `max_content`, but the
hard acceptance requirement is `len(result) <= DISCORD_DESC_LIMIT` — do not exceed it.

- **ref.invalidate() / mutations:** N/A — pure functions, no state, no cache.

---

## 5. TESTS  *(the second substantive deliverable — replaces "Screens & Widgets")*

### File: `/Volumes/Data/Perso/discord-ots-bot/test_bot.py`  (create; ~120-150 lines)

- **Framework:** stdlib `unittest` only. **No new dependency, no new folder, no test
  runner config** (RULES §1/§2/§8). Runnable via `python -m unittest test_bot` (also
  `python -m unittest` discovery, since the filename matches `test*.py`).

- **Import-safety setup (critical):** `bot.py` calls `validate_config(...)` at
  **module load** (bot.py:62), which `sys.exit(1)`s if any of the four env vars is
  missing, and the `@tree.command(... guild=discord.Object(id=GUILD_ID))` decorator
  (bot.py:188) needs `GUILD_ID` to be a parseable int. Therefore the test module must
  set dummy env vars **before** `import bot`:
  ```python
  import os, unittest
  os.environ.setdefault("DISCORD_TOKEN", "test-token")
  os.environ.setdefault("GUILD_ID", "1")
  os.environ.setdefault("SUPABASE_URL", "http://localhost")
  os.environ.setdefault("SUPABASE_SERVICE_KEY", "test-key")
  import bot  # side-effect-free: client.run is under __main__ guard; no network at import
  ```
  This satisfies the RFC-004 §3.3 / RFC-003 Risk-2 handoff ("tests will set the vars")
  **without** weakening boot-time validation. `setdefault` won't override a real local
  `.env` already loaded by `load_dotenv()`. The `__main__` guard already exists
  (bot.py:233-234, landed in RFC-003) — RFC-004 adds **no** guard change.

- **Test matrix (RFC-004 §3.3 / §6 acceptance):**

  `normalize_name`:
  1. `"NAME"`, `"name"`, `"NaMe"` all equal `"name"` (case-insensitivity).
  2. `"  name  "` -> `"name"` (leading/trailing trim).
  3. `"my name"` -> `"my name"` (internal whitespace preserved).
  4. `""` -> `""` and `"   "` -> `""` (empty / whitespace-only, no crash).
  5. (Recommended) a Unicode-whitespace case, e.g. `"\tname\n"` -> `"name"`.

  `render_team_text`:
  6. Ordinary short set: result starts with the opening fence, ends with the closing
     fence, contains the original text verbatim, no marker.
  7. Text containing a single triple-backtick run: assert the result has **no** substring
     of three consecutive backticks yet still contains the original visible backtick
     characters (count preserved), and text stays inside the fence.
  8. Text with a **4+**-backtick run and **multiple** separate runs: same
     no-3-consecutive-backticks assertion holds for every run.
  9. Oversized input (e.g. `"A" * 5000`): `len(result) <= DISCORD_DESC_LIMIT`,
     `TRUNCATION_MARKER` present, result still ends with the closing fence.
  10. Exactly-at-limit input: construct `team_text` whose assembled `full` length equals
      4096, assert `TRUNCATION_MARKER` **not** in result and `len(result) == 4096`.
  11. Empty input `""`: returns a valid fenced block, no crash, no marker.
  12. Oversized input made of triple-backtick runs: still `len(result) <= 4096`
      (neutralization length accounted for before the cut).

- **States (loading/error/empty/data) equivalent:** N/A — no UI. The four analogous
  cases for the pure logic are the empty / short / oversized / fence-containing inputs
  above.

---

## 6. ROUTING

**N/A.** No `app_router.dart`. RFC-004 registers no Discord command and changes no
route; `/ots` (bot.py:185-224) is untouched. RFC-005 owns the handler that will *call*
these two functions.

---

## 7. EDGE FUNCTIONS

**N/A.** No `supabase/functions/`. RFC-004 is pure in-process Python logic plus tests;
no DB trigger, pg_cron, or edge function.

---

## 8. IMPLEMENTATION ORDER

All production code is in `/Volumes/Data/Perso/discord-ots-bot/bot.py`; tests in
`/Volumes/Data/Perso/discord-ots-bot/test_bot.py`.

1. **Imports.** Add a module-level `import re` alongside the stdlib imports at
   lines 16-17 (currently `re` is imported *inside* `fetch_pokepaste` at line 84).
   The module-level import is required for `render_team_text`; the redundant local one
   may be left or removed (harmless).
2. **Constants.** Add `DISCORD_DESC_LIMIT = 4096` and
   `TRUNCATION_MARKER = "\n… (équipe tronquée)"` near the existing module constants
   (after line 62).
3. **`normalize_name`.** Add per §4.2, with the DB-lockstep docstring comment.
4. **`render_team_text`.** Add per §4.3, with the neutralize -> assemble ->
   budget/truncate algorithm and the subtle char-accounting comments.
5. **`test_bot.py`.** Create per §5, with the env-var-before-import guard and the full
   test matrix.
6. **Run tests:** `python -m unittest test_bot` (from repo root) — must be green, no new
   dependency, no new folder. Also confirm `python -c "import bot"` with the four env
   vars set exits cleanly and does not start the bot / hit the network.
7. **Verify no scope creep:** `USERNAME_URLS`, `fetch_pokepaste`, and the `/ots` handler
   are untouched; `requirements.txt` unchanged; no new files besides `test_bot.py`.

*(Migrations first, models second, providers third, UI last: mapped here as constants ->
pure functions -> tests, since there are no DB/model/UI layers.)*

---

## 9. RISK AREAS

1. **Normalization drift from RFC-001 (documented invariant).** `normalize_name` must
   equal the DB transform (`btrim` + `lower(ingame_name)` index). **Strategy:** the
   docstring explicitly links to RFC-001 and says "change both together"; RFC-005 must
   call `normalize_name`, never ad-hoc `.lower()`. No code fix needed now — preserve the
   comment. (RULES §4.)

2. **Off-by-one in the truncation budget (core F14 failure mode).** A wrong count lets
   Discord reject the embed. **Strategy:** subtract wrapper (4 + 4) + full
   `len(TRUNCATION_MARKER)` from `DISCORD_DESC_LIMIT`; the exactly-at-limit and oversized
   tests (matrix 9, 10, 12) assert `len(result) <= 4096` / `== 4096`.

3. **Neutralization increases length.** ZWSP insertion adds chars; truncating *before*
   neutralizing could push the final result over budget. **Strategy:** neutralize first,
   then truncate the hardened string (§4.3 step order); test 12 guards this.

4. **Backtick run > 3 and multiple runs.** A naive `replace` of a fixed triple misses 4+
   runs and can create new triples. **Strategy:** the global `re.sub(r"`{3,}", ...)`
   joins every backtick in each run with ZWSP, guaranteeing no 3 consecutive backticks
   remain anywhere; tests 7 and 8 cover single, 4+, and multiple runs.

5. **Import-safety for tests vs. fail-fast config (RFC-003 Risk-2 handoff).**
   `import bot` triggers `validate_config` at module load and needs a parseable
   `GUILD_ID`. **Strategy:** `test_bot.py` sets four dummy env vars via
   `os.environ.setdefault(...)` *before* `import bot`. This keeps boot validation strict
   in production while making the import side-effect-free in tests (no `client.run` — it
   is under the `__main__` guard; no network — the fetch helpers are only defined, not
   called). Do **not** weaken `validate_config`.

6. **UTF-16 vs. Python char count.** Discord counts UTF-16 code units; astral emoji count
   double. **Strategy:** document the char-count choice inline (RFC-004 §8); the coder
   may reserve a small margin but must keep `len(result) <= DISCORD_DESC_LIMIT`. Accepted,
   documented pragmatic limitation — not a blocker.

7. **French marker text.** User-facing string must be French (RULES §3 / PRD §5.3).
   **Strategy:** `TRUNCATION_MARKER = "\n… (équipe tronquée)"`; asserted present in the
   oversized test.
