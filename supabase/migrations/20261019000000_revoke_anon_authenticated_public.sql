-- ============================================================================
-- Enforce "anon and authenticated get NOTHING" in `public` (RFC-015)
-- ============================================================================
-- WHY THIS EXISTS (found 2026-10-19, standing up the self-hosted stack).
--
-- 20260816000100_explicit_service_role_grants.sql makes the posture explicit
-- by *omitting* anon/authenticated from every grant. That is only enough on a
-- database whose default privileges grant them nothing (a current Supabase
-- CLI's local stack). The self-hosted `supabase/postgres` image ships the
-- older, permissive default ACL instead: objects created by `postgres` in
-- `public` come out with full privileges for anon, authenticated and
-- service_role. On that image, anon holds all seven privileges on every
-- table; only RLS (enabled, zero policies) keeps it at `200 []`.
--
-- That is the exact "environment-dependent schema" the grants migration was
-- written to eliminate, in the other direction: here the platform default
-- GIVES access rather than withholding it. So revoke it explicitly, for the
-- tables that exist now and for the ones future migrations will create.
--
-- service_role is untouched: its explicit grants (20260816000100) stand.
-- RLS is untouched: it stays enabled with zero policies, independent of this.
--
-- After this, anon's access to a table is rejected on privilege
-- (`403 permission denied`) before RLS is consulted — strictly stronger than
-- the `200 []` it returned before, same as the grants migration documents.
--
-- Scope: objects owned by `postgres` in `public`. Default ACLs owned by
-- `supabase_admin` belong to Supabase's own internal objects and are not ours
-- to alter (and `postgres` is not a member of that role).
--
-- Idempotent: `revoke` of a privilege not held is a no-op.
-- ============================================================================

-- Existing objects.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

-- Objects created by later migrations (run as postgres) will not re-acquire
-- the permissive defaults.
alter default privileges for role postgres in schema public
  revoke all on tables    from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on functions from anon, authenticated;
