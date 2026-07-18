# RFC-005 — `/ots` Command Refactor: Live Read, Deferral, Embed & Fail-Soft

- **Status:** Ready for implementation
- **Implementation order:** 5 of 6
- **Complexity:** High (core command-path refactor — highest-risk item, F11)
- **Features covered:** F11, F13, F15, F16, F17 (routing), F18, F22 (code parts), F24 (code cleanup)
- **PRD refs:** §5.3, §6, §7 (Journey C & D), §11.3, §11.4, §12, §13, §9 (Day 3–4)
- **Builds upon:** RFC-003 (`fetch_active_player` + config), RFC-004 (`normalize_name`, `render_team_text`)
- **Built upon by:** RFC-006 (E2E checklist, dry-run, deploy validate this end-to-end)

---

## 1. Summary

Rewrite the `/ots` command handler to the v2.0 contract: **defer immediately**,
perform a **bounded, live Supabase read** (via RFC-003's `fetch_active_player`),
resolve the player with **normalized lookup** (RFC-004's `normalize_name`), build the
**embed** with an optional clickable URL and **render-safe** description (RFC-004's
`render_team_text`), deliver by **DM with ephemeral fallback**, and **fail soft** with
three distinct French outcomes plus server-side operator logging. Finally, **delete
`USERNAME_URLS` and `fetch_pokepaste`** entirely (delete, don't disable — RULES §2/F24).
This is the **atomic swap** that realizes the release; it must land as one coherent
change with **zero player-facing regression** vs. v1 (PRD §6).

## 2. Features & requirements addressed

| Feature | Requirement |
|---------|-------------|
| **F18** | Defer the interaction **immediately**, before any network I/O; defer **ephemeral** to preserve reply privacy. |
| **F11** | On each `/ots`, live-read the active tournament's matching player (via RFC-003); no hardcoded map or scraper remains. |
| **F12** (integration) | Normalize input with `normalize_name` (RFC-004) before the lookup. |
| **F13** | Build embed: title `OTS de {username}`; clickable title URL = `pokepaste_url` **only if present**; description = `team_text` in a code block; color `0x3B4CCA`. |
| **F14** (use) | Render the description through `render_team_text` (RFC-004). |
| **F17** (routing) | Timeout/unreachable from the read → the "service unavailable" French branch. |
| **F15** | Three distinct friendly **French** outcomes: (a) not found in active tournament, (b) no active tournament, (c) Supabase unreachable/timeout/error. Never a crash/stack trace to the user. |
| **F16** | The not-found message clarifies the lookup is **scoped to the current tournament**. |
| **F22** (code) | Graceful degradation (fail-soft) + **server-side error logging** on the outage path (fail-soft ≠ fail-silent). |
| **F24** (code) | Remove `USERNAME_URLS` and `fetch_pokepaste` from `bot.py`. |

## 3. Technical approach

### 3.1 Command handler — required order (RULES §5)

```
1. Defer immediately, ephemeral:   await interaction.response.defer(ephemeral=True)
2. normalized = normalize_name(username)              # RFC-004
3. status, player = await fetch_active_player(normalized)   # RFC-003 (bounded 5s)
4. Branch on status:
     "no_active"    -> followup: French "no active tournament" message      (F15b)
     "unavailable"  -> followup: French "service temporarily unavailable"   (F15c)
                       (RFC-003 already logged the operator diagnostic)
     "not_found"    -> followup: French "not found, scoped to current
                       tournament" message                                  (F15a/F16)
     "ok"           -> build embed + deliver (steps 5–6)
5. Build embed (F13):
     title = f"OTS de {username}"          # echo the user's spelling, as v1
     url   = player["pokepaste_url"] or None   # omit kwarg when None (F13/F2)
     description = render_team_text(player["team_text"])   # RFC-004 (F14)
     color = 0x3B4CCA
6. Deliver (unchanged from v1):
     try: await interaction.user.send(embed=embed)
          await interaction.followup.send("✅ …DM…", ephemeral=True)
     except discord.Forbidden:
          await interaction.followup.send("⚠️ …voici votre OTS…",
                                          embed=embed, ephemeral=True)
```

Notes:
- **Defer first (F18).** Every invocation now does a network read; the 3s ack window
  is always at risk, so deferral is unconditional (was conditional in v1). All
  subsequent replies use `interaction.followup.send(...)`.
- **Optional URL (F13/F2):** when `pokepaste_url` is `None`, construct the embed
  **without** a `url` (don't pass `url=None` if that renders oddly — omit it). The
  embed must still render.
- **Title spelling:** keep `OTS de {username}` using the user's original input (v1
  behavior), not the normalized form.
- **Delivery + fallback** is preserved verbatim from v1 (the DM / `discord.Forbidden`
  → ephemeral branch), catching **narrowly** (`discord.Forbidden`) per RULES §7.

### 3.2 French copy (F15/F16 — all user-facing strings French, RULES §3)

Provide three distinct messages, matching v1 tone/emoji (✅/⚠️/❌):
- **(a) not found (F15a + F16):** e.g.
  `❌ Aucun joueur nommé **{username}** dans le tournoi en cours.`
  — must convey the lookup is scoped to the **current/active tournament**.
- **(b) no active tournament (F15b):** e.g.
  `⚠️ Aucun tournoi actif pour le moment. Réessayez plus tard.`
- **(c) unavailable/timeout/error (F15c):** e.g.
  `⚠️ Service momentanément indisponible. Réessayez dans un instant.`

Finalize exact wording during implementation; keep it friendly and French. These are
distinct so a player (and the organizer reading over their shoulder) can tell "you
typed a wrong name" from "the backend is down."

### 3.3 Cleanup (F24, RULES §2 "delete, don't disable")

- Delete the `USERNAME_URLS` dict and the entire `fetch_pokepaste` function.
- Remove now-stale setup comments referencing "Modifier USERNAME_URLS".
- No commented-out dead code, no dormant v1 fallback branch in the working tree (the
  v1 break-glass path lives only in git history — RFC-006 documents recovering it).
- Ensure `import re` (used only by the scraper) is removed if now unused.

### 3.4 Fail-soft / logging contract (F22 code)

- No unhandled exception may reach the interaction response (RULES §7). The read
  helper (RFC-003) never raises; the handler still wraps delivery defensively so a
  Discord hiccup degrades to a friendly message, not a stack trace.
- Operator logging for the outage path is emitted by RFC-003's helper (console,
  alongside the heartbeat), never including secrets or full `team_text`.

## 4. Data models / schema changes

None. Consumes RFC-001 data via RFC-003; uses RFC-004 pure functions.

## 5. Interfaces / contracts exposed

- The finished **`/ots` behavioral contract** (RULES §5) — the release's player-facing
  surface, validated end-to-end in RFC-006.
- No new public function signatures beyond wiring; `fetch_active_player`,
  `normalize_name`, `render_team_text` are consumed as defined in RFC-003/004.

## 6. Acceptance criteria

- [ ] **F18:** `/ots` never fails with a Discord "interaction failed"/timeout under normal Supabase latency (deferred before the read).
- [ ] **F11:** No `USERNAME_URLS` and no `fetch_pokepaste` remain in `bot.py`; each `/ots` reflects current Supabase data (edit in Studio → next lookup shows it — Journey B).
- [ ] **F12:** `/ots NAME`, `/ots name`, `/ots "  name  "` all resolve to the same seeded player.
- [ ] **F13:** A player **with** `pokepaste_url` → embed title links; a player **without** → embed renders with no link. Title `OTS de {username}`, code-block body, color `0x3B4CCA` — visually matches v1.
- [ ] **F14:** Oversized / backtick-containing `team_text` renders as a valid, non-broken embed (uses RFC-004 `render_team_text`).
- [ ] **F15:** Three distinct French messages for not-found / no-active / unavailable; each triggered by its condition; no stack trace ever reaches the user.
- [ ] **F16:** The not-found message references the current-tournament scope.
- [ ] **F17:** A timed-out/unreachable Supabase produces the unavailable message (not a hang, not a crash) and an operator log line exists.
- [ ] **Delivery:** DM succeeds → ephemeral "envoyé en DM" confirmation; DMs closed (`discord.Forbidden`) → ephemeral reply carrying the embed. (Unchanged from v1.)
- [ ] **F24:** Scraper + dict deleted; unused imports removed; no dead/commented code.

## 7. Implementation details

- **File:** `bot.py` only. Replace the body of the `ots` command; delete v1 lookup +
  scraper; keep the `@tree.command(... guild=discord.Object(id=GUILD_ID))` single-guild
  registration and `on_ready` sync unchanged (no regression, PRD §6).
- **Entrypoint guard:** `client.run(TOKEN)` under `if __name__ == "__main__":` (landed
  in RFC-004 for import-safety; confirm it remains).
- **French strings** as module-level constants or inline, matching existing style.
- Keep the handler readable and linear (RULES §10: boring over clever).

## 8. Edge cases & risks

- **Highest technical risk in the release (F11):** it touches the sole command path.
  Mitigation: predecessors already isolated the network seam (RFC-003) and the pure
  logic (RFC-004); this RFC is mostly wiring + branching + deletion.
- **Null `pokepaste_url`** → omit the `url` kwarg, don't pass `None`.
- **DM fallback** must still catch only `discord.Forbidden` (not broad `except`).
- **Deferred-then-error** ordering: after `defer`, every path must respond via
  `followup` exactly once (avoid double-respond / no-respond).
- **`username` echo vs. normalized** — title uses raw input; lookup uses normalized.
- **Empty/whitespace-only `/ots`** input → normalizes to `""` → `not_found` branch
  (never a crash).

## 9. Applicable rules (RULES.md)

- §5 (exact command-path order + three distinct French fail-soft branches). §2
  (single file; delete-don't-disable). §3 (French user strings, English internals).
  §6/§7 (no secrets logged; fail-soft-to-user + loud-to-operator; catch `Forbidden`
  narrowly; no unhandled exception to the user). §4 (optional URL is first-class;
  content trusted, rendering hardened via RFC-004). §10 (no stubs; ask before
  touching a locked decision).

## 10. Testing strategy

- **Manual in-guild** happy path (with/without URL) against RFC-002 seeded data.
- **Fail-soft branches:** deactivate all tournaments (no-active); wrong name
  (not-found); break the Supabase URL / take it offline (unavailable + operator log).
- **DMs-closed fallback:** test account with DMs disabled → ephemeral embed.
- **Render-safety:** seed an oversized and a backtick-containing `team_text`; confirm
  valid embeds. (RFC-004 unit tests already cover the pure logic.)
- The consolidated pass/fail sign-off is the **E2E checklist in RFC-006 (Day 5)** —
  the primary release gate (RULES §8).
