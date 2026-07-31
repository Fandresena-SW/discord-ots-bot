"""
Tests unitaires (stdlib unittest) pour les fonctions pures de bot.py :
normalize_name (F12) et render_team_text (F14).

Runnable via: python -m unittest test_bot
(ou par découverte: python -m unittest)

Import-safety: bot.py appelle validate_config(...) au chargement du module et
a besoin d'un GUILD_ID entier valide. On fixe donc des variables d'env
factices AVANT l'import, avec setdefault() pour ne pas écraser un .env local
déjà chargé. Aucun réseau n'est sollicité: client.run() est protégé par le
garde `if __name__ == "__main__":`.
"""

import os
import unittest
from datetime import datetime, timedelta, timezone

os.environ.setdefault("DISCORD_TOKEN", "test-token")
os.environ.setdefault("GUILD_ID", "1")
os.environ.setdefault("SUPABASE_URL", "http://localhost")
os.environ.setdefault("SUPABASE_SERVICE_KEY", "test-key")

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


if __name__ == "__main__":
    unittest.main()
