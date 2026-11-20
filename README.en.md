<div align="center">
  <img src="docs/images/app-icon.png" width="104" height="104" alt="MyWallpaper icon">
  <h1>MyWallpaper</h1>
  <p><a href="README.md">Русский</a> | <strong>English</strong></p>
  <p><strong>Your favorite video, on your Mac desktop.</strong></p>
  <p>Live wallpapers without subscriptions or watermarks.<br>A native app built with Swift and SwiftUI.</p>
  <p><strong>macOS 13+</strong> · Apple Silicon and Intel · Light and dark appearance</p>
  <p>
    <a href="#installation">Installation</a> ·
    <a href="#features">Features</a> ·
    <a href="#getting-started">Getting started</a> ·
    <a href="#wallpaper-library">Wallpaper library</a> ·
    <a href="#video-screen-saver-experimental">Screen saver</a> ·
    <a href="#updates">Updates</a> ·
    <a href="#for-developers">For developers</a>
  </p>
</div>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/wallpaper-dark.png">
  <img src="docs/images/wallpaper-light.png" alt="MyWallpaper: Aurora wallpaper preview, playback controls, and display selection" width="980">
</picture>

## Features

- **Your video on your desktop.** Local MP4, MOV, and other formats supported by macOS, playing in a continuous loop.
- **Wallpaper collection.** Cards with thumbnails, custom names, and saved settings: add videos, switch between them, rename, and delete.
- **Battery-aware playback.** Animated on external power and still on battery by default. Both modes are configurable.
- **Smart pause.** Playback pauses separately on each display when windows cover the desktop.
- **Always within reach.** Menu bar controls, wallpaper restoration, and launch at login.
- **Multiple displays.** Use all displays or just the main one, with Fill or Fit scaling.
- **System wallpaper from video.** Optionally save a frame as your regular macOS wallpaper; it stays after you stop the video or quit the app.
- **New versions nearby.** Check GitHub for updates, see an in-app notice, and download a DMG through your browser.
- **Video screen saver library.** Save variants with meaningful names, rename or delete them, and choose which to install in macOS. Currently experimental.
- **Wallpaper and screen saver together.** Optionally synchronize the video, scaling, and power settings through a separate MyWallpaper — Sync screen saver.

## Installation

**Requires macOS Ventura 13 or later and an Apple Silicon or Intel Mac.** The universal DMG includes both architectures; you do not need Xcode or Swift to install it.

