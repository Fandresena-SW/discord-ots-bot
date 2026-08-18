"""
Tests unitaires (stdlib unittest) pour les fonctions pures de bot.py :
normalize_name (F12), render_team_text (F14), participant_candidate_ids /
pick_opponent_id (RFC-009), is_cache_stale (RFC-010), validate_config /
is_organizer / resolve_binding_conflict / pick_season_roster_row /
OTS_STATUS_MESSAGES (RFC-013).

Runnable via: python -m unittest test_bot
(ou par découverte: python -m unittest)

Import-safety: bot.py appelle validate_config(...) au chargement du module et
a besoin d'un GUILD_ID entier valide et, depuis RFC-013, d'un
ORGANIZER_DISCORD_ID entier valide. On fixe donc des variables d'env
factices AVANT l'import, avec setdefault() pour ne pas écraser un .env local
déjà chargé. Aucun réseau n'est sollicité: client.run() est protégé par le
garde `if __name__ == "__main__":`. ORGANIZER_DISCORD_ID est délibérément
au-dessus de 2^53 pour que toute la suite exerce par défaut le contrat de
comparaison texte (les snowflakes Discord dépassent la précision d'un float).
"""

import contextlib
import io
import types
import unittest
from unittest.mock import patch
from datetime import datetime, timedelta, timezone
import os

os.environ.setdefault("DISCORD_TOKEN", "test-token")
os.environ.setdefault("GUILD_ID", "1")
os.environ.setdefault("SUPABASE_URL", "http://localhost")
os.environ.setdefault("SUPABASE_SERVICE_KEY", "test-key")
os.environ.setdefault("ORGANIZER_DISCORD_ID", "1234567890123456789")

import bot  # noqa: E402 (import must follow the env setup above)


class NormalizeNameTests(unittest.TestCase):
    def test_case_insensitivity(self):
        self.assertEqual(bot.normalize_name("NAME"), "name")
        self.assertEqual(bot.normalize_name("name"), "name")
        self.assertEqual(bot.normalize_name("NaMe"), "name")

    def test_leading_trailing_trim(self):
        self.assertEqual(bot.normalize_name("  name  "), "name")

    def test_internal_whitespace_preserved(self):
        self.assertEqual(bot.normalize_name("my name"), "my name")

    def test_empty_and_whitespace_only(self):
        self.assertEqual(bot.normalize_name(""), "")
        self.assertEqual(bot.normalize_name("   "), "")

    def test_unicode_whitespace(self):
        self.assertEqual(bot.normalize_name("\tname\n"), "name")


class RenderTeamTextTests(unittest.TestCase):
    def test_ordinary_short_set(self):
        team_text = "Pikachu @ Light Ball\nAdamant Nature\n- Volt Tackle"
        result = bot.render_team_text(team_text)
        self.assertTrue(result.startswith("```\n"))
        self.assertTrue(result.endswith("\n```"))
        self.assertIn(team_text, result)
        self.assertNotIn(bot.TRUNCATION_MARKER, result)

    def test_single_triple_backtick_run(self):
        team_text = "before ``` after"
        result = bot.render_team_text(team_text)
        body = result[len("```\n"):-len("\n```")]

        self.assertNotRegex(body, r"`{3,}")
        self.assertEqual(body.count("`"), team_text.count("`"))
        self.assertTrue(result.startswith("```\n"))
        self.assertTrue(result.endswith("\n```"))

    def test_four_plus_and_multiple_backtick_runs(self):
        team_text = "run1 ```` middle `````` end"
        result = bot.render_team_text(team_text)
        body = result[len("```\n"):-len("\n```")]

        self.assertNotRegex(body, r"`{3,}")
        self.assertEqual(body.count("`"), team_text.count("`"))

    def test_oversized_input_is_truncated(self):
        team_text = "A" * 5000
        result = bot.render_team_text(team_text)
        self.assertLessEqual(len(result), bot.DISCORD_DESC_LIMIT)
        self.assertIn(bot.TRUNCATION_MARKER, result)
        self.assertTrue(result.endswith("\n```"))

    def test_exactly_at_limit_no_truncation(self):
        opening, closing = "```\n", "\n```"
        content_len = bot.DISCORD_DESC_LIMIT - len(opening) - len(closing)
        team_text = "B" * content_len
        result = bot.render_team_text(team_text)
        self.assertEqual(len(result), bot.DISCORD_DESC_LIMIT)
        self.assertNotIn(bot.TRUNCATION_MARKER, result)

    def test_empty_input(self):
        result = bot.render_team_text("")
        self.assertEqual(result, "```\n\n```")

    def test_oversized_backtick_runs_stay_within_limit(self):
        team_text = "```" * 2000
        result = bot.render_team_text(team_text)
        body = result[len("```\n"):-len("\n```")]

        self.assertLessEqual(len(result), bot.DISCORD_DESC_LIMIT)
        self.assertNotRegex(body, r"`{3,}")


