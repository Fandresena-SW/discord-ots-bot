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


if __name__ == "__main__":
    unittest.main()
