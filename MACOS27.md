# Testing Ice 0.12.0-brakedalen.17 on macOS 27

The `main` branch includes `custom-build` through b16 (`df3b563`) and the
macOS 27 compatibility branch (`740fb0c`). The app version is
`0.12.0-brakedalen.17`, build `1155`. Custom automation, spacers, multi-account
OneDrive handling, coordinated image capture, permission lifecycle and
performance changes remain in the source. See [b17 QA notes](docs/QA-b17.md).

This fork integrates the macOS 27 implementation from
[upstream PR #995](https://github.com/jordanbaird/Ice/pull/995), at commit
`ce40c87ebd73afa8fa8e67d124c0d2ae47aa95d8`, together with its prerequisite
macOS 26 development code. The PR is still open. Attribution for the GPLv3
assessment-mode implementation is retained in `MenuBarAssessmentAssertion27.swift`.

macOS 27 renders status items in MenuBarAgent instead of separate windows.
Ice therefore reads items through Accessibility, captures their images from
the menu bar, and hides applications through dynamically loaded
MenuBarClientCore assessment assertions. These paths run only on macOS 27+;
the deployment target remains macOS 14.

## Run from Xcode

1. Use Xcode 27 with the macOS 27 SDK. Quit any other copy of Ice first.
2. Open `Ice.xcodeproj`, select the **Ice** scheme and **My Mac**, and run the
   **Debug** configuration. Both targets default to ad hoc signing for Debug;
   no author's development team is required. Hardened runtime is disabled only
   for Debug to allow the bundled Sparkle framework to load with this signature.
3. Grant **Accessibility** and **Screen & System Audio Recording** to this build
   in System Settings. An old permission entry may refer to a different
   signature; remove it and grant access again if needed, then restart Ice.
4. Open **Menu Bar Layout** and assign applications to Visible, Hidden and
   Always Hidden. Ice attempts to migrate the previous divider layout once,
   but a layout already rearranged by macOS must be assigned manually.
5. Disable automatic update checks/downloads while testing this fork to prevent
   the official update feed from replacing it.

For a certificate-signed build, select your own signing team/identity for both
Ice and MenuBarItemService. Release keeps hardened runtime enabled. If you
choose to install a local Release build, `Scripts/install.sh` handles signing
and verification, and disables hardened runtime for that local build only.
The script replaces an existing Ice installation in `~/Applications` by default.

## Checks on your Mac

- Toggle Hidden and Always Hidden, using both the Ice icon and hotkeys.
- Open Ice Bar and click a hidden application; confirm its menu opens.
- Move an application between layout rows, quit Ice and reopen it; confirm the
  section persists. macOS controls ordering within a row.
- Launch a hidden application after Ice, including a variable-width item such
  as AlDente. Confirm it gets its normal width when revealed
  ([#1007](https://github.com/jordanbaird/Ice/issues/1007)).
- Click the clock, Wi-Fi, battery and Control Centre while items are hidden.
- Test hover, fullscreen, light/dark mode and an external display if available.
- During a camera/microphone session, check the replacement capture indicator
  and its Control Centre action, then confirm it disappears after recording ends.

Run `swift test` from the repository root for the pure compatibility rules.
The package also runs on Linux; passing these tests does not validate Apple's
private APIs, Xcode compilation, code signing or the graphical application.

Validation results for the merged custom build are recorded in
[b17 QA notes](docs/QA-b17.md). The Xcode build and the manual macOS checks
above have not been run in this Linux environment.

## Known limitations

- Assessment allowlists may not retain Ice's own icon in ad hoc/development
  builds. Upstream reports Developer ID/App Store signing is needed to retain
  it reliably. Configure a hotkey before hiding items and test signing on
  your machine.
- Sections apply to an entire application, rather than individual icons owned
  by the same application. Items cannot be reordered within the native bar.
- Custom automation uses app sections on macOS 27. When rules or sibling icons
  request different sections, the most visible section wins. Native neighbor
  positions and independently moving Ice-owned spacers remain available on
  earlier macOS; macOS 27 cannot restore those positions through this backend.
- System-item clicks can briefly reveal concealed items and add latency.
- A crowded notched display can leave items folded away. The layout pane
  offers explicit relaunch buttons; save work in the selected app before using one.
- The implementation uses private macOS APIs and may need adjustment for later
  OS builds. Compatibility must be verified on your exact OS build.

Relevant reports: [#954](https://github.com/jordanbaird/Ice/issues/954),
[#965](https://github.com/jordanbaird/Ice/issues/965),
[#1006](https://github.com/jordanbaird/Ice/issues/1006) (layout migration and
Sparkle/signing), and [#1007](https://github.com/jordanbaird/Ice/issues/1007).