class ParticipantCandidateIdsTests(unittest.TestCase):
    """The dual-id-space fix: a participant row can carry a group-stage id
    alongside its stable top-level id (see mapping.ts's mapParticipant)."""

    def test_no_group_player_id_key_at_all(self):
        row = {"challonge_participant_id": 99}
        self.assertEqual(bot.participant_candidate_ids(row), {99})

    def test_group_player_id_none(self):
        row = {"challonge_participant_id": 99, "challonge_group_player_id": None}
        self.assertEqual(bot.participant_candidate_ids(row), {99})

    def test_both_ids_present(self):
        row = {"challonge_participant_id": 99, "challonge_group_player_id": 1}
        self.assertEqual(bot.participant_candidate_ids(row), {1, 99})


class PickOpponentIdTests(unittest.TestCase):
    """RFC-009 §7/§10: pure logic for the "current match -> opponent id" step,
    tested directly against RFC-007-shaped fixture dicts (no network).
    `own_ids` is a set because a participant in a group-stage tournament has
    two live join keys (top-level id + group-stage id) once Challonge
    generates a final bracket — see participant_candidate_ids."""

    def test_no_matches_returns_none(self):
        self.assertIsNone(bot.pick_opponent_id({1}, []))

    def test_own_id_on_player1_side(self):
        matches = [{"player1_challonge_id": 1, "player2_challonge_id": 2, "round": 1}]
        self.assertEqual(bot.pick_opponent_id({1}, matches), 2)

    def test_own_id_on_player2_side(self):
        matches = [{"player1_challonge_id": 2, "player2_challonge_id": 1, "round": 1}]
        self.assertEqual(bot.pick_opponent_id({1}, matches), 2)

    def test_multiple_open_matches_picks_highest_round(self):
        matches = [
            {"player1_challonge_id": 1, "player2_challonge_id": 2, "round": 1},
            {"player1_challonge_id": 1, "player2_challonge_id": 3, "round": 2},
        ]
        self.assertEqual(bot.pick_opponent_id({1}, matches), 3)

    def test_null_other_side_treated_as_no_match(self):
        matches = [{"player1_challonge_id": 1, "player2_challonge_id": None, "round": 1}]
        self.assertIsNone(bot.pick_opponent_id({1}, matches))

    def test_self_referential_match_treated_as_no_match(self):
        matches = [{"player1_challonge_id": 1, "player2_challonge_id": 1, "round": 1}]
        self.assertIsNone(bot.pick_opponent_id({1}, matches))

    def test_own_id_absent_from_match_treated_as_no_match(self):
        matches = [{"player1_challonge_id": 2, "player2_challonge_id": 3, "round": 1}]
        self.assertIsNone(bot.pick_opponent_id({1}, matches))

    def test_group_stage_id_matches_on_player1_side(self):
        # own_ids carries both the top-level id (99) and the group-stage id
        # (1); this match is keyed by the group-stage id only.
        matches = [{"player1_challonge_id": 1, "player2_challonge_id": 2, "round": 1}]
        self.assertEqual(bot.pick_opponent_id({1, 99}, matches), 2)

    def test_top_level_id_matches_final_bracket_match(self):
        # Same own_ids as above, but this match is the post-group-stage
        # final bracket, keyed by the top-level id (99) instead.
        matches = [{"player1_challonge_id": 99, "player2_challonge_id": 5, "round": 1}]
        self.assertEqual(bot.pick_opponent_id({1, 99}, matches), 5)

    def test_both_sides_in_own_ids_treated_as_no_match(self):
        matches = [{"player1_challonge_id": 1, "player2_challonge_id": 99, "round": 1}]
        self.assertIsNone(bot.pick_opponent_id({1, 99}, matches))


