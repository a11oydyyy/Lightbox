# Lightbox

Lightbox is a native macOS image material manager built with SwiftUI and AppKit.

The `main` line is the Lite personal gallery. The `full/finder-bridge` branch expands the same app into a Finder-like image browser for a local Library, pinned folders, local folders, and NAS-backed product catalogs.

## Requirements

- macOS 15 or newer
- Xcode / Command Line Tools with Swift 6.3 support
- GitHub CLI is optional, only needed for publishing changes

## Quick Start

```bash
git clone <repo-url>
cd Lightbox
swift build
./script/build_and_run.sh
```

For tests:

```bash
swift test
```

For a direct debug run without bundling:

```bash
swift run LightboxNative
```

## Project Layout

```text
Sources/LightboxNative/
  App/            App entry, commands, window configuration, shared state
  DesignSystem/   Glass, motion, spacing, radius, hover interaction primitives
  Domain/         Asset model, sources, filters, color tags, gallery mode
  Features/       Gallery, preview, shell, import UI
  Support/        Image loading, sources, index, local storage, drag/drop, clipboard, file watching
Tests/            Focused Swift tests
Docs/             Architecture notes
script/           Local build and run helper
```

## Local Data

The local Library is stored here by default:

```text
~/Library/Application Support/Lightbox/Library
```

New imports are copied into:

```text
~/Library/Application Support/Lightbox/Library/Imported
```

The fixed trash directory is:

```text
~/Library/Application Support/Lightbox/Trash
```

Pinned folders are referenced in place and can point at local folders or NAS-mounted folders. The app keeps a lightweight SQLite index at:

```text
~/Library/Application Support/Lightbox/Lightbox.sqlite
```

Adding or removing image files directly in the current folder is reflected through the directory monitor; `Cmd+R` manually refreshes the current location.

On first launch, the app migrates older local assets from:

```text
~/Library/Application Support/Lightbox/Imports
~/Downloads/素材
```

Those migrations are one-time user-default guarded copies into the default Library folder.

## Current Features

- Native macOS window with hidden title bar and polished light-mode visual system
- Local Library backed by real local files, not mock-only data
- Pinned folders for browsing paths in place
- Import by file picker or drag/drop into Library / Imported
- Top path bar with Library / pinned-folder picker, breadcrumb navigation, search, and multi-select state
- Directory row above the image gallery, independent from image thumbnail scale
- Local SQLite index for pinned paths and visible folder snapshots
- Drag images out to other apps as copied files
- Right-click menu with Copy, Move to Trash / Restore, Show in Finder, and macOS color tags
- Library / Trash / color-tag filtering from the bottom glass island
- Thumbnail size slider with animated resizing
- Masonry and square Grid gallery modes
- Mouse hover glow on image cards and visible SwiftUI buttons
- Single-click preview with animated open/close
- Multi-select with gray checkboxes, Cmd toggle, Shift range selection, and drag rectangle selection
- Fixed trash storage and empty Trash with no prompt

## Useful Commands

Build:

```bash
swift build
```

Run as an app bundle:

```bash
./script/build_and_run.sh
```

Run tests:

```bash
swift test
```

Verify app launch:

```bash
./script/build_and_run.sh --verify
```

Create the release app bundle and zip package:

```bash
./script/build_and_run.sh package
```

The main package is written to `dist/Lightbox-v1.3.2.zip`.
The macOS 13 / Intel-compatible package is written with:

```bash
./script/build_and_run.sh package13
```

That package is written to `dist/Lightbox-Intel-x86-v1.3.2.zip`.

This package is an internal test build. It is not signed with an Apple Developer ID and is not notarized, so Gatekeeper may show "damaged" or reject it after the zip is downloaded on another Mac. For internal testing, remove quarantine after copying it to `/Applications`:

```bash
xattr -dr com.apple.quarantine /Applications/Lightbox.app
```

For external distribution, use a Developer ID Application certificate and notarization instead of the default local package.

## Notes For Development On Another Mac

1. Clone the repo and run `swift build`.
2. Launch with `./script/build_and_run.sh`.
3. If the Library is empty, choose a Library folder, pin a folder, or import images.
4. If you want the same imported assets as this Mac, copy the Library folder from `~/Library/Application Support/Lightbox/Library` separately. Image assets are user data and are not stored in this repository.
5. The app icon is included at `Sources/LightboxNative/Resources/AppIcon.icns`.

## Current Architecture Status

The Full branch is file-system backed with a lightweight SQLite index. It scans supported image files from the current Library or pinned folder and the fixed Trash folder, reads dimensions with ImageIO, uses creation / added dates for sorting, and stores visible folder snapshots in SQLite. AB comparison and explicit file-management mode are planned next-phase features.
