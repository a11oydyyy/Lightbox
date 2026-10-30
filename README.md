<p align="center">
  <img src=".github/media/icon.png" width="128" height="128" alt="Lightbox app icon">
</p>

<h1 align="center">Lightbox</h1>

<p align="center">
  <b>A fast, lightweight image browser for Mac.</b><br>
  Browse, cull and organize photos right where they live — no import, no catalog.<br>
  A free Adobe Bridge alternative for photographers who edit in Camera Raw.
</p>

<p align="center">
  <a href="https://github.com/a11oydyyy/Lightbox/releases/latest"><img src="https://img.shields.io/github/v/release/a11oydyyy/Lightbox?label=download&color=2f2f2f" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-2f2f2f" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-native-2f2f2f" alt="Apple Silicon and Intel">
  <img src="https://img.shields.io/badge/languages-EN%20%C2%B7%20%E7%B9%81%E4%B8%AD%20%C2%B7%20%E7%AE%80%E4%B8%AD%20%C2%B7%20%E6%97%A5%E6%9C%AC%E8%AA%9E-2f2f2f" alt="English, Traditional Chinese, Simplified Chinese, Japanese">
</p>

<p align="center">
  <b>English</b> · <a href="README.zh-Hant.md">繁體中文</a> · <a href="README.ja.md">日本語</a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/media/hero-dark.jpg">
  <img src=".github/media/hero-light.jpg" alt="Lightbox showing a folder of photos from all its subfolders in a masonry grid, grouped by folder, with tabs and locations in the sidebar">
</picture>

## Why Lightbox

- **Your folders are the library.** Open any folder on your Mac, an external drive or a NAS and start browsing. Nothing is imported, copied or locked into a catalog, so Finder, Photoshop and every other app keep seeing the same files.
- **Made for Camera Raw workflows.** See at a glance which photos you have already edited in Adobe Camera Raw or Lightroom, cull with single keys, and export finished JPEGs through Photoshop — the parts of Adobe Bridge most photographers actually use, without the weight.
- **Feels like part of macOS.** Native, quick to open, light and dark, keyboard friendly, with tabs, Quick Look, color tags and undo where you expect them.

## Features

### Browse folders, not a library

<img src=".github/media/browse.gif" alt="Photos from all subfolders grouped by folder, collapsing a group, and enlarging the thumbnails">

- Tabs, pinned folders, back and forward, and a sidebar with your usual locations and drives
- A masonry photo grid that keeps every image's shape, or a list view with sortable columns
- **Include subfolders** to see a whole shoot at once, grouped by folder; collapse the groups you don't need and Lightbox remembers them
- A thumbnail slider, plus one-click steps of one image per row (⌘= / ⌘−)

### See what you've edited in Camera Raw


- A small mark on every photo with Camera Raw or Lightroom develop settings, read from `.xmp` sidecars for RAW files and from embedded XMP for JPEG, TIFF and DNG — the same thing Bridge shows
- Filter to **Edited** or **Not Edited** to find what is left to do
- RAW sidecars travel with their photo when you rename, copy, move or trash it in Lightbox

### Preview, zoom to 100%, and cull with one key

<img src=".github/media/preview-cull.gif" alt="Opening a preview, zooming to 100% to check detail, and marking a photo to keep with one key">

- Click a thumbnail for a large, fast preview; step through with the arrow keys
- Press **Z** to check focus at 100%, drag to look around, and keep the same spot while stepping through a burst
- Press **P** to keep, **X** to reject and **U** to clear — stored as standard Finder color tags, so the picks show up everywhere
- Camera, lens and exposure details, and a compare tray for choosing between similar shots

### Sort and filter without the clutter

<img src=".github/media/sort-filter.gif" alt="The Sort and Filter panel, and an active filter appearing as a small chip beside the bottom bar">

- Sort by name, date added, size, kind, dimensions or tags
- Filter by kind (photos, RAW, videos, documents), orientation, long edge, date added, file size and Camera Raw state, and by Finder color tag
- Active filters appear as a small chip you can clear with one click; search by file name across subfolders