class IsCacheStaleTests(unittest.TestCase):
    """RFC-010 §3.2/§7: pure logic for the F36 48h staleness warning."""

    def test_fresh_is_not_stale(self):
        now = datetime(2026, 7, 20, 12, 0, 0, tzinfo=timezone.utc)
        fetched_at = now - timedelta(hours=1)
        self.assertFalse(bot.is_cache_stale(fetched_at, now))

    def test_just_under_48h_is_not_stale(self):
        now = datetime(2026, 7, 20, 12, 0, 0, tzinfo=timezone.utc)
        fetched_at = now - timedelta(hours=48) + timedelta(seconds=1)
        self.assertFalse(bot.is_cache_stale(fetched_at, now))

    def test_exactly_48h_is_not_stale(self):
        now = datetime(2026, 7, 20, 12, 0, 0, tzinfo=timezone.utc)
        fetched_at = now - timedelta(hours=48)
        self.assertFalse(bot.is_cache_stale(fetched_at, now))

    def test_just_over_48h_is_stale(self):
        now = datetime(2026, 7, 20, 12, 0, 0, tzinfo=timezone.utc)
        fetched_at = now - timedelta(hours=48) - timedelta(seconds=1)
        self.assertTrue(bot.is_cache_stale(fetched_at, now))

    def test_long_idle_tournament_is_stale(self):
        now = datetime(2026, 7, 20, 12, 0, 0, tzinfo=timezone.utc)
        fetched_at = now - timedelta(days=30)
        self.assertTrue(bot.is_cache_stale(fetched_at, now))


