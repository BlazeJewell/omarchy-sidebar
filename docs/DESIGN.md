# jake.sidebar design guide

This is the design language, UI guide and layout guide for the sidebar. The
[README](../README.md#design-philosophy) explains *why* the desktop is shaped the
way it is. This guide covers *how* to build things that fit it: tokens,
components, layout rules and motion. The numbers come from `Sidebar.qml`, so if
you change one there, change it here too.

**Contents:**
1. [Design language](#1-design-language)
2. [Foundations: color, type, space, shape](#2-foundations)
3. [Layout guide](#3-layout-guide)
4. [Components](#4-components)
5. [Motion](#5-motion)
6. [Writing](#6-writing)
7. [Checklist for new UI](#7-checklist-for-new-ui)

---

## 1. Design language

Five principles. When two of them conflict, the earlier one wins.

| Principle | In practice |
| --- | --- |
| **One column** | Everything lives in the left panel: menu, settings, notifications, widgets. Nothing opens in the middle of the screen except the overview. New UI goes *in* the column or *over* it, never beside it. |
| **The rest is for apps** | Everything beside the panel belongs to your apps: one at full size by default, or several side by side (windows of the same app, Shift+click or drag-and-drop). The panel never covers an app unless asked to: auto-hide, quick settings and the overview are the only exceptions. A fullscreen app takes the whole monitor, panel included; tap Super to bring the panel back over it with the overview. |
| **Words first** | Apps and settings are listed by name. An icon supports a label and never replaces it (exceptions: the bottom row and tray, where space is tight and the icons are standard). |
| **Two levels of contrast** | Content is bright (`foreground`) and everything about it is dim (`dim`). Colour is not used for hierarchy. The one accent (`urgent`) means "this needs you" or "this is the current one". |
| **Calm** | Nothing moves unless you act. Each change gets one motion, in one direction, and it explains where something came from or went. |

### What it is not

- **Not a dock.** Rows are full-width text, not icon tiles.
- **Not a dashboard.** Values are plain figures with a unit, not gauges or rings
  (except small bars where a trend reads faster).
- **Not themed separately.** It takes its colours and font from Omarchy's
  current theme, so a theme switch restyles it without any work here.

---

## 2. Foundations

### Color

The palette has five tokens, all taken from the active Omarchy theme. Don't use
hex values in components.

| Token | Source | Use |
| --- | --- | --- |
| `foreground` | `Commons.Color.bar.text` | Primary content: the time, values, app names, selected items, switch "on" |
| `dim` | `foreground` at 55% | Labels, units, captions, hints, inactive items, chevrons |
| `faint` | `foreground` at 12% | Dividers, outlines, the focused app row, selected-row fill |
| `background` | `Commons.Color.bar.background` | Panel fill; text on a `foreground` fill (selected segment) |
| `urgent` | `Commons.Color.bar.active` | The theme accent: focused-app bar, drop targets, destructive hover ("forget"), muted labels |

**Surface tints.** A surface is `foreground` at a low alpha laid over the
panel. Use only these steps:

| Alpha | Use |
| --- | --- |
| 0.05 | Resting surface: settings section body, footer buttons |
| 0.06 | Hover on a row or header |
| 0.12 | Selected row (`ChoiceRow`), pressed or hover on footer buttons, `faint` |
| 0.16 | Inactive slider track, switch track when off |
| 0.18 | Accent wash (`urgent` at 0.18): spring-loaded drop target, update available |

**Panel background.** `general.background` is `solid` (opaque) or `glass`
(80% opacity). When the panel is styled like a window (*Apply to: sidebar/both*),
it is inset by Hyprland's gap and uses the theme's window border colours.

### Typography

There is one family, the theme's monospace font (`Style.font.family`, exposed as
`root.fontFamily`). Being monospaced means figures line up and don't jump as
they change, so don't add a second family.

| Role | Size (px) | Weight | Colour | Example |
| --- | --- | --- | --- | --- |
| Display | 30 | Light | foreground | Clock |
| Figure | 22 | Bold | foreground | Network rate |
| Title | 14 | Bold | foreground | "Edit sidebar" header |
| Heading | 12 | Regular; Bold when open | foreground | Settings section header |
| Body | 11 | Regular | foreground / dim | App name, switch label, choice row |
| Small | 10 | Regular | dim | Status text, hints, button labels, "Nothing is playing" |
| Caption | 9 | Regular, **UPPERCASE**, letter-spacing 1 | dim | `OUTPUT`, `POWER MODE`, `WI-FI NETWORKS` |
| Micro | 8 | Regular | dim | Labels under icon buttons (Lock, Sleep…) |

Rules:
- **Bold is for state, not for decoration.** Use it for an open section, a
  selected segment or something that needs attention ("Update rice · 3 new").
- **Captions are the only uppercase text.** Everything else is sentence case.
- Write units in `dim` next to a `foreground` value, either as separate Text
  items or with a small gap: `44` `%`, `13` `Kbps`.
- Always use `textFormat: Text.PlainText` for text that comes from outside
  (window titles, SSIDs, device names).

### Spacing

Spacing comes from a 2-px base. These are the steps the code uses:

| Step | Use |
| --- | --- |
| 2 | Between settings section headers; tight icon rows |
| 4 | Segmented buttons; row + trailing action |
| 6 | Inside a settings body (between rows); between footer buttons |
| 8 | Label to control inside a row; chips |
| 10 | Icon to label in a header or app row; body padding |
| 14 | **Between panel sections** (the main column); app-row left inset |
| 16 | Panel content inset from its edges (top, left, right) |

### Shape

| Radius | Use |
| --- | --- |
| 1–3 | Indicators: focus bar (3×18), running dot (5×5), slider track (4 high) |
| 4–5 | Small controls: segmented buttons, choice rows, inputs |
| 6 | Rows and buttons: app rows, section headers, footer buttons |
| 8 | Containers: settings section body, switch track (pill) |

Dividers are 1 px `faint`. Outlines are 1 px `faint` (resting) or `dim`
(a focused input).

### Control heights

| Height | Control |
| --- | --- |
| 36 (30 compact) + 4 with hints | App row (`root.rowH`) |
| 34 | Settings section header |
| 28 | Switch row, footer button, password input |
| 26 | Choice row, segmented button |
| 24 | Slider row, link row |
| 16 | Switch track (30 wide); knob 12 |

---

## 3. Layout guide

### The frame

```
┌─────────────── screen ────────────────────────────────┐
│┌── panel ──┐┌───────────── the app ──────────────────┐│
││ 16 inset  ││                                        ││
││ clock     ││                                        ││
││ system    ││     one app, full size                 ││
││ workspaces││     (tiles only with its own windows   ││
││ search    ││      or after Shift+click)             ││
││ apps ↕    ││                                        ││
││ …widgets  ││                                        ││
││───────────││                                        ││
││ bottom row││                                        ││
│└───────────┘└────────────────────────────────────────┘│
└───────────────────────────────────────────────────────┘
```

- **Width:** 280 by default. Drag the panel's right edge to resize it between
  220 and 400, in steps of 10. The width is remembered per resolution.
- **Exclusive zone:** the panel reserves its width, so windows never go under
  it. With auto-hide it tucks into a **4 px edge**: in *float* mode it slides
  over the app, and in *push* mode the app makes room.
- **Content inset:** 16 px on the top, left and right and 10 px on the bottom,
  plus the window gap and border when the panel is styled like a window.
- **One panel per monitor.** The menu, quick settings and the overview open on
  the monitor you're using.

### Section order

Sections stack top to bottom in one column with **14 px** between them. The
default order goes from glance to act:

1. **clock** — the time (Display type) and the date (dim)
2. **system** — CPU, memory, disk, GPU and temperature as figures, plus network rates
3. **workspaces** — numbered chips
4. **search** — the entry to the Super+Space menu, which types in place
5. **apps** — pinned apps, then running ones; this is the only section that grows to fill the space
6. **widgets** — Omarchy plugins and panels placed as sections (e.g. agents)
7. **bottom** — the settings gear on the left; plugin icons or workspace chips
   on the right (*Edit sidebar › Bottom row › Right side*); pinned to the bottom edge
8. **media / notifications** — appear when there's something to show

The order, visibility and per-section options live in
`~/.config/omarchy/sidebar-settings.json` (`order`, `extras`, per-section keys)
and are edited in place with *Edit sidebar*.

Rules:
- **Only one section flexes.** The app list takes the leftover height and
  scrolls. Every other section has a natural height, or a `maxH` with
  `fit: squeeze` for widgets.
- **Sections are full-width.** No side-by-side sections. Inside a section, a row
  may split into columns (e.g. stats, network down/up).
- **A section has no title by default.** Its content is its title, e.g. the
  time or the app list. Widgets may show a caption (`title: true`).

### Overlays on the panel

Some UI covers the panel instead of opening beside it, anchored to where it was
summoned from:

| Overlay | Anchored to | Size |
| --- | --- | --- |
| Quick settings | Bottom (over the gear) | Content height, up to the panel's height; scrolls beyond |
| Menu / search results | The search field | Fills down to the bottom row |
| Tray menu, calendar, dock panels | The item that opened it | Content height |
| Notifications | Top | Stack, newest first |

Overlay surfaces use the panel's own fill (`background`, opaque under glass),
so they read as part of the panel rather than as a popup over it. A 1 px
`faint` line marks the top edge of a bottom-anchored overlay.

### Quick settings layout

Quick settings is an **accordion**: one list of section headers, with only one
section open at a time, and **every control lives inside its open section**.
There are no detail pages and no "more ›" links to settings that could be shown
in place. Links are only for leaving the panel's scope (e.g. *Theme &
background* opens the menu).

```
 ⌂  Network                Ethernet  ›     ← SectionHeader (34)
 ⌂  Sound                       44%  ˅     ← open: bold label, ˅
 ┌───────────────────────────────────┐
 │ OUT  ━━━━━━━━●───────────   44%   │     ← SliderRow
 │ MIC  ━━━━━━━━━●──────────   47%   │
 │ OUTPUT                            │     ← Caption
 │  ● USB Audio                      │     ← ChoiceRow (selected)
 │  ○ MPG 274U                       │
 │ APPS                              │
 │ Nothing is playing                │     ← empty state, Small/dim
 └───────────────────────────────────┘     ← SectionBody (0.05, r8, pad 10)
 ⌂  Power                Performance  ›
 [ Edit sidebar ] [ All settings ]         ← footer buttons (28)
 [        ✓ Rice up to date        ]
```

Order inside a body: **master switch → status line → captioned groups → link**.
Each caption names the group below it. A group that would be empty shows a
one-line dim empty state instead of disappearing (e.g. "Looking for devices…").

Work that costs something follows the open section: Wi-Fi scanning, Bluetooth
discovery and the DNS and display polls run only while their section is open.

---

## 4. Components

These are all declared inline in `Sidebar.qml` as `component Name: …`. Reuse
them rather than restyling one-offs.

| Component | Anatomy | Behaviour |
| --- | --- | --- |
| **SectionHeader** | icon (16 wide) · label (Heading) · status (Small, dim, ≤110 px, elided) · chevron `›`/`˅` | Click toggles the section (`root.toggleSection`); hover 0.06 when closed |
| **SectionBody** | Rounded 8 container, 0.05 tint, 10 padding, 6 spacing | Holds rows; never nested |
| **SwitchRow** | label (Body) · optional hint (Small) · pill switch 30×16 | Whole row is the hit area. On = `foreground` track with a `background` knob |
| **SliderRow** | caption-style label (9, tracked; tap to mute, shows `urgent` when muted) · 4 px track · 12 px knob · % or "mute" | Click, drag or scroll (±5%) |
| **ChoiceRow** | 6 px radio dot · label · hint | One-of-many lists (outputs, networks, devices). Selected = 0.12 fill, filled dot, bright label |
| **Segmented** | Equal-width buttons, 26 high, r5, 4 apart | One-of-few options (power mode, DNS, scale). Selected = `foreground` fill, `background` bold text; others 1 px `faint` outline |
| **Caption** | Caption type, 4 px top margin | Names the group below it |
| **LinkRow** | Small dim text + ` ›` | Only for leaving the panel's scope |
| **App row** | dot or bar indicator · optional 18 px icon · name (Body) · optional hint line | See the states below |

### App row states

| State | Look |
| --- | --- |
| Not running (pinned) | Name dim, icon 70% |
| Running | 5 px `dim` dot on the left edge |
| All windows minimized | Hollow dot (1 px `dim` ring) |
| Focused | `faint` row fill, plus a **3×18 `urgent` bar** on the edge (indicator = bar) |
| Hover | 0.06 fill |
| Drop target (drag) | `urgent` at 0.18 |
| Several windows | Expands to list each window (30 px rows) |

The focused app is the **only** accented row on the panel. Don't add another
highlight that competes with it.

### Buttons

- **Footer buttons** (*Edit sidebar*, *All settings*, *Update*): 28 high, r6,
  0.05 rest, 0.12 hover, small icon + Small label, centred, and equal width
  when side by side.
- **Icon buttons** (power actions): 40 high, glyph 13 over a Micro label, no
  outline, 0.12 hover.
- **Destructive actions** ("forget"): dim text that turns `urgent` on hover,
  with no confirmation for reversible things.

---

## 5. Motion

All motion starts from or ends at the panel. One change gets one movement.

| What | Motion | Timing |
| --- | --- | --- |
| A new app opens | Slides in from the left (out of the panel) | Hyprland `windowsIn`, 410 ms, easeOutQuint |
| The previous app leaves / is minimized | Slides out to the left, behind the panel, then hides | `windowsOut`, 250 ms, easeInOutCubic |
| Restoring a minimized app | Slides in from where it was parked, off the left edge | follows `windowsMove` |
| Panel tuck / untuck (auto-hide) | Slides the panel by its width minus 4 px | same duration and curve as Hyprland's window move (`root.winAnimMs`, `winAnimCurve`), so the panel and windows move together |
| Panel over a fullscreen app | Slides in with the overview; slides out after it closes | 220 ms, InCubic |
| Overview | Previews zoom out from their windows into the grid while the backdrop fades | 280 ms, `Style.easeOut` |
| Switch knob, small state changes | Position change | 120 ms, OutCubic |
| Quick settings / notifications | Slide over the panel from their anchor edge | — |

Rules:
- **Use `Style.duration(ms)` for every duration**, so Omarchy's global
  animation speed (and "animations off") applies.
- **Tie panel motion to Hyprland's** timing by reading `hyprctl animations`
  (`animProc`) instead of hard-coding it, so windows and panel never drift
  apart.
- **Nothing loops or idles.** Spinners appear only while work is happening
  (the update check).
- **Don't fade text in and out to show a state change.** Swap it.

---

## 6. Writing

- **Sentence case** everywhere ("Do not disturb", "Stay awake"). Only Captions
  are uppercase.
- **Short labels, plain words.** Use "Saver / Balanced / Performance", not
  "Power-saving profile".
- **Status says the state, not the setting**: "44%", "Ethernet", "2 hidden",
  "Silenced".
- **Empty states say what to do or what's happening**: "Turn Bluetooth on to
  scan", "Nothing is playing".
- **Ellipsis for ongoing work**: "Checking for updates…", "Updating…".
- Use `·` (middle dot) to join facts in one line: "4K · 160 Hz", "Update rice ·
  3 new".

---

## 7. Checklist for new UI

Before adding a section, setting or overlay:

- [ ] It lives in the column (or over it), not in a new window or popup.
- [ ] Its colours come from the five tokens and the alpha steps, with no hex
      values.
- [ ] It uses the type scale, and captions are the only uppercase text.
- [ ] It reuses `SectionHeader`, `SwitchRow`, `SliderRow`, `ChoiceRow`,
      `Segmented` and `Caption` where they fit.
- [ ] Settings are editable where they're shown, with no detail page and no
      "more ›" link for something that fits in the section.
- [ ] Only the app list flexes. Anything else has a natural height or a `maxH`.
- [ ] Polling or scanning runs only while the thing is visible.
- [ ] Motion uses `Style.duration` and comes from or goes to the panel.
- [ ] Outside text uses `Text.PlainText` and elides.
- [ ] It works at 220 px width and on a second monitor.
