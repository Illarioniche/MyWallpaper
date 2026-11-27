#!/usr/bin/env python3
"""Exercise Sparkle's native installer in disposable apps, never the user's app.

Uses an ephemeral Ed25519 seed file (not the login Keychain), a loopback server,
unique bundle identifiers and preferences, and ad-hoc-signed host apps. Requires
an active macOS login session. All app artifacts and logs stay in .build.
"""

import argparse
import base64
import functools
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import threading
import time
import uuid


PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT / ".build" / "updater-probe"
TOOLS = PROJECT / ".build" / "sparkle-tools" / "2.10.1"


def run(*arguments, **kwargs):
    result = subprocess.run([str(value) for value in arguments], check=True,
                            capture_output=True, text=True, **kwargs)
    return result.stdout.strip()


def compile_probe():
    ROOT.mkdir(parents=True, exist_ok=True)
    executable = ROOT / "UpdateInstallerProbe"
    source = PROJECT / "Sources" / "MyWallpaper"
    snapshot = ROOT / "source-snapshot"
    snapshot.mkdir(exist_ok=True)
    names = ("Localization.swift", "UpdateController.swift", "UpdateInstallationController.swift",
             "UpdateRelaunchState.swift", "WhatsNewController.swift")
    for name in names:
        shutil.copy2(source / name, snapshot / name)
    shutil.copy2(PROJECT / "Tests/Integration/UpdateInstallerProbe.swift", snapshot / "UpdateInstallerProbe.swift")
    run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
        "-module-cache-path", ROOT / "ModuleCache", "-F", TOOLS,
        "-framework", "Sparkle", "-framework", "AppKit", "-framework", "CryptoKit",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", TOOLS,
        *(snapshot / name for name in names), snapshot / "UpdateInstallerProbe.swift",
        "-o", executable)
    return executable


def make_app(path, executable, public_key, identifier, case_root, feed_url, build, expects_failure):
    contents = path / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    shutil.copy2(executable, contents / "MacOS" / "UpdateInstallerProbe")
    run("ditto", TOOLS / "Sparkle.framework", contents / "Frameworks" / "Sparkle.framework")
    info = {
        "CFBundleExecutable": "UpdateInstallerProbe",
        "CFBundleIdentifier": identifier,
        "CFBundleName": "MyWallpaper Update Probe",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.10.1" if build == "13" else "0.10.0",
        "CFBundleVersion": build,
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,
        "SUPublicEDKey": public_key,
        "SUFeedURL": feed_url,
        "SUEnableAutomaticChecks": False,
        "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True, "NSAllowsArbitraryLoads": True},
        "ProbeRoot": str(case_root),
        "ProbeExpectsFailure": expects_failure,
        "ProbeQuitDuringExtraction": case_root.name == "quit-during-extraction",
    }
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    run("codesign", "--force", "--sign", "-", path)
    run("codesign", "--verify", "--deep", "--strict", path)


def fixture(run_root, scenario, executable, public_key, private_key, base_url):
    case_root = run_root / scenario
    case_root.mkdir()
    identifier = "local.mywallpaper.update-probe." + uuid.uuid4().hex
    feed_url = f"{base_url}/{scenario}/appcast.xml"
    source_app = case_root / "installed" / "MyWallpaperUpdateProbe.app"
    target_app = case_root / "staging" / "MyWallpaperUpdateProbe.app"
    for app, build in ((source_app, "12"), (target_app, "13")):
        make_app(app, executable, public_key, identifier, case_root, feed_url, build, scenario.startswith("invalid-"))
    archive = case_root / "update.dmg"
    run("hdiutil", "create", "-volname", "MyWallpaper Update Probe", "-srcfolder", target_app.parent,
        "-format", "UDZO", "-ov", archive)
    signature = run(TOOLS / "bin/sign_update", "--ed-key-file", private_key, "-p", archive)
    if scenario == "invalid-archive-signature":
        signature = base64.b64encode(os.urandom(64)).decode()
    feed = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Isolated installer probe</title><item><title>Fixture update</title>
