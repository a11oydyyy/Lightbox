---
name: Lightbox
description: A quiet, native macOS image browser where controls recede and visual material leads.
colors:
  system-accent: "#246BCE"
  gallery-canvas: "#F7F7F8"
  sidebar-surface: "#EEEEF0"
  floating-surface: "#FFFFFF"
  inspection-canvas: "#F2F2F3"
  primary-text: "#242426"
  regular-text: "#545458"
  muted-text: "#65656B"
  faint-text: "#65656B"
  divider: "#D8D8DD"
  content-stroke: "#D8D8DD"
  glass-stroke: "#D8D8DD"
  selected-surface: "color-mix(in srgb, AccentColor 8%, transparent)"
  hover-surface: "color-mix(in srgb, AccentColor 3.5%, transparent)"
typography:
  app-title:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "18px"
    fontWeight: 600
    lineHeight: 1.2
  surface-title:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: 1.2
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.35
  control-label:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: 1.2
  micro-label:
    fontFamily: "-apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "9px"
    fontWeight: 600
    lineHeight: 1.1
rounded:
  small: "5px"
  control: "9px"
  card: "10px"
  panel: "16px"
  capsule: "999px"
spacing:
  tight: "8px"
  regular: "12px"
  loose: "18px"
  page: "22px"
components:
  compact-active:
    backgroundColor: "{colors.selected-surface}"
    textColor: "{colors.primary-text}"
    typography: "{typography.control-label}"
    border: "none"
  floating-control:
    backgroundColor: "{colors.gallery-canvas}"
    textColor: "{colors.regular-text}"
    typography: "{typography.control-label}"
    rounded: "{rounded.capsule}"
    height: "36px"
  gallery-card:
    backgroundColor: "{colors.gallery-canvas}"
    rounded: "{rounded.card}"
  sidebar-row:
    textColor: "{colors.regular-text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    height: "30px"
---

# Design System: Lightbox

## Overview

**Creative North Star: "The Quiet Finder Gallery"**

Lightbox should feel like a highly refined Finder mode built specifically for visual material. It is native, compact, and calm: the window chrome communicates location and state precisely, while the gallery gives nearly all available attention to the images. The system follows macOS conventions before inventing custom behavior, then adds polish through restrained glass, semantic accent tint, and short state-driven motion.

This is an operating interface, not a marketing surface. Controls stay quiet at rest, become legible on hover, and state their selection without becoming heavy. Gallery content is allowed to be colorful; application chrome remains cool-neutral and uses the current macOS accent color as its only interaction voice.

**Key Characteristics:**

- Native macOS materials, system typography, SF Symbols, and familiar Finder behavior.
- Image-first white or system-canvas gallery with compact, floating navigation chrome.
- One shared compact-control state grammar: light accent tint plus stronger text, without a persistent outline.
- Dense but breathable controls, short labels, and middle truncation for paths and filenames.
- Fast, interruptible motion with a deliberate reduced-motion fallback.

## Colors

The palette uses cool, low-chroma neutrals and adapts to the macOS appearance. `LightboxColorTokens` owns surfaces and readable text; the system accent or user-selected hover color continues to own interaction states. The gallery and inspection canvases are flat, without a decorative gradient that changes image perception.

| Role | Light | Dark |
| --- | --- | --- |
| Gallery canvas | `#F7F7F8` | `#1C1C1E` |
| Sidebar | `#EEEEF0` | `#252527` |
| Floating controls | `#FFFFFF` | `#323234` |
| Image inspection | `#F2F2F3` | `#18181A` |
| Primary text | `#242426` | `#F0F0F2` |
| Secondary text | `#545458` | `#C5C5CA` |
| Muted text | `#65656B` | `#A4A4AC` |
| Disabled text | `#898991` | `#777780` |
| Hairline edge | `#D8D8DD` | `#48484F` |

The frontmatter lists light-mode values; the table and adaptive native tokens define both appearances. Material transparency remains user-adjustable. Text keeps a stable foreground color instead of compounding multiple opacity modifiers. Finder tag colors, photo pixels, and semantic warning/error colors are unchanged. Panels use the same neutral control family; sidebar tint sits below content and never over images. Preview uses a strongly neutral veil (88% in light, 90% in dark) to suppress color spill from the gallery; comparison uses the flat inspection canvas.

### Primary