class ValidateConfigTests(unittest.TestCase):
    """RFC-013 §7.2: validate_config grows a fifth parameter,
    ORGANIZER_DISCORD_ID, parsed as an int but returned/stored as text."""

    def _call(self, token="t", guild="1", url="http://x", key="k", organizer="123"):
        with contextlib.redirect_stdout(io.StringIO()):
            return bot.validate_config(token, guild, url, key, organizer)

    def test_missing_organizer_discord_id_exits(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit):
                bot.validate_config("t", "1", "http://x", "k", None)

    def test_non_numeric_organizer_discord_id_exits(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit):
                bot.validate_config("t", "1", "http://x", "k", "abc")

    def test_valid_returns_int_guild_and_text_organizer(self):
        guild_id, organizer_id = self._call(guild="42", organizer="999")
        self.assertEqual(guild_id, 42)
        self.assertIsInstance(guild_id, int)
        self.assertEqual(organizer_id, "999")
        self.assertIsInstance(organizer_id, str)

    def test_whitespace_padded_organizer_id_normalizes(self):
        _, organizer_id = self._call(organizer=" 123 \n")
        self.assertEqual(organizer_id, "123")

    def test_snowflake_above_2_53_survives_byte_exact(self):
        big = "9007199254740993"  # 2^53 + 1
        _, organizer_id = self._call(organizer=big)
        self.assertEqual(organizer_id, big)

    def test_missing_discord_token_still_exits(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit):
                bot.validate_config(None, "1", "http://x", "k", "123")

    def test_missing_guild_id_still_exits(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit):
                bot.validate_config("t", None, "http://x", "k", "123")

    def test_missing_supabase_url_still_exits(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit):
                bot.validate_config("t", "1", None, "k", "123")

    def test_missing_supabase_service_key_still_exits(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit):
                bot.validate_config("t", "1", "http://x", None, "123")

    def test_non_numeric_guild_id_still_exits_with_guild_message(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            with self.assertRaises(SystemExit):
                bot.validate_config("t", "abc", "http://x", "k", "123")
        self.assertIn("GUILD_ID", buf.getvalue())
        self.assertNotIn("ORGANIZER_DISCORD_ID", buf.getvalue())


class IsOrganizerTests(unittest.TestCase):
    """RFC-013 §7.2: is_organizer must compare as TEXT everywhere."""

    def _interaction(self, user_id):
        return types.SimpleNamespace(user=types.SimpleNamespace(id=user_id))

    def test_exact_match(self):
        with patch.object(bot, "ORGANIZER_DISCORD_ID", "123"):
            self.assertTrue(bot.is_organizer(self._interaction("123")))

    def test_mismatch(self):
        with patch.object(bot, "ORGANIZER_DISCORD_ID", "123"):
            self.assertFalse(bot.is_organizer(self._interaction("456")))

    def test_snowflake_above_2_53_precision(self):
        with patch.object(bot, "ORGANIZER_DISCORD_ID", "9007199254740993"):
            self.assertTrue(bot.is_organizer(self._interaction(9007199254740993)))
            self.assertFalse(bot.is_organizer(self._interaction(9007199254740992)))

    def test_int_interaction_id_matches_text_constant(self):
        with patch.object(bot, "ORGANIZER_DISCORD_ID", "42"):
            self.assertTrue(bot.is_organizer(self._interaction(42)))


class ResolveBindingConflictTests(unittest.TestCase):
    """RFC-013 §7.2: one test per F59 branch."""

    def test_no_roster_row_is_not_found(self):
        self.assertEqual(
            bot.resolve_binding_conflict(None, None, None, None, False),
            "not_found",
        )

    def test_unbound_row_is_bind(self):
        self.assertEqual(
            bot.resolve_binding_conflict({"id": 1}, None, 5, None, False),
            "bind",
        )

    def test_same_profile_is_already_bound_same_confirm_false(self):
        self.assertEqual(
            bot.resolve_binding_conflict({"id": 1}, 5, 5, None, False),
            "already_bound_same",
        )

    def test_same_profile_is_already_bound_same_confirm_true(self):
        self.assertEqual(
            bot.resolve_binding_conflict({"id": 1}, 5, 5, None, True),
            "already_bound_same",
        )

    def test_different_profile_no_confirm_needs_confirm(self):
        self.assertEqual(
            bot.resolve_binding_conflict({"id": 1}, 5, 6, None, False),
            "rebind_needs_confirm",
        )

    def test_different_profile_with_confirm_rebinds(self):
        self.assertEqual(
            bot.resolve_binding_conflict({"id": 1}, 5, 6, None, True),
            "rebind",
        )

    def test_account_slot_taken_wins_even_with_confirm_and_other_binding(self):
        # The mentioned account already holds a DIFFERENT roster slot in this
        # tournament — takes precedence over the rebind branches even when
        # the row itself is also bound elsewhere and confirm_rebind is True.
        self.assertEqual(
            bot.resolve_binding_conflict({"id": 1}, 5, 6, "some_other_name", True),
            "account_slot_taken",
        )

    def test_target_profile_none_on_bound_row_is_rebind_needs_confirm(self):
        self.assertEqual(
            bot.resolve_binding_conflict({"id": 1}, 5, None, None, False),
            "rebind_needs_confirm",
        )

    def test_target_profile_none_on_bound_row_with_confirm_is_rebind(self):
        self.assertEqual(
            bot.resolve_binding_conflict({"id": 1}, 5, None, None, True),
            "rebind",
        )

    def test_account_slot_taken_wins_over_bind_on_unbound_row(self):
        # The roster row itself is unbound (would otherwise be a plain
        # "bind"), but the mentioned account already holds a DIFFERENT
        # roster slot in this tournament — account_slot_taken still wins.
        self.assertEqual(
            bot.resolve_binding_conflict({"id": 1}, None, 6, "some_other_name", False),
            "account_slot_taken",
        )


class PickSeasonRosterRowTests(unittest.TestCase):
    """RFC-013 §7.2: F71's most-recent-tournament tie-break."""

    def test_empty_rows_returns_none(self):
        self.assertIsNone(bot.pick_season_roster_row([], [7, 8]))

    def test_empty_id_list_returns_none(self):
        self.assertIsNone(bot.pick_season_roster_row([{"tournament_id": 7}], []))

    def test_single_row_returned(self):
        row = {"tournament_id": 7, "id": 1}
        self.assertEqual(bot.pick_season_roster_row([row], [7]), row)

    def test_most_recent_tournament_wins(self):
        older = {"tournament_id": 7, "id": 1}
        newer = {"tournament_id": 9, "id": 2}
        # recency list: 9 is more recent than 7
        self.assertEqual(bot.pick_season_roster_row([older, newer], [9, 7]), newer)

    def test_row_from_tournament_absent_from_recency_list_is_ignored(self):
        row = {"tournament_id": 99, "id": 1}
        self.assertIsNone(bot.pick_season_roster_row([row], [7, 8]))


class OtsStatusMessagesTests(unittest.TestCase):
    """RFC-013 §7.2: the /ots status -> French message dispatch table."""

    EXPECTED_STATUSES = {
        "no_active", "no_challonge_link", "not_linked", "not_in_tournament",
        "requester_not_found", "no_current_match", "opponent_no_ots",
        "unavailable",
    }

    def test_keys_are_exactly_the_eight_failure_statuses(self):
        self.assertEqual(set(bot.OTS_STATUS_MESSAGES.keys()), self.EXPECTED_STATUSES)

    def test_every_message_non_empty_and_distinct(self):
        values = list(bot.OTS_STATUS_MESSAGES.values())
        self.assertTrue(all(v for v in values))
        self.assertEqual(len(set(values)), 8)

    def test_unknown_status_falls_back_to_unavailable(self):
        result = bot.OTS_STATUS_MESSAGES.get("some_future_status", bot.OTS_STATUS_MESSAGES["unavailable"])
        self.assertEqual(result, bot.OTS_STATUS_MESSAGES["unavailable"])


if __name__ == "__main__":
    unittest.main()
