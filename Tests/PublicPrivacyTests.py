import importlib.util
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location(
    "privacy", Path(__file__).resolve().parent.parent / "scripts/check-public-privacy.py"
)
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class PublicPrivacyTests(unittest.TestCase):
    def test_private_values_are_detected_without_echoing_them(self):
        # Split fixtures keep the repository check from treating these as actual disclosures.
        text = "/Users/" + "private-person/project\n"
        text += "private-person@" + "mail.invalid\n"
        text += "Developer ID Application: " + "Private Person (ABCDEFGHIJ)"
        result = privacy.findings("docs/guide.md", text)
        self.assertEqual([line for line, _ in result], [1, 2, 3])
        self.assertNotIn("private-person", str(result))
        self.assertNotIn("Private Person", str(result))

    def test_documented_placeholders_and_fixture_paths_are_allowed(self):
        text = "/Users/you/project someone@example.com icon@2x.png\n"
        text += "Developer ID Application: YOUR SIGNING NAME (TEAM_ID)"
        self.assertEqual(privacy.findings("docs/guide.md", text), [])
        fixture = "/Users/" + "test/project"
        self.assertEqual(privacy.findings("Tests/Fixture.swift", fixture), [])
        self.assertTrue(privacy.findings("docs/guide.md", fixture))

    def test_noreply_domain_cannot_be_used_as_a_suffix_bypass(self):
        self.assertEqual(privacy.findings("guide.md", "123+user@users.noreply.github.com"), [])
        self.assertTrue(privacy.findings("guide.md", "user@" + "users.noreply.github.com.evil.invalid"))


if __name__ == "__main__":
    unittest.main()
