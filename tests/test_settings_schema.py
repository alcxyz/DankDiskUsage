"""Keep plugin.json's settings schema wired to both QML files.

A setting is only real once it exists in three places: the manifest schema, the
settings UI, and the widget that reads it back. Adding one and forgetting another
fails silently at runtime -- the toggle appears but changes nothing, or the widget
reads a key no UI ever writes. These tests make that a build failure instead.
"""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "plugin.json"
SETTINGS_QML = ROOT / "DankDiskUsageSettings.qml"
WIDGET_QML = ROOT / "DankDiskUsageWidget.qml"


def manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def schema_keys() -> set:
    return set(manifest().get("settings_schema", {}))


def settings_ui_keys() -> set:
    source = SETTINGS_QML.read_text(encoding="utf-8")
    return set(re.findall(r'settingKey:\s*"([^"]+)"', source))


def widget_loaded_keys() -> set:
    source = WIDGET_QML.read_text(encoding="utf-8")
    return set(re.findall(r'loadPluginData\(\s*"dankDiskUsage"\s*,\s*"([^"]+)"', source))


class SettingsSchemaTest(unittest.TestCase):
    def test_every_schema_key_has_a_settings_control(self):
        missing = schema_keys() - settings_ui_keys()
        self.assertEqual(
            set(),
            missing,
            f"declared in plugin.json but not exposed in DankDiskUsageSettings.qml: {sorted(missing)}",
        )

    def test_every_settings_control_is_declared_in_the_schema(self):
        undeclared = settings_ui_keys() - schema_keys()
        self.assertEqual(
            set(),
            undeclared,
            f"exposed in DankDiskUsageSettings.qml but missing from plugin.json: {sorted(undeclared)}",
        )

    def test_every_schema_key_is_read_by_the_widget(self):
        unread = schema_keys() - widget_loaded_keys()
        self.assertEqual(
            set(),
            unread,
            f"declared in plugin.json but never read in DankDiskUsageWidget.qml: {sorted(unread)}",
        )

    def test_boolean_defaults_agree_between_schema_and_settings_ui(self):
        ui_defaults = dict(
            re.findall(
                r'settingKey:\s*"([^"]+)"[^}]*?defaultValue:\s*(true|false)\b',
                SETTINGS_QML.read_text(encoding="utf-8"),
                re.DOTALL,
            )
        )
        for key, spec in manifest()["settings_schema"].items():
            if spec.get("type") != "boolean":
                continue
            with self.subTest(setting=key):
                self.assertIn(key, ui_defaults, f"{key} has no defaultValue in the settings UI")
                self.assertEqual(
                    str(spec["default"]).lower(),
                    ui_defaults[key],
                    f"{key} default disagrees between plugin.json and DankDiskUsageSettings.qml",
                )


if __name__ == "__main__":
    unittest.main()
