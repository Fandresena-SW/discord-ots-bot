-- ============================================================================
-- Explicit privilege posture for the PostgREST roles
-- ============================================================================
-- WHY THIS EXISTS (found 2026-08-16, during the migration cutover).
--
-- Until now the schema never granted anything. It relied on a Supabase
-- platform default: "new tables in `public` get SELECT for anon/authenticated/
-- service_role, and RLS is what closes the anon hole" — exactly what the
-- baseline migration's section 5 comment describes.
--
-- That default is no longer guaranteed. On a database provisioned by a current
-- Supabase CLI, the default ACL for objects created by `postgres` in `public`
-- grants only `Dxtm` (TRUNCATE/REFERENCES/TRIGGER/MAINTAIN) — no SELECT, no
-- INSERT/UPDATE/DELETE. Tables created by migrations therefore come out
-- unreadable, and the bot's service-key reads fail with HTTP 403 even though
-- RLS and the service key are configured correctly.
--
-- Production predates the change and still carries the old implicit grants, so
-- it is unaffected today — but the schema was only ever *accidentally* working
-- there. Any rebuild (a fresh project, a restore, a new local stack, CI) would
-- have produced a silently broken database. Making the grants explicit is what
-- migrating was supposed to buy us; leaving them implicit would keep shipping
-- an environment-dependent schema.
--
-- SECURITY POSTURE — unchanged in intent, now enforced rather than assumed:
--   * `service_role` gets DML. It is worker-only (bot + Edge Function), never
--     client-side, and already bypasses RLS. RULES §6 is preserved.
--   * `anon` and `authenticated` get NOTHING. They are deliberately omitted,
--     not merely un-granted-by-default. Deny-by-default is now the explicit
--     state rather than a platform side effect.
--   * RLS stays enabled with zero policies on every table. This grant does not
--     weaken it; the two mechanisms are independent, which is precisely why
--     the 403 above happened while RLS was already correct.
--
-- Note this changes what the F49 anon check *looks* like on a rebuilt
-- database: anon now gets `401/403 permission denied` instead of `200 []`,
-- because it is rejected on privilege before RLS is ever consulted. Both are
-- passes; the new one is strictly stronger. See the RFC-011 Completion record.
--
-- Idempotent: `grant` is safe to re-run.
-- ============================================================================


-- v2.0 / v3.0 tables (RFC-001, RFC-007)
grant select, insert, update, delete on tournaments                  to service_role;
grant select, insert, update, delete on players                      to service_role;
grant select, insert, update, delete on challonge_participants_cache to service_role;
grant select, insert, update, delete on challonge_matches_cache      to service_role;

-- v4.0 tables (RFC-011)
grant select, insert, update, delete on profiles                     to service_role;
grant select, insert, update, delete on seasons                      to service_role;
grant select, insert, update, delete on tournament_tiers             to service_role;
grant select, insert, update, delete on tournament_results           to service_role;

-- v4.0 views (RFC-011, F66/F70). Read-only by nature; `security_invoker = on`
-- means they still resolve under the caller's own RLS context.
grant select on current_season   to service_role;
grant select on season_standings to service_role;

-- Sequences backing the `bigint generated always as identity` primary keys —
-- without USAGE, service_role INSERTs fail even with the table grant above.
grant usage, select on all sequences in schema public to service_role;

-- Belt and braces: future tables created by `postgres` in `public` inherit the
-- same posture, so the next migration cannot reintroduce the 403 by omission.
alter default privileges in schema public
  grant select, insert, update, delete on tables to service_role;
alter default privileges in schema public
  grant usage, select on sequences to service_role;
