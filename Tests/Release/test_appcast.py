#!/usr/bin/env python3
import base64
import importlib.util
import pathlib
import sys
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("appcast", pathlib.Path(__file__).parents[2] / "scripts/prepare-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def info(self):
        return {
            "CFBundleShortVersionString": "0.10.0", "CFBundleVersion": "12",
            "LSMinimumSystemVersion": "13.0", "CFBundleIdentifier": "local.mywallpaper.MyWallpaper",
            "SUPublicEDKey": base64.b64encode(bytes(32)).decode(),
            "SUFeedURL": appcast.FEED, "SUVerifyUpdateBeforeExtraction": True,
            "SURequireSignedFeed": True,
        }

    def test_stable_release(self):
        self.assertEqual(appcast.release_info(self.info())[:3], ("0.10.0", "12", "13.0"))

    def test_rejects_nonstable_or_ambiguous_versions(self):
        for value in ["v0.10.0", "0.10", "0.10.0-beta", "00.10.0", "1.2.3/escape"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                appcast.release_info(self.info() | {"CFBundleShortVersionString": value})

    def test_requires_increasing_numeric_build_format(self):
        for value in ["0", "-1", "12.0", "0012", "next"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                appcast.release_info(self.info() | {"CFBundleVersion": value})

    def test_rejects_key_and_feed_misconfiguration(self):
        for key, value in [("SUPublicEDKey", "placeholder"), ("SUPublicEDKey", base64.b64encode(bytes(31)).decode()),
                           ("SUFeedURL", "https://example.com/appcast.xml"),
                           ("CFBundleIdentifier", "another.app")]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                appcast.release_info(self.info() | {key: value})

    def test_signatures_cannot_be_disabled(self):
        for key in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                appcast.release_info(self.info() | {key: False})

    def test_feed_pins_exact_universal_archive_and_versions(self):
        signature = base64.b64encode(bytes(64)).decode()
        root = ET.fromstring(appcast.make_appcast("0.10.0", "12", "13.0", 1000, signature))
        item = root.find("channel/item")
        self.assertEqual(item.find("sparkle:version", {"sparkle": appcast.NAMESPACE}).text, "12")
        self.assertEqual(item.find("sparkle:shortVersionString", {"sparkle": appcast.NAMESPACE}).text, "0.10.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.attrib["url"], "https://github.com/Illarioniche/MyWallpaper/releases/download/v0.10.0/MyWallpaper-0.10.0-universal.dmg")
        self.assertEqual(enclosure.attrib["length"], "1000")
        self.assertEqual(enclosure.attrib[f"{{{appcast.NAMESPACE}}}edSignature"], signature)

    def test_rejects_empty_or_unsigned_archive(self):
        for size, signature in [(0, base64.b64encode(bytes(64)).decode()), (100, ""), (100, "bad-signature")]:
            with self.subTest(size=size, signature=signature), self.assertRaises(ValueError):
                appcast.make_appcast("0.10.0", "12", "13.0", size, signature)


if __name__ == "__main__":
    unittest.main()
