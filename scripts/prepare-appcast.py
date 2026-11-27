#!/usr/bin/env python3
"""Prepare a signed GitHub Releases appcast from an already verified release DMG.

Use prepare-update.sh for the complete build/mount/verification workflow. This
module does not upload anything and never reads or exports the private key.
"""
from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import pathlib
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

RELEASES = "https://github.com/Illarioniche/MyWallpaper/releases"
FEED = RELEASES + "/latest/download/appcast.xml"
NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ACCOUNT = "local.mywallpaper.MyWallpaper"
ET.register_namespace("sparkle", NAMESPACE)


def release_info(info: dict) -> tuple[str, str, str, str]:
    version = info.get("CFBundleShortVersionString", "")
    build = info.get("CFBundleVersion", "")
    minimum = info.get("LSMinimumSystemVersion", "")
    key = info.get("SUPublicEDKey", "")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Expected a stable three-component release version.")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("CFBundleVersion must be a positive, increasing integer.")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", minimum):
        raise ValueError("Missing or invalid minimum macOS version.")
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except (ValueError, TypeError):
        valid_key = False
    if not valid_key:
        raise ValueError("Run setup-update-signing.sh to configure a valid public key.")
    if info.get("SUFeedURL") != FEED:
        raise ValueError("The built application has an unexpected update feed URL.")
    if info.get("SUVerifyUpdateBeforeExtraction") is not True or info.get("SURequireSignedFeed") is not True:
        raise ValueError("The application must require signed archives and a signed feed.")
    if info.get("CFBundleIdentifier") != "local.mywallpaper.MyWallpaper":
        raise ValueError("Unexpected application bundle identifier.")
    return version, build, minimum, key


def make_appcast(version: str, build: str, minimum: str, size: int, signature: str) -> bytes:
    if size <= 0 or len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid archive signature or size.")
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "MyWallpaper Updates"
    ET.SubElement(channel, "link").text = RELEASES
    ET.SubElement(channel, "description").text = "Stable MyWallpaper releases for macOS."
    ET.SubElement(channel, "language").text = "en"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "MyWallpaper " + version
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, "link").text = RELEASES + "/tag/v" + version
    ET.SubElement(item, f"{{{NAMESPACE}}}version").text = build
    ET.SubElement(item, f"{{{NAMESPACE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{NAMESPACE}}}minimumSystemVersion").text = minimum
    ET.SubElement(item, "enclosure", {
        "url": f"{RELEASES}/download/v{version}/MyWallpaper-{version}-universal.dmg",
        "length": str(size),
        "type": "application/octet-stream",
        f"{{{NAMESPACE}}}edSignature": signature,
    })
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def run(*args: str | pathlib.Path) -> str:
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def prepare(app: pathlib.Path, dist: pathlib.Path, tools: pathlib.Path) -> pathlib.Path:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version, build, minimum, public_key = release_info(info)
    # Do not accidentally sign with another application's/default Sparkle key.
    if run(tools / "generate_keys", "--account", ACCOUNT, "-p") != public_key:
        raise ValueError("The signing key does not match the public key in this application.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    executable = info.get("CFBundleExecutable", "")
    if executable != "MyWallpaper":
        raise ValueError("Unexpected application executable.")
    run("/usr/bin/xcrun", "lipo", app / "Contents/MacOS" / executable, "-verify_arch", "arm64", "x86_64")
    archive = dist / f"MyWallpaper-{version}-universal.dmg"
    checksum = archive.with_suffix(".dmg.sha256")
    # The DMG was mounted and compared to this app by build-dmg.sh. Check its
    # digest again before signing so damaged or replaced output fails closed.
    hasher = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    if checksum.read_text().strip() != f"{digest}  {archive.name}":
        raise ValueError("DMG checksum mismatch. Rebuild using prepare-update.sh.")
    signature = run(tools / "sign_update", "--account", ACCOUNT, "-p", archive)
    run(tools / "sign_update", "--account", ACCOUNT, "--verify", archive, signature)
    content = make_appcast(version, build, minimum, archive.stat().st_size, signature)
    with tempfile.TemporaryDirectory(prefix=".appcast-", dir=dist) as stage:
        temporary = pathlib.Path(stage) / "appcast.xml"
        temporary.write_bytes(content)
        run(tools / "sign_update", "--account", ACCOUNT, "-p", temporary)
        run(tools / "sign_update", "--account", ACCOUNT, "--verify", temporary)
        output = dist / "appcast.xml"
        temporary.replace(output)
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--dist", type=pathlib.Path, required=True)
    parser.add_argument("--sparkle-bin", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        output = prepare(args.app, args.dist, args.sparkle_bin)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Cannot prepare update: {error}\n")
    print(f"Signed feed: {output}")
    print("Publish the DMG, its SHA-256 file and appcast.xml together in the matching stable GitHub release.")


if __name__ == "__main__":
    main()