<sparkle:version>13</sparkle:version><sparkle:shortVersionString>0.10.1</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
<enclosure url="{base_url}/{scenario}/update.dmg" length="{archive.stat().st_size}"
type="application/octet-stream" sparkle:edSignature="{signature}" />
</item></channel></rss>
'''
    feed_path = case_root / "appcast.xml"
    feed_path.write_text(feed)
    run(TOOLS / "bin/sign_update", "--ed-key-file", private_key, feed_path)
    if scenario == "invalid-feed-signature":
        feed_path.write_text(feed_path.read_text().replace("Fixture update", "Altered update"))
    return case_root, source_app, identifier


def terminate_fixture(case_root, identifier):
    """Only touch PIDs recorded by this fixture and still running this exact app."""
    events_path = case_root / "events.jsonl"
    if events_path.exists():
        for line in events_path.read_text().splitlines():
            event = json.loads(line)
            pid = event.get("pid")
            if pid and event.get("event") == "launch":
                result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
                if str(case_root) in result.stdout and "UpdateInstallerProbe" in result.stdout:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
    subprocess.run(["defaults", "delete", identifier], capture_output=True)
    # Sparkle and Foundation create caches outside the bundle. These names belong
    # exclusively to this fixture's random identifier, never the production app.
    for directory in ("Caches", "HTTPStorages"):
        shutil.rmtree(Path.home() / "Library" / directory / identifier, ignore_errors=True)
    shutil.rmtree(Path.home() / "Library/Saved Application State" / (identifier + ".savedState"), ignore_errors=True)


def exercise(case_root, app, identifier, timeout):
    print(f"Running {case_root.name}…", flush=True)
    run("open", "-n", "--stdout", case_root / "stdout.log", "--stderr", case_root / "stderr.log", app)
    deadline = time.monotonic() + timeout
    seen = 0
    result_path = case_root / "result.json"
    try:
        while time.monotonic() < deadline:
            events = case_root / "events.jsonl"
            if events.exists():
                lines = events.read_text().splitlines()
                for line in lines[seen:]:
                    print("  " + line, flush=True)
                seen = len(lines)
            if result_path.exists():
                result = json.loads(result_path.read_text())
                # The fixture writes its result immediately before gracefully terminating.
                time.sleep(0.5)
                installed_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                expected_build = "12" if case_root.name.startswith("invalid-") else "13"
                result["installedBuild"] = installed_info["CFBundleVersion"]
                result["passed"] &= result["installedBuild"] == expected_build
                if case_root.name.startswith("invalid-"):
                    result["passed"] &= "readyToInstall" not in events.read_text()
                return result
            stderr = case_root / "stderr.log"
            if stderr.exists() and "Fatal error:" in stderr.read_text():
                return {"passed": False, "error": "Fixture initialization failed", "diagnostic": str(stderr)}
            time.sleep(0.2)
        return {"passed": False, "error": "Timed out waiting for the fixture result", "path": str(case_root)}
    finally:
        terminate_fixture(case_root, identifier)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--scenario", choices=("valid", "invalid-archive-signature", "invalid-feed-signature", "quit-during-extraction"))
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args()
    if not (TOOLS / "Sparkle.framework").exists():
        raise SystemExit("Download Sparkle first: scripts/sparkle-tools.sh")
    executable = ROOT / "UpdateInstallerProbe" if args.skip_build else compile_probe()
    if args.build_only:
        print(executable)
        return
    run_root = ROOT / ("run-" + uuid.uuid4().hex)
    run_root.mkdir(mode=0o700)
    key = run_root / "ephemeral-private-key"
    public_key = run(executable, "--generate-key", key)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *values):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(run_root)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://127.0.0.1:{server.server_port}"
    results = {}
    try:
        scenarios = (args.scenario,) if args.scenario else ("valid", "invalid-archive-signature", "invalid-feed-signature", "quit-during-extraction")
        for scenario in scenarios:
            case_root, app, identifier = fixture(run_root, scenario, executable, public_key, key, base_url)
            results[scenario] = exercise(case_root, app, identifier, args.timeout)
        (run_root / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(json.dumps(results, indent=2), flush=True)
        print(f"Evidence: {run_root / 'results.json'}", flush=True)
    finally:
        key.unlink(missing_ok=True)
        server.shutdown()
        server.server_close()
    if not all(result["passed"] for result in results.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout or "")
        print(error.stderr or "")
        raise SystemExit(error.returncode)
