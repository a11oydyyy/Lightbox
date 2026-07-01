# Lightbox Native Architecture Notes

## Audit

This repository was empty when the native rewrite started. There was no Electron source, database schema, import pipeline, or UI behavior available to migrate from this path.

## Current Implementation

- The app is a native SwiftUI/AppKit macOS executable built with SwiftPM.
- The Library is file-system backed, not SQLite-backed yet.
- The default Library folder is `~/Library/Application Support/Lightbox/Library`.
- The fixed Trash folder is `~/Library/Application Support/Lightbox/Trash`.
- Users can choose a custom Library folder; direct file changes in that folder are picked up by a directory monitor, with `Cmd+R` available as a manual refresh.
- Imports copy images into the selected Library folder while preserving source file names where possible.
- Trash operations move backing files into the fixed Trash folder.
- Image dimensions are read through ImageIO; sorting uses file added / creation / modification dates.

## User-Facing Surface

- Bottom glass island for Library / Trash / color tag filtering.
- Thumbnail size slider.
- Masonry and square Grid gallery modes.
- Single-click animated preview.
- Drag-out copy to other apps.
- Right-click Copy, Move to Trash / Restore, Show in Finder, and color tags.
- Multi-select with gray checkboxes, Cmd toggle, Shift range selection, drag rectangle selection, and floating count text.

## Target Architecture

- `App`: app entry, shared state, commands, window configuration.
- `DesignSystem`: glass, motion, spacing, radius, and hover interaction primitives.
- `Domain`: library assets, filters, tags, and import state.
- `Data`: future GRDB database, migrations, records, repositories if the file-backed model becomes limiting.
- `Services`: future library creation, file storage, sha256, metadata, thumbnails, preview generation, and import pipeline if dedicated generated derivatives are added.
- `Features`: shell, sidebar, gallery, preview, import UI, tags, trash, menus.
- `Support`: AppKit/SwiftUI bridges and platform helpers.

## Next Phase

1. Decide whether the current file-backed Library is enough for the near term.
2. Persist user-applied color tags instead of deriving tags from image dimensions.
3. Add multi-selected batch actions when the workflow needs them.
4. Add generated thumbnail / preview derivatives only if large-library performance requires them.
5. Consider GRDB only after the UI and library workflow stabilize.