### Organize files like Finder — with undo

- Rename one file or a whole batch (replace text, add text, or name and number), create folders, and move to Trash, all with ⌘Z
- Drag photos between tabs to copy or move them; drag them out to any app
- Quick Look, Show in Finder, Open With, and an option to show non-image files too

### Export JPEGs through Photoshop


Lightbox's take on Bridge's **Image Processor**: select photos, choose **Export as JPEG…**, and Photoshop opens each one with its Camera Raw settings applied and saves a JPEG — quality, sRGB conversion and an optional long-edge limit included. Originals are never touched and nothing is overwritten. **Open in Photoshop** is one click away for everything else.

> Only Adobe's engine can render Camera Raw edits, so exporting needs Photoshop installed. Browsing, culling and organizing do not.

### Made for the Mac

- Light and dark appearances that follow the system, with optional glass styling
- Full keyboard control and VoiceOver labels
- English, Traditional Chinese, Simplified Chinese and Japanese
- Checks for updates and asks before installing

## Keyboard shortcuts

| Action | Keys | Action | Keys |
| --- | --- | --- | --- |
| New tab / close tab | ⌘T / ⌘W | Preview / Quick Look | Space / ⌘Y |
| Back / forward | ⌘[ / ⌘] | Zoom preview to 100% | Z |
| Enclosing folder | ⌘↑ | Keep / reject / clear | P / X / U |
| Go to folder | ⇧⌘G | Rename | ⇧⌘R |
| Search | ⌘F | New folder | ⇧⌘N |
| Sort & Filter | ⌥⌘F | Move to Trash | ⌘⌫ |
| Larger / smaller thumbnails | ⌘= / ⌘− | Open in Photoshop | ⌥⌘O |
| Gallery / list | ⌃⌘1 / ⌃⌘2 | Export as JPEG | ⇧⌘E |

## Download

Get the latest version from **[Releases](https://github.com/a11oydyyy/Lightbox/releases/latest)**.

| Package | Requirements |
| --- | --- |
| `Lightbox-v*.zip` | Apple Silicon, macOS 15 or later |
| `Lightbox-Intel-x86-v*.zip` | Intel or Apple Silicon, macOS 13 or later |

The Intel package contains both architectures and runs natively on Apple Silicon too. Release notes list the signing status and known limitations of each version.

## FAQ

**Is Lightbox an Adobe Bridge alternative?**
For browsing folders, checking Camera Raw edits, culling and batch JPEG export, yes. It deliberately leaves out keywords, collections and output templates to stay small and fast.

**Does Lightbox import or change my photos?**
No. It reads your folders where they are. It only changes files when you ask — renaming, moving, tagging or trashing. Renaming, tagging and trashing can be undone. Moving files between tabs cannot yet be undone and clears earlier undo history.

**Does it support RAW files?**
Yes: CR3, CR2, NEF, ARW, RAF, ORF, RW2, DNG and other formats macOS can read. Previews show the original RAW; Camera Raw edits are rendered by Photoshop when you export.

**Can I use it as a photo viewer instead of Preview or Photos?**
Yes. It opens straight onto a folder, previews with one click and steps with the arrow keys, without importing anything into a library.

**Does it work with external drives and NAS?**
Yes. Network and removable volumes are loaded conservatively so large shares stay responsive.

## Feedback

Found a problem or have an idea? Open an [issue](https://github.com/a11oydyyy/Lightbox/issues) and include your Lightbox version, macOS version and Mac chip.

<sub>Demo photography courtesy of the contributing photographers on <a href="https://unsplash.com">Unsplash</a>.</sub>

<sub>Keywords: Mac image browser · macOS photo viewer · Adobe Bridge alternative · Camera Raw · XMP sidecar · photo culling · RAW viewer · Finder for photos · batch rename · JPEG export</sub>