1. Download the `.dmg` from [GitHub Releases](https://github.com/Illarioniche/MyWallpaper/releases).
2. Open the disk image and drag **MyWallpaper.app → Applications**.
3. Eject the disk image and open **MyWallpaper** from Applications.
4. In **Wallpaper**, click **Add Video** or drag an MP4/MOV into the app window.

> **Opening the app for the first time.** This build has a local ad-hoc signature and has not been notarized by Apple. If macOS cannot verify the developer or the app, first attempt to open it, then go to **System Settings → Privacy & Security → Open Anyway** and confirm if you trust the download source. [Apple's instructions](https://support.apple.com/102445).

## Getting started

1. In **Wallpaper → My Wallpapers**, add a video and configure it using **⋯ → Configure** on its card.
2. In **Power**, keep the default energy-saving settings or choose how playback behaves on external power and battery.
3. In **General**, optionally enable launch at login. Do this from the installed copy in Applications.
4. In **Updates**, check your app version and configure automatic update checks.

Under **General → App Language**, choose **System**, **Русский**, or **English**. Your choice is saved and takes effect immediately, without restarting the app. System mode uses the first supported language in your macOS preferred-language list, falling back to English if none match.

In **Wallpaper → Configure → Audio**, adjust the volume from **0 to 100%**. **Mute** works independently: it temporarily silences the video while keeping your chosen volume. A volume of **0%** is also silent, even when Mute is off.

Under **Wallpaper → Configure → Appearance**, you can enable **System Wallpaper from Video**; it is off by default. The app saves a frame from the selected video as a still macOS wallpaper and updates it when you change the video, scaling, selected displays, or connected monitors. The frame applies to the current desktop on the selected displays; macOS may turn off Show on All Spaces when it is updated. You can turn that option back on manually in macOS Wallpaper settings if desired. Automatic application to every Space and display on the lock screen are not guaranteed. MyWallpaper continues to provide the animation. Turning this setting off stops future updates and leaves the last saved frame in place.

Closing the window keeps the wallpaper running in the menu bar. **Pause** preserves the current frame; **Turn Off** stops the video and reveals your regular macOS wallpaper. If you saved a system wallpaper frame from the video, that frame stays after you stop playback or quit the app.

<img src="docs/images/power-light.png" alt="Power settings: animation on external power, still wallpaper on battery, and automatic pause" width="780">

## Wallpaper library

The **Wallpaper** section contains **My Wallpapers**. Adding a video saves a separate copy and thumbnail in the app's library; there is no need to choose a folder or manage internal files. The original stays in place. Saved wallpapers remain available after restarting, even if you later move the original video.

- **Apply** activates a video with its saved settings. Its card indicates the currently selected wallpaper.
- **⋯ → Configure** opens that entry's display, scaling, mute and volume, animation on external power and battery, covered-desktop and Low Power Mode pauses, and system wallpaper sync settings. **Save** updates the entry and immediately applies changes if it is currently selected. Configuring another entry does not switch the current wallpaper.
- **⋯ → Rename** changes the card's name. **Delete** asks for confirmation, then removes the entry and its internal video copy. The original video is preserved. Deleting the selected wallpaper stops playback and prevents that entry from being restored at launch. Any previously saved system wallpaper frame remains.

The card, current wallpaper panel and menu bar open the same **Configure** editor. For the active wallpaper it shows the current values; for another video it shows its saved settings. **Save** stores changes, while **Cancel** keeps the existing settings. Quick mute commands also remember their state across app launches.

**Power** defines common rules for external power, battery, Low Power Mode and desktop coverage. New wallpapers follow these rules. To make an exception, turn off **Use Shared Rules** in that wallpaper’s editor and choose its own modes. Switching wallpapers never changes the common rules.

On upgrade, previous power preferences seed the common rules, while saved power settings in existing cards remain individual exceptions. Current settings of the active wallpaper that had not been saved to its card are also restored and can be saved through the unified editor. Original videos and saved presets are not automatically overwritten.

After an update, an existing wallpaper continues to work as before; the app does not copy it automatically. Choose **Save Current Wallpaper** to add it to the library with its current settings.

## Video screen saver (experimental)

Under **Screen Saver**, **My Screen Savers** lists your saved variants with thumbnails and names. The section above it can synchronize the screen saver with your wallpaper.

1. In **New Screen Saver**, enter a meaningful name and click **Choose Video**, or use **Use Current Wallpaper** to take the file already selected for your wallpaper.
2. Choose scaling and animation settings for external power and battery. These settings belong to the screen saver: by default, it animates on external power and shows a still frame on battery or in Low Power Mode.
3. Click **Save to Library**. The app stores the screen saver with a copy of its video; there is no need to choose a folder or manage files.
4. Find the variant you want in **My Screen Savers** and click **Install…**. Confirm installation in macOS. Different screen savers can be installed together; when reinstalling the same one, confirm replacement of its previous copy.
5. Click **Open Screen Saver Settings**, select your installed screen saver by name, and check its preview. In macOS 26 and later, open **Wallpaper → Screen Saver…** and choose **Custom** in the **Use Screen Saver** row. Scroll down **inside the dialog** to **Other** and click **Show All** if needed. In macOS 14–15, open **Screen Saver → Other** and expand the full list if needed; in macOS 13, find it in the thumbnail list under **Screen Saver**. [Apple's instructions](https://support.apple.com/en-om/guide/mac-help/mchl4b68853d/mac).

Use an entry's menu to rename or delete a saved variant. Deletion requires confirmation and removes only that library entry and its video copy. **The original video and any screen saver already installed in macOS are not deleted.** Renaming updates the library name immediately; reinstall that screen saver to update its name in macOS.

The installed screen saver runs independently of MyWallpaper; you can quit the app. It is **always muted**, regardless of the wallpaper volume. **Use Current Wallpaper** takes the selected video once; later wallpaper changes do not change saved screen savers. To use a different video or settings, save a new variant and install it from the library.

Existing library entries are preserved. To update one, click **Install…** again: the app prepares the screen saver using its saved video and the current version of the bundled player. There is no need to recreate the entry or select the original file again.

Discovery of two independently installed screen savers was verified on macOS 26.7.1: after reopening System Settings, the system catalog returned both entries with their user-defined names. Their presence in the system screen saver picker was also confirmed. **If the new screen saver does not appear, close and reopen System Settings.**

**This feature is experimental.** The System Settings preview and behavior on the actual lock screen still need verification; behavior depends on the macOS version and its support for third-party screen savers. A message saying the installer opened does not confirm installation is complete: check your chosen screen saver in System Settings. Video behind the password field is not supported. The login screen and FileVault unlock screen are unchanged. You control installation and screen saver selection; the app does not change lock settings.

### Synchronize with wallpaper

1. Choose an **MP4 or MOV** wallpaper, then open **Screen Saver → Wallpaper and Screen Saver Together**.
2. Enable **Sync with Wallpaper**. The app prepares a separate copy of the selected video with its current scaling and power settings.
3. Click **Install MyWallpaper — Sync…** and confirm the macOS installer. Then select **MyWallpaper — Sync** in System Settings. In macOS 26, open **Wallpaper → Screen Saver… → Use Screen Saver → Custom → Other** and click **Show All** if needed.

Once installation is detected, setup collapses into a **Screen Saver Installed** status. The **⋯** menu keeps **Reinstall…**, a shortcut to System Settings, and the setup instructions. If you delete the screen saver from macOS, the install button returns when you switch back to the app. This status confirms installation; you still choose the active screen saver in System Settings.

Install and select this screen saver once. When you change the wallpaper, scaling, or power settings, MyWallpaper updates the saved data that the screen saver reads on its next start. Ordinary entries in **My Screen Savers** remain independent; selecting one of them in macOS does not automatically enable synchronization.

The screen saver is always muted. Manual wallpaper pause, desktop window coverage, and the main-display selection do not carry over: macOS controls which displays show the screen saver. Turning off sync, stopping wallpaper playback, quitting the app, or deleting the wallpaper library entry leaves the last saved video available to the screen saver. Synchronization is off by default.

**This mode is experimental:** the linked screen saver's System Settings preview and behavior on the actual lock screen still need verification. Opening the installer does not confirm that macOS completed installation or selected the screen saver; you need to confirm those steps yourself.

## Updates

MyWallpaper checks the latest stable release in the public [GitHub repository](https://github.com/Illarioniche/MyWallpaper/releases/latest). Automatic checks are enabled by default: the app checks whether a request is due at startup and every hour while running, but sends an automatic request no more than once every 24 hours. You can disable this in **Updates**; the manual **Check for Updates** button remains available.

When a new version is found, a banner appears in the app and a badge appears on its menu bar icon. The app does not use system notifications or request notification permission. **Updates** provides the release page and, when published, links to the universal DMG and its SHA-256 file. Downloads open in your browser; the app does not download or install updates itself. If GitHub is unavailable or a check fails, your wallpaper keeps working and you can retry manually.

To update:

1. Download the DMG and quit MyWallpaper from its menu.
2. Open the disk image and drag **MyWallpaper.app** into **Applications**, confirming that you want to replace the previous version.
3. Eject the disk image and launch the app from **Applications**.

Replacing the app preserves your settings and selected video; the original video file is neither moved nor deleted. See [below](#building-a-dmg) for SHA-256 verification.

<details>
<summary><strong>I cannot see the menu bar icon</strong></summary>

If your macOS version has a Menu Bar settings section, check MyWallpaper's permission there. On a MacBook with a notch, the icon may be hidden because there is not enough space. While it is visible, hold **⌘ Command** and drag it closer to the clock, or make room among your other icons. Opening MyWallpaper again from Applications also brings back the control window.

</details>

<details>
<summary><strong>Launch at login will not turn on</strong></summary>

First quit MyWallpaper, move the app to **/Applications**, and open the installed copy. Do not enable launch at login for a copy running directly from a DMG. macOS may also run a downloaded app from a temporary isolated location, called App Translocation. The app shows installation guidance for this location and for read-only disks.

Return to **General** and try enabling launch at login again. The app refreshes its status from macOS: a missing registration does not prevent another attempt. If approval is required, open System Settings from the app. If registration still fails, go to **System Settings → General → Login Items & Extensions**, click **+** below **Open at Login**, and select the installed **MyWallpaper.app**. The section name may differ between macOS versions. [Apple's instructions](https://support.apple.com/en-hk/guide/mac-help/-mh15189/mac).

After adding the app manually, also enable **Restore Wallpaper at Launch** in MyWallpaper so your selected video returns when you log in.

Launch at login uses the system Service Management framework. This build is ad-hoc signed and not notarized; registration and launch at login cannot be guaranteed on every macOS version and configuration.

</details>

---

## For developers

There are no external dependencies. The following sections cover building, release packaging, validation, and how the app works.

### Building from source

You need Swift 6 or later and a compatible version of Xcode or Apple Command Line Tools. The macOS version required to build depends on your chosen tools; macOS 13 is the minimum for running the built app. To install Apple's tools and check the compiler version:

```sh
xcode-select --install
swift --version
```

From the project directory:

```sh
./scripts/build-app.sh
open dist/MyWallpaper.app
```

By default, the script builds for your Mac's architecture. To build a universal app:

```sh
./scripts/build-app.sh --universal
```

The script builds arm64 and x86_64 separately, combines them with `lipo`, adds icons, and embeds the screen saver template in `Contents/PlugIns/MyWallpaper.saver`. The nested screen saver is signed first, then the final `.app` receives a local ad-hoc signature. A local build requires neither paid Apple Developer membership nor `sudo`. You can open the project in Xcode using `Package.swift`.

### Building the screen saver template

```sh
./scripts/build-screensaver.sh
./scripts/build-screensaver.sh --universal
```

The first command builds for your Mac's architecture; the second builds arm64 and x86_64. The result is `.build/MyWallpaper.saver`, a standalone Mach-O bundle with a `ScreenSaverView` from the [Screen Saver framework](https://developer.apple.com/documentation/screensaver). Its version comes from `Resources/Info.plist`; the build verifies its signature and architectures. The template contains no video and is intended for the app's exporter. Without exported resources, it shows a static background with guidance. The script does not install anything, open System Settings, or run the screen saver.

The app library is stored in `~/Library/Application Support/MyWallpaper/ScreenSavers`. Each entry has a UUID directory and its own metadata. Before installation, the app prepares a newly signed bundle using the saved resources and the current runtime. The UUID determines stable, unique bundle identifiers, class names, and installer filenames (`MyWallpaper-UUID.saver`); the user-facing name is written to `CFBundleName` and `CFBundleDisplayName`. Resources include standard `thumbnail.png` and `thumbnail@2x.png` previews for the system list. Preparing an installation does not alter the existing library entry. Deleting an entry frees its internal storage without affecting a separately installed system copy.

### Building a DMG

```sh
./scripts/build-dmg.sh
```

This command builds a universal app and creates a compressed disk image for drag-to-Applications installation:

```text
dist/
├── MyWallpaper.app
├── MyWallpaper-0.9.0-universal.dmg
└── MyWallpaper-0.9.0-universal.dmg.sha256
```

The image contains the app, a link to Applications, and brief installation instructions. The version comes from `Info.plist`; the architecture comes from the built executable. To package an existing build without recompiling:

```sh
./scripts/build-dmg.sh --skip-build
```

The filename reflects the actual architectures: `universal`, `arm64`, or `x86_64`. The script verifies the app signature, DMG integrity, and mounted image contents. Files in `dist/` are not tracked in Git: attach the `.dmg` and `.sha256` to a GitHub release. The scripts do not create tags or publish releases.

To verify a downloaded image, run this from the directory containing both files:

```sh
shasum -a 256 -c MyWallpaper-0.9.0-universal.dmg.sha256
```

The universal build includes Intel, but launch validation has been performed on Apple Silicon. Distribution with a verified developer identity separately requires Developer ID signing and Apple notarization.

### Icons and screenshots

The app, interface, and menu bar icons are drawn in `Sources/MyWallpaper/AppIconArtwork.swift`. The build generates a complete set of `.icns` sizes from the same artwork.

The screenshots in this README use the project's **Aurora** demo landscape, without user files. To reproduce them:

```sh
./scripts/render-readme.sh
```

The demo MP4 and intermediate images are saved in `.build/readme/`; the video is not included in the app or DMG. Rendering uses isolated settings, does not show windows, and does not enable wallpaper. After visually reviewing the output, update the documentation images:

```sh
./scripts/render-readme.sh --copy-images
```

### Detailed usage

1. Click **Choose Video** or drag an MP4/MOV into the app window.
2. Choose a section in the sidebar: **Wallpaper**, **General**, **Power**, **Screen Saver**, or **Updates**. These contain the wallpaper library and unified editor; startup and language settings; common power rules; the system screen saver library; and update checks and downloads.
3. Control playback from the window or menu bar icon. Closing the window leaves the wallpaper running.
4. Pause stops the video on its current frame. Turning the wallpaper off or quitting restores your regular desktop.

Video playback loops, and sound is muted by default. Video volume ranges from 0–100% independently of mute; both settings are saved. The app remembers the selected file and interface language. If the file is deleted or becomes unavailable, choose it again. Codec support depends on AVFoundation in your installed macOS version.

Playback pauses while the display is asleep or the session is inactive. Automatic pausing in Low Power Mode is also available in settings.

### Launch at login and energy use

In **Power**, **Animate on External Power** is enabled by default and **Animate on Battery** is disabled. A MacBook connected to power, including when its battery is fully charged, as well as a Mac mini or Mac Studio, uses the external-power setting. Switching to battery freezes the video on the current frame; connecting power resumes it. Both settings can be changed independently and are remembered across power changes and app launches.

The **Animate Now** button temporarily enables animation until the power source changes, another wallpaper is selected, or playback is turned off. It does not change saved rules or the linked screen saver’s mode. A manual pause persists when connecting or disconnecting power; sleep, a hidden desktop, and Low Power Mode remain separate reasons to pause. When starting in still mode, the first frame appears without briefly playing the video. If macOS does not report the power source, the saved external-power setting applies.

The menu bar provides wallpaper status, playback, stop, mute, and shortcuts to the unified editor and app settings. **Open Settings…** and `⌘,` open **General**.

Use **General → Launch at Login** to enable system-managed startup. Enabling it also turns on restoration of the selected video. After login, the app starts in the menu bar without opening its control window. A manual pause and **Turn Off Wallpaper** are remembered for the next launch.

If macOS requires approval, the app shows a pending state and a link to System Settings. It refreshes the status when you open settings, so external changes are reflected too. Missing registration can be retried; an error never overrides the actual system status. For regular use, first move the `.app` to Applications, open that copy, and enable launch at login there. If registration fails, see **Launch at login will not turn on** above.

**Pause When the Desktop Is Hidden** is enabled by default. Each display is handled separately: wallpaper fully covered by windows freezes on its last frame and resumes when the desktop becomes visible. A 16-point macOS margin allows small edge gaps from rounded windows. When only some displays are hidden, the status shows the number still playing, for example **Playing on 1 of 2 displays**. When all selected displays are hidden, it shows **Paused: desktop is hidden**. Manual pause, sleep, and Low Power Mode take priority over automatic resuming. You can disable this setting in **Power** or in an individual wallpaper’s rules. Coverage uses window bounds, not per-pixel transparency, so a maximized translucent window can also trigger a pause.

### Validation

Swift Testing unit tests cover saved settings, language selection and translations, independent volume and mute controls, power sources and transitions, combinations of pause reasons, login management through a fake service, and update checks through a fake network transport. Tests do not modify real login items or device power settings, and update tests do not contact GitHub:

```sh
./scripts/test.sh
```

To test coverage with real macOS windows without loading a video or changing settings:

```sh
./scripts/test-coverage.sh --run
```

This briefly opens small test windows within a 360 × 240 area. It checks normal rounded windows, partial and combined coverage, a separate process, and stopping background checks. All test windows close automatically; other apps' windows are unchanged. Use `--build-only` to compile without running it.

The integration smoke test requires an active graphical macOS session and a local video path. It temporarily displays that video on the desktop, checks app behavior, then removes the test wallpaper. Its settings are isolated from the regular app.

```sh
./scripts/smoke-test.sh "/absolute/path/video.mp4"
```

The test checks video restoration after relaunch, manual pause, and desktop coverage with real test windows. It saves images of its own window to `.build/verification/empty.png` and `loaded.png`. Leave part of the desktop visible for visibility checks; the test does not close other apps' windows. To compile without opening windows, use `./scripts/smoke-test.sh --build-only`.

A separate wallpaper library integration test checks import, applying saved entries with their settings, restoration, and deletion:

```sh
./scripts/test-wallpaper-library.sh "/path/to/video.mp4"
```

It requires a graphical macOS session and temporarily displays muted video in its own desktop test windows. Storage and preferences are isolated from the app; the system wallpaper, existing collections, and original video remain untouched. The test windows close after validation. To compile without running it, use `./scripts/test-wallpaper-library.sh --build-only`.

To check the linked screen saver in hidden test windows:

```sh
./scripts/build-screensaver.sh
./scripts/test-screensaver-sync.sh "/path/to/video.mp4"
```

This creates temporary media and an installer, switches videos and settings, checks recovery from unavailable data, and verifies compatibility with ordinary screen savers. It does not install a saver or lock macOS; it does not replace testing the System Settings preview.

To check the interface without showing windows or enabling wallpaper:

```sh
./scripts/render-ui.sh "/absolute/path/video.mp4"
```

The video path is optional. A supplied demo or local video is used for thumbnails and, when a built screen saver template is available, a temporary library with two entries in `.build/verification/ScreenSaverPreview-UUID`. The bundles receive a local ad-hoc signature through `codesign`; the temporary library is removed when rendering finishes. The script renders the app sections, screen saver list, empty library, and creation form in light and dark appearances, including compact variants. Update fixtures separately cover an available release, an in-progress check, an offline error, and an up-to-date app; the banner is saved separately as `ui-update-banner-wallpaper-*.png`. Standard README screenshots do not announce fictional releases. Additional fixtures cover login guidance for missing registration, a read-only disk, and a registration error. GitHub responses, login services, and the screen saver installer are fake: there are no real network requests, login-item changes, screen saver installations, or System Settings launches. Images are saved as `.build/verification/ui-*.png`, with `-compact` for compact variants. Settings are isolated and no desktop screenshots are taken.

### How it works

Separate AppKit windows sit at desktop level below Finder icons and let mouse clicks pass through. On each display, an `AVQueuePlayer` with an `AVPlayerLooper` plays the video. By default, the system wallpaper image stays unchanged while the app overlays its video. Enabling System Wallpaper from Video also saves a frame as the static macOS wallpaper using `NSWorkspace.setDesktopImageURL`; this frame remains after quitting MyWallpaper.

Launch at login uses [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice). Visibility is tracked through [AppKit window occlusion notifications](https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification), supplemented by checking window rectangles once a second. The additional check runs only when pause-on-hidden is enabled and animation is allowed. It reads window geometry; screen recording, window content access, and Accessibility permission are not required.

IOKit reports the power source through system notifications, without a timer. For startup in still mode, `AVAssetImageGenerator` extracts one frame and displays it until the video layer is ready. Pausing an already-playing video preserves its current frame.

`AppLocalizer` selects the Russian or English `Resources/*/Localizable.strings` catalog according to the app's language setting. Changing the language updates the interface and menus without changing macOS settings. Volume and mute are stored separately and applied to the video players; muting does not reset the chosen volume.

`UpdateController` requests the public GitHub API at `GET /repos/Illarioniche/MyWallpaper/releases/latest` and compares the installed app version with the latest stable release. Prereleases and drafts are not offered. The controller stores the automatic-check preference, the last attempt time for the daily interval, and the last successful check time. If a later check fails, a previously discovered update remains available. DMG, release-page, and SHA-256 links open in the browser. This mechanism does not install updates or modify app files.

The project is an MVP. The distributed DMG uses a local ad-hoc signature. Separate videos per display, a scene editor, and Developer ID signing/notarization are not yet implemented. Video wallpapers use CPU/GPU resources; energy use depends on resolution, frame rate, and the number of displays.
