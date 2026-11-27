# jake.sidebar — everything in one left panel

![The sidebar on a single monitor](docs/mock-single.png)

A rice for [Omarchy](https://omarchy.org) that replaces the top bar with one vertical panel on
the left. The clock, system stats, workspaces, the Super+Space menu, your apps, settings,
notifications and widgets all live in it, and the rest of the screen belongs to your apps.

Requires an Omarchy install with the Lua Hyprland config (Omarchy 4+).

## Design philosophy

### Everything in one place

A desktop usually spreads its controls around the screen: a bar on top, a launcher in the
middle, a dock at the bottom, popups in the corners. Here they share **one column on the
left**. Your eyes and your pointer always go the same way to find something, and nothing opens
in the middle of your work.

- **The Super+Space menu types into the panel.** The full Omarchy menu, app search and the
  clipboard all open there instead of in a centred popup.
- **Quick settings slide over the panel itself**: network, sound, display, power and updates.
- **Notifications appear inside the panel**, at the top, sliding in from the edge over
  what's there and away again when they're done.
- **Any Omarchy panel can be a section**, such as media, notifications or AI agents, and its
  keyboard shortcut opens it in place.

Why the left? Screens are wide, so a column costs less than a bar costs in height. A column
reads like a list, top to bottom, and the panel ends where the app's own content begins, which
is also where you start reading.

### The rest is for apps

Everything beside the panel belongs to your apps. Clicking an app shows **that app, full
size**, and the one before it slides out to the left. When you want several side by side,
they tile: windows of the same app do it on their own, and Shift+click or drag-and-drop in
the panel places another app next to the current one. The panel never covers an app unless
you ask it to (auto-hide, quick settings and the overview).

A **fullscreen** app or game takes the whole monitor, panel included. Tap Super and the panel
slides back over it with the overview, then slides away again when you're done.

Every motion starts from the panel: apps slide in from the left, minimized apps slide back
into it, and the panel itself slides away for fullscreen. Tap Super for an overview of
everything that's open.

### Ease of use

- **One click, one result.** Click an app to show it. Click it again to hide it.
- **The panel is the launcher.** Pinned apps sit on top, running apps underneath, and search
  is always in the same spot.
- **Familiar keys.** Super+Space for the menu, Super for the overview, Super+Alt+1…9 for
  pinned apps. Omarchy's own panel shortcuts (Super+Ctrl+A/B/D/N/P…) open inside the panel.
- **Arranged in place.** *Edit sidebar* (the *Sidebar* row in quick settings) happens inside the panel: it outlines each section, and
  clicking one opens its settings right under it. Reorder, resize, hide and add sections where
  you see them; the whole sidebar's settings open from the top of the panel.

### Simplicity

One panel and one direction of motion. Sections you don't use can be hidden, and the
panel can auto-hide to a 4 px edge. Underneath it's Omarchy, not a fork: the menu,
notifications, Do not disturb, update checks and panels all come from Omarchy's own
services, so updates keep working.

### Readability

![Anatomy of the panel](docs/mock-anatomy.png)

- **Top to bottom, the panel follows one order**: time, then system, workspace, search,
  apps, what's playing, and settings.
- **Words over icons.** Apps and settings are listed by name, and icons only support the label.
- **Two levels of contrast.** What matters, such as the time, values and the current app, is
  bright. Labels and units are dim, so numbers stand out without colour.
- **Monospaced and aligned.** Your theme's font, with figures that don't jump around as they
  change.
- **Calm by default.** Nothing moves unless you act. The current app has one highlight.

For colours, type, spacing, components, layout rules and motion, see the
[design guide](docs/DESIGN.md).

## See it work

| | |
| --- | --- |
| **Super+Space: the menu, in the panel** ![Menu demo](docs/demo-menu.gif) | **Quick settings slide over the panel** ![Quick settings demo](docs/demo-quick-settings.gif) |

**Each new app opens full size, sliding in from the left as the last one slides out; minimizing slides an app away behind the panel**

![Opening and minimizing apps demo](docs/demo-one-app.gif)

**Notifications appear inside the panel, at the top**

![Notifications demo](docs/demo-notifications.gif)

## Every screen size

The layout is one column plus your apps, so it scales down without changing shape. Only the
column's width and whether it stays docked change.

![The layout from desktop to phone width](docs/responsive.gif)

### Single monitor

The panel is docked on the left and your apps fill the rest (see the picture at the top). Drag
the panel's right edge to resize it. The scale is remembered per resolution, so a 4K and a
1080p screen each keep their own size.

### Multiple monitors

![Two monitors, each with its own panel](docs/mock-multi.png)

Every monitor gets its own panel, with its own clock, workspaces and apps. The menu, quick
settings and overview open on the monitor you're using, so you never have to look across to
another screen. Fullscreen apps and games cover their monitor's panel until you tap Super.

### Tablet-size screens

![Tablet: docked in landscape, tucked in portrait](docs/mock-tablet.png)

In landscape, a narrower panel stays docked. In portrait, turn on auto-hide
(*Edit sidebar › Sidebar*): the panel tucks into a 4 px edge and slides over the app when you
reach for it, so the app keeps the full width.

### Phone-size screens (concept)

![Phone: the app, the panel as home screen, quick settings](docs/mock-phone.png)

Showing one app full size is already how phones work. At phone width the panel becomes the
home screen: the app runs full screen, and pulling the panel out from the edge gives the
launcher, workspaces and quick settings at full width. Omarchy is a desktop, so this is a
concept. Panel width, auto-hide and choosing sections exist today; touch gestures don't.

The mockups are drawn from [`docs/mockups.html`](docs/mockups.html), which you can open in a
browser.

## Install

The repo is private, so clone it with your GitHub login (`gh auth login` once per machine):

```bash
gh repo clone BlazeJewell/omarchy-sidebar ~/.config/omarchy/plugins/jake.sidebar
~/.config/omarchy/plugins/jake.sidebar/install.sh
```

(`git clone https://github.com/BlazeJewell/omarchy-sidebar.git ~/.config/omarchy/plugins/jake.sidebar` works too.)

The installer:

- puts the plugin in `~/.config/omarchy/plugins/jake.sidebar`
- loads `hypr/` (Super+Space and other bindings, full-size app opening, animations)
  with one line in `~/.config/hypr/hyprland.lua` (`hypr-link.sh`)
- switches the bar to the sidebar (`omarchy bar use jake.sidebar`) and turns off
  Omarchy's dock

Undo with `./uninstall.sh` (add `--purge` to delete the plugin and layout too).

Installing with `omarchy plugin add https://github.com/BlazeJewell/omarchy-sidebar`
works too: the first time the sidebar starts it sets itself up (`setup.sh`). It hooks
up its Hyprland side (`hypr-link.sh`, which reloads Hyprland once), turns off
Omarchy's dock, and docks notifications top-left. The dock and notification part
happens once per install, so turning the dock back on later sticks; removing and
re-adding the plugin sets it up again. The Hyprland line skips itself if the plugin
folder is removed, and `hypr/` only loads while the sidebar is the bar in use, so
disabling it gives Super+Space and the rest back to Omarchy.

Either way the sidebar starts with its default layout: the standard sections, and
the apps pinned in your Omarchy dock (Omarchy's defaults if you never changed
them) until you pin or unpin something in the sidebar. Your layout is your own;
installing never copies one in. To carry yours between machines, see below.

## Keeping machines in sync

```bash
cd ~/.config/omarchy/plugins/jake.sidebar
./sync.sh save     # this machine's layout -> layout/, commit, push
./sync.sh load     # pull, apply layout/ here
./sync.sh update   # pull plugin / Hyprland changes, keep this machine's layout
```

Or use the **Update** button at the bottom of quick settings: it checks GitHub when
quick settings opens, shows how many updates are waiting, and runs `sync.sh update`.

The layout is the `sidebar-*.json` files: sections and their order, pinned apps,
hidden icons, profiles. Display scale and refresh rate stay per machine.

## What's where

| Path | What |
| --- | --- |
| `Sidebar.qml` | the sidebar (Quickshell, loaded by omarchy-shell as a `bar` plugin) |
| `hypr/` | Hyprland side (loaded by `hypr-link.sh`): `binds.lua`, `look.lua` (animations, borders, corners, grouping), `solo.lua` (new apps open full size), `rules.lua` |
| `*.sh` | helpers the sidebar runs: `minimize.sh` / `restore.sh` (slide out / back in; layout-aware), `solo.sh` (clears the workspace so an app comes up full size), `fsmem.sh` (fullscreen memory), `drop.sh` / `pair.sh` (drag to place), `hbatch.sh` (sends batched commands to Hyprland without moving the pointer), `refresh.sh` (resolution & refresh rate), `gpu.sh` (finds the GPU), `update.sh` (the quick-settings Update button) |
| `notifications/` | a copy of Omarchy's notification service, changed so notifications appear inside the top of the sidebar, drawn like a panel section (installed as the `jake.notifications` plugin) |
| `audio-meter/` | mic in and sound out as a live level meter, as vertical bars, horizontal rows or one split line (linked in as the `jake.audio-meter` plugin; add it as a section in the editor). See its own README |
| `layout/` | the saved sidebar layout synced between machines |
| `MenuModel.js` | copy of Omarchy's own menu model (`/usr/share/omarchy/shell/plugins/menu/MenuModel.js`); plugins may not contain symlinks, so re-copy it if Omarchy changes it |

## Works with stock Omarchy

- Panel shortcuts open inside the sidebar: Super+Ctrl+A/B/D/N/P, Super+Ctrl+1…9
  (counted like the stock bar), Super+Ctrl+Alt+D (calendar), Super+Ctrl+Alt+E
  (world clock) and any other `{ panel = ... }` bind.
- `omarchy toggle bar` and the fullscreen-desktop toggle tuck the sidebar away.
- Minimized windows use Omarchy's `special:minimized` workspace and
  `omarchy-minimized-from-N` tag, and Omarchy's floating workspace layout is
  respected (windows stay floating and keep their size).
- Notifications keep all of Omarchy's features (stacks, actions, history, Do not
  disturb); only their place and motion change. If an Omarchy update changes
  notifications, re-clone with `omarchy plugin clone omarchy.notifications` and
  re-apply the few `jake.sidebar:` lines.
- Do not disturb, indicators, update available and keyboard layout come from
  Omarchy's own services and widgets.

## Keys

| Keys | Does |
| --- | --- |
| Super (tap) | overview of open windows |
| Super+Space | the menu, inside the sidebar |
| Super+Alt+1…9 | pinned apps |
| Super+M | minimize (slides out left) |
| Super+Ctrl+A / B / D / N / P | sound / bluetooth / display / network / power settings |

Widget sections that use other plugins (for example AI Usage) need that plugin
installed on the machine too; otherwise the section says it has no panel.

After editing `Sidebar.qml`, run `omarchy restart shell` — the shell caches bar plugins.