- **App Accent:** Blue (#246BCE light, #70A9FF dark) is the sole interaction color. Use it for compact-control tint, focus, drop targets, progress, and content-selection glow.

### Neutral

- **Gallery Canvas:** The image field and default card surface. It stays visually quiet and must not tint product imagery.
- **Primary Text:** Current location, active tab, selected mode, and essential status.
- **Regular and Muted Text:** Inactive controls, metadata, secondary navigation, and helper content.
- **Divider and Content Stroke:** Hairlines only; they organize compact chrome without creating boxed panels.
- **Glass Stroke:** A faint light edge used only on floating material surfaces.

### Named Rules

**The One Accent Voice Rule.** Compact navigation and mode controls use the current accent color for hover, focus, selection, and drop targeting. Do not introduce a second navigation color.

**The Unified Active-State Rule.** Every compact navigation, filter, and mode control uses the same persistent active treatment: an 8% accent-tinted fill, semibold text, and no outline. Hover uses a lighter 3.5% tint or localized glow, also without an outline. A stroke is reserved for keyboard focus, file-drop targeting, and selected content objects where the boundary itself carries meaning.

**The Content Owns the Color Rule.** Finder color tags and the images themselves may be vivid. Window chrome remains neutral except for semantic state.

## Typography

**Display Font:** None. Lightbox does not use display typography.

**Body Font:** macOS system font (`-apple-system`) with native language fallback.

**Character:** Compact, functional, and quiet. Hierarchy comes from small changes in weight and opacity, not large size jumps, uppercase styling, or decorative type.

### Hierarchy

- **App Title** (semibold, 18px): Settings identity and rare high-level product naming.
- **Surface Title** (semibold, 12px): Current breadcrumb, popover status, and selected sidebar destinations.
- **Body** (regular, 12px): Settings rows, sidebar labels, metadata, and explanatory text.
- **Control Label** (medium; semibold when selected, 11px): Tabs, segmented modes, sort labels, and compact actions.
- **Micro Label / Icon** (semibold, 9–10px): Small symbols and dense supporting controls only.

### Named Rules

**The Weight-Before-Size Rule.** Prefer medium-to-semibold state changes before increasing type size. No interface label should imitate a page headline.

**The Middle-Truncation Rule.** Paths, filenames, and tab titles preserve both identity and extension where possible by truncating in the middle. The current breadcrumb receives the highest compression priority.

## Layout

Lightbox uses one application window with a minimum working size of 980 × 680.

- The continuous main header uses a 52pt AppKit titlebar accessory view, with a quiet bottom hairline and no enclosing capsules or automatic toolbar-item glass group. Interactive header content must never be drawn underneath the native titlebar.
- Native window controls use AppKit’s unified toolbar inset and remain inside the sidebar header; the adjacent sidebar toggle is a native toolbar item, aligned and hit-tested by AppKit. The sidebar surface extends into the titlebar safe area.
- Back, Forward and Up sit at the main header's leading edge; search, sort and operation status sit at its trailing edge. Header icon actions use shared AppKit NSButtons, including native disabled and keyboard behavior.
- The current folder title is geometrically centered in the gallery region. Equal left/right reservations prevent actions from pushing it off center.
- The current folder uses 14pt semibold pure black/white text. Ancestors occupy a smaller second line in the same header with crisp 11pt muted text; never blur navigation labels. Long ancestor paths truncate within the native path control; the current folder context menu preserves every ancestor.
- The header has an opaque adaptive canvas fill that masks scrolling content in both appearances. The header divider sits 52pt from the top, followed by 6pt of gallery spacing. Clicking outside the path editor cancels uncommitted edits and delivers the same click normally. Header fields suppress blue outer focus rings while retaining the native caret and text selection. Sorting uses an NSMenu with standard checkmarks and no custom popover surface.
- Tabs live in a vertical sidebar section with a fixed New Tab action above the scrolling list. Each row supports activation, closing, reordering, and image transfer; there is no top-header tab popover. Keyboard shortcuts remain available.
- The bottom scale and layout control is 34pt high and floats over content.
- The sidebar defaults to 236pt and may resize from 188pt to 360pt. Sidebar rows are 36pt high.
- Folder tiles stay compact and independent of image thumbnail scale. Gallery cards use masonry without text captions beneath the images. The bottom scope control switches between the current folder and all supported images in its subfolders; recursive results are grouped by relative folder path. Search follows that scope. Package contents and symbolic links are excluded; unreadable subfolders produce an incomplete-results notice rather than a silent cap.

## Elevation & Depth

Depth is hybrid but restrained. Gallery content is flat by default. Navigation, scale controls, preview information, comparison controls, and operation status may use translucent material because they float over content and need separation.

Floating capsules use a soft ambient shadow with an 8px blur and 3px downward offset; glass opacity is fixed at 85%. Ordinary controls use a neutral hover fill (6%) and pressed fill (10%), without scaling, pointer-following glow, or added shadows. Compact-control selection is communicated by tint and weight, not by an outline or another shadow.

### Named Rules

**The Glass Has a Job Rule.** Use glass only for chrome that literally floats over content. Do not wrap gallery tiles, settings sections, or ordinary rows in decorative glass.

**The Flat Content Rule.** Cards and tiles are flat at rest. Elevation appears only for interaction, preview transition, or floating shell separation.

## Shapes

The form language is continuously rounded and native rather than bubbly. Shape communicates component scale:

- **5px:** checkboxes, compact chips, and small selection rectangles.
- **9px:** buttons, popover rows, and sidebar/list rows.
- **10px:** gallery cards, folder tiles, and comparison panes.
- **16px:** large floating panels and preview information surfaces.
- **Capsule:** the outer tab rail, compact segmented modes, and floating gallery controls. The main titlebar has no enclosing capsule.

Borders are hairlines between 0.6px and 1px. Do not combine a prominent border with a prominent shadow. Pills are reserved for small controls and state, never for large content containers.

**The Shared-Radius Rule.** Components with the same role must use the same named radius token; do not introduce local corner-radius literals. Nested surfaces in one compound control must use the same shape family so their curves remain concentric after inset. For capsule pairs, both layers use the capsule token and their rendered radii scale with their heights.

**The Sibling-Consistency Rule.** Before changing UI, identify every sibling component that expresses the same state and update the shared token or component first. A new state treatment is incomplete until tabs, breadcrumbs, filters, sidebar destinations, popover rows, and other applicable siblings agree in both light and dark appearance. If an existing semantic category does not fit, define the new category here before introducing a local implementation.

## Components

### Buttons

- **Shape:** Circle, capsule, or continuously rounded 9px rectangle according to hit area.
- **Rest:** Neutral text or hierarchical SF Symbol; no opaque colored block.
- **Hover:** Accent-following localized glow or 3.5% tint, subtle scale, and low ambient shadow; no outline.
- **Press:** Brief compression followed by a small, damped release. Reduced Motion replaces spatial motion with a short fade.
- **Disabled:** Lower text opacity without changing geometry.

### Compact Active States

- **Canonical style:** `LightboxSelectionSurface` supplies the shared 8% accent tint without a persistent outline.
- **Text:** Medium at rest, semibold when selected.
- **Scope:** Tabs, current breadcrumb, layout mode, library/trash filters, sidebar destinations, selected popover rows, and future compact navigation or mode selections.
- **Hover:** Use `LightboxSelectionTokens.hoverFillOpacity` or the shared hover style; do not add a hover outline.
- **Exceptions:** Image selection uses a card glow and checkbox; Finder color tags keep their semantic color rings; keyboard focus and file-drop targeting may use a fine outline; native system controls keep native selected styling.

### Tabs

- **Geometry:** A 28px-high capsule segment inside a 36px glass capsule rail; both layers use the same capsule token, producing concentric curves across the 4px inset. Labels use 11px system text with middle truncation.
- **Active:** Subtle accent tint plus semibold text, without a complete inner outline. The close button appears on the active or hovered tab.
- **Hover:** A lighter accent tint without an outline.
- **Overflow:** Hidden tabs remain selectable and valid file-drop targets through the overflow popover.
- **Drag:** Tab reordering and cross-tab file drops are distinct interactions; only transient file-drop targeting adds a fine accent outline.

### Breadcrumbs and Header

- Current location is a centered, high-contrast title without a selection capsule. Ancestors are secondary clickable text underneath.
- Full ancestor access survives compression through the ellipsis menu; full paths are also available as tooltips.
- Clicking the current location or `⌘⇧G` opens the inline path editor. Return opens; Escape cancels. Context actions retain copy-path and pin-current-path.
- Header utilities use flat hover/focus tints. Search may expand inline while the centered title yields width symmetrically.
- File operation progress and multi-selection actions remain accessible in the same header.

### Gallery Cards and Folder Tiles

- **Cards:** 10px continuous corners with no persistent border, filename, or tag caption below the image.
- **Image Selection:** Accent glow plus a compact top-left checkbox; sticky multi-select remains visible until the last selected item is removed.
- **Folder List:** A collapsible count heading above an adaptive multi-column list. Rows are 36pt (44pt with search context), use blue folder icons, single-line middle truncation, and no persistent border or fill. Hover adds a quiet gray fill; selection adds a 10% accent fill. Single-click selects, double-click opens, and Command-click opens in a new tab. Context menus, Finder tag dots, and URL dragging remain available. Width is independent of image thumbnail scale.
- **Hover:** Keep the card flat and add a high-contrast dual-tone inner border that remains visible on both light and dark imagery; do not add a highlight gradient, sheen, or glow over the image.

### Sidebar

- **Header:** A fixed 48pt reserved area sits beneath the native window buttons and sidebar toolbar item; no duplicate SwiftUI toggle overlays the titlebar. The list scrolls independently below it. When collapsed, the toggle remains at the window’s upper leading edge, separate from tabs and path navigation.

- **Rows:** 36px high, 9px continuous corners, 13px system label, middle truncation.
- **Hierarchy:** Disclosure indentation uses 13px per depth level. Current destination uses the same 8% active tint and semibold text as other compact controls.
- **Actions:** Pin buttons appear when their row is hovered or any row control has keyboard focus, including for already-pinned folders. Keep their layout space and accessibility actions stable; the folder remains the primary click target.
- **Section headings:** Localize Pinned / Locations / Volumes (固定 / 位置 / 磁盘 in Simplified Chinese), using 11px semibold secondary text and 24px between groups. Pinned destinations are separated from locations by a quiet hairline.
- **Panel:** Use the native ultra-thin material as a quiet structural surface, with a faint 0.7px edge and a soft shadow offset 3px downward; avoid the refractive highlight of an interactive glass control.
- **Hidden items:** `⌘⇧.` toggles dot-prefixed files and folders globally. The same persisted setting governs gallery folder cards, recursive search, and expanded sidebar trees; Settings exposes the identical toggle.

### Tags and Inputs

- **Finder Tags:** Use the seven native Finder colors and native ordering. Selection is expressed with a ring, not a replacement fill.
- **Inputs:** Prefer native macOS sliders, segmented pickers, menus, toggles, and color pickers. Custom controls must preserve native focus, accessibility labels, and hit areas.

## Do's and Don'ts

### Do:

- **Do** use `LightboxSelectionSurface` for new compact selected navigation and mode controls.
- **Do** classify every new state as compact-control active, hover, keyboard focus, drop target, content selection, or semantic tag, then use that category's shared component and token.
- **Do** keep tabs, path, search, sort, and progress on one top row.
- **Do** use system typography, SF Symbols, dynamic appearance colors, and the unified app accent.
- **Do** keep images dominant and validate both the 980px minimum window and a wide window.
- **Do** provide hover, focus, selected, disabled, loading, failure, cancellation, and reduced-motion states where applicable.
- **Do** use middle truncation for paths, tab names, and filenames.
- **Do** reuse the same named radius token for every instance of a component and every layer of a compound control.

### Don't:

- **Don't** use an opaque gray pill or persistent outline for compact selected controls.
- **Don't** define selection or hover colors, opacities, strokes, or weights locally when a shared token or component exists.
- **Don't** nest a fully outlined tab capsule inside the fully outlined glass tab rail.
- **Don't** introduce a one-off corner radius when an existing shape token describes the component role.
- **Don't** create a second toolbar row as tabs or status controls grow.
- **Don't** use decorative glass, nested cards, marketing copy, display headlines, or persistent captions below gallery images.
- **Don't** introduce custom icons when an appropriate SF Symbol exists.
- **Do** use the shared adaptive blue accent; custom global color pickers and stored glow overrides are not part of the UI.
- Sidebar icons use flat, mostly filled SF Symbols with hierarchical rendering and no tile background. Folders default to the app blue and inherit their first Finder color tag when tagged. Other locations use blue, downloads green, photos orange, movies purple, music/trash rose, and disks neutral gray. Finder bitmap icons are not used. Labels remain neutral.
- **Don't** restore transient selection, preview, comparison, or unfinished file operations after relaunch.

Gallery cards remain geometrically fixed under hover; PreviewSpace is defined on the gallery/preview shared internal container, inside the full-size titlebar safe-area handling. Shared feedback uses critically damped motion and respects Reduce Motion.

Sidebar folders collapse immediately without animation; expansion fades children in place within a clipped subtree. Gallery hover uses a single subtle exterior outline with a gap from the image, without painting over image pixels.

### Fixed folder sizing and glass opacity

- Folder tiles use a fixed 180pt adaptive minimum; no folder-width slider or disclosure arrow is exposed. Image thumbnail sizing remains adjustable.
- Glass opacity is fixed at 0.85 in both appearances; historical user opacity values are ignored. Sidebar width remains independently adjustable.

### Interaction consistency

- Ordinary controls share `LightboxButtonHoverStyle`; native titlebar controls use the same neutral 6% hover / 10% press values. Disabled controls do not gain hover feedback.
- Persistent control selection uses the shared 8% accent surface. Image selection uses a 1.5pt accent outline outside the image; keyboard focus uses a neutral 1.5pt marker, distinct from selection.
- Standalone icon actions use a 32pt hit target, 14pt symbol and 8pt hover radius. Compact close-tab and tag controls remain purpose-sized within their rows.
- Primary, secondary and supporting copy use `primaryText`, `secondaryText` and `mutedText`; image/tag overlays may keep contrast-specific treatments.
- Floating tool/status surfaces share an 8pt shadow blur with a 3pt vertical offset. Image-preview depth and native popovers remain separate semantic layers.
