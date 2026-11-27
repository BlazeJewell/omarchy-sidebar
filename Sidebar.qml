import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.SystemTray
import Quickshell.Services.Pipewire
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import "MenuModel.js" as MenuModel
import "DisplayModel.js" as DisplayModel

// A wide sidebar on the left edge that replaces the Omarchy bar:
// clock, system stats, workspaces, launcher, open windows, tray, and the
// stock Omarchy status widgets (their popups open beside the sidebar).
//
// Options live in shell.json under "bar":
//   "sidebarWidth": 280
//   "sidebarWidgets": ["omarchy.menu", "omarchy.bluetooth", ...]
Item {
  id: root

  // `omarchy plugin add` only installs this panel: setup.sh hooks up the
  // Hyprland side (Super+Space, one app at a time, animations) if it isn't yet,
  // and on first install turns off Omarchy's dock and docks notifications
  // top-left. Does nothing once that's done.
  Component.onCompleted: Quickshell.execDetached(["bash", Qt.resolvedUrl("setup.sh").toString().replace("file://", "")])

  // ---- injected by the omarchy-shell host -------------------------------
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barConfig: ({})
  property var barWidgetRegistry: QtObject {
    property var widgets: ({})
    property int revision: 0
    function metadataFor(id) { return null }
  }

  // ---- what the host and other plugins read off the active bar -----------
  readonly property int sidebarWidth: {
    if (root.liveWidth > 0) return root.liveWidth
    var s = root.userSettings ? root.userSettings.width : undefined
    if (s >= 200) return Math.round(s)
    var w = barConfig && barConfig.sidebarWidth
    return w > 120 ? Math.round(w) : 280
  }
  // Omarchy widgets kept loaded (hidden) so their panels open docked in the
  // sidebar: the stock bar's right section, plus any other panel a shortcut asks
  // for (Super+Ctrl+Alt+E's world clock...), added the first time it's summoned.
  property var extraPanelIds: []
  property string pendingSummon: ""
  readonly property var widgetIds: {
    var list = barConfig && barConfig.sidebarWidgets
    var base = Array.isArray(list) ? list : [
      "omarchy.menu", "omarchy.agents", "omarchy.bluetooth",
      "omarchy.network", "omarchy.audio", "omarchy.monitor", "omarchy.power"
    ]
    return base.concat(root.extraPanelIds.filter(function(id) { return base.indexOf(id) === -1 }))
  }
  // Plugin widgets the sidebar shows in its bottom row: everything in the bar's
  // tray section, plus any third-party widget placed anywhere in the bar layout
  // (Omarchy's own widgets are covered by the sidebar itself).
  // Every plugin widget enabled in the bar layout (shell.json), wherever Omarchy
  // was told to put it; the sidebar decides its place itself (pluginPlaces).
  readonly property var allPluginEntries: {
    var layout = barConfig && barConfig.layout ? barConfig.layout : {}
    var out = [], seen = {}
    function add(e) {
      var id = e && (typeof e === "string" ? e : e.id)
      if (!id || seen[id] || root.widgetIds.indexOf(id) !== -1 || id === "omarchy.tray") return
      seen[id] = true
      out.push(typeof e === "string" ? { id: e } : e)
    }
    ;(layout.tray || []).forEach(add)
    ;["left", "centerBegin", "center", "centerEnd", "right"].forEach(function(sec) {
      (layout[sec] || []).forEach(function(e) {
        var id = e && (typeof e === "string" ? e : e.id)
        if (id && String(id).indexOf("omarchy.") !== 0) add(e)
      })
    })
    return out
  }
  // the ones that live in the Plugins row (the rest have their own section or sit in Status)
  readonly property var pluginEntries: root.allPluginEntries.filter(function(e) {
    var p = root.pluginPlaces[e.id]
    if (p === "section" || p === "status") return false
    // shown as a section of its own already (added from "+ add section")
    return !root.extraSections.some(function(x) { return x.id === "w:" + e.id })
  })

  // ---- where each plugin goes ---------------------------------------------------
  // New plugins go in the Plugins row. A plugin given a section of its own
  // ("+ add section") is noted as "section" so it leaves the row ("status":
  // in the Status row). Kept per machine in ~/.config/omarchy/sidebar-plugin-places.json.
  readonly property string placesPath: Quickshell.env("HOME") + "/.config/omarchy/sidebar-plugin-places.json"
  property var pluginPlaces: ({})
  FileView {
    path: root.placesPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { var v = JSON.parse(text()); if (v && typeof v === "object" && !Array.isArray(v)) root.pluginPlaces = v } catch (e) {} }
  }
  function writePlaces(next) {
    root.pluginPlaces = next
    Quickshell.execDetached(["bash", "-c", "printf '%s\\n' \"$1\" > \"$2\"", "sh", JSON.stringify(next, null, 2), root.placesPath])
  }
  // Plugin widgets / tray icons hidden from the sidebar ("tray:<id>" for tray
  // icons), kept in ~/.config/omarchy/sidebar-hidden.json (not shell.json).
  readonly property string hiddenPath: Quickshell.env("HOME") + "/.config/omarchy/sidebar-hidden.json"
  property var hiddenIds: []
  property var pendingHidden: null
  readonly property var hiddenNow: root.pendingHidden || root.hiddenIds
  FileView {
    path: root.hiddenPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { var v = JSON.parse(text()); if (Array.isArray(v)) root.hiddenIds = v } catch (e) {} root.pendingHidden = null }
  }
  function isHidden(id) { return root.hiddenNow.indexOf(String(id)) !== -1 }
  function setHidden(id, hide) {
    id = String(id)
    var list = root.hiddenNow.filter(function(x) { return x !== id })
    if (hide) list.push(id)
    root.pendingHidden = list
    Quickshell.execDetached(["bash", "-c", "printf '%s\\n' \"$1\" > \"$2\"", "sh", JSON.stringify(list), root.hiddenPath])
  }
  function trayLabel(t) { return String(t.tooltipTitle || t.title || t.id || "Tray icon") }
  readonly property var trayItemsShown: SystemTray.items.values.filter(function(t) { return !root.isHidden("tray:" + t.id) })
  property string position: "left"
  readonly property bool vertical: true
  readonly property int barSize: sidebarWidth
  // `omarchy toggle bar` (and the fullscreen-desktop toggle) hide the bar with a
  // flag file; the sidebar then tucks away like auto-hide until it's needed.
  property bool barHidden: false
  Process {
    id: barHiddenProbe
    running: true
    command: ["bash", "-c", "[[ -f $HOME/.local/state/omarchy/toggles/bar-off ]] && echo yes || echo no"]
    stdout: SplitParser { onRead: function(line) { root.barHidden = String(line).trim() === "yes" } }
  }
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/toggles"
    watchChanges: true
    printErrors: false
    onFileChanged: barHiddenProbe.running = true
  }
  ShellIpc {
    target: "omarchy.bar"
    function syncHidden(): void { barHiddenProbe.running = true }
  }
  readonly property string fontFamily: Style.font.family
  readonly property color foreground: Commons.Color.bar.text
  readonly property color barForeground: Commons.Color.bar.text
  readonly property color background: Commons.Color.bar.background
  readonly property color urgent: Commons.Color.bar.active
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property var screenBarSizes: {
    var sizes = ({})
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) sizes[screens[i].name] = root.sidebarWidth
    return sizes
  }
  property bool debugBarGeometry: false

  function run(command) { Quickshell.execDetached(["bash", "-c", String(command || "")]) }
  function cycleBackground() {}

  // ---- popout coordination + panel summoning (Super+Ctrl+A etc.) ---------
  property var activePopout: null
  property var clickTargets: []
  property var hostedItems: []

  function requestPopout(owner) {
    if (activePopout === owner) return
    if (activePopout) {
      if ("closeForPopoutSwitch" in activePopout) activePopout.closeForPopoutSwitch()
      else if ("close" in activePopout) activePopout.close()
    }
    activePopout = owner
  }
  function releasePopout(owner) { if (activePopout === owner) activePopout = null }

  function moduleWidgets(id) {
    return hostedItems.filter(function(h) { return h && h.moduleName === String(id) && h.item })
                      .map(function(h) { return h.item })
  }
  function findPanelWidget(id) {
    var items = moduleWidgets(id)
    if (items.length === 0) return null
    var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    for (var i = 0; i < items.length; i++) {
      var w = items[i].QsWindow ? items[i].QsWindow.window : null
      if (w && w.screen && w.screen.name === focused) return items[i]
    }
    return items[0]
  }
  function summonBarWidget(id) {
    id = String(id)
    if (id === "omarchy.clock") { root.calMonth = new Date(); root.calendarOpen = true; return true }   // the clock's calendar
    var item = findPanelWidget(id)
    if (!item) {
      // not hosted yet: load it, and open it once it's there
      var reg = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
      if (!reg || !reg[id] || !reg[id].component) return false
      root.pendingSummon = id
      if (root.widgetIds.indexOf(id) === -1) root.extraPanelIds = root.extraPanelIds.concat([id])
      return true
    }
    if (typeof item.open !== "function") return false
    item.open(); return true
  }
  function hideBarWidget(id) {
    if (String(id) === "omarchy.clock") { root.calendarOpen = false; return true }
    var item = findPanelWidget(id)
    if (!item || typeof item.close !== "function") return false
    item.close(); return true
  }
  function isBarWidgetOpen(id) {
    if (String(id) === "omarchy.clock") return root.calendarOpen
    var item = findPanelWidget(id)
    return !!item && item.opened === true
  }
  // Super+Ctrl+1..9: the Nth widget that has a panel, as the stock bar counts them.
  function panelWidgetIdAt(region, index) {
    var withPanels = root.widgetIds.filter(function(id) { return root.noPanelWidgets.indexOf(String(id)) === -1 })
    var id = withPanels[Math.round(Number(index)) - 1]
    return id ? String(id) : ""
  }

  // The object handed to hosted Omarchy widgets as their `bar`. They are drawn
  // icon-only (vertical mode) at the normal 28px, while their popups are told
  // the strip is as wide as the sidebar so they open beside it.
  QtObject {
    id: widgetBar
    readonly property var shell: root.shell
    readonly property color foreground: root.foreground
    readonly property color barForeground: root.barForeground
    readonly property color background: root.background
    readonly property color urgent: root.urgent
    readonly property string fontFamily: root.fontFamily
    readonly property string position: "left"
    readonly property bool vertical: true
    readonly property int barSize: Style.bar.sizeVertical
    readonly property int sizeHorizontal: Style.bar.sizeHorizontal
    readonly property int iconSlot: Style.bar.iconSlot
    readonly property int statusSlot: Style.bar.statusSlot
    readonly property int iconSize: Style.bar.iconSize
    readonly property int iconCanvas: Style.bar.iconCanvas
    readonly property int iconFont: Style.bar.iconFont
    readonly property bool transparent: false
    readonly property bool barHidden: false
    readonly property bool foregroundAnimationEnabled: true
    readonly property bool centerSectionRevealHeld: false
    readonly property bool centerHoverRevealSuppressed: false
    readonly property bool traySectionDragActive: false
    readonly property bool traySectionPopoutOpen: false
    readonly property bool microphoneMuted: false
    readonly property bool microphoneLive: false
    readonly property bool microphoneInUse: false
    readonly property int pendingUpdates: 0
    readonly property var layoutConfig: ({ left: [], centerBegin: [], center: [], centerEnd: [], right: root.widgetIds.map(function(id) { return { id: id } }), tray: [] })
    readonly property var activePopout: root.activePopout
    readonly property var clickTargets: root.clickTargets

    function barSizeFor(screenName) { return root.sidebarWidth }
    function run(command) { root.run(command) }
    function requestPopout(owner) { root.requestPopout(owner); Qt.callLater(root.dockOpenPanel); dockRetry.restart() }
    function releasePopout(owner) { root.releasePopout(owner) }
    function notePopoutCard(card) {}
    function popoutCardFor(owner) { return null }
    function switchPanelFrom(owner, direction) { return false }
    function moduleWidgets(id) { return root.moduleWidgets(id) }
    function registerClickTarget(target) {
      if (target && root.clickTargets.indexOf(target) === -1) root.clickTargets = root.clickTargets.concat([target])
    }
    function unregisterClickTarget(target) {
      root.clickTargets = root.clickTargets.filter(function(t) { return t !== target })
    }
    function targetBelongsToWindow(target, window) {
      var w = target && target.QsWindow ? target.QsWindow.window : null
      return !!w && !!window && (w === window || w.screen === window.screen)
    }
    function setCenterHoverRevealSuppressed(value) {}
    function showTooltip(target, text) { tooltip.show(target, text) }
    function hideTooltip(target) { tooltip.hide(target) }
  }
  // The same, but horizontal: for the status row under the clock (indicators,
  // update available, keyboard layout), which lays out like the top bar's.
  QtObject {
    id: statusBar
    readonly property var shell: root.shell
    readonly property color foreground: root.foreground
    readonly property color barForeground: root.barForeground
    readonly property color background: root.background
    readonly property color urgent: root.urgent
    readonly property string fontFamily: root.fontFamily
    readonly property string position: "top"
    readonly property bool vertical: false
    readonly property int barSize: Style.bar.sizeHorizontal
    readonly property int sizeHorizontal: Style.bar.sizeHorizontal
    readonly property int iconSlot: Style.bar.iconSlot
    readonly property int statusSlot: Style.bar.statusSlot
    readonly property int iconSize: Style.bar.iconSize
    readonly property int iconCanvas: Style.bar.iconCanvas
    readonly property int iconFont: Style.bar.iconFont
    readonly property bool transparent: false
    readonly property bool barHidden: false
    readonly property bool foregroundAnimationEnabled: true
    readonly property bool centerSectionRevealHeld: false
    readonly property bool centerHoverRevealSuppressed: false
    readonly property bool traySectionDragActive: false
    readonly property bool traySectionPopoutOpen: false
    readonly property bool microphoneMuted: false
    readonly property bool microphoneLive: false
    readonly property bool microphoneInUse: false
    readonly property int pendingUpdates: 0
    readonly property var layoutConfig: ({ left: [], centerBegin: [], center: [], centerEnd: [], right: root.widgetIds.map(function(id) { return { id: id } }), tray: [] })
    readonly property var activePopout: root.activePopout
    readonly property var clickTargets: root.clickTargets

    function barSizeFor(screenName) { return root.sidebarWidth }
    function run(command) { root.run(command) }
    function requestPopout(owner) { root.requestPopout(owner); Qt.callLater(root.dockOpenPanel); dockRetry.restart() }
    function releasePopout(owner) { root.releasePopout(owner) }
    function notePopoutCard(card) {}
    function popoutCardFor(owner) { return null }
    function switchPanelFrom(owner, direction) { return false }
    function moduleWidgets(id) { return root.moduleWidgets(id) }
    function registerClickTarget(target) {
      if (target && root.clickTargets.indexOf(target) === -1) root.clickTargets = root.clickTargets.concat([target])
    }
    function unregisterClickTarget(target) {
      root.clickTargets = root.clickTargets.filter(function(t) { return t !== target })
    }
    function targetBelongsToWindow(target, window) {
      var w = target && target.QsWindow ? target.QsWindow.window : null
      return !!w && !!window && (w === window || w.screen === window.screen)
    }
    function setCenterHoverRevealSuppressed(value) {}
    function showTooltip(target, text) { tooltip.show(target, text) }
    function hideTooltip(target) { tooltip.hide(target) }
  }
  // ---- status row, calendar and battery (what the stock top bar shows) ---------
  readonly property var statusIds: ["omarchy.indicators", "omarchy.system-update", "omarchy.keyboard-layout"]
  // each one can be turned off in the Status settings
  readonly property var statusIdSetting: ({ "omarchy.indicators": "indicators", "omarchy.system-update": "update", "omarchy.keyboard-layout": "keyboard" })
  readonly property var statusIdsShown: root.statusIds.filter(function(id) { return root.setting("status", root.statusIdSetting[id]) !== false })
    .concat(root.allPluginEntries.filter(function(e) { return root.pluginPlaces[e.id] === "status" }).map(function(e) { return e.id }))
  readonly property bool statusBatteryShown: root.batteryPresent && root.setting("status", "battery") !== false
  // The indicators Omarchy's widget offers ([{value, label}]), from its manifest,
  // so new ones show up in the settings by themselves.
  readonly property var indicatorOptions: {
    var w = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
    var meta = w && w["omarchy.indicators"] ? w["omarchy.indicators"].metadata || {} : {}
    var schema = meta.barWidget && Array.isArray(meta.barWidget.schema) ? meta.barWidget.schema : []
    for (var i = 0; i < schema.length; i++) if (schema[i].key === "items" && Array.isArray(schema[i].options)) return schema[i].options
    return []
  }
  // the chosen ones (none chosen = all of them, as the widget itself reads it)
  readonly property var indicatorItems: {
    var v = root.setting("status", "indicatorItems")
    return Array.isArray(v) ? v : []
  }
  function indicatorOn(value) { return root.indicatorItems.length === 0 || root.indicatorItems.indexOf(value) !== -1 }
  function toggleIndicator(value) {
    var all = root.indicatorOptions.map(function(o) { return o.value })
    var on = all.filter(function(v) { return root.indicatorOn(v) })
    if (root.indicatorOn(value)) {
      if (on.length <= 1) return          // keep one; "Indicators: off" hides them all
      on = on.filter(function(v) { return v !== value })
    } else on.push(value)
    root.setSetting("status", "indicatorItems", on.length === all.length ? [] : all.filter(function(v) { return on.indexOf(v) !== -1 }))
  }
  // settings handed to a status widget on top of its own defaults
  function statusWidgetSettings(id) {
    if (id !== "omarchy.indicators") {
      // a plugin placed here: its own settings from the bar layout, as in the Plugins row
      var e = root.allPluginEntries.filter(function(x) { return x.id === id })[0]
      var out = {}
      if (e) for (var k in e) if (k !== "id") out[k] = e[k]
      return out
    }
    return { items: root.indicatorItems, alwaysShow: root.setting("status", "indicatorsAlways") === true }
  }
  property bool calendarOpen: false
  property bool clockAlt: false
  property date calMonth: new Date()
  function isoWeek(d) {
    var t = new Date(d.getFullYear(), d.getMonth(), d.getDate())
    t.setDate(t.getDate() + 3 - (t.getDay() + 6) % 7)
    var w1 = new Date(t.getFullYear(), 0, 4)
    return 1 + Math.round(((t - w1) / 86400000 - 3 + (w1.getDay() + 6) % 7) / 7)
  }
  function calDays(month) {
    var first = new Date(month.getFullYear(), month.getMonth(), 1)
    var start = Qt.locale(Commons.I18n.formatLocale).firstDayOfWeek % 7
    var off = (first.getDay() - start + 7) % 7
    var out = []
    for (var i = 0; i < 42; i++) out.push(new Date(month.getFullYear(), month.getMonth(), 1 - off + i))
    return out
  }
  readonly property var battery: UPower.displayDevice
  readonly property bool batteryPresent: !!(battery && battery.isPresent && battery.isLaptopBattery)
  readonly property int batteryPct: batteryPresent ? Math.round(battery.percentage > 1 ? battery.percentage : battery.percentage * 100) : -1
  readonly property bool batteryCharging: batteryPresent && !UPower.onBattery
  function batteryGlyph() {
    if (!batteryPresent) return ""
    if (batteryCharging) return "\udb80\udc84"
    var g = ["\udb80\udc8e", "\udb80\udc7a", "\udb80\udc7b", "\udb80\udc7c", "\udb80\udc7d", "\udb80\udc7e", "\udb80\udc7f", "\udb80\udc80", "\udb80\udc81", "\udb80\udc82", "\udb80\udc79"]
    return g[Math.max(0, Math.min(10, Math.round(batteryPct / 10)))]
  }


  // ---- system stats ---------------------------------------------------------
  property real cpu: 0
  property real mem: 0
  property real disk: 0
  // GPU (the one with the most VRAM; gpu.sh)
  property bool gpuFound: false
  property real gpu: 0
  property real vramUsed: 0
  property real vramTotal: 0
  property real gpuTemp: 0
  property real rxRate: 0
  property real txRate: 0
  property var rxHistory: []
  property var txHistory: []
  property var _lastCpu: null
  property var _lastNet: null

  function parseStats(text) {
    var lines = String(text).split("\n")
    var memTotal = 0, memAvail = 0
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].trim().split(/\s+/)
      if (f[0] === "cpu") {
        var nums = f.slice(1).map(Number)
        var idle = nums[3] + (nums[4] || 0)
        var total = nums.reduce(function(a, b) { return a + b }, 0)
        if (_lastCpu && total > _lastCpu.total)
          cpu = 100 * (1 - (idle - _lastCpu.idle) / (total - _lastCpu.total))
        _lastCpu = { idle: idle, total: total }
      } else if (f[0] === "MemTotal:") memTotal = Number(f[1])
      else if (f[0] === "MemAvailable:") memAvail = Number(f[1])
      else if (f[0] === "disk") disk = parseInt(f[1])
      else if (f[0] === "gpu") { gpuFound = true; gpu = Number(f[1]) || 0; vramUsed = Number(f[2]) || 0; vramTotal = Number(f[3]) || 0; gpuTemp = Number(f[4]) || 0 }
      else if (f[0] === "net") {
        var now = Date.now(), rx = Number(f[1]), tx = Number(f[2])
        if (_lastNet) {
          var dt = (now - _lastNet.t) / 1000
          rxRate = Math.max(0, (rx - _lastNet.rx) / dt)
          txRate = Math.max(0, (tx - _lastNet.tx) / dt)
          rxHistory = rxHistory.concat([rxRate]).slice(-24)
          txHistory = txHistory.concat([txRate]).slice(-24)
        }
        _lastNet = { t: now, rx: rx, tx: tx }
      }
    }
    if (memTotal > 0) mem = 100 * (1 - memAvail / memTotal)
  }

  // The system section's readings ("data points"): each can be shown or not, small
  // (inline) / half / full width, and drawn as a number, a bar or a graph. Their
  // order and options are system.items in the settings (dragged in edit mode).
  readonly property var statIds: ["cpu", "mem", "disk", "gpu", "vram", "gpuTemp", "down", "up"]
  readonly property var statShort: ({ cpu: "CPU", mem: "MEM", disk: "DSK", gpu: "GPU", vram: "VRM", gpuTemp: "TMP", down: "DOWN", up: "UP" })
  readonly property var statLong: ({ cpu: "CPU", mem: "Memory", disk: "Disk", gpu: "GPU usage", vram: "GPU memory", gpuTemp: "GPU temperature", down: "Download", up: "Upload" })
  property var statHist: ({})          // id -> the last 24 readings
  function statValue(id) {
    if (id === "cpu") return root.cpu
    if (id === "mem") return root.mem
    if (id === "disk") return root.disk
    if (id === "gpu") return root.gpu
    if (id === "vram") return root.vramTotal > 0 ? 100 * root.vramUsed / root.vramTotal : 0
    if (id === "gpuTemp") return root.gpuTemp
    if (id === "down") return root.rxRate
    if (id === "up") return root.txRate
    return 0
  }
  function isRate(id) { return id === "down" || id === "up" }
  // [figure, unit]
  function statText(id) {
    var v = root.statValue(id)
    if (root.isRate(id)) return root.rateParts(v)
    return [Math.round(v).toString(), id === "gpuTemp" ? "°" : "%"]
  }
  // the scale a bar or graph is drawn against (rates: the recent peak)
  function statPeak(id, hist) { return root.isRate(id) ? Math.max.apply(null, [1].concat(hist || [])) : 100 }
  function statHot(id) { return !root.isRate(id) && root.statValue(id) >= 85 }
  function pushStatHist() {
    var h = {}
    root.statIds.forEach(function(id) { h[id] = (root.statHist[id] || []).concat([root.statValue(id)]).slice(-24) })
    root.statHist = h
  }
  readonly property var systemItems: {
    var saved = root.setting("system", "items")
    saved = Array.isArray(saved) ? saved : []
    var out = [], seen = {}
    saved.forEach(function(it) { if (it && root.statIds.indexOf(it.id) !== -1 && !seen[it.id]) { seen[it.id] = true; out.push(it) } })
    root.statIds.forEach(function(id) { if (!seen[id]) out.push({ id: id }) })
    return out.map(function(it) {
      var net = root.isRate(it.id)
      return {
        id: it.id,
        // older settings: one switch per reading, "network" for both rates, "netGraph" for their graphs
        show: it.show !== undefined ? it.show : (net ? root.setting("system", "network") !== false : root.setting("system", it.id) !== false),
        // width as a share of the section (5 = a fifth … 1 = all of it), height in rows;
        // older "size": small = a third, one row; half / full = two rows
        w: [5, 3, 2, 1].indexOf(it.w) !== -1 ? it.w : ({ small: 3, half: 2, full: 1 })[it.size || (net ? "half" : "small")] || 3,
        h: [1, 2, 3].indexOf(it.h) !== -1 ? it.h : ((it.size || (net ? "half" : "small")) === "small" ? 1 : 2),
        style: it.style || (net ? (root.setting("system", "netGraph") !== false ? "graph" : "value") : "value"),
        avail: ["gpu", "vram", "gpuTemp"].indexOf(it.id) === -1 || root.gpuFound
      }
    })
  }
  function systemItemsPlain() { return root.systemItems.map(function(it) { return { id: it.id, show: it.show, w: it.w, h: it.h, style: it.style } }) }
  function setSystemItem(id, key, value) {
    var list = root.systemItemsPlain()
    list.forEach(function(it) { if (it.id === id) it[key] = value })
    root.setSetting("system", "items", list)
  }
  // move one reading just before (or after) another one
  function moveSystemItem(id, targetId, after) {
    var list = root.systemItemsPlain()
    var from = list.findIndex(function(it) { return it.id === id })
    if (from < 0 || id === targetId) return
    var it = list.splice(from, 1)[0]
    var to = list.findIndex(function(x) { return x.id === targetId })
    if (to < 0) return
    list.splice(after ? to + 1 : to, 0, it)
    root.setSetting("system", "items", list)
  }
  // step a reading one place earlier (-1) or later (+1) among the ones shown
  function nudgeSystemItem(id, dir) {
    var seen = root.systemItems.filter(function(x) { return x.avail })
    var i = seen.findIndex(function(x) { return x.id === id })
    var j = i + dir
    if (i < 0 || j < 0 || j >= seen.length) return
    root.moveSystemItem(id, seen[j].id, dir > 0)
  }
  property string systemPick: "cpu"    // the reading picked in the editor

  function rateParts(bytesPerSec) {
    var bits = bytesPerSec * 8
    if (bits >= 1e9) return [(bits / 1e9).toFixed(1), "Gbps"]
    if (bits >= 1e6) return [(bits / 1e6).toFixed(bits >= 1e8 ? 0 : 1), "Mbps"]
    return [Math.round(bits / 1e3).toString(), "Kbps"]
  }

  // Read straight from /proc and sysfs (no processes) every refresh; disk use
  // changes slowly, so df runs once a minute.
  FileView { id: fvStat; path: "/proc/stat"; blockLoading: true; printErrors: false }
  FileView { id: fvMem; path: "/proc/meminfo"; blockLoading: true; printErrors: false }
  FileView { id: fvNet; path: "/proc/net/dev"; blockLoading: true; printErrors: false }
  // GPU: an amdgpu card's sysfs files (the one with the most VRAM), found once
  // by gpu.sh; on NVIDIA, nvidia-smi is polled instead.
  property string gpuDir: ""
  property string gpuTempFile: ""
  property bool gpuNvidia: false
  FileView { id: fvGpuBusy; path: root.gpuDir ? root.gpuDir + "/gpu_busy_percent" : ""; blockLoading: true; printErrors: false }
  FileView { id: fvGpuUsed; path: root.gpuDir ? root.gpuDir + "/mem_info_vram_used" : ""; blockLoading: true; printErrors: false }
  FileView { id: fvGpuTotal; path: root.gpuDir ? root.gpuDir + "/mem_info_vram_total" : ""; blockLoading: true; printErrors: false }
  FileView { id: fvGpuTemp; path: root.gpuTempFile; blockLoading: true; printErrors: false }
  Process {
    running: true
    command: ["sh", Qt.resolvedUrl("gpu.sh").toString().replace("file://", ""), "find"]
    stdout: StdioCollector {
      onStreamFinished: {
        String(text).split("\n").forEach(function(l) {
          var f = l.trim().split(" ")
          if (f[0] === "amd") { root.gpuDir = f[1] || ""; root.gpuTempFile = f[2] || "" }
          else if (f[0] === "nvidia") root.gpuNvidia = true
        })
      }
    }
  }
  Process {
    id: nvidiaProc
    command: ["nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu", "--format=csv,noheader,nounits"]
    stdout: StdioCollector {
      onStreamFinished: {
        var f = String(text).split("\n")[0].split(",").map(function(v) { return Number(v.trim()) })
        if (f.length >= 4 && !isNaN(f[0])) root.parseStats("gpu " + f.join(" "))
      }
    }
  }
  Process {
    id: diskProc
    command: ["sh", "-c", "df -P / | awk 'NR==2{print \"disk\", $5}'"]
    stdout: StdioCollector { onStreamFinished: root.parseStats(text) }
  }
  Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: diskProc.running = true }

  // ---- rice updates (quick settings › Update button) -----------------------
  readonly property string updateScript: Qt.resolvedUrl("update.sh").toString().replace("file://", "")
  property string updateCount: ""        // "" checking, "0" up to date, "?" offline, else commits waiting
  property bool updating: false
  property real updateCheckedAt: 0
  Process {
    id: updateCheckProc
    command: ["bash", root.updateScript, "check"]
    stdout: StdioCollector { onStreamFinished: { root.updateCount = text.trim() || "?"; root.updateCheckedAt = Date.now() } }
  }
  function checkForUpdates(force) {
    if (updateCheckProc.running || root.updating) return
    if (!force && root.updateCount !== "" && Date.now() - root.updateCheckedAt < 300000) return
    root.updateCount = ""
    updateCheckProc.running = true
  }
  function runUpdate() {
    root.updating = true
    Quickshell.execDetached(["bash", root.updateScript, "run"])
  }
  Timer { interval: 6 * 3600000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.checkForUpdates(true) }
  function pollStats() {
    fvStat.reload(); fvMem.reload(); fvNet.reload()
    var out = [String(fvStat.text()).split("\n")[0]]
    String(fvMem.text()).split("\n").forEach(function(l) { if (/^(MemTotal|MemAvailable):/.test(l)) out.push(l) })
    var rx = 0, tx = 0
    String(fvNet.text()).split("\n").slice(2).forEach(function(l) {
      var parts = l.split(":")
      if (parts.length < 2 || parts[0].trim() === "lo") return
      var n = parts[1].trim().split(/\s+/)
      rx += Number(n[0]) || 0; tx += Number(n[8]) || 0
    })
    out.push("net " + rx + " " + tx)
    if (root.gpuDir) {
      fvGpuBusy.reload(); fvGpuUsed.reload(); fvGpuTotal.reload()
      var temp = 0
      if (root.gpuTempFile) { fvGpuTemp.reload(); temp = Math.round(Number(fvGpuTemp.text()) / 1000) || 0 }
      out.push("gpu " + (Number(fvGpuBusy.text()) || 0) + " " + Math.round((Number(fvGpuUsed.text()) || 0) / 1048576)
               + " " + Math.round((Number(fvGpuTotal.text()) || 0) / 1048576) + " " + temp)
    } else if (root.gpuNvidia && !nvidiaProc.running) nvidiaProc.running = true
    root.parseStats(out.join("\n"))
    root.pushStatHist()
  }
  Timer {
    interval: Math.max(1, root.setting("system", "refresh")) * 1000; running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.pollStats()
  }

  SystemClock { id: clock; precision: root.setting("clock", "seconds") ? SystemClock.Seconds : SystemClock.Minutes }


  // ---- pinned apps --------------------------------------------------------
  // Kept in ~/.config/omarchy/sidebar-pins.json, not shell.json: any write to
  // shell.json makes the shell rebuild the bar, which shoves windows around.
  readonly property string pinsPath: Quickshell.env("HOME") + "/.config/omarchy/sidebar-pins.json"
  property var savedPins: []
  property bool pinsSaved: false   // the file exists: pins are the user's own
  property var pendingPins: null
  FileView {
    path: root.pinsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { var v = JSON.parse(text()); if (Array.isArray(v)) { root.savedPins = v; root.pinsSaved = true } } catch (e) {}
      root.pendingPins = null
    }
  }
  // Until something is pinned or unpinned here, start from the apps pinned in
  // Omarchy's dock, which the sidebar replaces: yours from shell.json, or
  // Omarchy's defaults. (Read from the files: the host only hands a bar its bar
  // settings.) Ones that aren't installed are skipped (appItems).
  property var userDockPins: null
  property var defaultDockPins: null
  function dockPinsFrom(text) {
    try { var v = JSON.parse(text); return v && v.dock && Array.isArray(v.dock.pinned) ? v.dock.pinned : null } catch (e) { return null }
  }
  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.userDockPins = root.dockPinsFrom(text())
  }
  FileView {
    path: (root.omarchyPath || "/usr/share/omarchy") + "/config/omarchy/shell.json"
    printErrors: false
    onLoaded: root.defaultDockPins = root.dockPinsFrom(text())
  }
  readonly property var dockPins: {
    var list = root.userDockPins || root.defaultDockPins || []
    return list.map(function(id) { id = String(id || "").trim(); return id.slice(-8) === ".desktop" ? id.slice(0, -8) : id })
      .filter(function(id, i, a) { return id && a.indexOf(id) === i })
  }
  readonly property var pinnedIds: root.pendingPins || (root.pinsSaved ? root.savedPins : root.dockPins)

  function entryIdFor(appId) {
    var e = DesktopEntries.heuristicLookup(appId)
    return e ? e.id : appId
  }

  // [{ key, entry, windows: [HyprlandToplevel], separator }]
  function appItems(monitorName) {
    var appsRevision = DesktopEntries.applications.values.length
    var byKey = {}
    var order = []
    var tl = Hyprland.toplevels.values
    for (var i = 0; i < tl.length; i++) {
      var w = tl[i].wayland
      if (!w || w.parent) continue
      var app = String(w.appId || "")
      if (!app || app.toLowerCase().indexOf("fcitx") !== -1) continue
      var ws = tl[i].workspace
      if (ws && String(ws.name).indexOf("special:") === 0 && ws.name !== "special:minimized") continue
      var key = root.entryIdFor(app)
      if (!byKey[key]) { byKey[key] = []; order.push(key) }
      byKey[key].push(tl[i])
    }
    var orderRev = root.windowOrderRev
    for (var ok in byKey) {
      var wOrder = root.windowOrder[ok]
      if (!wOrder) continue
      byKey[ok].sort(function(a, b) {
        var ia = wOrder.indexOf(root.addrOf(a)), ib = wOrder.indexOf(root.addrOf(b))
        return (ia < 0 ? 1e6 : ia) - (ib < 0 ? 1e6 : ib)
      })
    }
    var out = []
    var seen = {}
    for (var p = 0; p < root.pinnedIds.length; p++) {
      var pin = root.pinnedIds[p]
      if (pin && typeof pin === "object") {
        // an app with no launcher entry, pinned by its window class + command
        if (!pin["class"]) continue
        seen[pin["class"]] = true
        out.push({ key: pin["class"], entry: null, custom: pin, windows: byKey[pin["class"]] || [], separator: false, pinned: true })
        continue
      }
      var id = String(pin)
      var entry = DesktopEntries.byId(id)
      if (!entry) continue
      seen[id] = true
      out.push({ key: id, entry: entry, windows: byKey[id] || [], separator: false, pinned: true })
    }
    var extra = root.setting("apps", "running") ? order.filter(function(k) { return !seen[k] }) : []
    if (extra.length > 0) out.push({ key: "--", entry: null, windows: [], separator: true, pinned: false })
    for (var x = 0; x < extra.length; x++) {
      var e = DesktopEntries.byId(extra[x]) || DesktopEntries.heuristicLookup(extra[x])
      out.push({ key: extra[x], entry: e, windows: byKey[extra[x]], separator: false, pinned: false })
    }
    return out
  }

  function setPins(list) {
    root.pendingPins = list
    root.run("printf '%s\\n' " + Util.shellQuote(JSON.stringify(list)) + " > " + Util.shellQuote(root.pinsPath))
  }
  // Drop an app at a spot in the list: `index` counts the pinned rows; past
  // them (the running section) a pinned app is unpinned.
  function dropOnList(item, index) {
    if (!item || item.separator) return
    var rows = root.appItems("").filter(function(r) { return r.pinned })
    var key = item.entry ? String(item.entry.id) : String(item.key)
    if (index > rows.length) { if (item.pinned) root.togglePin(item); return }
    var beforeKey = index < rows.length ? rows[index].key : null
    if (beforeKey === key) return
    var list = root.pinnedIds.slice()
    var value = null
    for (var i = 0; i < list.length; i++) if (root.pinKey(list[i]) === key) { value = list[i]; list.splice(i, 1); break }
    if (value === null && !item.entry) {
      // not pinned and no launcher entry: capture its command first, then place it
      if (!item.windows || item.windows.length === 0) return
      pinCapture.insertBefore = beforeKey
      root.togglePin(item)
      return
    }
    if (value === null) value = key
    var at = list.length
    if (beforeKey !== null) for (var j = 0; j < list.length; j++) if (root.pinKey(list[j]) === beforeKey) { at = j; break }
    list.splice(at, 0, value)
    root.setPins(list)
  }
  function pinKey(pin) { return pin && typeof pin === "object" ? String(pin["class"] || "") : String(pin) }
  function togglePin(item) {
    if (!item || item.separator) return
    var key = item.entry ? String(item.entry.id) : String(item.key)
    var list = root.pinnedIds.slice()
    var at = -1
    for (var i = 0; i < list.length; i++) if (root.pinKey(list[i]) === key) { at = i; break }
    if (at >= 0) { list.splice(at, 1); root.setPins(list); return }
    if (item.entry) { list.push(key); root.setPins(list); return }
    // No launcher entry: remember the command its window was started with.
    if (!item.windows || item.windows.length === 0) return
    pinCapture.item = item
    pinCapture.command = ["bash", "-c", "pid=$(hyprctl clients -j | jq -r --arg a \"$1\" 'first(.[] | select(.address == $a) | .pid) // empty'); [ -n \"$pid\" ] && jq -Rsc 'split(\"\\u0000\") | map(select(length > 0))' < /proc/$pid/cmdline", "sh", root.addrOf(item.windows[0])]
    pinCapture.running = true
  }
  Process {
    id: pinCapture
    property var item: null
    property var insertBefore: null
    stdout: StdioCollector {
      onStreamFinished: {
        var argv = []
        try { argv = JSON.parse(String(text).trim() || "[]") } catch (e) {}
        var it = pinCapture.item
        if (!it || !Array.isArray(argv) || argv.length === 0) return
        var list = root.pinnedIds.slice()
        var value = { "class": String(it.key), name: root.displayName(it), argv: argv }
        var at = list.length
        if (pinCapture.insertBefore !== null) for (var j = 0; j < list.length; j++) if (root.pinKey(list[j]) === pinCapture.insertBefore) { at = j; break }
        pinCapture.insertBefore = null
        list.splice(at, 0, value)
        root.setPins(list)
      }
    }
  }
  // How to start an item: its launcher entry, or the command a pinned window was started with.
  function launchCommandFor(item) {
    if (!item) return ""
    if (item.entry) return root.launchCommand(item.entry)
    var argv = item.custom && Array.isArray(item.custom.argv) ? item.custom.argv : []
    return argv.length ? "uwsm-app -- " + argv.map(function(a) { return Util.shellQuote(String(a)) }).join(" ") : ""
  }
  function displayName(item) {
    if (item.entry && item.entry.name) return item.entry.name
    if (item.custom && item.custom.name) return item.custom.name
    var key = String(item.key)
    var t = item.windows && item.windows.length ? String(item.windows[0].title || "") : ""
    if (key.indexOf("chrome-") === 0 && t) return t.split(" - ").pop().trim()
    var last = key.split(".").pop()
    return last.charAt(0).toUpperCase() + last.slice(1)
  }

  // Right-click menu for an app row: [{ label, act, danger }]
  function appMenuEntries(item) {
    if (!item) return []
    var out = []
    var running = item.windows && item.windows.length > 0
    var front = running && item.windows.some(function(t) { return t.activated && !root.isMinimized(t) })
    var allHidden = running && item.windows.every(function(t) { return root.isMinimized(t) })
    out.push({ label: front ? "Minimize" : allHidden ? "Restore" : running ? "Focus" : "Open", act: "open" })
    if (root.launchCommandFor(item)) out.push({ label: "New window", act: "new" })
    if (item.entry || item.custom || (item.windows && item.windows.length > 0)) out.push({ label: item.pinned ? "Unpin" : "Pin", act: "pin" })
    if (running) out.push({ label: item.windows.length > 1 ? "Close all windows" : "Close", act: "close", danger: true })
    var actions = item.entry && item.entry.actions ? item.entry.actions : []
    if (actions.length > 0) out.push({ sep: true })
    for (var i = 0; i < actions.length; i++) out.push({ label: actions[i].name, act: "action", index: i })
    return out
  }
  function runAppMenu(item, e) {
    if (!item || !e) return
    if (e.act === "open") root.activateApp(item)
    else if (e.act === "new") { var nw = root.launchCommandFor(item); if (nw) root.run(nw) }
    else if (e.act === "action") item.entry.actions[e.index].execute()
    else if (e.act === "pin") root.togglePin(item)
    else if (e.act === "close") {
      var cmds = item.windows.map(function(t) {
        var a = String(t.address || ""); if (a.indexOf("0x") !== 0) a = "0x" + a
        return "hyprctl dispatch " + Util.shellQuote("hl.dsp.window.close({ window = \"address:" + a + "\" })") + " >/dev/null"
      })
      root.run(cmds.join("; "))
    }
  }

  function launchCommand(entry) {
    if (!entry) return ""
    if (entry.runInTerminal) {
      var cmd = (entry.command || []).filter(function(w) { return !/^%[a-zA-Z]$/.test(String(w)) })
      return "omarchy-launch-tui " + cmd.map(function(w) { return Util.shellQuote(w) }).join(" ")
    }
    return "uwsm-app -- gtk-launch " + Util.shellQuote(entry.id + ".desktop")
  }

  // Drop an app at a global point: beside the tiled window there, on the
  // side of it the point is on. An open app's window is moved there; one that
  // isn't running is launched there.
  readonly property string dropScript: Qt.resolvedUrl("drop.sh").toString().replace("file://", "")
  function dropApp(item, gx, gy) {
    if (!item || item.separator) return
    var wins = item.windows || []
    var pick = null
    for (var i = 0; i < wins.length; i++) if (!root.isMinimized(wins[i])) { pick = wins[i]; break }
    if (!pick && wins.length > 0) pick = wins[0]
    var addr = "-"
    if (pick) { addr = String(pick.address || ""); if (addr.indexOf("0x") !== 0) addr = "0x" + addr }
    var launch = pick ? "-" : (root.launchCommandFor(item) || "-")
    if (addr === "-" && launch === "-") return
    if (launch !== "-") root.run(root.tileNextCommand())   // a dropped app opens beside, not alone
    Quickshell.execDetached(["bash", root.dropScript, String(Math.round(gx)), String(Math.round(gy)), addr, launch])
  }

  // Not running: launch it. Running: focus it (cycling through its windows
  // when it's already focused). The pointer is put back where it was, since
  // Hyprland warps it to the focused window.
  function isMinimized(t) { return !!t.workspace && t.workspace.name === "special:minimized" }
  function windowTarget(t) {
    var a = String(t.address || "")
    if (a.indexOf("0x") !== 0) a = "0x" + a
    return "window = \"address:" + a + "\""
  }
  // Run Hyprland dispatches without moving the pointer: every batch the sidebar
  // sends turns cursor warps off for itself (hbatch.sh), so focusing a window
  // from here doesn't drag the pointer out of the sidebar.
  readonly property string hbatchScript: Qt.resolvedUrl("hbatch.sh").toString().replace("file://", "")
  function dispatchKeepCursor(steps, tail, head) {
    var parts = []
    var batch = steps.map(function(s) { return "dispatch " + s }).join(" ; ")
    if (head) {
      // solo.sh remembers fullscreen windows itself, and sends the steps in the
      // same batch that starts the old windows sliding out, so the app brought
      // forward moves in the same frame.
      parts.push((batch ? "SIDEBAR_THEN=" + Util.shellQuote(batch) + " " : "") + head)
    } else {
      // remember a fullscreen window being switched away from (fsmem.sh);
      // minimize.sh does this itself
      if (String(tail || "").indexOf(root.minimizeScript) < 0) parts.push("bash " + Util.shellQuote(root.fsmemScript) + " save")
      if (batch) parts.push(". " + Util.shellQuote(root.hbatchScript) + "; hbatch " + Util.shellQuote(batch))
    }
    if (tail) parts.push(tail)
    if (!parts.length) return
    var cmd = parts.join("; ")
    root.run(cmd)
  }

  // ---- one app at a time ------------------------------------------------------
  // An app opened or brought forward takes its workspace to itself: the other
  // windows there are minimized (solo.sh). Shift+click tiles it alongside instead,
  // and more windows from the same app (Steam + its chat) tile together.
  readonly property string soloScript: Qt.resolvedUrl("solo.sh").toString().replace("file://", "")
  readonly property string minimizeScript: Qt.resolvedUrl("minimize.sh").toString().replace("file://", "")
  readonly property string fsmemScript: Qt.resolvedUrl("fsmem.sh").toString().replace("file://", "")
  readonly property string restoreScript: Qt.resolvedUrl("restore.sh").toString().replace("file://", "")
  function restoreCommand(ws, list) { return "bash " + Util.shellQuote(root.restoreScript) + " " + ws + list.map(function(t) { return " " + Util.shellQuote(root.addrOf(t)) }).join("") }
  function fsRestore(list) { return "bash " + Util.shellQuote(root.fsmemScript) + " restore" + list.map(function(t) { return " " + Util.shellQuote(root.addrOf(t)) }).join("") }
  // The next new window tiles instead of opening alone (Shift+click, drag-and-drop):
  // a short-lived note read by hypr/solo.lua.
  readonly property string tileNextFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/jake-sidebar-tile-next"
  function tileNextCommand() { return "echo $(( $(date +%s) + 30 )) > " + Util.shellQuote(root.tileNextFile) }
  // Shift state, written by pass-through Shift binds in hypr/binds.lua
  // (the sidebar has no keyboard focus, so it can't see modifiers itself).
  property bool shiftHeld: false
  FileView {
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/jake-sidebar-shift"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.shiftHeld = String(text()).trim() === "1"
  }
  function clearCommand(keep) {
    var mon = Hyprland.focusedMonitor
    var here = mon && mon.activeWorkspace ? mon.activeWorkspace.id : 1
    return "bash " + Util.shellQuote(root.soloScript) + " --clear " + here
      + (keep || []).map(function(k) { return " " + Util.shellQuote(root.addrOf(k)) }).join("")
  }
  // A gear as an SVG path: `teeth` teeth between radius ri and ro around (cx, cy),
  // with a round hole of radius rh (fill it with the odd-even rule).
  function gearPath(cx, cy, ro, ri, rh, teeth) {
    var step = 2 * Math.PI / teeth, pts = []
    function pt(a, r) { return (cx + r * Math.cos(a)).toFixed(3) + " " + (cy + r * Math.sin(a)).toFixed(3) }
    for (var k = 0; k < teeth; k++) {
      var a = k * step + step / 2       // a gap, not a tooth, where the cut runs
      pts.push(pt(a - step * 0.36, ri), pt(a - step * 0.22, ro), pt(a + step * 0.22, ro), pt(a + step * 0.36, ri))
    }
    var hole = "M " + (cx + rh) + " " + cy + " A " + rh + " " + rh + " 0 1 0 " + (cx - rh) + " " + cy
             + " A " + rh + " " + rh + " 0 1 0 " + (cx + rh) + " " + cy + " Z"
    return "M " + pts.join(" L ") + " Z " + hole
  }
  function addrOf(t) { var a = String(t.address || ""); return a.indexOf("0x") === 0 ? a : "0x" + a }

  // Click on an app:
  //   not running            -> launch it
  //   in front (focused)     -> minimize its windows
  //   open but not in front  -> bring it forward
  //   only minimized windows -> restore them here and focus
  // Order of an app's windows in its list, as rearranged by dragging (this session).
  property var windowOrder: ({})
  property int windowOrderRev: 0
  function moveWindowTo(appKey, windows, t, index) {
    var addrs = windows.map(function(w) { return root.addrOf(w) })
    var a = root.addrOf(t)
    var from = addrs.indexOf(a)
    if (from < 0) return
    addrs.splice(from, 1)
    if (from < index) index--
    addrs.splice(Math.max(0, Math.min(index, addrs.length)), 0, a)
    var next = Object.assign({}, root.windowOrder)
    next[appKey] = addrs
    root.windowOrder = next
    root.windowOrderRev++
  }
  // A single window, dragged on its own: looks like an app item holding just it.
  function windowDragItem(app, t) {
    return { key: app.key, entry: app.entry, custom: app.custom, windows: [t], separator: false, pinned: app.pinned,
             windowOnly: true, label: String(t.title || root.displayName(app)), appWindows: app.windows }
  }

  // Overview (Super): every open window of the list, shown over the window area.
  property bool overviewOpen: false
  property string overviewMonitor: ""
  // 0 = previews sit on the real windows, 1 = zoomed out into the grid
  property real ovProgress: 0
  Behavior on ovProgress { NumberAnimation { duration: Style.duration(280); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
  property var ovGeometry: ({})
  function toggleOverview() {
    if (root.overviewOpen) { root.closeOverview(); return }
    // not while editing: it would cover the editor (and closing that drops unsaved changes)
    if (root.editing) return
    // the overview replaces whatever the sidebar had open
    if (root.searching) root.exitSearch("overview")
    root.qsOpen = false
    root.closeTrayMenu()
    root.overviewMonitor = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    ovGeoProc.running = true          // read where each window is, then zoom out
  }
  function closeOverview() { root.overviewOpen = false; root.ovProgress = 0 }
  Process {
    id: ovGeoProc
    command: ["bash", "-c", "hyprctl clients -j | jq -c 'map({key: .address, value: {x: .at[0], y: .at[1], w: .size[0], h: .size[1]}}) | from_entries'"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.ovGeometry = JSON.parse(text) } catch (e) { root.ovGeometry = ({}) }
        root.overviewOpen = true
        Qt.callLater(function() { root.ovProgress = 1 })
      }
    }
  }
  readonly property string pairScript: Qt.resolvedUrl("pair.sh").toString().replace("file://", "")
  // Overview drag-and-drop: `dragged` beside `target` (side "l"/"r"), the rest minimized.
  function pairWindows(target, dragged, side) {
    var mon = Hyprland.focusedMonitor
    var here = mon && mon.activeWorkspace ? mon.activeWorkspace.id : 1
    root.closeOverview()
    Quickshell.execDetached(["bash", root.pairScript, root.addrOf(target), root.addrOf(dragged), side, String(here)])
  }
  function overviewWindows() {
    var out = []
    root.appItems("").forEach(function(r) { (r.windows || []).forEach(function(t) { out.push(t) }) })
    // showing windows first, minimized after
    return out.filter(function(t) { return !root.isMinimized(t) }).concat(out.filter(function(t) { return root.isMinimized(t) }))
  }
  function overviewAppName(t) {
    var app = t && t.wayland ? String(t.wayland.appId || "") : ""
    var rows = root.appItems("").filter(function(r) { return r.key === root.entryIdFor(app) })
    return rows.length ? root.displayName(rows[0]) : (app.split(".").pop() || "Window")
  }

  // Apps with several windows can be expanded into a list of them.
  property var expandedApps: ({})
  function toggleExpanded(key) {
    var next = Object.assign({}, root.expandedApps)
    next[key] = !next[key]
    root.expandedApps = next
    root.writeState()
  }
  // One window of an app: in front -> minimize it; otherwise show it on its own
  // (others minimized first), or beside what's showing with Shift.
  function activateWindow(t, tile) {
    if (!t) return
    // From the overview a click always opens: close it, never minimize.
    var fromOverview = root.overviewOpen
    if (fromOverview) root.closeOverview()
    if (!fromOverview && !root.isMinimized(t) && t.activated) {
      root.dispatchKeepCursor([], "bash " + Util.shellQuote(root.minimizeScript) + " " + Util.shellQuote(root.addrOf(t)))
      return
    }
    var mon = Hyprland.focusedMonitor
    var here = mon && mon.activeWorkspace ? mon.activeWorkspace.id : 1
    var head = tile ? "" : root.clearCommand([t])
    if (root.isMinimized(t)) { root.dispatchKeepCursor([], root.restoreCommand(here, [t]), head); return }
    var steps = ["hl.dsp.focus({ " + root.windowTarget(t) + " })",
                 "hl.dsp.window.alter_zorder({ mode = \"top\", " + root.windowTarget(t) + " })"]
    root.dispatchKeepCursor(steps, root.fsRestore([t]), head)
  }
  function closeWindow(t) {
    if (t) root.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.window.close({ " + root.windowTarget(t) + " })"))
  }

  function activateApp(item, tile) {
    if (!item || item.separator) return
    var fromOverview = root.overviewOpen
    if (fromOverview) root.closeOverview()
    var wins = item.windows || []
    if (wins.length === 0) {
      var launch = root.launchCommandFor(item)
      if (launch) root.run(tile ? root.tileNextCommand() + "; " + launch : launch)
      return
    }

    var mon = Hyprland.focusedMonitor
    var here = mon && mon.activeWorkspace ? mon.activeWorkspace.id : 1
    var visible = wins.filter(function(t) { return !root.isMinimized(t) })
    var hidden = wins.filter(function(t) { return root.isMinimized(t) })
    var focused = visible.some(function(t) { return t.activated })
    var steps = []
    var head = ""
    var park = ""

    if (focused && !fromOverview) {
      // Slide them out to the left and hide them (minimize.sh).
      head = ""
      park = "bash " + Util.shellQuote(root.minimizeScript) + visible.map(function(t) { return " " + Util.shellQuote(root.addrOf(t)) }).join("")
    } else if (visible.length > 0) {
      var t = visible[0]
      if (!tile) head = root.clearCommand(visible)
      steps.push("hl.dsp.focus({ " + root.windowTarget(t) + " })")
      steps.push("hl.dsp.window.alter_zorder({ mode = \"top\", " + root.windowTarget(t) + " })")
    } else {
      if (!tile) head = root.clearCommand([])
      // Parked off the left edge while minimized: tiling them again slides them in from there.
      park = root.restoreCommand(here, hidden)
    }
    if (!park) park = root.fsRestore([visible[0]])
    root.dispatchKeepCursor(steps, park, head)
  }


  // ---- integrated Omarchy menu (the Super+Space menu) ------------------------
  // Reads the same JSONC menu files as Omarchy's menu and reuses its model
  // code, so menu extensions and Omarchy updates show up here too.
  property bool searching: false
  property string searchMonitor: ""
  property string query: ""
  property string activeMenu: "root"
  property int selectedIndex: 0
  property var defaultMenuItems: []
  property var userMenuItems: []
  property bool defaultMenuSettled: false
  property bool userMenuSettled: false
  property var menuItems: ({})
  property var menuOrder: []
  property var whenResults: ({})
  property var checkedResults: ({})
  property var disabledResults: ({})

  ShellIpc {
    target: "jake.sidebar"
    function search() { root.toggleSearch() }
    function openSearch() { root.enterSearch() }
    function closeSearch() { root.exitSearch() }
    function quickSettings() { root.toggleQuickSettings() }
    function launchPinned(n: int) { root.launchPinned(n) }
    function edit() { if (root.editing) root.stopEditing(); else root.startEditing() }
    function overview() { root.toggleOverview() }
    function settings(section: string) { root.openSettings(section) }
    // the old detail pages are now sections ("audio" was the sound page)
    function settingsPage(page: string) { if (!root.qsOpen) root.openSettings(""); root.qsSection = page === "audio" ? "sound" : page }
    function searchFor(text: string) { root.enterSearch(); root.query = text }
  }

  function toggleSearch() { if (root.searching) root.exitSearch(); else root.enterSearch() }
  function enterSearch(monitorName) {
    var mon = monitorName || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    root.query = ""
    root.activeMenu = "root"
    root.selectedIndex = 0
    root.searchMonitor = mon
    root.closeTrayMenu()
    root.closeDockedPanel()
    root.searching = true
  }
  function exitSearch(why) {
    root.searching = false
    root.query = ""
    root.activeMenu = "root"
    root.selectedIndex = 0
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.defaultMenuItems = MenuModel.keepMenuRows(root.defaultMenuItems, text(), true); root.defaultMenuSettled = true; root.rebuildMenu() }
    onLoadFailed: { root.defaultMenuSettled = true; root.rebuildMenu() }
  }
  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.userMenuItems = MenuModel.keepMenuRows(root.userMenuItems, text(), false); root.userMenuSettled = true; root.rebuildMenu() }
    onLoadFailed: { root.userMenuItems = []; root.userMenuSettled = true; root.rebuildMenu() }
  }
  function rebuildMenu() {
    var merged = MenuModel.mergeMenuSources(root.defaultMenuItems, root.userMenuItems, "Go")
    root.menuItems = merged.items
    root.menuOrder = merged.itemOrder
    if (root.defaultMenuSettled && root.userMenuSettled) root.evaluateGuards()
  }

  // when / checked / disabled conditions, batched into one bash run.
  function evaluateGuards() {
    if (guardProc.running) { guardRerun.restart(); return }
    var script = MenuModel.guardScript(root.menuItems)
    if (!script) { root.whenResults = ({}); root.checkedResults = ({}); root.disabledResults = ({}); return }
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }
  Timer { id: guardRerun; interval: 200; onTriggered: root.evaluateGuards() }
  // Conditions can change (installs, toggles), so re-check each time it opens.
  onSearchingChanged: {
    if (searching) qsOpen = false
    if (searching && defaultMenuSettled && userMenuSettled) evaluateGuards()
  }
  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser { onRead: function(data) { guardProc.collected += data + "\n" } }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) return
      var w = ({}), c = ({}), d = ({})
      var lines = guardProc.collected.split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt), tag = rest.substring(tagAt + 1)
        if (tag === "w") w[id] = value
        else if (tag === "c") c[id] = value
        else if (tag === "d") d[id] = value
      }
      root.whenResults = w; root.checkedResults = c; root.disabledResults = d
    }
  }

  function visibleEntry(e) { return MenuModel.isVisible(root.menuItems, root.menuOrder, root.whenResults, e) }
  function disabledEntry(e) { return MenuModel.isDisabled(root.disabledResults, e) }
  function menuRow(e, detail, score) {
    var r = MenuModel.displayRow(root.menuItems, root.menuOrder, root.checkedResults, root.disabledResults, e, detail, score, "")
    return r
  }
  function launchableApps() {
    var all = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < all.length; i++) if (!all[i].noDisplay) out.push(all[i])
    return out
  }
  function appRow(entry, score, detail) {
    return { kind: "app", itemId: "app:" + entry.id, label: entry.name, icon: "", iconFont: "", detail: detail || "",
             target: "", action: "", provider: "", disabled: false, childCount: 0, score: score, entry: entry }
  }

  // The rows the panel shows while searching.
  readonly property var searchRows: {
    var revision = DesktopEntries.applications.values.length
    var items = root.menuItems, order = root.menuOrder
    var q = root.query.trim()
    var active = items[root.activeMenu] ? root.activeMenu : "root"
    var rows = []
    if (q) {
      var terms = q.toLowerCase().split(/\s+/)
      var apps = root.launchableApps()
      for (var a = 0; a < apps.length; a++) {
        var e = apps[a]
        var name = String(e.name || "").toLowerCase()
        var hay = (name + " " + String(e.genericName || "") + " " + (e.keywords || []).join(" ") + " " + String(e.id || "")).toLowerCase()
        if (!terms.every(function(t) { return hay.indexOf(t) >= 0 })) continue
        var needle = q.toLowerCase()
        var sc = name === needle || name.split(/\s+/).indexOf(needle) >= 0 ? 0 : name.indexOf(needle) === 0 ? 10 : name.indexOf(needle) >= 0 ? 30 : 40
        rows.push(root.appRow(e, (sc - 5) * 1000, "Apps"))
      }
      for (var i = 0; i < order.length; i++) {
        var m = items[order[i]]
        if (!m || m.id === "root" || m.id === "apps") continue
        if (!MenuModel.isDescendantOf(items, m.id, active)) continue
        if (!MenuModel.matchesQuery(m, q, root.visibleEntry(m) && !root.disabledEntry(m))) continue
        rows.push(root.menuRow(m, MenuModel.parentPathFor(items, m.id), MenuModel.searchScore(items, m, q)))
      }
      rows.sort(function(x, y) { return x.score - y.score || String(x.label).localeCompare(String(y.label)) })
      rows = rows.slice(0, 80)
    } else if (active === "apps") {
      rows = root.launchableApps().map(function(e) { return root.appRow(e, 0, "") })
      rows.sort(function(x, y) { return String(x.label).toLowerCase().localeCompare(String(y.label).toLowerCase()) })
    } else {
      for (var j = 0; j < order.length; j++) {
        var c = items[order[j]]
        if (!c || c.parent !== active || !root.visibleEntry(c)) continue
        rows.push(root.menuRow(c, c.description, c.order))
      }
    }
    if (active !== "root" && !q) {
      var here = items[active]
      rows.unshift({ kind: "back", itemId: "back", label: here ? (here.title || here.label) : "Back", icon: "", iconFont: "",
                     detail: "", target: "", action: "", provider: "", disabled: false, childCount: 0, score: -1 })
    }
    return rows
  }
  onSearchRowsChanged: if (selectedIndex >= searchRows.length) selectedIndex = Math.max(0, searchRows.length - 1)
  onQueryChanged: selectedIndex = 0

  function menuBack() {
    var here = root.menuItems[root.activeMenu]
    root.activeMenu = here && here.parent ? here.parent : "root"
    root.selectedIndex = 0
  }
  function openMenu(id) {
    root.activeMenu = id
    root.query = ""
    root.selectedIndex = 0
  }
  function activateSearchRow(row) {
    if (!row || row.disabled) return
    if (row.kind === "back") { root.menuBack(); return }
    if (row.kind === "app") {
      // Same as the app list: minimize what's showing first, so it opens full.
      var launch = root.launchCommand(row.entry)
      if (launch) root.run(root.shiftHeld ? root.tileNextCommand() + "; " + launch : launch)
      root.exitSearch()
      return
    }
    if (row.provider === "apps") { root.openMenu("apps"); return }
    if (row.kind === "menu" || row.kind === "link") {
      var target = row.target || row.itemId
      var t = root.menuItems[target]
      // Rows built at runtime by the Omarchy menu (fonts, kernels, languages)
      // still open in Omarchy's own menu.
      if (t && t.provider && t.provider !== "apps") {
        Quickshell.execDetached(["omarchy-menu", "summon", target])
        root.exitSearch()
        return
      }
      root.openMenu(target)
      return
    }
    if (row.action) Quickshell.execDetached(["bash", "-lc", String(row.action)])
    root.exitSearch()
  }
  function moveSelection(step) {
    var rows = root.searchRows
    if (rows.length === 0) return
    var i = root.selectedIndex
    for (var n = 0; n < rows.length; n++) {
      i = (i + step + rows.length) % rows.length
      if (!rows[i].disabled) { root.selectedIndex = i; return }
    }
  }

  // ---- quick settings -------------------------------------------------------
  // Omarchy's Setup menu entries live in the quick settings tabs they belong to.
  // One entry as a menu row, or null when it's missing or hidden on this machine.
  function menuRowById(id) {
    var e = root.menuItems[id]
    if (!e || !root.visibleEntry(e)) return null
    return root.menuRow(e, e.description, e.order)
  }
  // the label of the chosen option in a pick-one submenu (the default browser …)
  function checkedChildLabel(id) {
    var items = root.menuItems, order = root.menuOrder
    for (var i = 0; i < order.length; i++) {
      var c = items[order[i]]
      if (c && c.parent === id && root.checkedResults[c.id]) return String(c.label || "")
    }
    return ""
  }
  // re-read what's checked and what shows (after something ran, or on opening)
  function refreshMenuGuards() { if (root.defaultMenuSettled && root.userMenuSettled) root.evaluateGuards() }
  Timer { id: guardsLater; interval: 2500; onTriggered: root.refreshMenuGuards() }
  property bool qsOpen: false
  property string qsMonitor: ""
  property var qsState: ({ wifi: false, night: false, idle: false, profile: "", netType: "", netName: "" })
  function toggleQuickSettings(monitorName) {
    root.closeDockedPanel()
    if (root.qsOpen) { root.qsOpen = false; return }
    root.closeOverview()     // it would cover what opens next
    root.exitSearch()
    root.closeTrayMenu()
    root.qsMonitor = monitorName || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    root.qsOpen = true
    root.selDisplay = root.qsMonitor
    qsPoll.running = true
    root.refreshMenuGuards()
    displayPoll.running = true
  }
  function closeQuickSettings() { root.qsOpen = false }

  Process {
    id: qsPoll
    command: ["bash", "-c",
      "echo wifi $(nmcli radio wifi 2>/dev/null); " +
      "echo night $(omarchy-toggle-nightlight --status 2>/dev/null | jq -r .enabled); " +
      "echo idle $(omarchy-toggle-idle status 2>/dev/null | jq -r .enabled); " +
      "echo profile $(powerprofilesctl get 2>/dev/null); " +
      "nmcli -t -f TYPE,STATE,CONNECTION device 2>/dev/null | awk -F: '$2==\"connected\" && $1!=\"loopback\" {print \"net\", $1, $3; exit}'"]
    stdout: StdioCollector {
      onStreamFinished: {
        var next = Object.assign({}, root.qsState)
        String(text).split("\n").forEach(function(line) {
          var f = line.trim().split(/\s+/)
          if (f[0] === "wifi") next.wifi = f[1] === "enabled"
          else if (f[0] === "night") next.night = f[1] === "true"
          else if (f[0] === "idle") next.idle = f[1] === "true"
          else if (f[0] === "profile") next.profile = f[1] || ""
          else if (f[0] === "net") { next.netType = f[1] || ""; next.netName = f.slice(2).join(" ") }
        })
        root.qsState = next
      }
    }
  }
  Timer { id: qsRepoll; interval: 900; onTriggered: qsPoll.running = true }

  // Do not disturb, live from Omarchy's notification service.
  readonly property var notifService: root.shell && typeof root.shell.firstPartyServiceFor === "function"
    ? root.shell.firstPartyServiceFor("omarchy.notifications") : null
  readonly property bool dnd: !!root.notifService && root.notifService.doNotDisturb === true
  function qsToggle(key) {
    if (key === "dnd" && root.notifService && typeof root.notifService.setDoNotDisturb === "function") {
      root.notifService.setDoNotDisturb(!root.dnd)
      return
    }
    var s = Object.assign({}, root.qsState)
    var cmd = ""
    if (key === "wifi") cmd = "nmcli radio wifi " + (s.wifi ? "off" : "on")
    else if (key === "bt") cmd = "omarchy-bluetooth-power " + (root.btAdapter && root.btAdapter.enabled ? "off" : "on")
    else if (key === "night") cmd = "omarchy-toggle-nightlight"
    else if (key === "idle") cmd = "omarchy-toggle-idle"
    else if (key === "dnd") cmd = "omarchy-toggle-notification-silencing"
    else if (key === "profile") {
      var order = ["power-saver", "balanced", "performance"]
      var next = order[(order.indexOf(s.profile) + 1) % order.length]
      cmd = "powerprofilesctl set " + next
      s.profile = next
    }
    if (key !== "profile") s[key] = !s[key]
    root.qsState = s
    if (cmd) Quickshell.execDetached(["bash", "-lc", cmd])
    qsRepoll.restart()
  }

  function systemAction(cmd) {
    root.closeQuickSettings()
    Quickshell.execDetached(["bash", "-lc", cmd])
  }

  // Settings section (in the sidebar, above the gear)
  property string qsSection: ""
  function toggleSection(id) { root.qsSection = root.qsSection === id ? "" : id }
  // an expanded row inside a section (a default-apps category, Security, Plugins …)
  property string qsSub: ""
  onQsSectionChanged: { qsSub = ""; qsTyping = "" }
  // a text field in quick settings that wants the keyboard ("" = none)
  property string qsTyping: ""

  // ---- Omarchy menu entries edited right in quick settings ----
  // the visible children of a menu entry, in menu order
  function menuChildren(id) {
    var items = root.menuItems, order = root.menuOrder, out = []
    for (var i = 0; i < order.length; i++) {
      var e = items[order[i]]
      if (!e || e.parent !== id || !root.visibleEntry(e)) continue
      out.push({ id: e.id, label: String(e.label || ""), action: String(e.action || ""),
                 checkable: e.checked !== undefined && e.checked !== "" && e.checked !== null,
                 checked: !!root.checkedResults[e.id], disabled: root.disabledEntry(e),
                 hasKids: MenuModel.childCount(items, order, e.id) > 0 || !!e.provider })
    }
    return out
  }
  // a pick (default browser …) runs here and quick settings stays open; anything
  // that opens a window (a setup wizard, an editor) closes it first
  function runMenuEntry(c) {
    if (!c || c.disabled) return
    if (c.hasKids) {
      var row = root.menuRowById(c.id), mon = root.qsMonitor
      root.closeQuickSettings(); root.enterSearch(mon); root.activateSearchRow(row); return
    }
    if (!c.action) return
    if (c.checkable) {
      var chk = Object.assign({}, root.checkedResults), e = root.menuItems[c.id]
      root.menuChildren(e ? e.parent : "").forEach(function(s) { chk[s.id] = false })
      chk[c.id] = true
      root.checkedResults = chk          // show the pick at once
      Quickshell.execDetached(["bash", "-lc", c.action])
      guardsLater.restart()
      return
    }
    root.closeQuickSettings()
    Quickshell.execDetached(["bash", "-lc", c.action])
    guardsLater.restart()
  }

  // ---- Keyboard & mouse (input.sh) ----
  readonly property string inputScript: Qt.resolvedUrl("input.sh").toString().replace("file://", "")
  property var inputState: ({})
  property var inputPending: ({})
  function inputVal(k, dflt) { var v = root.inputState[k]; return v === undefined || v === null ? dflt : v }
  function setInput(k, v) {
    var st = Object.assign({}, root.inputState); st[k] = v; root.inputState = st
    var p = Object.assign({}, root.inputPending); p[k] = String(v); root.inputPending = p
    inputApply.restart()
  }
  Timer {
    id: inputApply
    interval: 300
    onTriggered: {
      if (inputSetProc.running) { restart(); return }
      var args = ["bash", "-c", 's=$1; shift; while (($#)); do bash "$s" set "$1" "$2"; shift 2; done', "sh", root.inputScript]
      var p = root.inputPending, n = 0
      for (var k in p) { args.push(k, p[k]); n++ }
      root.inputPending = ({})
      if (!n) return
      inputSetProc.command = args
      inputSetProc.running = true
    }
  }
  Process { id: inputSetProc; onExited: inputPoll.running = true }
  function resetInput() { Quickshell.execDetached(["bash", "-c", 'bash "$1" reset', "sh", root.inputScript]); inputPollLater.restart() }
  Timer { id: inputPollLater; interval: 900; onTriggered: inputPoll.running = true }
  Process {
    id: inputPoll
    command: ["bash", root.inputScript, "get"]
    stdout: StdioCollector {
      onStreamFinished: { try { var v = JSON.parse(String(text)); if (v && typeof v === "object" && !inputSetProc.running && !inputApply.running) root.inputState = v } catch (e) {} }
    }
  }

  // ---- System › Plugins (omarchy plugin list) ----
  property var pluginList: []
  property bool pluginBusy: false
  readonly property var pluginsShown: root.pluginList.filter(function(p) { return (p.kinds || []).indexOf("bar") < 0 })   // not the bar itself (that's this sidebar)
  Process {
    id: pluginPoll
    command: ["omarchy", "plugin", "list", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var v = JSON.parse(String(text))
          if (Array.isArray(v)) root.pluginList = v.sort(function(a, b) { return (b.enabled - a.enabled) || String(a.name).localeCompare(String(b.name)) })
        } catch (e) {}
        root.pluginBusy = false
      }
    }
  }
  function setPluginEnabled(p, on) {
    if (!on && !p.canDisable) return
    var l = root.pluginList.map(function(x) { return x.id === p.id ? Object.assign({}, x, { enabled: on }) : x })
    root.pluginList = l
    root.pluginBusy = true
    Quickshell.execDetached(["omarchy", "plugin", on ? "enable" : "disable", p.id])
    pluginPollLater.restart()
  }
  Timer { id: pluginPollLater; interval: 1500; onTriggered: pluginPoll.running = true }

  // ---- System › Git ----
  property string gitName: ""
  property string gitEmail: ""
  Process {
    id: gitPoll
    command: ["bash", "-c", "git config --global user.name; echo; git config --global user.email"]
    stdout: StdioCollector {
      onStreamFinished: { var l = String(text).split("\n"); root.gitName = (l[0] || "").trim(); root.gitEmail = (l[2] || l[1] || "").trim() }
    }
  }
  function setGit(field, value) {
    value = String(value).trim()
    root.qsTyping = ""
    if (!value) return
    if (field === "name") root.gitName = value; else root.gitEmail = value
    Quickshell.execDetached(["omarchy-setup-git", field === "name" ? "--name" : "--email", value])
  }
  readonly property var btAdapter: Bluetooth.defaultAdapter
  readonly property var btDevices: {
    var all = Bluetooth.devices ? Bluetooth.devices.values : []
    return all.filter(function(d) { return d.paired || d.bonded || d.trusted || d.connected })
              .sort(function(a, b) { return (b.connected ? 1 : 0) - (a.connected ? 1 : 0) || String(a.name).localeCompare(String(b.name)) })
  }
  function btToggleDevice(d) {
    if (!d || !d.address) return
    Quickshell.execDetached(["omarchy-bluetooth-device", d.connected ? "disconnect" : "connect", d.address])
  }
  readonly property var source: Pipewire.defaultAudioSource
  PwObjectTracker { objects: root.source ? [root.source] : [] }
  readonly property var sinkNodes: {
    var all = Pipewire.nodes ? Pipewire.nodes.values : []
    return all.filter(function(n) { return n.isSink && !n.isStream && n.audio })
  }
  PwObjectTracker { objects: root.sinkNodes }
  function nodeName(n) { return n ? String(n.nickname || n.description || n.name || "") : "" }
  function setSink(n) {
    if (!n) return
    Pipewire.preferredDefaultAudioSink = n
    if (n.id !== undefined && n.name) Quickshell.execDetached(["omarchy-audio-output-set-default", String(n.id), String(n.name)])
  }
  function setProfile(p) {
    var s = Object.assign({}, root.qsState); s.profile = p; root.qsState = s
    Quickshell.execDetached(["powerprofilesctl", "set", p])
    qsRepoll.restart()
  }
  function profileLabel(p) { return p === "power-saver" ? "Saver" : p === "performance" ? "Performance" : p === "balanced" ? "Balanced" : "" }

  // Tray menus
  property var trayMenuItem: null
  property var trayMenuSub: null
  property string trayMenuMonitor: ""
  function openTrayMenu(item, monitorName) {
    root.closeDockedPanel()
    root.qsOpen = false
    root.exitSearch()
    root.trayMenuSub = null
    root.trayMenuMonitor = monitorName
    root.trayMenuItem = item
  }
  function closeTrayMenu() { root.trayMenuSub = null; root.trayMenuItem = null }

  // ---- settings sections: everything is edited right in the open section ----
  onQsOpenChanged: if (!qsOpen) { qsSection = ""; pwSsid = ""; qsTyping = ""; displayDraft = ({}) } else checkForUpdates(false)
  readonly property string qsLive: qsOpen ? qsSection : ""
  onQsLiveChanged: {
    pwSsid = ""
    if (root.wifiDevice) root.wifiDevice.scannerEnabled = qsLive === "network"
    if (root.btAdapter) root.btAdapter.discovering = qsLive === "bluetooth"
    if (qsLive === "network") dnsProc.running = true
    if (qsLive === "display") displayPoll.running = true
    if (qsLive === "input") inputPoll.running = true
    if (qsLive === "system") { pluginPoll.running = true; gitPoll.running = true }
    if (qsLive === "defaults") root.refreshMenuGuards()
  }
  // Open settings at a section (keybinds); the same section again closes it.
  function openSettings(section) {
    if (root.qsOpen && (!section || root.qsSection === section)) { root.qsOpen = false; return }
    root.closeOverview()
    root.exitSearch()
    root.closeTrayMenu()
    root.qsMonitor = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    root.selDisplay = root.qsMonitor
    if (section) root.qsSection = section
    root.qsOpen = true
    qsPoll.running = true
    root.refreshMenuGuards()
  }

  // Wi-Fi
  readonly property var wifiDevice: {
    var devs = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devs.length; i++) if (devs[i].type === DeviceType.Wifi) return devs[i]
    return null
  }
  function signalOf(n) { var s = Number(n.signalStrength || 0); return s > 1 ? s / 100 : s }
  readonly property var wifiNetworks: {
    var nets = root.wifiDevice && root.wifiDevice.networks ? root.wifiDevice.networks.values : []
    return nets.filter(function(n) { return n && n.name })
               .sort(function(a, b) { return (b.connected ? 1 : 0) - (a.connected ? 1 : 0) || (b.known ? 1 : 0) - (a.known ? 1 : 0) || root.signalOf(b) - root.signalOf(a) })
  }
  function secured(n) { return n.security !== WifiSecurityType.Open && n.security !== WifiSecurityType.Owe }
  function bars(n) { var s = root.signalOf(n); return s > 0.75 ? "▂▄▆█" : s > 0.5 ? "▂▄▆ " : s > 0.25 ? "▂▄  " : "▂   " }
  property string pwSsid: ""
  function wifiClick(n) {
    if (!n) return
    if (n.connected) { n.disconnect(); return }
    if (root.secured(n) && !n.known) { root.pwSsid = n.name; return }
    n.connect()
  }
  function wifiConnectWithPassword(pass) {
    var nets = root.wifiNetworks
    for (var i = 0; i < nets.length; i++) if (nets[i].name === root.pwSsid) { nets[i].connectWithPsk(pass); break }
    root.pwSsid = ""
  }

  // DNS
  property string dnsProvider: ""
  Process {
    id: dnsProc
    command: ["omarchy-dns"]
    stdout: StdioCollector { onStreamFinished: root.dnsProvider = String(text).trim().split("\n")[0] }
  }
  function setDns(p) {
    root.dnsProvider = p
    Quickshell.execDetached(["bash", "-lc", "omarchy-dns " + Util.shellQuote(p)])
  }

  // Bluetooth pairing
  readonly property var btNearby: {
    var all = Bluetooth.devices ? Bluetooth.devices.values : []
    var macLike = /^([0-9A-F]{2}[-:]){5}[0-9A-F]{2}$/i
    return all.filter(function(d) {
      var name = String(d.name || d.deviceName || "")
      return !(d.paired || d.bonded || d.trusted || d.connected) && name && !macLike.test(name)
    })
  }
  function btPair(d) { if (d && d.address) Quickshell.execDetached(["omarchy-bluetooth-device", "pair", d.address]) }
  function btForget(d) { if (d && d.address) Quickshell.execDetached(["omarchy-bluetooth-device", "forget", d.address]) }

  // Audio inputs and app volumes
  readonly property var sourceNodes: {
    var all = Pipewire.nodes ? Pipewire.nodes.values : []
    return all.filter(function(n) { return !n.isSink && !n.isStream && n.audio && String(n.name).indexOf(".monitor") < 0 })
  }

  PwObjectTracker { objects: root.sourceNodes }
  function setSource(n) {
    if (!n) return
    if (n.audio) Pipewire.preferredDefaultAudioSource = n
    if (n.id !== undefined && n.name) Quickshell.execDetached(["omarchy-audio-input-set-default", String(n.id), String(n.name)])
  }
  function streamName(n) {
    var p = n.properties || {}
    return String(p["application.name"] || p["media.name"] || n.description || n.name || "App")
  }

  // Display
  property int brightness: -1
  property string displayScale: ""
  property int textPx: 12
  property string modeSize: ""
  property real refreshRate: 0
  property var refreshRates: []
  property var resolutions: []
  property string modeRes: ""
  function resLabel(res) {
    var p = String(res).split("x"), w = Number(p[0]), h = Number(p[1])
    if (w * 9 === h * 16) return h === 2160 ? "4K" : h === 2880 ? "5K" : h + "p"
    return w + "×" + h
  }
  // The native (largest) resolution plus the other 16:9 ones, up to four.
  readonly property var resolutionOptions: {
    var out = []
    for (var i = 0; i < root.resolutions.length && out.length < 4; i++) {
      var p = root.resolutions[i].split("x")
      if (i === 0 || Number(p[0]) * 9 === Number(p[1]) * 16 || root.resolutions[i] === root.modeRes) out.push([root.resolutions[i], root.resLabel(root.resolutions[i])])
    }
    return out
  }
  function setResolution(res) {
    var m = root.selMon
    if (!m) return
    var rates = (m.ratesByRes || {})[res] || []
    // keep the refresh rate if the new resolution has it, else its fastest
    var keep = rates.filter(function(r) { return Math.abs(Number(r) - Number(m.hz)) < 0.01 })[0]
    // and the scale, rounded up to one this resolution accepts
    var p = res.split("x")
    root.editDisplay(m.name, { res: res, rate: keep || rates[0] || m.hz, scale: DisplayModel.cleanScale(m.scale, res) })
    root.reseatDraft(m.name)
  }
  // A dual-mode monitor switching modes reconnects with a new mode list:
  // re-read it whenever Hyprland reports monitors coming or going.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = String(event.name)
      if (n.indexOf("monitoradded") === 0 || n.indexOf("monitorremoved") === 0 || n === "configreloaded") displayRepoll.restart()
      if (n === "configreloaded") { themeProc.running = true; animProc.running = true; wallProc.running = true }
    }
  }
  readonly property string displayScript: Qt.resolvedUrl("display.sh").toString().replace("file://", "")

  // ---- displays: every connected monitor; the controls act on the selected one ----
  property var displaysLive: []      // from display.sh state
  property string selDisplay: ""     // picked in the list (defaults to the panel's monitor)
  // Edits wait here until Apply: { name: { res, rate, scale, transform, disabled, x, y } }
  property var displayDraft: ({})
  // the displays as they'll be after Apply (live + draft)
  readonly property var displays: root.displaysLive.map(function(m) {
    var e = root.displayDraft[m.name]
    if (!e) return m
    var c = Object.assign({}, m)
    if (e.res !== undefined) { var p = e.res.split("x"); c.w = Number(p[0]); c.h = Number(p[1]); c.rates = (m.ratesByRes || {})[e.res] || [] }
    if (e.rate !== undefined) c.hz = Number(e.rate)
    if (e.scale !== undefined) c.scale = Number(e.scale)
    if (e.transform !== undefined) c.transform = Number(e.transform)
    if (e.disabled !== undefined) c.disabled = e.disabled
    if (e.x !== undefined) { c.x = e.x; c.y = e.y }
    c.mode = c.w + "x" + c.h + "@" + c.hz
    return c
  })
  readonly property bool displayPending: {
    for (var i = 0; i < root.displays.length; i++) if (root.displayDirty(root.displays[i], root.displaysLive[i])) return true
    return false
  }
  function displayDirty(a, b) {
    if (!a || !b) return false
    if (a.disabled !== b.disabled) return true
    if (a.disabled) return false
    return a.w !== b.w || a.h !== b.h || Math.abs(Number(a.hz) - Number(b.hz)) > 0.01 || Number(a.scale) !== Number(b.scale)
        || Number(a.transform) !== Number(b.transform) || Math.round(a.x) !== Math.round(b.x) || Math.round(a.y) !== Math.round(b.y)
  }
  function editDisplay(name, change) {
    var d = Object.assign({}, root.displayDraft)
    d[name] = Object.assign({}, d[name] || {}, change)
    root.displayDraft = d
    root.applySelectedDisplay()
  }
  // a size change (resolution, scale, rotation, on/off) can make displays overlap: re-seat in the draft
  function reseatDraft(name) {
    if (root.enabledDisplays.length < 2) return
    var list = DisplayModel.clone(root.displays), idx = -1
    for (var i = 0; i < list.length; i++) if (list[i].name === name) idx = i
    if (idx < 0) return
    root.draftPositions(list[idx].disabled ? DisplayModel.tidy(list) : DisplayModel.reseat(list, idx))
  }
  function draftPositions(list) {
    var d = Object.assign({}, root.displayDraft)
    list.forEach(function(m) { if (!m.disabled) d[m.name] = Object.assign({}, d[m.name] || {}, { x: Math.round(m.x), y: Math.round(m.y) }) })
    root.displayDraft = d
  }
  function discardDisplayChanges() { root.displayDraft = ({}); root.applySelectedDisplay() }
  function applyDisplayChanges() {
    if (!root.displayPending) return
    var out = root.displays.map(function(m) {
      if (m.disabled) return { name: m.name, disabled: true }
      var rate = ""
      for (var i = 0; i < (m.rates || []).length; i++) if (Math.abs(Number(m.rates[i]) - Number(m.hz)) < 0.01) rate = m.rates[i]
      return { name: m.name, disabled: false, res: m.w + "x" + m.h, rate: rate || "best", scale: Number(m.scale), transform: Number(m.transform), x: Math.round(m.x), y: Math.round(m.y) }
    })
    // remember the chosen scale for the chosen resolution, so the poll doesn't swap it back
    root.displays.forEach(function(m, i) { if (!m.disabled && root.displayDirty(m, root.displaysLive[i])) root.saveScaleFor(m.name, m.w + "x" + m.h, String(Number(m.scale))) })
    root.displaysLive = root.displays   // show it as applied straight away
    root.displayDraft = ({})
    // display.sh puts the old settings back after 15 s unless Keep is pressed (works even if this panel is gone)
    Quickshell.execDetached(["bash", root.displayScript, "apply", JSON.stringify(out), "--confirm"])
    root.displayCountdown = 15
    displayRepoll.restart()
  }
  // ---- Keep / Revert after Apply ----
  property int displayCountdown: 0
  Timer {
    interval: 1000; repeat: true; running: root.displayCountdown > 0
    onTriggered: { root.displayCountdown--; if (root.displayCountdown === 0) displayRevertRepoll.restart() }
  }
  // the watchdog has reverted by now: read the monitors again
  Timer { id: displayRevertRepoll; interval: 2500; onTriggered: displayPoll.running = true }
  function keepDisplayChanges() {
    root.displayCountdown = 0
    Quickshell.execDetached(["bash", root.displayScript, "keep"])
  }
  function revertDisplayChanges() {
    root.displayCountdown = 0
    root.displayDraft = ({})
    Quickshell.execDetached(["bash", root.displayScript, "revert"])
    displayRevertRepoll.restart()
  }
  readonly property var selMon: {
    var d = root.displays, f = null
    for (var i = 0; i < d.length; i++) { if (d[i].name === root.selDisplay) return d[i]; if (d[i].focused) f = d[i] }
    return f || (d.length ? d[0] : null)
  }
  readonly property string selName: selMon ? selMon.name : ""
  readonly property var enabledDisplays: root.displays.filter(function(m) { return !m.disabled })
  onSelNameChanged: { root.applySelectedDisplay(); root.brightness = -1; brightnessPoll.running = true }
  function applySelectedDisplay() {
    var m = root.selMon
    if (!m) return
    root.modeSize = m.w + "×" + m.h
    root.modeRes = m.w + "x" + m.h
    root.refreshRate = Number(m.hz) || 0
    root.refreshRates = m.rates || []
    root.resolutions = m.resolutions || []
    root.displayScale = String(Number(m.scale))
    root.displayTransform = String(m.transform || 0)
  }
  property string displayTransform: "0"
  function displaySummary(m) {
    if (m.disabled) return "Off"
    if (m.mirrorOf && m.mirrorOf !== "none") return "Mirrors " + m.mirrorOf
    return root.resLabel(m.w + "x" + m.h) + " · " + Math.round(m.hz) + " Hz · " + Number(m.scale) + "×"
  }
  // drop display `name` at logical (x, y): snap it edge to edge with the others
  function moveDisplay(name, x, y) {
    var list = DisplayModel.clone(root.displays)
    for (var i = 0; i < list.length; i++) if (list[i].name === name) { root.draftPositions(DisplayModel.moveTo(list, i, x, y)); return }
  }
  function setDisplayEnabled(name, on) {
    if (!on && root.enabledDisplays.length < 2) return
    root.editDisplay(name, { disabled: !on })
    root.reseatDraft(name)
  }
  function setTransform(t) {
    root.displayTransform = t
    root.editDisplay(root.selName, { transform: Number(t) })
    root.reseatDraft(root.selName)
  }
  Process {
    id: brightnessPoll
    command: ["bash", root.displayScript, "brightness", root.selName]
    stdout: StdioCollector {
      onStreamFinished: { var b = parseInt(String(text).trim()); root.brightness = isNaN(b) ? -1 : b }
    }
  }
  // Whole-number rates, plus the current one if it's fractional (119.88, 59.94).
  readonly property var refreshOptions: {
    var cur = root.refreshRate
    return root.refreshRates.filter(function(r) {
      var n = Number(r)
      return Math.abs(n - Math.round(n)) < 0.001 || Math.abs(n - cur) < 0.01
    }).map(function(r) { var n = Number(r); return [r, (Math.abs(n - Math.round(n)) < 0.001 ? Math.round(n) : n.toFixed(2)) + " Hz"] })
  }
  readonly property string refreshCurrent: {
    for (var i = 0; i < root.refreshRates.length; i++) if (Math.abs(Number(root.refreshRates[i]) - root.refreshRate) < 0.01) return root.refreshRates[i]
    return ""
  }
  Timer { id: displayRepoll; interval: 1200; onTriggered: displayPoll.running = true }
  function setRefresh(r) {
    root.refreshRate = Number(r)
    root.editDisplay(root.selName, { rate: r })
  }
  Process {
    id: displayPoll
    command: ["bash", "-c", "bash \"$1\" state; omarchy-display-text-size 2>/dev/null | awk '/^Text size/ {print \"text\", $3}'", "sh", root.displayScript]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text).split("\n")
        try { var d = JSON.parse(lines[0]); if (Array.isArray(d)) root.displaysLive = d } catch (e) {}
        lines.forEach(function(l) {
          var f = l.trim().split(/\s+/)
          if (f[0] === "text") root.textPx = parseInt(f[1]) || 12
        })
        root.applySelectedDisplay()
        brightnessPoll.running = true
        root.rememberOrRestoreScale()
      }
    }
  }
  Timer {
    id: brightnessApply
    interval: 150
    onTriggered: {
      Quickshell.execDetached(["omarchy-brightness-display", "--no-osd", "--monitor", root.selName, root.brightness + "%"])
    }
  }
  function setBrightness(v) { root.brightness = Math.round(v * 100); brightnessApply.restart() }
  function setScale(sc) {
    root.displayScale = sc
    root.editDisplay(root.selName, { scale: DisplayModel.cleanScale(Number(sc), root.modeRes) })
    root.reseatDraft(root.selName)
  }

  // ---- scale remembered per monitor + resolution ----------------------------
  // Kept in ~/.config/omarchy/sidebar-display.json: { lastMode: {mon: res}, scales: {"mon:res": scale} }.
  // When a monitor comes back at a different resolution (a dual-mode switch),
  // the scale last used at that resolution is put back.
  readonly property string displayStatePath: Quickshell.env("HOME") + "/.config/omarchy/sidebar-display.json"
  property var displayState: ({ lastMode: {}, scales: {} })
  property bool displayStateLoaded: false
  FileView {
    path: root.displayStatePath
    printErrors: false
    onLoaded: {
      try { var v = JSON.parse(text()); if (v && typeof v === "object") root.displayState = { lastMode: v.lastMode || {}, scales: v.scales || {} } } catch (e) {}
      root.displayStateLoaded = true
      displayPoll.running = true
    }
    onLoadFailed: { root.displayStateLoaded = true; displayPoll.running = true }
  }
  function writeDisplayState() {
    Quickshell.execDetached(["bash", "-c", "printf '%s\\n' \"$1\" > \"$2\"", "sh", JSON.stringify(root.displayState), root.displayStatePath])
  }
  function saveScaleFor(mon, res, sc) {
    if (!mon || !res || !sc) return
    var st = { lastMode: Object.assign({}, root.displayState.lastMode), scales: Object.assign({}, root.displayState.scales) }
    st.scales[mon + ":" + res] = String(sc)
    st.lastMode[mon] = res
    root.displayState = st
    root.writeDisplayState()
  }
  function rememberOrRestoreScale() {
    if (!root.displayStateLoaded || !root.displaysLive.length) return
    var st = { lastMode: Object.assign({}, root.displayState.lastMode), scales: Object.assign({}, root.displayState.scales) }
    var dirty = false
    root.displaysLive.forEach(function(m) {
      if (m.disabled) return
      var mon = m.name, res = m.w + "x" + m.h, cur = String(Number(m.scale))
      var key = mon + ":" + res, saved = st.scales[key]
      var changedMode = st.lastMode[mon] !== undefined && st.lastMode[mon] !== res
      if (st.lastMode[mon] !== res) { st.lastMode[mon] = res; dirty = true }
      if (changedMode && saved && Number(saved) !== Number(cur)) {
        // New mode: put its remembered scale back.
        Quickshell.execDetached(["bash", root.displayScript, "scale", mon, saved])
        if (mon === root.selName) root.displayScale = saved
      } else if (saved !== cur) {
        // Same mode: whatever scale is in use now is the one to remember for it.
        st.scales[key] = cur; dirty = true
      }
    })
    if (!dirty) return
    root.displayState = st
    root.writeDisplayState()
  }
  function setTextPx(px) {
    px = Math.max(9, Math.min(20, px)); root.textPx = px
    Quickshell.execDetached(["omarchy-display-text-size", String(px)])
  }

  // ---- plugin panels docked inside the sidebar ------------------------------
  // A widget's panel (Omarchy's shared KeyboardPanel, which plugins use) normally
  // floats beside the bar. While one is open, its content is moved into the
  // sidebar above the bottom row and its own window is hidden; closing moves the
  // content back. Works for any plugin built on that panel, no per-plugin code.
  property var dockedPanel: null
  property var dockedItems: []
  property var dockedParents: []
  property string dockedName: ""
  property string dockedId: ""
  property string dockMonitor: ""
  property var dockBodies: ({})
  function registerDockBody(mon, item) { var n = Object.assign({}, root.dockBodies); n[mon] = item; root.dockBodies = n }

  function isKeyboardPanel(o) {
    return !!o && o.loadedContent !== undefined && o.contentRequested !== undefined && o.anchorItem !== undefined && o.contentItem !== undefined
  }
  // ---- widget parts: the blocks a widget section's panel is made of -------------
  // Found by walking the panel's content (moved into the section); each can be
  // switched off in the editor. Saved per section as "hiddenParts": paths of
  // child indexes from the section's content ("0/3/1").
  property var widgetParts: ({})        // section id -> [{ path, label, depth }]
  // Trim: px cut off a widget section's top / bottom ("cropTop", "cropBottom"),
  // for blank space a plugin's panel reserves or bits to cover. While a handle
  // is dragged in the editor the live values are here, saved on release.
  property var cropDrag: null           // { id, top, bottom }
  function cropOf(secId, edge) {
    if (root.cropDrag && root.cropDrag.id === secId) return edge === "top" ? root.cropDrag.top : root.cropDrag.bottom
    return Math.max(0, Number(root.setting(secId, edge === "top" ? "cropTop" : "cropBottom")) || 0)
  }
  function saveCrop(secId, top, bottom) {
    var next = JSON.parse(JSON.stringify(root.userSettings))
    next[secId] = next[secId] || {}
    next[secId].cropTop = Math.max(0, Math.round(top))
    next[secId].cropBottom = Math.max(0, Math.round(bottom))
    root.saveSettings(next)
  }
  function partKids(o, hiddenItems) {
    var out = []
    var kids = o && o.children ? o.children : []
    for (var i = 0; i < kids.length; i++) {
      var c = kids[i]
      if (!c || c.width === undefined) continue
      // what shows, plus what was switched off here (its own logic may hide it otherwise)
      if (c.visible || hiddenItems.indexOf(c) !== -1) out.push({ index: i, item: c })
    }
    return out
  }
  // the first real text inside (not an icon glyph), as the part's name
  function partLabel(o) {
    var queue = [o], seen = 0
    while (queue.length && seen++ < 200) {
      var n = queue.shift()
      var t = n && typeof n.text === "string" ? n.text.replace(/[\ue000-\uf8ff]/g, "").trim() : ""
      if (t) return t.length > 32 ? t.slice(0, 31) + "…" : t
      var kids = n && n.children ? n.children : []
      for (var i = 0; i < kids.length; i++) if (kids[i] && kids[i].visible !== false) queue.push(kids[i])
    }
    if (o && o.height <= 3) return "divider"
    return o && o.width <= 48 && o.height <= 48 ? "icon" : "unnamed part"
  }
  // [{ path, label, depth }]: skips wrappers with one child, lists the blocks of
  // the first container with several, and one level inside blocks that are lists
  function scanParts(top, hiddenItems) {
    var node = top, path = [], out = []
    for (var d = 0; d < 10; d++) {
      var only = root.partKids(node, hiddenItems)
      if (only.length !== 1) break
      node = only[0].item; path.push(only[0].index)
    }
    root.partKids(node, hiddenItems).forEach(function(k) {
      var p = path.concat([k.index])
      var row = { path: p.join("/"), label: root.partLabel(k.item), depth: 0 }
      out.push(row)
      var inner = k.item, ip = p.slice()
      for (var d2 = 0; d2 < 6; d2++) {
        var one = root.partKids(inner, hiddenItems)
        if (one.length !== 1) break
        inner = one[0].item; ip.push(one[0].index)
      }
      var subs = root.partKids(inner, hiddenItems)
      if (subs.length >= 2 && subs.length <= 12) {
        var named = []
        subs.forEach(function(s2) {
          var l = root.partLabel(s2.item)
          out.push({ path: ip.concat([s2.index]).join("/"), label: l, depth: 1 })
          if (l !== "divider" && l !== "icon" && l !== "unnamed part") named.push(l)
        })
        // a block holding a list is named after what's in it
        if (named.length >= 2) { var j = named.slice(0, 3).join(" · ") + (named.length > 3 ? " …" : ""); row.label = j.length > 40 ? j.slice(0, 39) + "…" : j }
      }
    })
    return out
  }
  function partAt(top, path) {
    var n = top
    var ix = String(path).split("/")
    for (var i = 0; i < ix.length && n; i++) n = n.children ? n.children[parseInt(ix[i])] : null
    return n || null
  }
  function togglePart(secId, path) {
    var cur = root.setting(secId, "hiddenParts")
    var list = Array.isArray(cur) ? cur.slice() : []
    var at = list.indexOf(path)
    if (at === -1) list.push(path); else list.splice(at, 1)
    root.setSetting(secId, "hiddenParts", list)
  }
  function findPanels(o, out, depth, seen) {
    if (!o || depth > 14 || seen.indexOf(o) !== -1) return
    seen.push(o)
    if (root.isKeyboardPanel(o)) { out.push(o); return }
    var kids = []
    try { if (o.data) for (var i = 0; i < o.data.length; i++) kids.push(o.data[i]) } catch (e) {}
    try { if (o.children) for (var j = 0; j < o.children.length; j++) kids.push(o.children[j]) } catch (e) {}
    try { if (o.item && typeof o.item === "object") kids.push(o.item) } catch (e) {}
    for (var k = 0; k < kids.length; k++) root.findPanels(kids[k], out, depth + 1, seen)
  }
  function hostedName(host) {
    var meta = host && host.registryEntry && host.registryEntry.metadata ? host.registryEntry.metadata : {}
    return String(meta.displayName || (meta.barWidget && meta.barWidget.displayName) || meta.name || (host ? host.moduleName : "") || "")
  }
  // Called when a hosted widget asks to show its panel.
  function dockOpenPanel() {
    for (var i = 0; i < root.hostedItems.length; i++) {
      var host = root.hostedItems[i]
      var panels = []
      root.findPanels(host.item, panels, 0, [])
      for (var p = 0; p < panels.length; p++) {
        if (panels[p].open) { root.dockedId = host.moduleName; root.dockPanel(panels[p], root.hostedName(host)); return }
      }
    }
  }
  function dockPanel(panel, name) {
    if (root.dockedPanel === panel) return
    root.undockPanel()
    root.qsOpen = false
    root.exitSearch()
    root.closeTrayMenu()
    var mon = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var body = root.dockBodies[mon] || root.dockBodies[Object.keys(root.dockBodies)[0]]
    if (!body) return
    panel.visible = false
    var kids = []
    for (var i = 0; i < panel.contentItem.length; i++) kids.push(panel.contentItem[i])
    root.dockedParents = kids.map(function(k) { return k.parent })
    kids.forEach(function(k) { k.parent = body; if (k.width < 1 || !k.anchors.fill) k.width = Qt.binding(function() { return body.width }) })
    root.dockedItems = kids
    root.dockedName = name || ""
    root.dockMonitor = mon
    root.dockedPanel = panel
  }
  function undockPanel() {
    if (!root.dockedPanel) return
    var kids = root.dockedItems, parents = root.dockedParents
    for (var i = 0; i < kids.length; i++) if (kids[i] && parents[i]) kids[i].parent = parents[i]
    root.dockedItems = []
    root.dockedParents = []
    root.dockedPanel = null
  }
  function closeDockedPanel() {
    var owner = root.activePopout
    if (owner && typeof owner.close === "function") owner.close()
    else if (root.dockedPanel) root.dockedPanel.open = false
    root.undockPanel()
  }
  readonly property real dockHeight: {
    // The panel's own idea of its height is the most reliable: content built up
    // front just fills the panel's frame and measures 0 on its own.
    var h = root.dockedPanel ? Math.max(0, root.dockedPanel.contentHeight) : 0
    var kids = root.dockedItems
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i]
      if (!k) continue
      var kh = (k.item !== undefined && k.sourceComponent !== undefined) ? (k.item ? k.item.implicitHeight : 0) : (k.implicitHeight || k.height)
      h = Math.max(h, kh)
    }
    return h
  }
  Timer { id: dockRetry; interval: 120; onTriggered: if (!root.dockedPanel) root.dockOpenPanel() }
  Connections {
    target: root.dockedPanel
    function onOpenChanged() { if (root.dockedPanel && !root.dockedPanel.open) root.undockPanel() }
  }

  // ---- sidebar settings (edited in the "Edit sidebar" panel) -----------------
  // Kept in ~/.config/omarchy/sidebar-settings.json; anything not set there
  // uses these defaults, which are how the sidebar looks out of the box.
  readonly property var settingsDefaults: ({
    clock: { show: true, h24: true, date: true, seconds: false, calendar: true },
    status: { show: true, indicators: true, indicatorItems: [], indicatorsAlways: false, update: true, keyboard: true, battery: true },
    system: { show: true, cpu: true, mem: true, disk: true, gpu: true, vram: false, gpuTemp: false, network: true, netGraph: true, refresh: 2 },
    workspaces: { show: true, count: 5, style: "numbers", scroll: true },
    media: { show: false, idle: true },
    notifications: { show: false, count: 4 },
    search: { show: true, clip: true },
    apps: { running: true, group: true, compact: false, indicator: "bar", icons: false, badges: true, workspace: false, hints: true, hintSymbols: true },
    bottom: { plugins: true, right: "plugins" },
    tray: { show: true, align: "right" },
    general: { background: "solid", autohide: false, autohideMode: "float", autohideEdge: "show", windowRounding: 10, windowBorder: 0, lookScope: "windows" }
  })
  readonly property string settingsPath: Quickshell.env("HOME") + "/.config/omarchy/sidebar-settings.json"
  property var userSettings: ({})
  FileView {
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { var v = JSON.parse(text()); if (v && typeof v === "object") root.userSettings = root.migrateTray(root.migrateSettings(v)) } catch (e) {} }
  }
  function setting(section, key) {
    var u = root.userSettings[section]
    if (u && u[key] !== undefined) return u[key]
    var d = root.settingsDefaults[section]
    return d ? d[key] : undefined
  }
  // While editing, changes only preview (Save writes them, Cancel drops them).
  // Settings saved by older versions: the row under the clock was part of the
  // clock section (clock.status, clock.status*); it's the "status" section now.
  function migrateSettings(v) {
    var c = v && v.clock
    if (!c || typeof c !== "object") return v
    var map = { status: "show", statusIndicators: "indicators", statusIndicatorItems: "indicatorItems", statusIndicatorsAlways: "indicatorsAlways",
                statusUpdate: "update", statusKeyboard: "keyboard", statusBattery: "battery" }
    for (var k in map) {
      if (c[k] === undefined) continue
      v.status = v.status || {}
      if (v.status[map[k]] === undefined) v.status[map[k]] = c[k]
      delete c[k]
    }
    return v
  }
  function migrateTray(v) {
    // the tray icons were part of the bottom row (bottom.tray); they're the "tray" section now
    var b = v && v.bottom
    if (b && typeof b === "object" && b.tray !== undefined) {
      v.tray = v.tray || {}
      if (v.tray.show === undefined) v.tray.show = b.tray
      delete b.tray
    }
    return v
  }
  function saveSettings(next) {
    if (root.editing) root.editHistory = root.editHistory.concat([JSON.stringify(root.userSettings)]).slice(-50)
    root.userSettings = next
    if (!root.editing) root.writeSettings()
  }
  function writeSettings() {
    Quickshell.execDetached(["bash", "-c", "printf '%s\\n' \"$1\" > \"$2\"", "sh", JSON.stringify(root.userSettings, null, 2), root.settingsPath])
  }
  // Window corners and borders (Whole sidebar › Windows): applied to Hyprland
  // as they change, previews included; hypr/look.lua reads the saved values
  // whenever Hyprland loads its config.
  // "Apply to": windows / sidebar / both. With "sidebar", windows get back what
  // your Hyprland config gives them (recorded by hypr/look.lua as it loads).
  readonly property string lookScope: String(root.setting("general", "lookScope") || "windows")
  readonly property int lookRounding: Number(root.setting("general", "windowRounding")) || 0
  readonly property int lookBorder: Number(root.setting("general", "windowBorder")) || 0
  property var windowBase: null       // [border, rounding] from your config
  FileView {
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/jake-sidebar-window-base"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { var v = String(text()).trim().split(/\s+/).map(Number); if (v.length === 2 && !isNaN(v[0]) && !isNaN(v[1])) root.windowBase = v }
  }
  readonly property string windowLook: JSON.stringify(root.lookScope === "sidebar"
    ? (root.windowBase ? [root.windowBase[1], root.windowBase[0]] : null)
    : [root.lookRounding, root.lookBorder])
  function applyWindowLook() {
    var v = JSON.parse(root.windowLook)
    if (!v) return
    Quickshell.execDetached(["hyprctl", "eval", "hl.config({ decoration = { rounding = " + v[0] + " }, general = { border_size = " + v[1] + " } })"])
  }
  onWindowLookChanged: applyWindowLook()
  // and once everything's loaded after the shell starts (a change can't be missed then)
  Timer { interval: 2500; running: true; onTriggered: root.applyWindowLook() }
  // The sidebar drawn like a window (Apply to: sidebar / both): inset by
  // Hyprland's gap, rounded, with your theme's window border colour(s).
  readonly property bool panelStyled: root.lookScope !== "windows" && (root.lookRounding > 0 || root.lookBorder > 0)
  // Hyprland's window move animation, so the sidebar sliding in/out keeps
  // pace with the windows making room (or taking it back)
  property int winAnimMs: 379
  property var winAnimCurve: [0.23, 1, 0.32, 1, 1, 1]
  Process {
    id: animProc
    command: ["hyprctl", "animations", "-j"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var d = JSON.parse(text), leaves = d[0] || [], curves = d[1] || []
          function leaf(n) { return leaves.filter(function(a) { return a.name === n })[0] }
          // windowsMove falls back to windows when it isn't set itself
          var a = leaf("windowsMove")
          if (!a || !a.overridden) a = leaf("windows")
          if (!a || !a.enabled) { root.winAnimMs = 0; return }
          root.winAnimMs = Math.round(a.speed * 100)
          var c = curves.filter(function(b) { return b.name === a.bezier })[0]
          if (c) root.winAnimCurve = [c.X0, c.Y0, c.X1, c.Y1, 1, 1]
        } catch (e) {}
      }
    }
  }
  property var themeBorder: ["#33ccff", "#00ff99"]
  property real themeBorderAngle: 45
  property int hyprGap: 10
  // the wallpaper file, for the gap left of the panel (gapCover); not a video
  property string wallPath: ""
  Process {
    id: wallProc
    command: ["bash", "-c", "readlink -f \"$HOME/.local/state/omarchy/current/background\""]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        var p = String(text).trim()
        if (/\.(mp4|webm|mkv|mov|avi|gif)$/i.test(p)) p = ""
        if (p !== root.wallPath) root.wallPath = p
      }
    }
  }
  // a new theme or background repoints the link; the theme's colours change with
  // a theme, and the timer catches a background picked on its own
  onBackgroundChanged: wallProc.running = true
  Timer { interval: 15000; running: true; repeat: true; onTriggered: wallProc.running = true }
  Process {
    id: themeProc
    command: ["bash", "-c", "hyprctl getoption general:col.active_border | head -1; hyprctl getoption general:gaps_out | head -1"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text).split("\n")
        var cols = (lines[0] || "").replace(/^[^:]*:/, "").trim().split(/\s+/)
        var out = [], angle = 0
        cols.forEach(function(c) {
          if (/^[0-9a-fA-F]{8}$/.test(c)) out.push("#" + c)
          else { var m = /^(-?\d+)deg$/.exec(c); if (m) angle = parseInt(m[1]) }
        })
        if (out.length) { root.themeBorder = out; root.themeBorderAngle = angle }
        var g = /(\d+)/.exec((lines[1] || "").replace(/^[^:]*:/, ""))
        if (g) root.hyprGap = parseInt(g[1])
      }
    }
  }
  function setSetting(section, key, value) {
    var next = JSON.parse(JSON.stringify(root.userSettings))
    if (section === "") next[key] = value
    else { next[section] = next[section] || {}; next[section][key] = value }
    root.saveSettings(next)
  }
  // A section's height: "auto" fits its content, "max" fits it up to heightPx and
  // scrolls past that, "fixed" is always heightPx tall and scrolls if the content
  // is taller. (Widget sections saved before this used "maxH" for "max".)
  function heightMode(id) {
    var m = root.setting(id, "height")
    if (m === "fixed" || m === "max" || m === "auto") return m
    return (Number(root.setting(id, "maxH")) || 0) > 0 ? "max" : "auto"
  }
  function heightPx(id) { return Number(root.setting(id, "heightPx")) || Number(root.setting(id, "maxH")) || 200 }
  function setHeight(id, mode, px) {
    var next = JSON.parse(JSON.stringify(root.userSettings))
    next[id] = next[id] || {}
    next[id].height = mode
    next[id].heightPx = Math.max(40, Math.round(px))
    delete next[id].maxH
    root.saveSettings(next)
  }
  // the height a section's box gets for its content height
  function heightFor(id, contentH) {
    var m = root.heightMode(id)
    if (m === "fixed") return root.heightPx(id)
    if (m === "max") return Math.min(contentH, root.heightPx(id))
    return contentH
  }
  function resetSection(section) {
    var next = JSON.parse(JSON.stringify(root.userSettings))
    delete next[section]
    root.saveSettings(next)
  }
  // A section hidden in the settings still shows (faded) while editing, so it can be turned back on.
  function sectionShown(section) { return root.setting(section, "show") !== false }
  function sectionOpacity(section) { return root.setting(section, "show") === false ? 0.35 : 1 }
  // a little taller when apps show a hint line under their name
  readonly property int rowH: (root.setting("apps", "compact") ? 30 : 36) + (root.setting("apps", "hints") !== false ? 4 : 0)
  // Order of the sections down the sidebar (dragged in edit mode).
  readonly property var defaultOrder: ["clock", "status", "system", "workspaces", "search", "media", "notifications", "apps", "tray", "bottom"]
  readonly property var sectionOrder: {
    var saved = Array.isArray(root.userSettings.order) ? root.userSettings.order : []
    var known = root.defaultOrder.concat(root.extraSections.map(function(e) { return e.id }))
    var out = saved.filter(function(id, i) { return known.indexOf(id) !== -1 && saved.indexOf(id) === i })
    // a section the saved order doesn't know yet (new in this version) goes
    // just before the one it comes before by default (else just after the one
    // it follows), not at the very end
    root.defaultOrder.forEach(function(id, i) {
      if (out.indexOf(id) !== -1) return
      var before = -1, after = -1
      for (var j = i + 1; j < root.defaultOrder.length && before < 0; j++) before = out.indexOf(root.defaultOrder[j])
      if (before >= 0) { out.splice(before, 0, id); return }
      for (var k = i - 1; k >= 0 && after < 0; k--) after = out.indexOf(root.defaultOrder[k])
      out.splice(after + 1, 0, id)
    })
    root.extraSections.forEach(function(e) {
      if (out.indexOf(e.id) === -1) { var at = out.indexOf("bottom"); out.splice(at < 0 ? out.length : at, 0, e.id) }
    })
    return out
  }

  // ---- edit mode ---------------------------------------------------------------
  property bool editing: false
  property string editMonitor: ""
  property string editSection: ""      // "" nothing open, "_sidebar" the whole sidebar's settings
  readonly property var editSections: [
    { id: "clock", label: "CLOCK" }, { id: "status", label: "STATUS" }, { id: "system", label: "SYSTEM" }, { id: "workspaces", label: "WORKSPACES" },
    { id: "search", label: "SEARCH" }, { id: "media", label: "MEDIA" }, { id: "notifications", label: "NOTIFICATIONS" },
    { id: "apps", label: "APP LIST" }, { id: "tray", label: "TRAY" }, { id: "bottom", label: "BOTTOM ROW" }
  ].concat(root.extraSections.map(function(e) { return { id: e.id, label: root.widgetName(root.widgetOf(e.id)).toUpperCase() } }))
  function startEditing(monitorName) {
    root.closeOverview()     // it covers the window area, where the editor opens
    root.closeQuickSettings()
    root.exitSearch()
    root.closeTrayMenu()
    root.closeDockedPanel()
    root.editMonitor = monitorName || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    root.editSnapshot = JSON.parse(JSON.stringify(root.userSettings))
    root.editHistory = []
    root.profileNaming = false
    root.editSection = ""
    root.editing = true
  }
  property var editSnapshot: ({})
  function saveEditing() { root.editing = false; root.writeSettings() }
  function cancelEditing() { root.editing = false; root.userSettings = root.editSnapshot }
  function stopEditing() { root.cancelEditing() }

  // ---- widget sections: a widget's panel, kept open as a section of its own ----
  // Saved as settings.extras = [{ id: "w:<widget id>" }]; each also has a place
  // in the section order and its own settings ({ show, title }).
  readonly property var extraSections: (Array.isArray(root.userSettings.extras) ? root.userSettings.extras : [])
    .filter(function(e) { return e && typeof e.id === "string" && e.id.indexOf("w:") === 0 })
  function widgetOf(secId) { return String(secId).indexOf("w:") === 0 ? String(secId).slice(2) : "" }
  function widgetName(wid) {
    var w = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
    var meta = w && w[wid] ? (w[wid].metadata || {}) : {}
    return String(meta.displayName || (meta.barWidget && meta.barWidget.displayName) || meta.name || wid)
  }
  // Widgets whose panel can become a section (bar-only widgets have none).
  readonly property var noPanelWidgets: ["omarchy.workspaces", "omarchy.tray", "omarchy.spacer", "omarchy.indicators", "omarchy.menu",
                                         "omarchy.keyboard-layout", "omarchy.system-update", "omarchy.active-window", "omarchy.microphone"]
  readonly property var embeddableWidgets: {
    var w = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
    if (!w) return []
    var added = root.extraSections.map(function(e) { return root.widgetOf(e.id) })
    return Object.keys(w).filter(function(id) { return w[id] && w[id].component && root.noPanelWidgets.indexOf(id) === -1 && added.indexOf(id) === -1 })
      .sort(function(a, b) { return root.widgetName(a).localeCompare(root.widgetName(b)) })
  }
  function addWidgetSection(wid) {
    var id = "w:" + wid
    var next = JSON.parse(JSON.stringify(root.userSettings))
    next.extras = (Array.isArray(next.extras) ? next.extras : []).filter(function(e) { return e.id !== id }).concat([{ id: id }])
    var order = root.sectionOrder.filter(function(x) { return x !== id })
    var at = order.indexOf("bottom")
    order.splice(at < 0 ? order.length : at, 0, id)
    next.order = order
    root.saveSettings(next)
    root.editSection = id
    root.addOpen = false
    // a plugin given a section of its own leaves the Plugins row
    if (root.allPluginEntries.some(function(e) { return e.id === wid }) && root.pluginPlaces[wid] !== "section") {
      var places = Object.assign({}, root.pluginPlaces); places[wid] = "section"; root.writePlaces(places)
    }
  }
  function removeWidgetSection(id) {
    // a plugin whose section goes away goes back to the Plugins row
    var wid = root.widgetOf(id)
    if (root.pluginPlaces[wid] === "section") { var places = Object.assign({}, root.pluginPlaces); places[wid] = "row"; root.writePlaces(places) }
    var next = JSON.parse(JSON.stringify(root.userSettings))
    next.extras = (Array.isArray(next.extras) ? next.extras : []).filter(function(e) { return e.id !== id })
    if (Array.isArray(next.order)) next.order = next.order.filter(function(x) { return x !== id })
    delete next[id]
    root.saveSettings(next)
    if (root.editSection === id) root.editSection = ""
  }
  readonly property var defaultSectionDesc: ({ tray: "Tray icons of running apps", status: "Indicators, update available, keyboard layout and battery", media: "Now playing, with play/pause, skip and seek", notifications: "Your latest notifications, and Do not disturb" })
  property bool addOpen: false
  onEditingChanged: if (!editing) addOpen = false
  function removeSection(id) {
    if (!id || id === "bottom") return
    if (String(id).indexOf("w:") === 0) root.removeWidgetSection(id)
    else root.setSetting(id, "show", false)
    if (root.editSection === id) root.editSection = ""
  }

  // The bar handed to widgets living in a section: same as the bottom row's,
  // but their panel never takes part in the one-popup-at-a-time juggling.
  QtObject {
    id: embedBar
    readonly property var shell: root.shell
    readonly property color foreground: root.foreground
    readonly property color barForeground: root.barForeground
    readonly property color background: root.background
    readonly property color urgent: root.urgent
    readonly property string fontFamily: root.fontFamily
    readonly property string position: "left"
    readonly property bool vertical: true
    readonly property int barSize: Style.bar.sizeVertical
    readonly property int sizeHorizontal: Style.bar.sizeHorizontal
    readonly property int iconSlot: Style.bar.iconSlot
    readonly property int statusSlot: Style.bar.statusSlot
    readonly property int iconSize: Style.bar.iconSize
    readonly property int iconCanvas: Style.bar.iconCanvas
    readonly property int iconFont: Style.bar.iconFont
    readonly property bool transparent: false
    readonly property bool barHidden: false
    readonly property bool foregroundAnimationEnabled: true
    readonly property bool centerSectionRevealHeld: false
    readonly property bool centerHoverRevealSuppressed: false
    readonly property bool traySectionDragActive: false
    readonly property bool traySectionPopoutOpen: false
    readonly property bool microphoneMuted: false
    readonly property bool microphoneLive: false
    readonly property bool microphoneInUse: false
    readonly property int pendingUpdates: 0
    readonly property var layoutConfig: widgetBar.layoutConfig
    readonly property var activePopout: null
    readonly property var clickTargets: []
    function barSizeFor(screenName) { return root.sidebarWidth }
    function run(command) { root.run(command) }
    function requestPopout(owner) {}
    function releasePopout(owner) {}
    function notePopoutCard(card) {}
    function popoutCardFor(owner) { return null }
    function switchPanelFrom(owner, direction) { return false }
    function moduleWidgets(id) { return [] }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
    function targetBelongsToWindow(target, window) { return false }
    function setCenterHoverRevealSuppressed(value) {}
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
  }

  // The "Add section" picker: searchable, grouped (hidden sections / Omarchy / plugins).
  property string addQuery: ""
  property int addIndex: 0
  onAddOpenChanged: { addQuery = ""; addIndex = 0 }
  onAddQueryChanged: addIndex = 0
  readonly property var addRows: {
    var q = root.addQuery.toLowerCase().trim()
    var terms = q ? q.split(/\s+/) : []
    function match(text) { text = String(text).toLowerCase(); return terms.every(function(t) { return text.indexOf(t) >= 0 }) }
    // built-in sections that are off (widget sections that are off go with their kind below)
    var hidden = root.editSections.filter(function(e) { return e.id.indexOf("w:") !== 0 && root.setting(e.id, "show") === false })
      .map(function(e) { return { kind: "hidden", id: e.id, name: e.label.charAt(0) + e.label.slice(1).toLowerCase(), desc: root.defaultSectionDesc[e.id] || "Not in the sidebar — add it", cat: "Section" } })
    var w = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : {}
    var omarchy = [], plugins = []
    root.embeddableWidgets.forEach(function(id) {
      var meta = w[id] && w[id].metadata ? w[id].metadata : {}
      var row = { kind: "widget", id: id, name: root.widgetName(id), desc: String(meta.description || (meta.barWidget && meta.barWidget.description) || ""),
                  cat: String(meta.category || (meta.barWidget && meta.barWidget.category) || "") }
      ;(meta.firstParty ? omarchy : plugins).push(row)
    })
    // widget sections already added but hidden: show them again, filed by kind
    root.extraSections.forEach(function(e) {
      if (root.setting(e.id, "show") !== false) return
      var wid = root.widgetOf(e.id)
      var meta = w[wid] && w[wid].metadata ? w[wid].metadata : {}
      var row = { kind: "hidden", id: e.id, name: root.widgetName(wid), desc: "Hidden — show it again", cat: String(meta.category || "") }
      ;(meta.firstParty ? omarchy : plugins).push(row)
    })
    omarchy.sort(function(a, b) { return a.name.localeCompare(b.name) })
    plugins.sort(function(a, b) { return a.name.localeCompare(b.name) })
    var out = []
    function group(title, rows) {
      rows = rows.filter(function(r) { return match(r.name + " " + r.desc + " " + r.cat + " " + r.id) })
      if (rows.length === 0) return
      out.push({ kind: "header", name: title + " · " + rows.length })
      rows.forEach(function(r) { out.push(r) })
    }
    group("SECTIONS", hidden)
    group("OMARCHY", omarchy)
    group("PLUGINS", plugins)
    return out
  }
  readonly property var addPickable: root.addRows.filter(function(r) { return r.kind !== "header" })
  function addPick(row) {
    if (!row) return
    if (row.kind === "hidden") { root.setSetting(row.id, "show", true); root.editSection = row.id; root.addOpen = false }
    else if (row.kind === "widget") root.addWidgetSection(row.id)
  }

  // ---- media (MPRIS) -----------------------------------------------------------
  readonly property var mediaPlayer: {
    var ps = Mpris.players ? Mpris.players.values : []
    for (var i = 0; i < ps.length; i++) if (ps[i].isPlaying) return ps[i]
    return ps.length > 0 ? ps[0] : null
  }
  // MPRIS doesn't push the position; nudge it while something plays
  Timer {
    interval: 1000
    repeat: true
    running: !!root.mediaPlayer && root.mediaPlayer.isPlaying && root.setting("media", "show") !== false
    onTriggered: if (root.mediaPlayer) root.mediaPlayer.positionChanged()
  }
  function fmtTime(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    return Math.floor(sec / 60) + ":" + ("0" + (sec % 60)).slice(-2)
  }

  // ---- notifications (Omarchy keeps the history in a file) ----------------------
  property var notifHistory: []
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { var v = JSON.parse(text()); if (Array.isArray(v)) root.notifHistory = v } catch (e) {} }
  }
  function agoText(ts) {
    var s = Math.max(0, Date.now() / 1000 - Number(ts || 0))
    if (s < 60) return "now"
    if (s < 3600) return Math.floor(s / 60) + "m"
    if (s < 86400) return Math.floor(s / 3600) + "h"
    return Math.floor(s / 86400) + "d"
  }
  property int agoTick: 0
  Timer { interval: 60000; repeat: true; running: true; onTriggered: root.agoTick++ }

  // ---- app list extras -------------------------------------------------------------
  // Unread count an app shows in its window title, like "(6) Discord".
  // A hint of what an app is showing, from its window title: the page in a
  // browser, the folder in a terminal, the file in an editor. The unread count
  // ("(6) ") and the app's own name ("... — Mozilla Firefox") are left off, and
  // nothing is shown when what's left is just the app's name.
  function hintOf(item) {
    var wins = item && item.windows ? item.windows : []
    if (!wins.length) return ""
    var t = null
    for (var i = 0; i < wins.length && !t; i++) if (wins[i].activated) t = wins[i]
    for (var j = 0; j < wins.length && !t; j++) if (!root.isMinimized(wins[j])) t = wins[j]
    var title = String((t || wins[0]).title || "").replace(/^\s*\(\d+\)\s*/, "").trim()
    // Status symbols some apps put in front of their title (a spinner while an
    // agent works, a dot for unsaved changes, an emoji): left off when the
    // "Status symbols in hints" setting is off.
    if (root.setting("apps", "hintSymbols") === false)
      title = title.replace(/^(?:[\u00B7\u2022*\u2190-\u21FF\u2300-\u23FF\u2500-\u27BF\u2800-\u28FF\u2B00-\u2BFF\uFE0F]|[\uD83C-\uD83E][\uDC00-\uDFFF])+\s*/, "").trim()
    var name = root.displayName(item).toLowerCase()
    var key = String(item.key || "").split(".").pop().toLowerCase()
    // the last " - ", " – ", " — " or " | " part, if it names the app
    var m = /^(.*\S)\s+[-\u2013\u2014|]\s+(.+)$/.exec(title)
    if (m) {
      var last = m[2].toLowerCase()
      if (last.indexOf(name) >= 0 || (last.length >= 3 && name.indexOf(last) >= 0) || (key && last.indexOf(key) >= 0)) title = m[1]
    }
    var low = title.toLowerCase()
    // just the app's name ("Mozilla Firefox" on a new tab): nothing to hint at
    if (!title || low === name || low === key || (key && low.slice(-key.length - 1) === " " + key)) return ""
    return title
  }
  function badgeOf(item) {
    var wins = item && item.windows ? item.windows : []
    var n = 0
    for (var i = 0; i < wins.length; i++) {
      var m = /^\s*\((\d+)\)/.exec(String(wins[i].title || ""))
      if (m) n = Math.max(n, parseInt(m[1]))
    }
    return n
  }
  // App icons (only scanned while the option is on)
  property var iconIndex: ({})
  property var _pendingIcons: ({})
  function iconFor(icon) {
    var v = String(icon || "")
    if (v.indexOf("file://") === 0 || v.indexOf("image://") === 0) return v
    if (v.charAt(0) === "/") return "file://" + v
    var found = v ? root.iconIndex[v] : null
    if (found) return "file://" + found
    var themed = v ? Quickshell.iconPath(v, true) : ""
    if (themed.length > 0) return themed
    var fb = root.iconIndex["application-x-executable"]
    return fb ? "file://" + fb : ""
  }
  Process {
    id: iconScan
    running: root.setting("apps", "icons") === true
    command: ["bash", "-c",
      'dirs="$HOME/.icons $HOME/.local/share/icons"; IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS; ' +
      '{ for base in $dirs; do [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null; done; ' +
      'find /usr/share/pixmaps -maxdepth 1 \\( -name "*.svg" -o -name "*.png" \\) 2>/dev/null; } ' +
      "| awk '/\\.svg$/ { print; next } { png[++n] = $0 } END { for (i = 1; i <= n; i++) print png[i] }'"]
    onStarted: root._pendingIcons = ({})
    stdout: SplitParser {
      onRead: function(line) {
        var v = String(line || "").trim(), file = v.slice(v.lastIndexOf("/") + 1), dot = file.lastIndexOf(".")
        var name = dot > 0 ? file.slice(0, dot) : file
        if (name && root._pendingIcons[name] === undefined) root._pendingIcons[name] = v
      }
    }
    onExited: root.iconIndex = root._pendingIcons
  }

  // Expanded window lists, remembered across restarts.
  readonly property string statePath: Quickshell.env("HOME") + "/.config/omarchy/sidebar-state.json"
  FileView {
    path: root.statePath
    printErrors: false
    onLoaded: { try { var v = JSON.parse(text()); if (v && v.expanded) root.expandedApps = v.expanded } catch (e) {} }
  }
  function writeState() {
    Quickshell.execDetached(["bash", "-c", "printf '%s\\n' \"$1\" > \"$2\"", "sh", JSON.stringify({ expanded: root.expandedApps }), root.statePath])
  }

  // Super+Alt+1..9: the pinned apps, in order.
  function launchPinned(n) {
    var rows = root.appItems("").filter(function(r) { return r.pinned })
    var row = rows[n - 1]
    if (row) root.activateApp(row, false)
  }
  // Move an app's showing windows to a workspace (dropping it on a workspace number).
  function moveToWorkspace(item, ws) {
    var wins = (item.windows || []).filter(function(t) { return !root.isMinimized(t) })
    if (wins.length === 0) wins = item.windows || []
    var steps = wins.map(function(t) {
      return "hyprctl dispatch " + Util.shellQuote("hl.dsp.window.move({ workspace = \"" + ws + "\", follow = false, " + root.windowTarget(t) + " })")
        + " >/dev/null; [[ $layout == floating ]] || hyprctl dispatch " + Util.shellQuote("hl.dsp.window.float({ action = \"off\", " + root.windowTarget(t) + " })") + " >/dev/null"
    })
    // windows dropped on an Omarchy floating workspace stay floating
    if (steps.length) root.run("layout=$(omarchy-hyprland-workspace-layout-current " + Number(ws) + " 2>/dev/null); " + steps.join("; "))
  }

  // ---- editor history, reset, profiles ---------------------------------------------
  property var editHistory: []
  // The open section's own Cancel / Save: Cancel puts back what it was when the
  // section was opened, Save keeps the changes; both close it. (Nothing is written
  // to disk until the editor's own Save.)
  property string formSnapshot: ""
  onEditSectionChanged: root.formSnapshot = root.editSection !== "" ? JSON.stringify(root.userSettings) : ""
  function closeForm(keep) {
    if (!keep && root.formSnapshot !== "" && JSON.stringify(root.userSettings) !== root.formSnapshot)
      root.saveSettings(JSON.parse(root.formSnapshot))
    root.editSection = ""
  }
  readonly property string editSectionLabel: {
    if (root.editSection === "_sidebar") return "WHOLE SIDEBAR"
    var e = root.editSections.filter(function(x) { return x.id === root.editSection })[0]
    return e ? e.label + (root.editSection.indexOf("w:") === 0 ? " · WIDGET" : "") : ""
  }
  function undoEdit() {
    if (root.editHistory.length === 0) return
    var prev = root.editHistory[root.editHistory.length - 1]
    root.editHistory = root.editHistory.slice(0, -1)
    root.userSettings = JSON.parse(prev)
  }
  function resetAll() { root.saveSettings({}) }
  readonly property string profilesPath: Quickshell.env("HOME") + "/.config/omarchy/sidebar-profiles.json"
  property var profiles: ({})
  property bool profileNaming: false
  FileView {
    path: root.profilesPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { var v = JSON.parse(text()); if (v && typeof v === "object") root.profiles = v } catch (e) {} }
  }
  function writeProfiles(next) {
    root.profiles = next
    Quickshell.execDetached(["bash", "-c", "printf '%s\\n' \"$1\" > \"$2\"", "sh", JSON.stringify(next, null, 2), root.profilesPath])
  }
  function saveProfile(name) {
    name = String(name || "").trim()
    if (!name) return
    var next = Object.assign({}, root.profiles)
    next[name] = JSON.parse(JSON.stringify(root.userSettings))
    root.writeProfiles(next)
  }
  function loadProfile(name) { if (root.profiles[name]) root.saveSettings(root.migrateTray(root.migrateSettings(JSON.parse(JSON.stringify(root.profiles[name]))))) }
  function deleteProfile(name) { var next = Object.assign({}, root.profiles); delete next[name]; root.writeProfiles(next) }
  // Width while the edge is being dragged (saved on release).
  property int liveWidth: 0

  // Default output volume
  readonly property var sink: Pipewire.defaultAudioSink
  PwObjectTracker { objects: root.sink ? [root.sink] : [] }

  // ---- shared tooltip -----------------------------------------------------
  QtObject {
    id: tooltip
    property var target: null
    property string text: ""
    function show(t, s) { target = t; text = String(s || "") }
    function hide(t) { if (!t || t === target) { target = null; text = "" } }
  }

  // ---- one sidebar per screen --------------------------------------------
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      readonly property var monitor: Hyprland.monitorFor(modelData)
      readonly property string monitorName: monitor ? monitor.name : ""

      WlrLayershell.namespace: "omarchy-bar"
      // A fullscreen window (a game) covers the Top layer, so while the sidebar
      // is in use over one (overview, search, settings, editor) lift it to Overlay.
      readonly property bool fsHere: !!(monitor && monitor.activeWorkspace && monitor.activeWorkspace.hasFullscreen)
      readonly property bool lifted: fsHere && win.keepOpen && win.dragItem === null
      onFsHereChanged: if (fsHere && !root.overviewOpen) {
        if (root.searching && root.searchMonitor === win.monitorName) root.exitSearch("fullscreen")
        if (win.qsHere) root.qsOpen = false
        if (win.trayHere) root.closeTrayMenu()
      }
      WlrLayershell.layer: win.lifted ? WlrLayer.Overlay : WlrLayer.Top
      WlrLayershell.keyboardFocus: (root.searching && root.searchMonitor === win.monitorName) || (win.qsHere && (root.pwSsid !== "" || root.qsTyping !== ""))
                                   || (win.editHere && (root.addOpen || root.profileNaming))
        ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      anchors { top: true; bottom: true; left: true }
      implicitWidth: root.sidebarWidth
      // auto-hide "push": windows make room while it's out; "float": it goes over them
      // (a fullscreen app keeps the whole screen: the sidebar goes over it)
      readonly property bool pushWhenShown: root.setting("general", "autohideMode") === "push" && !root.barHidden && !win.fsHere
      exclusionMode: win.autoHide && !win.pushWhenShown ? ExclusionMode.Ignore : ExclusionMode.Normal
      exclusiveZone: !win.autoHide ? root.sidebarWidth : (win.pushWhenShown && !win.tucked ? root.sidebarWidth : 0)
      // Over a fullscreen window the sidebar slides in with the overview as it opens.
      // On close it waits: the previews zoom back first, and only once the overview is
      // gone does the sidebar slide out (fsOut), so nothing moves at the same time.
      readonly property bool fsAlone: win.fsHere && !(root.searching && root.searchMonitor === win.monitorName)
                                      && !win.qsHere && !win.trayHere && !win.editHere
      property real fsOut: 0
      property bool fsLeaving: false
      NumberAnimation {
        id: fsOutAnim
        target: win; property: "fsOut"; from: 0; to: 1
        duration: Style.duration(220); easing.type: Easing.InCubic
        onFinished: { win.fsLeaving = false; win.fsOut = 0 }
      }
      onOverviewHereChanged: {
        if (!win.overviewHere && win.fsAlone) { win.fsLeaving = true; fsOutAnim.restart() }
        else if (win.overviewHere && fsOutAnim.running) { fsOutAnim.stop(); win.fsLeaving = false; win.fsOut = 0 }
      }
      readonly property real fsSlide: !win.fsAlone ? 0
                                      : win.fsLeaving ? win.fsOut
                                      : win.overviewHere && root.overviewOpen ? 1 - root.ovProgress : 0
      // 0 = out, 1 = tucked away; animated like Hyprland moves windows
      property real tuckAmount: win.tucked ? 1 : 0
      Behavior on tuckAmount { NumberAnimation { duration: root.winAnimMs; easing.type: Easing.Bezier; easing.bezierCurve: root.winAnimCurve } }
      margins.left: win.fsSlide > 0 ? -Math.round(root.sidebarWidth * win.fsSlide) : -Math.round((root.sidebarWidth - 4) * win.tuckAmount)
      readonly property color panelColor: Qt.rgba(root.background.r, root.background.g, root.background.b, root.setting("general", "background") === "glass" ? 0.8 : 1)
      // tucked away with the edge hidden: the 4px strip stays (to hover) but shows nothing
      readonly property bool edgeHidden: win.tucked && win.tuckAmount > 0.999 && root.setting("general", "autohideEdge") === "hide"
      color: root.panelStyled || win.edgeHidden ? "transparent" : panelColor
      Binding { target: win.contentItem; property: "opacity"; value: win.edgeHidden ? 0 : 1 }
      // drawn like a window: inset by Hyprland's gap (top, left, bottom), rounded, bordered
      readonly property int panelInset: root.panelStyled ? root.hyprGap : 0
      readonly property int panelBorderW: root.panelStyled ? root.lookBorder : 0
      readonly property real panelInnerX: panelInset + panelBorderW
      readonly property real panelInnerW: width - panelInset - 2 * panelBorderW
      // The gap left of the panel shows the wallpaper. A window sliding out to the
      // left is far wider than the panel, so its body would show through that gap
      // on the way out; the wallpaper is drawn there too (laid out like Omarchy's
      // background: the whole screen, cropped to cover), so the gap looks the same
      // but windows pass behind it.
      Item {
        id: gapCover
        visible: root.panelStyled && win.panelInset > 0 && root.wallPath !== "" && !win.edgeHidden
        z: -11
        x: 0; y: 0
        // over a fullscreen app the whole strip gets the wallpaper (the gaps above
        // and below the panel and its rounded corners), not just the left gap
        width: win.fsHere ? win.width : win.panelInset
        height: win.height
        clip: true
        Image {
          x: -win.margins.left
          y: 0
          width: win.screen ? win.screen.width : 0
          height: win.screen ? win.screen.height : 0
          source: root.wallPath === "" ? "" : "file://" + root.wallPath
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: width
          sourceSize.height: height
          asynchronous: true
          cache: false
          smooth: true
        }
      }
      Rectangle {
        id: panelFrame
        visible: root.panelStyled
        z: -10
        x: win.panelInset; y: win.panelInset
        width: win.width - win.panelInset
        height: win.height - 2 * win.panelInset
        radius: root.lookRounding
        // the border: the theme's colour, or its gradient
        gradient: root.themeBorder.length > 1 && win.panelBorderW > 0 ? borderGrad : null
        color: win.panelBorderW > 0 ? root.themeBorder[0] : win.panelColor
        Gradient {
          id: borderGrad
          orientation: Math.abs(root.themeBorderAngle % 180) < 45 || Math.abs(root.themeBorderAngle % 180) > 135 ? Gradient.Horizontal : Gradient.Vertical
          GradientStop { position: 0; color: root.themeBorder[0] }
          GradientStop { position: 1; color: root.themeBorder[root.themeBorder.length - 1] }
        }
        Rectangle {
          visible: win.panelBorderW > 0
          anchors.fill: parent
          anchors.margins: win.panelBorderW
          radius: Math.max(0, root.lookRounding - win.panelBorderW)
          color: win.panelColor
        }
      }

      // -- auto-hide: tucked away off the left edge until the pointer touches it --
      // Only the setting tucks the panel; the `omarchy toggle bar` flag used to
      // force this too, so a stale bar-off flag made the panel auto-hide while
      // auto-hide was off.
      readonly property bool autoHide: root.setting("general", "autohide") === true
      readonly property bool keepOpen: (root.searching && root.searchMonitor === win.monitorName) || win.qsHere || win.trayHere
        || root.dockedPanel !== null || win.editHere || win.menuItem !== null || win.dragItem !== null || win.overviewHere || win.fsLeaving
      property bool revealed: false
      readonly property bool tucked: autoHide && !revealed && !keepOpen
      HoverHandler {
        id: sideHover
        onHoveredChanged: { if (hovered) { hideTimer.stop(); win.revealed = true } else hideTimer.restart() }
      }
      Timer { id: hideTimer; interval: 600; onTriggered: if (!sideHover.hovered) win.revealed = false }
      onKeepOpenChanged: if (!keepOpen && !sideHover.hovered) hideTimer.restart()

      // -- drag the sidebar's right edge to resize it ----------------------------------
      MouseArea {
        z: 70
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: 5
        cursorShape: Qt.SizeHorCursor
        hoverEnabled: true
        preventStealing: true
        property bool resizing: false
        onPressed: resizing = true
        onPositionChanged: function(m) {
          if (!resizing) return
          var p = mapToItem(win.contentItem, m.x, m.y)
          root.liveWidth = Math.max(220, Math.min(400, Math.round(p.x / 10) * 10))
        }
        onReleased: {
          resizing = false
          if (root.liveWidth > 0) { var w = root.liveWidth; root.setSetting("", "width", w); root.liveWidth = 0 }
        }
      }

      // Tooltip for hosted widgets and tray icons.
      PopupWindow {
        visible: tooltip.target !== null && tooltip.text !== "" && tooltip.target.QsWindow && tooltip.target.QsWindow.window === win
        anchor.item: visible ? tooltip.target : null
        anchor.edges: Edges.Top
        anchor.gravity: Edges.Top
        implicitWidth: tipText.implicitWidth + 16
        implicitHeight: tipText.implicitHeight + 10
        color: "transparent"
        Rectangle {
          anchors.fill: parent
          radius: 4
          color: root.background
          border.color: root.faint
          Text {
            id: tipText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: tooltip.text
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: 11
          }
        }
      }

      // -- drag an app out of the sidebar ------------------------------------------
      property var dragItem: null
      property real dragX: 0          // pointer, in this screen's coordinates
      property real dragY: 0
      property var dragRects: []      // tiled windows on the active workspace
      readonly property var dropRect: {
        var r = win.dragRects, x = win.dragX + win.screen.x, y = win.dragY + win.screen.y
        for (var i = 0; i < r.length; i++)
          if (x >= r[i].x && x < r[i].x + r[i].w && y >= r[i].y && y < r[i].y + r[i].h) {
            var left = x < r[i].x + r[i].w / 2
            return { x: (left ? r[i].x : r[i].x + r[i].w / 2) - win.screen.x, y: r[i].y - win.screen.y, w: r[i].w / 2, h: r[i].h }
          }
        return null
      }
      readonly property bool dragOverSidebar: win.dragX < root.sidebarWidth
      function beginDrag(item) {
        win.dragItem = item
        win.dragRects = []
        dragRectsProc.running = true
      }
      // Where in the app list a drag over the sidebar would land: { index, y }
      // (index counts rows; y is the insertion line in the list's own coordinates).
      property var listDrop: null
      function listDropAt(x, y) {
        if (x >= root.sidebarWidth || !appList.visible) return null
        var p = appList.mapFromItem(win.contentItem, x, y)
        if (p.y < -12 || p.y > appList.height + 12) return null
        var rows = appList.model || []
        var cy = p.y + appList.contentY
        var index = rows.length, lineY = appList.contentHeight
        for (var i = 0; i < rows.length; i++) {
          var it = appList.itemAtIndex(i)
          if (!it) continue
          if (rows[i].separator) { if (cy < it.y + it.height) { index = i; lineY = it.y; break } else continue }
          if (cy < it.y + Math.min(it.height, 36) / 2) { index = i; lineY = it.y - 1; break }
        }
        // rows before the separator are the pinned ones; the separator itself counts as "end of pinned"
        var pinnedCount = rows.filter(function(r) { return r.pinned }).length
        var listIndex = index <= pinnedCount ? index : pinnedCount + 1 + (index - pinnedCount)
        return { index: listIndex, y: lineY }
      }
      // The app row (and window row, if expanded) under a point in the list.
      function hoveredAt(x, y) {
        if (x >= root.sidebarWidth || !appList.visible) return null
        var p = appList.mapFromItem(win.contentItem, x, y)
        if (p.y < 0 || p.y > appList.height) return null
        var cy = p.y + appList.contentY
        var i = appList.indexAt(20, cy)
        var it = i >= 0 ? appList.itemAtIndex(i) : null
        var row = i >= 0 ? (appList.model || [])[i] : null
        if (!row || !it || row.separator) return null
        var local = cy - it.y
        if (local < 36) return { row: row, window: null, index: i, itemY: it.y }
        var k = Math.floor((local - 38) / 30)
        var wins = row.windows || []
        if (!it.expanded || k < 0 || k >= wins.length) return { row: row, window: null, index: i, itemY: it.y }
        return { row: row, window: wins[k], sub: k, index: i, itemY: it.y, subY: it.y + 38 + k * 30 }
      }
      // Spring-loading: hold a drag over another app (or one of its windows) to open it.
      property string springKey: ""
      property var springHit: null
      property string springDone: ""
      Timer {
        id: springTimer
        interval: 650
        onTriggered: {
          var h = win.springHit
          if (!h || !win.dragItem) return
          win.springDone = win.springKey
          if (h.window) {
            if (!(h.window.activated && !root.isMinimized(h.window))) root.activateWindow(h.window, false)
          } else {
            var front = (h.row.windows || []).some(function(t) { return t.activated && !root.isMinimized(t) })
            if (!front) root.activateApp(h.row, false)
          }
        }
      }
      function trackSpring(x, y) {
        var h = win.dragItem ? win.hoveredAt(x, y) : null
        var key = ""
        if (h) {
          key = h.window ? "w:" + root.addrOf(h.window) : "a:" + h.row.key
          // not the thing being dragged
          if (win.dragItem.windowOnly ? (h.window && root.addrOf(h.window) === root.addrOf(win.dragItem.windows[0])) || (!h.window && h.row.key === win.dragItem.key)
                                      : h.row.key === win.dragItem.key) key = ""
        }
        if (key !== win.springKey) {
          win.springKey = key
          win.springHit = key ? h : null
          if (key && key !== win.springDone) springTimer.restart(); else springTimer.stop()
        }
      }
      // A dragged window over its own app's window list: where it would go.
      function windowDropAt(x, y) {
        var item = win.dragItem
        if (!item || !item.windowOnly) return null
        var h = win.hoveredAt(x, y)
        if (!h || h.row.key !== item.key || !h.window) return null
        var p = appList.mapFromItem(win.contentItem, x, y)
        var cy = p.y + appList.contentY
        var after = cy > h.subY + 15
        return { index: h.sub + (after ? 1 : 0), y: h.subY + (after ? 30 : 0) - 1, row: h.row }
      }
      // a workspace number under the pointer while dragging (to move the app there)
      property int dragWs: -1
      // the workspace chips to show (the section and the bottom row share them):
      // the first "count", plus any other workspace in use on this monitor
      readonly property var wsIds: {
        var ids = []
        for (var n = 1; n <= root.setting("workspaces", "count"); n++) ids.push(n)
        var all = Hyprland.workspaces.values
        for (var i = 0; i < all.length; i++) {
          var ws = all[i]
          if (ws.id > 0 && ws.monitor && ws.monitor.name === win.monitorName && ids.indexOf(ws.id) === -1) ids.push(ws.id)
        }
        return ids.sort(function(a, b) { return a - b })
      }
      function focusWs(n) { root.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + n + "\" })")) }
      function wsScroll(e) {
        var cur = win.monitor && win.monitor.activeWorkspace ? win.monitor.activeWorkspace.id : 1
        var next = e.angleDelta.y < 0 ? cur + 1 : cur - 1
        if (next >= 1) win.focusWs(next)
      }
      function wsAt(x, y) {
        var rows = [secWs, bottomWs]
        for (var i = 0; i < rows.length; i++) {
          var r = rows[i]
          if (!r.visible) continue
          var p = r.mapFromItem(win.contentItem, x, y)
          var c = r.childAt(p.x, p.y)
          if (c && c.modelData !== undefined && typeof c.modelData === "number") return c.modelData
        }
        return -1
      }
      function updateDrag(x, y) {
        win.dragX = x; win.dragY = y
        win.dragWs = win.dragItem ? win.wsAt(x, y) : -1
        if (!win.dragItem) { win.listDrop = null; return }
        win.listDrop = win.dragItem.windowOnly ? win.windowDropAt(x, y) : win.listDropAt(x, y)
        win.trackSpring(x, y)
      }
      function endDrag(x, y) {
        var item = win.dragItem
        var target = item && item.windowOnly ? win.windowDropAt(x, y) : win.listDropAt(x, y)
        win.dragItem = null
        win.listDrop = null
        springTimer.stop(); win.springKey = ""; win.springHit = null; win.springDone = ""
        var ws = win.wsAt(x, y)
        win.dragWs = -1
        if (!item) return
        if (ws > 0 && (item.windows || []).length > 0) { root.moveToWorkspace(item, ws); return }
        if (x >= root.sidebarWidth) root.dropApp(item, x + win.screen.x, y + win.screen.y)
        else if (target && item.windowOnly) root.moveWindowTo(item.key, target.row.windows, item.windows[0], target.index)
        else if (target) root.dropOnList(item, target.index)
      }
      Process {
        id: dragRectsProc
        command: ["sh", "-c", "ws=$(hyprctl activeworkspace -j | jq .id); hyprctl clients -j | jq -c --argjson ws \"$ws\" '[.[] | select(.workspace.id == $ws and (.floating | not)) | {x: .at[0], y: .at[1], w: .size[0], h: .size[1], a: .address}]'"]
        stdout: StdioCollector {
          onStreamFinished: {
            try {
              var r = JSON.parse(text)
              var self = win.dragItem ? (win.dragItem.windows || []).map(function(t) { var a = String(t.address || ""); return a.indexOf("0x") === 0 ? a : "0x" + a }) : []
              win.dragRects = r.filter(function(w) { return self.indexOf(w.a) === -1 })
            } catch (e) { win.dragRects = [] }
          }
        }
      }
      // Drop preview: never takes input, so the drag stays with the sidebar.
      PanelWindow {
        screen: win.screen
        visible: win.dragItem !== null
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "jake-sidebar-drop"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}
        Rectangle {
          visible: !win.dragOverSidebar
          x: win.dropRect ? win.dropRect.x : root.sidebarWidth + 12
          y: win.dropRect ? win.dropRect.y : 12
          width: win.dropRect ? win.dropRect.w : parent.width - root.sidebarWidth - 24
          height: win.dropRect ? win.dropRect.h : parent.height - 24
          radius: 6
          color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.18)
          border.width: 2
          border.color: root.urgent
          Behavior on x { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
          Behavior on width { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
        }
        Rectangle {
          x: win.dragX + 14
          y: win.dragY + 10
          width: dragLabel.implicitWidth + 16
          height: dragLabel.implicitHeight + 8
          radius: 4
          color: root.background
          border.width: 1
          border.color: root.faint
          Text {
            id: dragLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: win.dragItem ? (win.dragItem.label || root.displayName(win.dragItem)) : ""
            color: root.foreground
            font.family: root.fontFamily; font.pixelSize: 12
          }
        }
      }

      // While searching, the rest of the screen catches one click to close it.
      PanelWindow {
        screen: win.screen
        visible: root.searching && root.searchMonitor === win.monitorName
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        margins.left: root.sidebarWidth
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: win.lifted ? WlrLayer.Overlay : WlrLayer.Top
        WlrLayershell.namespace: "jake-sidebar-search-dismiss"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.exitSearch("outside")
        }
      }

      readonly property bool qsHere: root.qsOpen && root.qsMonitor === win.monitorName

      // -- tray icon menu (drawn by the sidebar; native menus aren't available) --
      readonly property bool trayHere: root.trayMenuItem !== null && root.trayMenuMonitor === win.monitorName
      QsMenuOpener { id: trayRootOpener; menu: win.trayHere && root.trayMenuItem ? root.trayMenuItem.menu : null }
      QsMenuOpener { id: traySubOpener; menu: win.trayHere ? root.trayMenuSub : null }
      readonly property var trayEntries: {
        var model = root.trayMenuSub ? traySubOpener.children : trayRootOpener.children
        return model ? model.values : []
      }

      // -- overview (Super): every open window, zoomed out over the window area --
      // Each preview starts exactly over its real window (minimized ones just off
      // the left edge) and shrinks into the grid as the backdrop fades to opaque,
      // so the windows look like they zoom out into it; closing reverses it.
      readonly property bool overviewHere: root.overviewMonitor === win.monitorName && (root.overviewOpen || root.ovProgress > 0)
      PanelWindow {
        id: overviewWin
        screen: win.screen
        visible: win.overviewHere
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        readonly property int inset: root.sidebarWidth   // the sidebar is left alone
        margins.left: inset
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "jake-sidebar-overview"
        WlrLayershell.keyboardFocus: win.overviewHere && root.overviewOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None   // on-demand, not exclusive: exclusive also blocks the pointer from the sidebar

        readonly property real p: root.ovProgress
        // dragging one preview onto another
        property string dragAddr: ""
        property real dragX: 0
        property real dragY: 0
        property int dropIndex: -1
        property string dropSide: ""
        // type to search, a workspace filter, and a keyboard selection
        property string query: ""
        property int wsFilter: 0           // 0 = all workspaces
        property int sel: 0
        readonly property var allWins: win.overviewHere ? root.overviewWindows() : []
        readonly property var wsList: {
          var ids = []
          allWins.forEach(function(t) { if (t.workspace && t.workspace.id > 0 && ids.indexOf(t.workspace.id) === -1) ids.push(t.workspace.id) })
          return ids.sort(function(a, b) { return a - b })
        }
        readonly property var wins: allWins.filter(function(t) {
          if (overviewWin.wsFilter > 0 && !(t.workspace && t.workspace.id === overviewWin.wsFilter)) return false
          var q = overviewWin.query.toLowerCase().trim()
          if (!q) return true
          var hay = (String(t.title || "") + " " + root.overviewAppName(t)).toLowerCase()
          return q.split(/\s+/).every(function(w) { return hay.indexOf(w) >= 0 })
        })
        readonly property int count: wins.length
        readonly property int cols: Math.max(1, Math.ceil(Math.sqrt(count)))
        readonly property int rowsN: Math.max(1, Math.ceil(count / cols))
        onQueryChanged: sel = 0
        onWsFilterChanged: sel = 0
        onVisibleChanged: if (visible) { query = ""; wsFilter = 0; sel = 0 }
        function pickSelected() {
          var t = overviewWin.wins[overviewWin.sel]
          if (!t) return
          root.closeOverview()
          if (!(t.activated && !root.isMinimized(t))) root.activateWindow(t, root.shiftHeld)
        }
        readonly property real pad: 48
        readonly property real topPad: 64     // room for the search line and workspace strip
        readonly property real gap: 28
        readonly property real cellW: (width - pad * 2 - gap * (cols - 1)) / cols
        readonly property real cellH: (height - pad - topPad - gap * (rowsN - 1)) / rowsN
        function lerp(a, b) { return a + (b - a) * overviewWin.p }

        // jake.sidebar: the wallpaper behind the previews, so the overview looks
        // the same over a fullscreen app as over the desktop
        Image {
          visible: root.wallPath !== ""
          x: -overviewWin.inset
          width: overviewWin.screen ? overviewWin.screen.width : 0
          height: overviewWin.screen ? overviewWin.screen.height : 0
          source: root.wallPath === "" ? "" : "file://" + root.wallPath
          fillMode: Image.PreserveAspectCrop
          sourceSize.width: width
          sourceSize.height: height
          asynchronous: true
          opacity: overviewWin.p
        }
        Rectangle {
          anchors.fill: parent
          // a light tint over the wallpaper keeps the text readable; opaque without one
          color: Qt.rgba(root.background.r, root.background.g, root.background.b, root.wallPath !== "" ? 0.35 : 1)
          opacity: overviewWin.p
          focus: true
          Keys.onPressed: function(event) {
            var n = overviewWin.count, c = overviewWin.cols
            if (event.key === Qt.Key_Escape) { if (overviewWin.query) overviewWin.query = ""; else root.closeOverview() }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) overviewWin.pickSelected()
            else if (event.key === Qt.Key_Right) overviewWin.sel = n ? (overviewWin.sel + 1) % n : 0
            else if (event.key === Qt.Key_Left) overviewWin.sel = n ? (overviewWin.sel - 1 + n) % n : 0
            else if (event.key === Qt.Key_Down) overviewWin.sel = Math.min(n - 1, overviewWin.sel + c)
            else if (event.key === Qt.Key_Up) overviewWin.sel = Math.max(0, overviewWin.sel - c)
            else if (event.key === Qt.Key_Tab) {
              var list = [0].concat(overviewWin.wsList), at = list.indexOf(overviewWin.wsFilter)
              overviewWin.wsFilter = list[(at + 1) % list.length]
            }
            else if (event.key === Qt.Key_Backspace) overviewWin.query = overviewWin.query.slice(0, -1)
            else if (event.text && event.text.length === 1 && event.text >= " ") overviewWin.query += event.text
            else return
            event.accepted = true
          }
          MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; enabled: root.overviewOpen; onClicked: root.closeOverview() }
        }

        // search line + workspace strip
        RowLayout {
          x: overviewWin.pad
          width: overviewWin.width - overviewWin.pad * 2
          y: 22
          opacity: overviewWin.p
          spacing: 14
          Text {
            textFormat: Text.PlainText
            text: overviewWin.query ? "⌕ " + overviewWin.query : "⌕ type to search"
            color: overviewWin.query ? root.foreground : root.dim
            font.family: root.fontFamily; font.pixelSize: 12; font.bold: !!overviewWin.query
          }
          Item { Layout.fillWidth: true }
          Repeater {
            model: [0].concat(overviewWin.wsList)
            Text {
              required property var modelData
              readonly property bool on: overviewWin.wsFilter === modelData
              textFormat: Text.PlainText
              text: modelData === 0 ? "All" : String((modelData - 1) % 10 + 1)
              color: on ? root.foreground : (wsfMouse.containsMouse ? root.foreground : root.dim)
              font.family: root.fontFamily; font.pixelSize: 12; font.bold: on; font.underline: on
              MouseArea { id: wsfMouse; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: overviewWin.wsFilter = modelData }
            }
          }
          Text { textFormat: Text.PlainText; text: "Tab"; color: root.faint; font.family: root.fontFamily; font.pixelSize: 9 }
        }

        Text {
          visible: overviewWin.count === 0
          anchors.centerIn: parent
          opacity: overviewWin.p
          textFormat: Text.PlainText
          text: "No open windows"
          color: root.dim; font.family: root.fontFamily; font.pixelSize: 14
        }

        Repeater {
          id: ovCells
          model: overviewWin.wins
          Item {
            id: cell
            required property var modelData
            required property int index
            anchors.fill: parent
            readonly property bool hidden: root.isMinimized(modelData)
            readonly property bool front: !hidden && modelData.activated
            readonly property var geo: root.ovGeometry[root.addrOf(modelData)] || null
            // the window's own size and where it sits on screen (this window's coordinates)
            readonly property real srcW: geo ? geo.w : 1600
            readonly property real srcH: geo ? geo.h : 1000
            readonly property real startX: hidden || !geo ? -srcW : geo.x - win.screen.x - overviewWin.inset
            readonly property real startY: hidden || !geo ? (overviewWin.height - srcH) / 2 : geo.y - win.screen.y
            // its slot in the grid (a short last row is centred)
            readonly property int col: index % overviewWin.cols
            readonly property int row: Math.floor(index / overviewWin.cols)
            readonly property int inRow: row === overviewWin.rowsN - 1 ? overviewWin.count - overviewWin.cols * (overviewWin.rowsN - 1) : overviewWin.cols
            readonly property real cellX: overviewWin.pad + col * (overviewWin.cellW + overviewWin.gap) + (overviewWin.cols - inRow) * (overviewWin.cellW + overviewWin.gap) / 2
            readonly property real cellY: overviewWin.topPad + row * (overviewWin.cellH + overviewWin.gap)
            readonly property real fit: Math.min(overviewWin.cellW / srcW, (overviewWin.cellH - 34) / srcH)
            readonly property real endW: srcW * fit
            readonly property real endH: srcH * fit
            readonly property real endX: cellX + (overviewWin.cellW - endW) / 2
            readonly property real endY: cellY + (overviewWin.cellH - 34 - endH) / 2
            readonly property bool dragged: overviewWin.dragAddr !== "" && overviewWin.dragAddr === root.addrOf(modelData)
            property real grabX: 0
            property real grabY: 0
            z: dragged ? 10 : 0

            Rectangle {
              id: frame
              // follows the pointer (a little smaller) while it's being dragged
              x: cell.dragged ? overviewWin.dragX - cell.grabX : overviewWin.lerp(cell.startX, cell.endX) - 4
              y: cell.dragged ? overviewWin.dragY - cell.grabY : overviewWin.lerp(cell.startY, cell.endY) - 4
              width: overviewWin.lerp(cell.srcW, cell.endW) + 8
              height: overviewWin.lerp(cell.srcH, cell.endH) + 8
              scale: cell.dragged ? 0.85 : 1
              opacity: cell.dragged ? 0.9 : 1
              Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
              radius: 12
              color: cellMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
                   : !shot.hasContent ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07) : "transparent"
              border.width: (cell.index === overviewWin.sel ? 2 : (cell.front ? 1 : 0)) * overviewWin.p
              border.color: cell.index === overviewWin.sel ? root.foreground : root.urgent
              ScreencopyView {
                id: shot
                anchors.fill: parent
                anchors.margins: 4
                captureSource: cell.modelData.wayland
                live: win.overviewHere
                opacity: cell.hidden ? 0.55 + 0.45 * (1 - overviewWin.p) : 1
              }
              Text {
                visible: !shot.hasContent
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.overviewAppName(cell.modelData)
                color: root.dim; font.family: root.fontFamily; font.pixelSize: 16
              }
              Rectangle {
                visible: overviewWin.dropIndex === cell.index
                x: overviewWin.dropSide === "l" ? 4 : parent.width / 2
                y: 4
                width: parent.width / 2 - 4
                height: parent.height - 8
                radius: 8
                color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.28)
                border.width: 2
                border.color: root.urgent
              }
            }
            Text {
              x: cell.cellX
              y: frame.y + frame.height + 8
              width: overviewWin.cellW
              opacity: overviewWin.p
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: (cell.hidden ? "◌ " : "") + String(cell.modelData.title || root.overviewAppName(cell.modelData))
              color: cell.hidden ? root.dim : root.foreground
              font.family: root.fontFamily; font.pixelSize: 12; font.bold: cell.front
            }
            MouseArea {
              id: cellMouse
              anchors.fill: frame
              enabled: root.overviewOpen
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              cursorShape: cell.dragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
              preventStealing: true
              property real pressX: 0
              property real pressY: 0
              property bool moved: false
              onPressed: function(mouse) { pressX = mouse.x; pressY = mouse.y; moved = false }
              onPositionChanged: function(mouse) {
                if (!(pressedButtons & Qt.LeftButton)) return
                var p = mapToItem(overviewWin.contentItem, mouse.x, mouse.y)
                if (!cell.dragged && Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) > 12) {
                  moved = true
                  var f = mapToItem(frame, pressX, pressY)
                  cell.grabX = f.x; cell.grabY = f.y
                  overviewWin.dragAddr = root.addrOf(cell.modelData)
                }
                if (!cell.dragged) return
                overviewWin.dragX = p.x; overviewWin.dragY = p.y
                // which other preview is under the pointer, and which half
                var hit = -1, side = ""
                for (var i = 0; i < ovCells.count; i++) {
                  var c = ovCells.itemAt(i)
                  if (!c || c === cell) continue
                  var fr = c.children[0]
                  if (p.x >= fr.x && p.x < fr.x + fr.width && p.y >= fr.y && p.y < fr.y + fr.height) {
                    hit = i; side = p.x < fr.x + fr.width / 2 ? "l" : "r"; break
                  }
                }
                overviewWin.dropIndex = hit
                overviewWin.dropSide = side
              }
              onReleased: function(mouse) {
                if (!cell.dragged) return
                var target = overviewWin.dropIndex >= 0 ? ovCells.itemAt(overviewWin.dropIndex) : null
                var side = overviewWin.dropSide
                overviewWin.dragAddr = ""; overviewWin.dropIndex = -1; overviewWin.dropSide = ""
                if (target) root.pairWindows(target.modelData, cell.modelData, side)
              }
              onCanceled: { overviewWin.dragAddr = ""; overviewWin.dropIndex = -1 }
              onClicked: function(mouse) {
                if (moved) { moved = false; return }
                var t = cell.modelData
                if (mouse.button === Qt.MiddleButton) { root.closeWindow(t); return }
                root.closeOverview()
                if (!(t.activated && !root.isMinimized(t))) root.activateWindow(t, root.shiftHeld)
              }
            }
          }
        }
      }

      // -- app right-click menu -------------------------------------------------
      property var menuItem: null
      property real menuY: 0
      property bool menuGrab: false
      property bool menuEntered: false
      function openAppMenu(item, rowItem) {
        var entries = root.appMenuEntries(item)
        var h = 10
        for (var i = 0; i < entries.length; i++) h += entries[i].sep ? 9 : 28
        var y = rowItem.mapToItem(win.contentItem, 0, 0).y
        win.menuY = Math.max(8, Math.min(y, win.height - h - 8))
        win.menuEntered = false
        win.menuItem = item
      }
      function closeAppMenu(why) {
        win.menuGrab = false
        win.menuItem = null
      }
      // Close if the focused window changes underneath it.
      Connections {
        target: Hyprland
        function onActiveToplevelChanged() { if (win.menuItem) win.closeAppMenu("focus changed") }
      }
      // Close once the pointer has been away from the menu for a moment.
      Timer {
        id: menuLeaveTimer
        interval: 700
        onTriggered: win.closeAppMenu("pointer left")
      }
      PopupWindow {
        id: appMenu
        visible: win.menuItem !== null
        anchor.window: win
        anchor.rect.x: root.sidebarWidth - 8
        anchor.rect.y: win.menuY
        anchor.edges: Edges.Top | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.adjustment: PopupAdjustment.Slide
        implicitWidth: 190
        implicitHeight: menuColumn.implicitHeight + 10
        color: "transparent"
        // Grab only once the popup is mapped, or Hyprland may ignore it.
        onVisibleChanged: {
          menuLeaveTimer.stop()
          if (visible) Qt.callLater(function() { win.menuGrab = appMenu.visible })
          else win.menuGrab = false
        }
        HoverHandler {
          id: menuHover
          onHoveredChanged: {
            if (hovered) { win.menuEntered = true; menuLeaveTimer.stop() }
            else if (win.menuEntered) menuLeaveTimer.restart()
          }
        }
        Item {
          anchors.fill: parent
          focus: true
          Keys.onEscapePressed: win.closeAppMenu("escape")
        }
        Rectangle {
          anchors.fill: parent
          radius: 6
          color: root.background
          border.width: 1
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
          Column {
            id: menuColumn
            x: 5; y: 5
            width: parent.width - 10
            Repeater {
              model: root.appMenuEntries(win.menuItem)
              Item {
                id: menuRow
                required property var modelData
                width: menuColumn.width
                height: modelData.sep ? 9 : 28
                Rectangle {
                  visible: !!menuRow.modelData.sep
                  anchors.centerIn: parent
                  width: parent.width - 8; height: 1
                  color: root.faint
                }
                Rectangle {
                  visible: !menuRow.modelData.sep
                  anchors.fill: parent
                  radius: 4
                  color: menuMouse.containsMouse ? root.faint : "transparent"
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 10
                    width: parent.width - 20
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: menuRow.modelData.label || ""
                    color: menuRow.modelData.danger ? root.urgent : root.foreground
                    font.family: root.fontFamily; font.pixelSize: 12
                  }
                  MouseArea {
                    id: menuMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      // Run the action before closing: closing rebuilds the
                      // menu, which destroys this row mid-handler.
                      var item = win.menuItem, e = menuRow.modelData
                      var w = win, r = root
                      r.runAppMenu(item, e)
                      Qt.callLater(function() { w.closeAppMenu("item clicked") })
                    }
                  }
                }
              }
            }
          }
        }
      }
      // A click anywhere outside the menu closes it.
      HyprlandFocusGrab {
        windows: [appMenu, win]
        active: win.menuGrab
        onCleared: win.closeAppMenu("focus grab cleared")
      }
      // While the menu is open, a click anywhere on the sidebar just closes it
      // (a right-click on an app row re-opens it for that app).
      MouseArea {
        anchors.fill: parent
        z: 100
        enabled: win.menuItem !== null
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: function(mouse) {
          win.closeAppMenu("sidebar click")
        }
      }

      // -- widget sections (added in edit mode): each widget's panel, kept open --
      property var extraItems: ({})
      Instantiator {
        model: root.extraSections
        delegate: ColumnLayout {
          id: xsec
          required property var modelData
          readonly property string secId: modelData.id
          readonly property string wid: root.widgetOf(secId)
          // bumped to look the widget up again (a plugin installed or updated after this section was made)
          property int entryRev: 0
          // briefly off to load the widget afresh (a part switched back on gets its own logic back)
          property bool reloading: false
          property var hiddenItems: []
          property var appliedHidden: []
          readonly property var hiddenParts: { var v = root.setting(xsec.secId, "hiddenParts"); return Array.isArray(v) ? v : [] }
          function applyParts() {
            if (!xsec.panel) return
            // a part switched back on: load the widget again so its own visibility rules return
            if (xsec.appliedHidden.some(function(p) { return xsec.hiddenParts.indexOf(p) === -1 })) { xsec.reload(); return }
            var items = []
            xsec.hiddenParts.forEach(function(p) { var it = root.partAt(xinner, p); if (it) { it.visible = false; items.push(it) } })
            xsec.hiddenItems = items
            xsec.appliedHidden = xsec.hiddenParts.slice()
          }
          function scanParts() {
            if (!xsec.panel) return
            var next = Object.assign({}, root.widgetParts)
            next[xsec.secId] = root.scanParts(xinner, xsec.hiddenItems)
            if (JSON.stringify(next[xsec.secId]) !== JSON.stringify(root.widgetParts[xsec.secId])) root.widgetParts = next
          }
          function reload() {
            xsec.panel = null; xsec.hiddenItems = []; xsec.appliedHidden = []
            xsec.reloading = true
            Qt.callLater(function() { xsec.reloading = false })
          }
          onHiddenPartsChanged: applyParts()
          // keep parts off (some are made later, e.g. on another tab) and the list fresh while editing it
          Timer {
            interval: 1500
            repeat: true
            running: !!xsec.panel && xsec.visible
            onTriggered: { xsec.applyParts(); if (root.editing && root.editSection === xsec.secId) xsec.scanParts() }
          }
          Connections {
            target: root
            function onEditSectionChanged() { if (root.editSection === xsec.secId) xsec.scanParts() }
          }
          readonly property var entry: {
            var r = xsec.entryRev
            var w = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
            return w ? w[xsec.wid] || null : null
          }
          parent: mainCol
          Layout.fillWidth: true
          spacing: 6
          visible: root.sectionShown(secId)
          opacity: root.sectionOpacity(secId)

          property var panel: null
          property bool noPanel: false
          property int tries: 0

          // folded by clicking the title; only while the title shows, so a section can never vanish
          readonly property bool collapsed: root.setting(secId, "title") === true && root.setting(secId, "collapsed") === true
          Text {
            visible: root.setting(xsec.secId, "title") === true   // off unless turned on in the editor
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: (xsec.collapsed ? "▸ " : "▾ ") + root.widgetName(xsec.wid).toUpperCase()
            color: xTitleMouse.containsMouse ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1
            elide: Text.ElideRight
            // click the title to fold the section
            MouseArea { id: xTitleMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setSetting(xsec.secId, "collapsed", !xsec.collapsed) }
          }
          // "squeeze": content reflows to the sidebar's width; "shrink": drawn at the
          // panel's own width and scaled down to fit (for fixed-width panels)
          readonly property bool shrink: root.setting(secId, "fit") === "shrink"
          readonly property real natW: xsec.panel ? Math.max(1, xsec.panel.contentWidth) : 1
          readonly property real k: shrink ? Math.min(1, xbody.width / natW) : 1
          // a widget can ask to sit tight (no popup padding): its content's own height
          readonly property bool tight: !!xsec.panel && !!xsec.panel.owner && xsec.panel.owner.tightInSidebar === true
          readonly property real panelH: xsec.panel ? (xsec.tight ? xsec.panel.loadedContentHeight : xsec.panel.contentHeight) : 0
          readonly property real fullH: xsec.panel ? Math.max(0, xsec.panelH) * xsec.k : (xsec.noPanel ? 20 : 0)
          readonly property real cropTop: root.cropOf(secId, "top")
          readonly property real cropBottom: root.cropOf(secId, "bottom")
          // what's left after trimming the top and bottom
          readonly property real visH: Math.max(0, xsec.fullH - xsec.cropTop - xsec.cropBottom)
          Flickable {
            id: xbody
            visible: !xsec.collapsed
            Layout.fillWidth: true
            Layout.preferredHeight: root.heightFor(xsec.secId, xsec.visH)
            // when the sidebar runs out of room it shrinks (and scrolls) instead of
            // pushing the sections above it off the screen
            Layout.minimumHeight: Math.min(Layout.preferredHeight, 90)
            contentWidth: width
            contentHeight: xsec.visH
            interactive: contentHeight > height + 1
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            Item {
              id: xinner
              y: -xsec.cropTop
              width: xsec.shrink ? xsec.natW : xbody.width
              height: xsec.panel ? Math.max(0, xsec.panelH) : 0
              scale: xsec.k
              transformOrigin: Item.TopLeft
            }
            Text {
              visible: xsec.noPanel
              textFormat: Text.PlainText
              text: "This widget has no panel to show."
              color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
            }
          }
          // the widget itself (its button stays hidden; only its panel is shown)
          Loader {
            id: xhost
            visible: false
            Layout.preferredWidth: 0
            Layout.preferredHeight: 0
            active: !xsec.reloading && !!xsec.entry && !!xsec.entry.component
            sourceComponent: xsec.entry ? xsec.entry.component : null
            onLoaded: {
              if ("fixedEdge" in item) item.fixedEdge = "start"
              if ("bar" in item) item.bar = embedBar
              if ("moduleName" in item) item.moduleName = xsec.wid
              xsec.applySettings()
              // a fresh load (also after the plugin was reloaded): look for its panel from scratch
              xsec.noPanel = false
              xsec.tries = 0
              embedTimer.restart()
            }
          }
          // the widget's settings: its defaults, its bar entry, then options set in the editor
          function applySettings() {
            var item = xhost.item
            if (!item || !("settings" in item)) return
            var meta = xsec.entry && xsec.entry.metadata ? xsec.entry.metadata : {}
            var defs = meta.barWidget && meta.barWidget.defaults ? meta.barWidget.defaults : (meta.defaults || {})
            var merged = JSON.parse(JSON.stringify(defs))
            var lay = root.barConfig && root.barConfig.layout ? root.barConfig.layout : {}
            ;["left", "centerBegin", "center", "centerEnd", "right", "tray"].forEach(function(sec) {
              (lay[sec] || []).forEach(function(e) { if (e && e.id === xsec.wid) for (var k in e) if (k !== "id") merged[k] = e[k] })
            })
            var opts = root.setting(xsec.secId, "opts") || {}
            for (var o in opts) merged[o] = opts[o]
            if (JSON.stringify(item.settings) !== JSON.stringify(merged)) item.settings = merged
          }
          Connections {
            target: root
            function onUserSettingsChanged() { xsec.applySettings() }
          }
          // Watchdog: showing but with nothing in it (the plugin wasn't loaded yet, or
          // was reloaded and its old panel went away): try again until it works.
          Timer {
            interval: 1500
            repeat: true
            running: xsec.visible && !xsec.collapsed && !xsec.panel && !xsec.noPanel
            onTriggered: {
              if (xhost.item) { xsec.tries = 0; embedTimer.restart() }
              else xsec.entryRev++
            }
          }
          // find the widget's panel, keep it open (its window hidden) and move its content here
          Timer {
            id: embedTimer
            interval: 150
            onTriggered: {
              var item = xhost.item
              if (!item) return
              var ps = []
              root.findPanels(item, ps, 0, [])
              if (ps.length === 0) { if (++xsec.tries < 15) embedTimer.restart(); else xsec.noPanel = true; return }
              var p = ps[0]
              p.visible = false
              p.contentRequested = true
              if (typeof item.open === "function") item.open(); else p.open = true
              xsec.panel = p
              moveTimer.restart()
            }
          }
          Timer {
            id: moveTimer
            interval: 60
            onTriggered: {
              var p = xsec.panel
              if (!p) return
              p.visible = false
              for (var i = p.contentItem.length - 1; i >= 0; i--) {
                var k = p.contentItem[i]
                k.parent = xinner
                if (!k.anchors.fill) k.width = Qt.binding(function() { return xinner.width })
              }
              Qt.callLater(function() { xsec.applyParts(); xsec.scanParts() })
            }
          }
          // if it closes itself, open it again; its window never shows
          Connections {
            target: xsec.panel
            function onOpenChanged() {
              if (xsec.panel && !xsec.panel.open) Qt.callLater(function() {
                if (xhost.item && typeof xhost.item.open === "function") xhost.item.open(); else if (xsec.panel) xsec.panel.open = true
              })
            }
            function onVisibleChanged() { if (xsec.panel && xsec.panel.visible) xsec.panel.visible = false }
          }
        }
        onObjectAdded: function(index, object) {
          var next = Object.assign({}, win.extraItems); next[object.secId] = object; win.extraItems = next
          Qt.callLater(win.applySectionOrder)
        }
        onObjectRemoved: function(index, object) {
          var next = Object.assign({}, win.extraItems); delete next[object.secId]; win.extraItems = next
          Qt.callLater(win.applySectionOrder)
        }
      }

      // ---- pinned sections ----------------------------------------------------
      // A pinned section keeps a placeholder of its height in the scrolling
      // column; the section itself is drawn above, with the sidebar's background,
      // and sticks where it is: at the top or bottom edge (stacked with any other
      // pinned ones) once scrolling would take it out of view. Not while editing.
      readonly property bool pinsOn: !root.editing
      readonly property var pinnedIds: root.sectionOrder.filter(function(id) { return id !== "apps" && root.setting(id, "pinned") === true })
      onPinnedIdsChanged: Qt.callLater(win.applySectionOrder)
      onPinsOnChanged: Qt.callLater(win.applySectionOrder)
      property var pinSlots: ({})
      property var pinHolders: ({})
      property int pinRev: 0
      Item { id: slotParking; visible: false }
      Item {
        id: pinLayer
        x: sideFlick.x; y: sideFlick.y; width: sideFlick.width; height: sideFlick.height
        z: 5
      }
      Component {
        id: pinSlotComp
        Item {
          property var holder: null
          Layout.fillWidth: true
          Layout.preferredHeight: holder ? holder.height : 0
          visible: !!holder && holder.height > 0
        }
      }
      Component {
        id: pinHolderComp
        Item {
          id: ph
          property string sid: ""
          property var slot: null
          readonly property alias col: phCol
          readonly property var shownPins: win.pinnedIds.filter(function(id) { var h = win.pinHolders[id]; return h && h.active && h.height > 0 })
          readonly property bool active: win.pinsOn && win.pinnedIds.indexOf(sid) !== -1
          // the room the pinned sections before and after this one take at the edges
          readonly property real topOff: { var t = 0, me = shownPins.indexOf(sid); for (var i = 0; i < me; i++) t += win.pinHolders[shownPins[i]].height + mainCol.spacing; return t }
          readonly property real bottomOff: { var b = 0, me = shownPins.indexOf(sid); if (me < 0) return 0; for (var i = me + 1; i < shownPins.length; i++) b += win.pinHolders[shownPins[i]].height + mainCol.spacing; return b }
          readonly property real naturalY: slot ? slot.y - sideFlick.contentY : 0
          visible: active && height > 0
          width: pinLayer.width
          height: phCol.implicitHeight
          y: Math.max(topOff, Math.min(naturalY, pinLayer.height - bottomOff - height))
          onYChanged: win.pinRev++
          onHeightChanged: win.pinRev++
          // the sidebar's background behind it, edge to edge, so what scrolls goes underneath
          Rectangle {
            x: win.panelInnerX - sideFlick.x
            y: -mainCol.spacing / 2
            width: win.panelInnerW
            height: parent.height + mainCol.spacing
            color: win.color.a < 1 ? root.background : win.color
          }
          ColumnLayout { id: phCol; width: parent.width; spacing: mainCol.spacing }
        }
      }
      // ---- trimmed built-in sections ------------------------------------------
      // A built-in section with a trim goes into a clipping box whose content is
      // shifted up by the top trim and cut short by the bottom one. Untrimmed
      // sections stay as they are. (Widget sections trim themselves.)
      // The same box gives a section a set height ("max" / "fixed"), scrolling
      // what doesn't fit. (Not the bottom row: it's one fixed row.)
      function isTrimmable(id) { return id !== "apps" && String(id).indexOf("w:") !== 0 }
      function isSizable(id) { return id !== "apps" && id !== "bottom" }
      readonly property var trimmedIds: root.sectionOrder.filter(function(id) {
        return win.isTrimmable(id) && (root.cropOf(id, "top") > 0 || root.cropOf(id, "bottom") > 0 || (win.isSizable(id) && root.heightMode(id) !== "auto"))
      })
      onTrimmedIdsChanged: Qt.callLater(win.applySectionOrder)
      property var trimBoxes: ({})
      property int trimRev: 0
      Component {
        id: trimBoxComp
        Flickable {
          id: tb
          property string sid: ""
          readonly property alias col: tbCol
          readonly property real cutTop: root.cropOf(sid, "top")
          readonly property real cutBottom: root.cropOf(sid, "bottom")
          readonly property real visH: Math.max(0, tbCol.implicitHeight - cutTop - cutBottom)
          Layout.fillWidth: true
          Layout.preferredHeight: win.isSizable(sid) ? root.heightFor(sid, visH) : visH
          visible: root.sectionShown(sid) || root.editing
          contentWidth: width
          contentHeight: visH
          interactive: contentHeight > height + 1
          boundsBehavior: Flickable.StopAtBounds
          clip: true
          onYChanged: win.trimRev++
          onHeightChanged: win.trimRev++
          ColumnLayout { id: tbCol; y: -tb.cutTop; width: tb.width; spacing: mainCol.spacing }
        }
      }
      function trimBox(id) {
        if (!win.trimBoxes[id]) {
          var b = trimBoxComp.createObject(slotParking, { sid: id })
          var bs = Object.assign({}, win.trimBoxes); bs[id] = b; win.trimBoxes = bs
        }
        return win.trimBoxes[id]
      }
      // a section's untrimmed height (the trim handles can't cut past it)
      function sectionFullH(id) {
        if (String(id).indexOf("w:") === 0) { var x = win.extraItems[id]; return x ? x.fullH : 0 }
        if (win.trimBoxes[id] && win.trimmedIds.indexOf(id) !== -1) return win.trimBoxes[id].col.implicitHeight
        var parts = win.sectionBlocks()[id] || [], h = 0, n = 0
        parts.forEach(function(it) { if (it && it.visible) { h += it.height; n++ } })
        return h + Math.max(0, n - 1) * mainCol.spacing
      }
      function sectionBlocks() {
        var blocks = {
          clock: [secClock, secCalendar], status: [secStatus], system: [secStats, secNet], workspaces: [secWs], search: [secSearch], media: [secMedia], notifications: [secNotif],
          apps: [menuList, appList], tray: [trayPanel, secTray], bottom: [dockCol, bottomSep, secBottom]
        }
        for (var key in win.extraItems) blocks[key] = [win.extraItems[key]]
        return blocks
      }
      function pinParts(id) {
        if (!win.pinHolders[id]) {
          var h = pinHolderComp.createObject(pinLayer, { sid: id })
          var sl = pinSlotComp.createObject(slotParking, { holder: h })
          h.slot = sl
          var hs = Object.assign({}, win.pinHolders); hs[id] = h; win.pinHolders = hs
          var ss = Object.assign({}, win.pinSlots); ss[id] = sl; win.pinSlots = ss
        }
        return { holder: win.pinHolders[id], slot: win.pinSlots[id] }
      }
      // ---- the grid ------------------------------------------------------------
      // The sidebar is 12 columns wide. A section takes a quarter, a third, half,
      // two thirds, three quarters or all of it; sections that fit side by side
      // share a row (a "lane"), in order. Every section sits in a cell, which can
      // also draw a card behind it, pad it and align it within its row. Pinned
      // sections always take the full width (and skip the cell).
      readonly property int gridCols: 12
      readonly property real gridGap: 14
      function sectionSpan(id) {
        if (win.pinsOn && win.pinnedIds.indexOf(id) !== -1) return 12
        var v = root.setting(id, "span")
        return [3, 4, 6, 8, 9, 12].indexOf(v) !== -1 ? v : 12
      }
      // what the lanes depend on: re-sort the column when it changes
      readonly property string laneKey: root.sectionOrder.map(function(id) {
        return id + ":" + win.sectionSpan(id) + ":" + (root.sectionShown(id) || root.editing ? 1 : 0) + ":" + (win.pinnedIds.indexOf(id) !== -1 ? 1 : 0)
      }).join(",")
      onLaneKeyChanged: Qt.callLater(win.applySectionOrder)
      property var laneCells: ({})
      // the room the app list would stretch into when it has a set height (or is
      // hidden), so the rest doesn't spread out and the bottom row stays at the bottom
      Item {
        id: laneStretch
        parent: slotParking
        readonly property var appsCell: win.laneCells["apps"] || null
        visible: !(appsCell && appsCell.parent && appsCell.parent !== slotParking && appsCell.fills)
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: 0
      }
      property var lanePool: []
      Component {
        id: laneComp
        RowLayout {
          id: laneRow
          Layout.fillWidth: true
          // the app list stretches to the bottom row; its lane stretches with it
          Layout.fillHeight: { var c = laneRow.children; for (var i = 0; i < c.length; i++) if (c[i].fills) return true; return false }
          spacing: win.gridGap
          property Item filler: Item { Layout.fillWidth: true; Layout.preferredHeight: 0 }
        }
      }
      Component {
        id: cellComp
        Item {
          id: cell
          property string sid: ""
          readonly property alias col: cellCol
          readonly property real laneW: mainCol.width   // not the lane's: that would size itself from the cells
          // the app list (at "fit content") takes the room that's left
          readonly property bool fills: sid === "apps" && root.heightMode("apps") === "auto"
          // empty cells fold away; the stretching one never does (the Super+Space menu
          // stands in for the app list with no height of its own, only the room left)
          readonly property bool hasContent: cellCol.implicitHeight > 0 || (fills && root.sectionShown(sid))
          readonly property bool card: root.setting(sid, "card") === true
          readonly property real pad: { var v = root.setting(sid, "pad"); return typeof v === "number" ? v : (card ? 10 : 0) }
          readonly property string valign: root.setting(sid, "align") || "top"
          readonly property real contentH: hasContent ? cellCol.implicitHeight + 2 * pad : 0
          Layout.alignment: valign === "middle" ? Qt.AlignVCenter : valign === "bottom" ? Qt.AlignBottom : Qt.AlignTop
          Layout.preferredWidth: hasContent ? Math.max(0, win.sectionSpan(sid) * (laneW + win.gridGap) / win.gridCols - win.gridGap) : 0
          Layout.preferredHeight: contentH
          Layout.minimumHeight: fills ? contentH : 0
          Layout.fillHeight: fills
          Rectangle {
            visible: cell.card && cell.hasContent
            anchors.fill: parent
            radius: 8
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)
          }
          ColumnLayout {
            id: cellCol
            x: cell.pad; y: cell.pad
            width: Math.max(0, cell.width - 2 * cell.pad)
            height: cell.fills ? Math.max(implicitHeight, cell.height - 2 * cell.pad) : implicitHeight
            spacing: mainCol.spacing
          }
        }
      }
      function laneCell(id) {
        if (!win.laneCells[id]) {
          var c = cellComp.createObject(slotParking, { sid: id })
          var cs = Object.assign({}, win.laneCells); cs[id] = c; win.laneCells = cs
        }
        return win.laneCells[id]
      }
      function lane(i) {
        while (win.lanePool.length <= i) {
          var l = laneComp.createObject(slotParking)
          l.filler.parent = slotParking
          win.lanePool = win.lanePool.concat([l])
        }
        return win.lanePool[i]
      }

      // where the separator above the bottom row is in the window (the overlays
      // that open above the bottom row sit on it); it may be scrolled or pinned
      readonly property real bottomEdgeY: {
        var dep = sideFlick.contentY + sideFlick.height + mainCol.height + bottomSep.y + win.pinRev + (secBottom.visible ? 1 : 0)
        // it sits in a grid cell (padded) in a lane: follow each of those as they move
        for (var up = bottomSep.parent; up && up !== mainCol && up !== win.contentItem; up = up.parent) dep += up.y + up.height
        if (!secBottom.visible || !bottomSep.parent) return sideFlick.y + sideFlick.height
        return Math.min(sideFlick.y + sideFlick.height, bottomSep.mapToItem(win.contentItem, 0, 0).y - mainCol.spacing)
      }

      // Put the column's pieces in the saved section order (each section moves
      // with its parts; the panels that open above the bottom row go with it).
      function applySectionOrder() {
        var blocks = win.sectionBlocks()
        // trimmed built-in sections: their parts go in a trim box, and the box takes their place
        var trimmed = {}
        win.trimmedIds.forEach(function(id) { if (blocks[id]) { trimmed[id] = { parts: blocks[id], box: win.trimBox(id) }; blocks[id] = [trimmed[id].box] } })
        var items = []
        var pinned = {}   // id -> its parts, drawn in its holder above the column
        var lanes = []    // [{ lane, cells: [{ cell, parts }] }]
        var open = null, used = 0, stretchAt = -1, bottomAt = -1
        function closeLane() {
          if (!open) return
          var l = { lane: win.lane(lanes.length), cells: open.map(function(id) { return { cell: win.laneCell(id), parts: blocks[id] } }) }
          lanes.push(l)
          if (open.indexOf("bottom") !== -1) bottomAt = items.length
          items.push(l.lane)
          if (open.indexOf("apps") !== -1) stretchAt = items.length
          open = null; used = 0
        }
        root.sectionOrder.forEach(function(id) {
          if (!blocks[id]) return
          if (win.pinsOn && win.pinnedIds.indexOf(id) !== -1) {
            closeLane()
            var pp = win.pinParts(id)
            items.push(pp.slot)
            pinned[id] = { parts: blocks[id], holder: pp.holder }
            return
          }
          // hidden: no room in a lane, just parked (invisible) in the column
          if (!(root.sectionShown(id) || root.editing)) { blocks[id].forEach(function(it) { items.push(it) }); return }
          var sp = win.sectionSpan(id)
          if (open && used + sp > win.gridCols) closeLane()
          open = open || []
          open.push(id); used += sp
          if (used >= win.gridCols) closeLane()
        })
        closeLane()
        // the stretch goes where the app list ends (else just above the bottom row)
        items.splice(stretchAt >= 0 ? stretchAt : (bottomAt >= 0 ? bottomAt : items.length), 0, laneStretch)
        var current = []
        for (var i = 0; i < mainCol.children.length; i++) current.push(mainCol.children[i])
        var holdersOk = Object.keys(pinned).every(function(id) {
          var c = pinned[id].holder.col.children
          return pinned[id].parts.length === c.length && pinned[id].parts.every(function(it, k) { return c[k] === it })
        })
        var boxesOk = Object.keys(trimmed).every(function(id) {
          var c = trimmed[id].box.col.children
          return trimmed[id].parts.length === c.length && trimmed[id].parts.every(function(it, k) { return c[k] === it })
        })
        var lanesOk = lanes.every(function(l) {
          var c = l.lane.children
          if (c.length !== l.cells.length + 1 || c[c.length - 1] !== l.lane.filler) return false
          return l.cells.every(function(x, k) {
            var cc = x.cell.col.children
            return c[k] === x.cell && x.parts.length === cc.length && x.parts.every(function(it, j) { return cc[j] === it })
          })
        })
        var same = lanesOk && boxesOk && holdersOk && items.length === current.length && items.every(function(it, k) { return current[k] === it })
        if (same) return
        // placeholders and trim boxes no longer used go back out of the column
        for (var sid in win.pinSlots) if (items.indexOf(win.pinSlots[sid]) === -1) win.pinSlots[sid].parent = slotParking
        for (var bid in win.trimBoxes) if (!trimmed[bid]) win.trimBoxes[bid].parent = slotParking
        var usedCells = {}
        lanes.forEach(function(l) { l.cells.forEach(function(x) { usedCells[x.cell.sid] = true }) })
        for (var cid in win.laneCells) if (!usedCells[cid]) win.laneCells[cid].parent = slotParking
        for (var li = lanes.length; li < win.lanePool.length; li++) win.lanePool[li].parent = slotParking
        laneStretch.parent = slotParking
        // a trimmed section's parts into its box first (the box may then be placed or pinned)
        for (var tid in trimmed) {
          trimmed[tid].parts.forEach(function(it) { it.parent = null })
          trimmed[tid].parts.forEach(function(it) { it.parent = trimmed[tid].box.col })
        }
        // a lane's sections into their cells, the cells into the lane
        lanes.forEach(function(l) {
          l.cells.forEach(function(x) {
            x.parts.forEach(function(it) { it.parent = null })
            x.parts.forEach(function(it) { it.parent = x.cell.col })
          })
          l.cells.forEach(function(x) { x.cell.parent = null })
          l.lane.filler.parent = null
          l.cells.forEach(function(x) { x.cell.parent = l.lane })
          l.lane.filler.parent = l.lane
        })
        items.forEach(function(it) { it.parent = null })
        items.forEach(function(it) { it.parent = mainCol })
        for (var pid in pinned) {
          pinned[pid].parts.forEach(function(it) { it.parent = null })
          pinned[pid].parts.forEach(function(it) { it.parent = pinned[pid].holder.col })
        }
        win.pinRev++
      }
      Component.onCompleted: Qt.callLater(win.applySectionOrder)
      Connections {
        target: root
        function onSectionOrderChanged() { Qt.callLater(win.applySectionOrder) }
      }

      // -- edit mode: a labelled outline on each section; clicking one picks it --
      readonly property bool editHere: root.editing && root.editMonitor === win.monitorName
      Item {
        id: editOverlay
        anchors.fill: parent
        anchors.topMargin: win.editHere ? editHeader.y + editHeader.height + 2 : 0
        clip: true
        z: 60
        visible: win.editHere
        // dragging a section to a new place
        property string dragId: ""
        property real dragY: 0
        property real grabY: 0
        property real dragX: 0
        property real grabX: 0
        property int dropIndex: -1
        property bool dropHide: false     // dragged past the sidebar's edge
        property string dropId: ""        // the section it'd land next to …
        property bool dropAfter: false    // … after it rather than before
        // the nearest outline; beside a part-width one it's left/right, else above/below
        function dropAt(p) {
          var others = root.sectionOrder.filter(function(id) { return id !== editOverlay.dragId && editOverlay.boxes[id] })
          var best = -1, bestD = 1e9
          for (var i = 0; i < others.length; i++) {
            var b = editOverlay.boxes[others[i]]
            var dx = Math.max(b.x - p.x, 0, p.x - (b.x + b.w))
            var dy = Math.max(b.y - p.y, 0, p.y - (b.y + b.h))
            var d = dx + dy * 3
            if (d < bestD) { bestD = d; best = i }
          }
          if (best < 0) { editOverlay.dropId = ""; return -1 }
          var bb = editOverlay.boxes[others[best]]
          var after = win.sectionSpan(others[best]) < win.gridCols ? p.x > bb.x + bb.w / 2 : p.y > bb.y + bb.h / 2
          editOverlay.dropId = others[best]; editOverlay.dropAfter = after
          return best + (after ? 1 : 0)
        }
        function finishDrag() {
          var id = editOverlay.dragId
          var idx = editOverlay.dropIndex
          var hide = editOverlay.dropHide
          editOverlay.dragId = ""
          editOverlay.dropIndex = -1
          editOverlay.dropHide = false
          editOverlay.dropId = ""
          if (!id) return
          if (hide) { root.removeSection(id); return }
          if (idx < 0) return
          var order = root.sectionOrder.filter(function(x) { return x !== id })
          // the index counts sections with outlines; map it onto the full order
          var shown = order.filter(function(x) { return editOverlay.boxes[x] })
          var before = idx < shown.length ? shown[idx] : null
          var at = before ? order.indexOf(before) : order.length
          order.splice(at, 0, id)
          // one write: the new order, and a hidden section dropped back in shows again
          var next = JSON.parse(JSON.stringify(root.userSettings))
          next.order = order
          if (root.setting(id, "show") === false) { next[id] = next[id] || {}; next[id].show = true }
          root.saveSettings(next)
        }
        Rectangle {
          readonly property var bottomBox: editOverlay.boxes["bottom"]
          visible: !!bottomBox && editOverlay.dragId === "" && root.editSection === ""
          z: 6
          // on the bottom section's top edge, between its label and its ×,
          // so it never covers the section above
          x: (parent.width - width) / 2
          y: bottomBox ? bottomBox.y - height / 2 : 0
          width: addText.implicitWidth + 14
          height: 18
          radius: 4
          color: addMouse.containsMouse || root.addOpen ? root.foreground : root.background
          border.width: 1
          border.color: root.dim
          Text { id: addText; anchors.centerIn: parent; textFormat: Text.PlainText; text: "+ add section"; color: addMouse.containsMouse || root.addOpen ? root.background : root.foreground
            font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1 }
          MouseArea { id: addMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.addOpen = !root.addOpen }
        }
        // where the dragged section will land: a line on that side of its neighbour
        Rectangle {
          readonly property var b: editOverlay.boxes[editOverlay.dropId]
          readonly property bool side: !!b && win.sectionSpan(editOverlay.dropId) < win.gridCols
          visible: editOverlay.dragId !== "" && !editOverlay.dropHide && !!b
          z: 5
          radius: 1
          color: root.foreground
          x: !b ? 0 : side ? (editOverlay.dropAfter ? b.x + b.w + 1 : b.x - 3) : b.x + 2
          y: !b ? 0 : side ? b.y : (editOverlay.dropAfter ? b.y + b.h + 3 : b.y - 5)
          width: !b ? 0 : side ? 2 : b.w - 4
          height: !b ? 0 : side ? b.h : 2
        }
        // each section's extent, from the items that make it up
        function boxFor(items) {
          var top = 1e9, bottom = -1e9, left = 1e9, right = -1e9
          for (var i = 0; i < items.length; i++) {
            var it = items[i]
            if (!it || !it.visible || !it.parent) continue
            var at = it.mapToItem(editOverlay, 0, 0)
            top = Math.min(top, at.y)
            bottom = Math.max(bottom, at.y + it.height)
            left = Math.min(left, at.x)
            right = Math.max(right, at.x + it.width)
          }
          if (top > bottom) return null
          // full width: the outline runs edge to edge; a part-width one hugs its cell
          var full = right - left >= mainCol.width - 2
          return full ? { x: 8, w: editOverlay.width - 16, y: top - 6, h: bottom - top + 12 }
                      : { x: left - 5, w: right - left + 10, y: top - 6, h: bottom - top + 12 }
        }
        // a trimmed section is outlined by its box (what's left showing)
        function boxItems(id, items) {
          var c = win.laneCells[id]
          if (c && c.parent && c.parent !== slotParking) return c.hasContent ? [c] : []
          return win.trimmedIds.indexOf(id) !== -1 && win.trimBoxes[id] ? [win.trimBoxes[id]] : items
        }
        readonly property var boxes: {
          var rev2 = secMedia.y + secMedia.height + secNotif.y + secNotif.height
          var rev = mainCol.height + sideFlick.contentY + secClock.y + secStatus.y + secStatus.height + secStats.y + secNet.y + secWs.y + secSearch.y + appList.y + appList.height + secTray.y + secTray.height + secBottom.y
          var rev3 = win.trimRev + win.trimmedIds.length
          var rev4 = sideFlick.y + sideFlick.height + editOverlay.y + editOverlay.height + editOverlay.width + mainCol.width
          var rev5 = win.laneKey.length; for (var lc in win.laneCells) { var lcell = win.laneCells[lc]; rev5 += lcell.x + lcell.width + lcell.y + lcell.height + (lcell.parent ? lcell.parent.y : 0) }
          var out = {
            clock: boxFor(boxItems("clock", [secClock])), status: boxFor(boxItems("status", [secStatus])), system: boxFor(boxItems("system", [secStats, secNet])),
            workspaces: boxFor(boxItems("workspaces", [secWs])), search: boxFor(boxItems("search", [secSearch])), media: boxFor(boxItems("media", [secMedia])),
            notifications: boxFor(boxItems("notifications", [secNotif])), apps: boxFor(boxItems("apps", [appList])), tray: boxFor(boxItems("tray", [secTray])), bottom: boxFor(boxItems("bottom", [secBottom]))
          }
          for (var key in win.extraItems) { var xi = win.extraItems[key]; var dep = xi.y + xi.height; out[key] = boxFor(boxItems(key, [xi])) }
          return out
        }
        Repeater {
          model: root.editSections
          Item {
            id: ebox
            required property var modelData
            readonly property var box: editOverlay.boxes[modelData.id]
            readonly property bool picked: root.editSection === modelData.id
            readonly property bool hiddenSec: root.setting(modelData.id, "show") === false
            readonly property bool dragged: editOverlay.dragId === modelData.id
            // one at a time: while a section's settings are open, the others rest
            readonly property bool locked: root.editSection !== "" && !picked
            visible: !!box
            x: dragged ? editOverlay.dragX - editOverlay.grabX : (box ? box.x : 0)
            y: dragged ? editOverlay.dragY - editOverlay.grabY : (box ? box.y : 0)
            z: dragged ? 4 : 0
            opacity: dragged ? (editOverlay.dropHide ? 0.45 : 0.85) : (locked ? 0.35 : 1)
            width: box ? box.w : 0
            height: box ? box.h : 0
            // dashed outline (solid for the one being edited)
            Canvas {
              anchors.fill: parent
              visible: !ebox.picked
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.strokeStyle = Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.28)
                ctx.lineWidth = 1
                ctx.setLineDash([4, 3])
                var r = 8, w = width - 1, h = height - 1
                ctx.beginPath()
                ctx.moveTo(r + 0.5, 0.5); ctx.lineTo(w - r, 0.5); ctx.arcTo(w, 0.5, w, r, r)
                ctx.lineTo(w, h - r); ctx.arcTo(w, h, w - r, h, r)
                ctx.lineTo(r + 0.5, h); ctx.arcTo(0.5, h, 0.5, h - r, r)
                ctx.lineTo(0.5, r); ctx.arcTo(0.5, 0.5, r + 0.5, 0.5, r)
                ctx.stroke()
              }
            }
            Rectangle {
              anchors.fill: parent
              visible: ebox.picked
              radius: 8
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
              border.width: 2
              border.color: root.foreground
            }
            // the label, sitting on the outline
            Rectangle {
              x: 8
              y: -7
              width: Math.min(elabel.implicitWidth, ebox.width - 46) + 8
              height: 13
              radius: 3
              color: ebox.picked ? root.foreground : root.background
              Text {
                id: elabel
                anchors.centerIn: parent
                width: Math.min(implicitWidth, ebox.width - 46)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: ebox.modelData.label + (ebox.dragged && editOverlay.dropHide ? " · RELEASE TO REMOVE"
                      : ebox.picked ? " · EDITING" : (ebox.hiddenSec ? " · HIDDEN" : ""))
                color: ebox.picked ? root.background : root.dim
                font.family: root.fontFamily; font.pixelSize: 8; font.letterSpacing: 1; font.bold: ebox.picked
              }
            }
            // trim handles: drag the top edge down or the bottom edge up to cut that much off
            Repeater {
              model: ebox.picked && ebox.modelData.id !== "apps" && !ebox.dragged ? ["top", "bottom"] : []
              Rectangle {
                id: trimHandle
                required property string modelData
                readonly property string sid: ebox.modelData.id
                z: 5
                width: 44; height: 8; radius: 4
                x: (parent.width - width) / 2 + (modelData === "top" ? 40 : 0)
                y: modelData === "top" ? -height / 2 : parent.height - height / 2
                color: trimMouse.containsMouse || trimMouse.pressed ? root.foreground : root.background
                border.width: 1
                border.color: root.foreground
                Rectangle { anchors.centerIn: parent; width: 16; height: 1; color: trimMouse.containsMouse || trimMouse.pressed ? root.background : root.foreground }
                MouseArea {
                  id: trimMouse
                  anchors.fill: parent
                  anchors.margins: -4
                  hoverEnabled: true
                  preventStealing: true
                  cursorShape: Qt.SizeVerCursor
                  property real startY: 0
                  property real startTop: 0
                  property real startBottom: 0
                  onPressed: function(mouse) {
                    startY = mapToItem(editOverlay, mouse.x, mouse.y).y
                    startTop = root.cropOf(trimHandle.sid, "top")
                    startBottom = root.cropOf(trimHandle.sid, "bottom")
                    root.cropDrag = { id: trimHandle.sid, top: startTop, bottom: startBottom }
                  }
                  onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var dy = mapToItem(editOverlay, mouse.x, mouse.y).y - startY
                    var full = win.sectionFullH(trimHandle.sid)
                    var t = startTop, b = startBottom
                    if (trimHandle.modelData === "top") t = Math.max(0, Math.min(startTop + dy, full - b - 8))
                    else b = Math.max(0, Math.min(startBottom - dy, full - t - 8))
                    root.cropDrag = { id: trimHandle.sid, top: Math.round(t), bottom: Math.round(b) }
                  }
                  onReleased: {
                    var d = root.cropDrag
                    root.cropDrag = null
                    if (d) root.saveCrop(d.id, d.top, d.bottom)
                  }
                  onCanceled: root.cropDrag = null
                }
              }
            }
            // remove button, sitting on the outline's top-right corner
            Rectangle {
              visible: ebox.modelData.id !== "bottom" && !ebox.dragged && !ebox.locked
              z: 3
              x: parent.width - width - 8
              y: -7
              width: 15
              height: 13
              radius: 3
              color: xRemMouse.containsMouse ? root.urgent : root.background
              border.width: 1
              border.color: xRemMouse.containsMouse ? root.urgent : root.dim
              Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: "✕"; color: xRemMouse.containsMouse ? root.background : root.dim; font.family: root.fontFamily; font.pixelSize: 8 }
              MouseArea { id: xRemMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeSection(ebox.modelData.id) }
            }
            MouseArea {
              anchors.fill: parent
              // the picked system section: its readings are clicked and dragged instead
              enabled: !(ebox.picked && ebox.modelData.id === "system") && !ebox.locked
              cursorShape: ebox.dragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton
              preventStealing: true
              property real pressY: 0
              property real pressX: 0
              property bool moved: false
              onPressed: function(mouse) { pressY = mouse.y; pressX = mouse.x; moved = false }
              onPositionChanged: function(mouse) {
                if (!(pressedButtons & Qt.LeftButton)) return
                var p = mapToItem(editOverlay, mouse.x, mouse.y)
                if (!ebox.dragged && Math.abs(mouse.y - pressY) + Math.abs(mouse.x - pressX) > 8) {
                  moved = true
                  editOverlay.grabY = pressY
                  editOverlay.grabX = pressX
                  editOverlay.dragId = ebox.modelData.id
                  root.editSection = ebox.modelData.id
                }
                if (!ebox.dragged) return
                editOverlay.dragY = p.y
                editOverlay.dragX = p.x
                editOverlay.dropHide = ebox.modelData.id !== "bottom" && p.x > editOverlay.width + 12
                editOverlay.dropIndex = editOverlay.dropHide ? -1 : editOverlay.dropAt(p)
              }
              onReleased: if (ebox.dragged) editOverlay.finishDrag()
              onCanceled: { editOverlay.dragId = ""; editOverlay.dropIndex = -1; editOverlay.dropHide = false; editOverlay.dropId = "" }
              onClicked: if (!moved) root.editSection = ebox.modelData.id
            }
          }
        }
      }

      // -- editor rows (used by the settings that open in the column) ------------------
      component OptRow: Item {
        id: orow
        property string label: ""
        property var options: []      // [[value, text], ...]
        property var current
        signal picked(var value)
        Layout.fillWidth: true
        // too narrow for both on one line: the options go under the label
        readonly property bool stacked: olabel.implicitWidth + 12 + oopts.implicitWidth > width
        implicitHeight: stacked ? olabel.implicitHeight + oopts.implicitHeight + 4 : 24
        Text {
          id: olabel
          y: orow.stacked ? 0 : (parent.height - height) / 2
          width: Math.min(implicitWidth, parent.width)
          elide: Text.ElideRight
          textFormat: Text.PlainText; text: orow.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 11
        }
        Row {
          id: oopts
          x: parent.width - width
          y: orow.stacked ? olabel.implicitHeight + 4 : (parent.height - height) / 2
          spacing: 0
          Repeater {
            model: orow.options
            Row {
              required property var modelData
              required property int index
              Text { visible: index > 0; textFormat: Text.PlainText; text: " / "; color: root.dim; font.family: root.fontFamily; font.pixelSize: 11 }
              Text {
                readonly property bool sel: orow.current === modelData[0]
                textFormat: Text.PlainText
                text: modelData[1]
                color: sel ? root.foreground : (optMouse.containsMouse ? root.foreground : root.dim)
                font.family: root.fontFamily; font.pixelSize: 11; font.bold: sel; font.underline: sel
                MouseArea { id: optMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: orow.picked(modelData[0]) }
              }
            }
          }
        }
      }
      // a scroll bar you can grab: drag the thumb, or click the track to jump there
      component DragBar: Item {
        id: db
        property var flick
        property bool horizontal: false
        readonly property real total: horizontal ? flick.contentWidth : flick.contentHeight
        readonly property real view: horizontal ? flick.width : flick.height
        readonly property real len: horizontal ? width : height
        readonly property real thumb: Math.max(24, len * view / Math.max(1, total))
        readonly property real pos: (horizontal ? flick.contentX : flick.contentY) / Math.max(1, total - view) * (len - thumb)
        readonly property bool active: dbMouse.pressed || dbMouse.containsMouse
        visible: total > view + 1
        Rectangle {
          x: db.horizontal ? 0 : (db.width - width) / 2
          y: db.horizontal ? (db.height - height) / 2 : 0
          width: db.horizontal ? db.width : (db.active ? 4 : 2)
          height: db.horizontal ? (db.active ? 4 : 2) : db.height
          radius: 2; color: root.faint; opacity: db.active ? 1 : 0.6
        }
        Rectangle {
          x: db.horizontal ? db.pos : (db.width - width) / 2
          y: db.horizontal ? (db.height - height) / 2 : db.pos
          width: db.horizontal ? db.thumb : (db.active ? 4 : 2)
          height: db.horizontal ? (db.active ? 4 : 2) : db.thumb
          radius: 2; color: root.foreground
          opacity: db.active ? 0.8 : (db.flick.moving ? 0.5 : 0.3)
        }
        MouseArea {
          id: dbMouse
          anchors.fill: parent
          hoverEnabled: true
          preventStealing: true
          cursorShape: Qt.PointingHandCursor
          property real grab: 0
          function to(p) {
            var t = Math.max(0, Math.min(db.len - db.thumb, p - grab))
            var c = t / Math.max(1, db.len - db.thumb) * Math.max(0, db.total - db.view)
            if (db.horizontal) db.flick.contentX = c; else db.flick.contentY = c
          }
          onPressed: function(m) {
            var p = db.horizontal ? m.x : m.y
            grab = (p >= db.pos && p <= db.pos + db.thumb) ? p - db.pos : db.thumb / 2
            to(p)
          }
          onPositionChanged: function(m) { if (pressed) to(db.horizontal ? m.x : m.y) }
          onWheel: function(w) { w.accepted = false }
        }
      }
      // a bar graph of recent readings, newest on the right
      component Spark: Row {
        id: sp
        property var hist: []
        property real peak: 1
        property real barH: 22
        property int n: 24
        height: barH
        spacing: 1
        Repeater {
          model: sp.n
          Rectangle {
            required property int index
            readonly property real v: { var h = sp.hist, i = index - (sp.n - h.length); return i >= 0 ? Math.min(1, h[i] / Math.max(1e-9, sp.peak)) : 0 }
            width: Math.max(1, (sp.width - (sp.n - 1)) / sp.n)
            height: Math.max(1, v * sp.barH)
            y: sp.barH - height
            color: v > 0 ? root.foreground : root.faint
            opacity: 0.35 + v * 0.65
          }
        }
      }
      component StepRow: Item {
        id: srow
        property string label: ""
        property real value: 0
        property real step: 1
        property real min: 0
        property real max: 100
        property string suffix: ""
        signal changed(real value)
        Layout.fillWidth: true
        implicitHeight: 24
        Text { anchors.verticalCenter: parent.verticalCenter; width: parent.width - srowCtl.width - 8; elide: Text.ElideRight; textFormat: Text.PlainText; text: srow.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 11 }
        Row {
          id: srowCtl
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          Text { textFormat: Text.PlainText; text: "−"; color: minusMouse.containsMouse ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 12
            MouseArea { id: minusMouse; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: srow.changed(Math.max(srow.min, srow.value - srow.step)) } }
          Text { textFormat: Text.PlainText; text: srow.value + srow.suffix; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 11; font.bold: true }
          Text { textFormat: Text.PlainText; text: "+"; color: plusMouse.containsMouse ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 12
            MouseArea { id: plusMouse; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: srow.changed(Math.min(srow.max, srow.value + srow.step)) } }
        }
      }
      // Height: fit the content, fit it up to a limit, or a fixed height; the
      // last two scroll what doesn't fit
      component HeightRows: ColumnLayout {
        id: hrows
        property string sid: ""
        property real fullH: 0          // the section's content height now
        readonly property string mode: root.heightMode(sid)
        Layout.fillWidth: true
        spacing: 6
        OptRow {
          label: "Height"
          options: [["auto", "fit content"], ["max", "up to"], ["fixed", "fixed"]]
          current: hrows.mode
          onPicked: function(v) {
            // starting a set height: begin from what it is now
            var px = root.setting(hrows.sid, "heightPx") || root.setting(hrows.sid, "maxH") || Math.round(hrows.fullH / 10) * 10
            root.setHeight(hrows.sid, v, px || 200)
          }
        }
        StepRow {
          visible: hrows.mode !== "auto"
          label: hrows.mode === "fixed" ? "Fixed height" : "Max height"
          value: root.heightPx(hrows.sid); step: 10; min: 40; max: 1200; suffix: " px"
          onChanged: function(v) { root.setHeight(hrows.sid, hrows.mode, v) }
        }
        Text {
          visible: hrows.mode !== "auto"
          Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
          text: hrows.mode === "fixed" ? "Always this tall. Content that doesn't fit scrolls." : "Fits the content up to this height, then scrolls."
          color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
        }
      }
      component EdHeading: Text {
        Layout.fillWidth: true
        Layout.topMargin: 6
        textFormat: Text.PlainText
        color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1
      }

      // -- edit mode, inside the sidebar ----------------------------------------------
      // The header (Save / Cancel / Undo / + Add section / Sidebar) sits at the top of
      // the panel; the picked section's settings open in the column right under it,
      // and the add-section picker slides over the column.
      Item {
        id: editHeader
        visible: win.editHere
        z: 70
        x: sideFlick.x
        y: 16 + win.panelInnerX
        width: sideFlick.width
        height: visible ? ehCol.implicitHeight : 0
        ColumnLayout {
          id: ehCol
          width: parent.width
          spacing: 8
          RowLayout {
            Layout.fillWidth: true
            spacing: 6
            Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: "Edit sidebar"; elide: Text.ElideRight; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 12; font.bold: true }
            Rectangle {
              implicitWidth: cancelText.implicitWidth + 16; implicitHeight: 24; radius: 4
              color: cancelMouse.containsMouse ? root.faint : "transparent"
              border.width: 1; border.color: root.dim
              Text { id: cancelText; anchors.centerIn: parent; textFormat: Text.PlainText; text: "Cancel"; color: cancelMouse.containsMouse ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
              MouseArea { id: cancelMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.cancelEditing() }
            }
            Rectangle {
              implicitWidth: saveText.implicitWidth + 16; implicitHeight: 24; radius: 4
              color: saveMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.8) : root.foreground
              Text { id: saveText; anchors.centerIn: parent; textFormat: Text.PlainText; text: "Save"; color: root.background; font.family: root.fontFamily; font.pixelSize: 10; font.bold: true }
              MouseArea { id: saveMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.saveEditing() }
            }
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: 12
            Text {
              textFormat: Text.PlainText; text: "+ Add section"
              color: root.addOpen || ehAddMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily; font.pixelSize: 11; font.bold: root.addOpen
              MouseArea { id: ehAddMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.addOpen = !root.addOpen }
            }
            Item { Layout.fillWidth: true }
            Text {
              visible: root.editHistory.length > 0
              textFormat: Text.PlainText; text: "Undo"
              color: ehUndoMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily; font.pixelSize: 11
              MouseArea { id: ehUndoMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.undoEdit() }
            }
            // the whole sidebar's settings (width, background, auto-hide, look, profiles)
            Text {
              readonly property bool open: root.editSection === "_sidebar"
              textFormat: Text.PlainText; text: "Sidebar " + (open ? "˅" : "›")
              color: open || ehSideMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily; font.pixelSize: 11; font.bold: open
              MouseArea { id: ehSideMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: { root.addOpen = false; root.editSection = parent.open ? "" : "_sidebar" } }
            }
          }
          Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.faint }
        }
      }

      // the "Add section" picker, over the column
      Rectangle {
        id: addSheet
        visible: win.editHere && root.addOpen
        z: 68
        // covers the outlines too (they sit a little outside the column)
        x: 4
        width: parent.width - 8 - win.panelBorderW
        y: editOverlay.y
        height: sideFlick.y + sideFlick.height - y
        ColumnLayout { anchors.fill: parent; anchors.leftMargin: sideFlick.x - 4; anchors.rightMargin: parent.width - sideFlick.x - sideFlick.width + 4; anchors.topMargin: 4
          Item { Layout.fillWidth: true; Layout.fillHeight: true; id: addSlot } }
        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1)
            ColumnLayout {
              parent: addSlot
              anchors.fill: parent
              visible: root.addOpen
              Layout.fillWidth: true
              Layout.fillHeight: true
              spacing: 8
              RowLayout {
                Layout.fillWidth: true
                Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: "ADD SECTION"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 10; font.letterSpacing: 1; font.bold: true }
                Text {
                  textFormat: Text.PlainText; text: "close ✕"; color: addCloseMouse.containsMouse ? root.foreground : root.dim
                  font.family: root.fontFamily; font.pixelSize: 10
                  MouseArea { id: addCloseMouse; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.addOpen = false }
                }
              }
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                radius: 5
                color: "transparent"
                border.width: 1
                border.color: addInput.activeFocus ? root.dim : root.faint
                TextInput {
                  id: addInput
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
                  verticalAlignment: TextInput.AlignVCenter
                  clip: true
                  color: root.foreground
                  font.family: root.fontFamily; font.pixelSize: 11
                  onTextChanged: root.addQuery = text
                  Keys.onPressed: function(event) {
                    var n = root.addPickable.length
                    if (event.key === Qt.Key_Down) { root.addIndex = n ? (root.addIndex + 1) % n : 0; event.accepted = true }
                    else if (event.key === Qt.Key_Up) { root.addIndex = n ? (root.addIndex - 1 + n) % n : 0; event.accepted = true }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.addPick(root.addPickable[root.addIndex]); event.accepted = true }
                    else if (event.key === Qt.Key_Escape) { if (text) text = ""; else root.addOpen = false; event.accepted = true }
                  }
                  Connections {
                    target: root
                    function onAddOpenChanged() { addInput.text = ""; if (root.addOpen) Qt.callLater(function() { addInput.forceActiveFocus() }) }
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !parent.text
                    textFormat: Text.PlainText
                    text: "Search widgets and sections…"
                    color: root.dim; font.family: root.fontFamily; font.pixelSize: 11
                  }
                }
              }
              ListView {
                id: addList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 1
                boundsBehavior: Flickable.StopAtBounds
                model: root.addRows
                delegate: Item {
                  id: arow
                  required property var modelData
                  readonly property int pick: root.addPickable.indexOf(modelData)
                  readonly property bool sel: pick >= 0 && pick === root.addIndex
                  width: addList.width
                  height: modelData.kind === "header" ? 28 : 40
                  Text {
                    visible: arow.modelData.kind === "header"
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 6
                    textFormat: Text.PlainText
                    text: arow.modelData.name
                    color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1
                  }
                  Rectangle {
                    visible: arow.modelData.kind !== "header"
                    anchors.fill: parent
                    radius: 4
                    color: arow.sel ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent"
                    Rectangle { visible: arow.sel; width: 2; height: parent.height - 12; anchors.verticalCenter: parent.verticalCenter; color: root.foreground }
                    ColumnLayout {
                      anchors.fill: parent
                      anchors.leftMargin: 10
                      anchors.rightMargin: 8
                      spacing: 1
                      RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: "+ " + arow.modelData.name; elide: Text.ElideRight
                          color: root.foreground; font.family: root.fontFamily; font.pixelSize: 11; font.bold: arow.sel }
                        Text { textFormat: Text.PlainText; text: (arow.modelData.cat || "").toLowerCase(); color: root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
                      }
                      Text { Layout.fillWidth: true; visible: !!arow.modelData.desc; textFormat: Text.PlainText; text: arow.modelData.desc || ""; elide: Text.ElideRight
                        color: root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
                    }
                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onEntered: if (arow.pick >= 0) root.addIndex = arow.pick
                      onClicked: root.addPick(arow.modelData)
                    }
                  }
                }
              }
              Text {
                visible: root.addPickable.length === 0
                textFormat: Text.PlainText
                text: root.addQuery ? "Nothing matches “" + root.addQuery + "”." : "Everything is already in the sidebar."
                color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
              }
              Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                text: "↑↓ to move · Enter to add · Esc to close. A widget section keeps its panel open in the sidebar."
                color: root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
            }
      }

      // The settings of the section being edited float over the column, so the
      // section stays where it is: under it if there's room, else above it, else
      // along the bottom. At most 420 px tall; longer settings scroll inside.
      // (The whole sidebar's settings open at the top, under the header.)
      Rectangle {
        id: editForm
        readonly property real maxH: 420
        readonly property real areaTop: editOverlay.y + 4
        readonly property real areaBot: sideFlick.y + sideFlick.height
        readonly property var box: editOverlay.boxes[root.editSection] || null
        readonly property real boxTop: box ? editOverlay.y + box.y : areaTop
        readonly property real boxBot: box ? editOverlay.y + box.y + box.h : areaTop
        readonly property real want: Math.min(efCol.implicitHeight + 18 + efHead.height + 15, maxH)
        readonly property real below: areaBot - (boxBot + 8)
        readonly property real above: boxTop - 12 - areaTop     // the outline's label sits on its top edge
        readonly property string place: root.editSection === "_sidebar" || !box ? "top"
          : below >= want ? "below" : above >= want ? "above"
          : Math.max(below, above) >= 140 ? (below >= above ? "below" : "above") : "bottom"
        visible: win.editHere && root.editSection !== "" && editOverlay.dragId === ""
        z: 66
        x: sideFlick.x - 4
        width: sideFlick.width + 8
        height: place === "below" ? Math.min(want, below) : place === "above" ? Math.min(want, above)
              : place === "top" ? Math.min(want, areaBot - areaTop) : Math.min(want, (areaBot - areaTop) * 0.6)
        y: place === "below" ? boxBot + 8 : place === "above" ? boxTop - 12 - height
         : place === "top" ? areaTop : areaBot - height
        onVisibleChanged: efFlick.contentY = 0
        Connections { target: root; function onEditSectionChanged() { efFlick.contentY = 0 } }
        radius: 8
        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 1)
        border.width: 1
        border.color: root.faint
        Rectangle { anchors.fill: parent; radius: 8; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05) }
        // clicks and scrolling here stay here (not on the outlines or the column underneath)
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: function(w) { w.accepted = true } }
        // the section's name, and its own Cancel / Save (both close it)
        RowLayout {
          id: efHead
          x: 10; y: 8
          width: parent.width - 20
          height: 24
          spacing: 6
          Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: root.editSectionLabel; elide: Text.ElideRight
            color: root.foreground; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1; font.bold: true }
          Rectangle {
            implicitWidth: efCancelText.implicitWidth + 14; implicitHeight: 22; radius: 4
            color: efCancelMouse.containsMouse ? root.faint : "transparent"
            border.width: 1; border.color: root.dim
            Text { id: efCancelText; anchors.centerIn: parent; textFormat: Text.PlainText; text: "Cancel"; color: efCancelMouse.containsMouse ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            MouseArea { id: efCancelMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeForm(false) }
          }
          Rectangle {
            implicitWidth: efSaveText.implicitWidth + 14; implicitHeight: 22; radius: 4
            color: efSaveMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.8) : root.foreground
            Text { id: efSaveText; anchors.centerIn: parent; textFormat: Text.PlainText; text: "Save"; color: root.background; font.family: root.fontFamily; font.pixelSize: 10; font.bold: true }
            MouseArea { id: efSaveMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeForm(true) }
          }
        }
        Rectangle { x: 1; y: efHead.y + efHead.height + 6; width: parent.width - 2; height: 1; color: root.faint }
        Flickable {
          id: efFlick
          anchors.fill: parent
          anchors.margins: 1
          anchors.topMargin: efHead.y + efHead.height + 7
          contentWidth: width
          contentHeight: efCol.implicitHeight + 18
          interactive: contentHeight > height + 1
          boundsBehavior: Flickable.StopAtBounds
          clip: true
        ColumnLayout {
          id: efCol
          x: 9; y: 9
          width: efFlick.width - 18
          spacing: 6
          readonly property bool secMode: root.editSection !== "" && root.editSection !== "_sidebar"
            readonly property var onOff: [[true, "on"], [false, "off"]]

            // CLOCK
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "clock"
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Show in sidebar"; options: parent.parent.onOff; current: root.setting("clock", "show"); onPicked: function(v) { root.setSetting("clock", "show", v) } }
              OptRow { label: "Format"; options: [[true, "24h"], [false, "12h"]]; current: root.setting("clock", "h24"); onPicked: function(v) { root.setSetting("clock", "h24", v) } }
              OptRow { label: "Date"; options: parent.parent.onOff; current: root.setting("clock", "date"); onPicked: function(v) { root.setSetting("clock", "date", v) } }
              OptRow { label: "Seconds"; options: parent.parent.onOff; current: root.setting("clock", "seconds"); onPicked: function(v) { root.setSetting("clock", "seconds", v) } }
              OptRow { label: "Calendar on click"; options: parent.parent.onOff; current: root.setting("clock", "calendar"); onPicked: function(v) { root.setSetting("clock", "calendar", v) } }
            }
            // STATUS (the row under the clock by default)
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "status"
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Show in sidebar"; options: parent.parent.onOff; current: root.setting("status", "show"); onPicked: function(v) { root.setSetting("status", "show", v) } }
              OptRow { label: "Indicators"; options: parent.parent.onOff; current: root.setting("status", "indicators"); onPicked: function(v) { root.setSetting("status", "indicators", v) } }
              // which indicators (click to turn one on or off)
              Flow {
                visible: root.setting("status", "indicators") !== false && root.indicatorOptions.length > 0
                Layout.fillWidth: true
                Layout.leftMargin: 10
                spacing: 10
                Repeater {
                  model: root.indicatorOptions
                  Text {
                    required property var modelData
                    readonly property bool on: root.indicatorOn(modelData.value)
                    textFormat: Text.PlainText
                    text: String(modelData.label || modelData.value).toLowerCase()
                    color: on ? root.foreground : (indMouse.containsMouse ? root.foreground : root.dim)
                    font.family: root.fontFamily; font.pixelSize: 11; font.bold: on; font.underline: on
                    MouseArea { id: indMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleIndicator(parent.modelData.value) }
                  }
                }
              }
              OptRow { visible: root.setting("status", "indicators") !== false; label: "Inactive indicators"; options: [[false, "on hover"], [true, "always"]]; current: root.setting("status", "indicatorsAlways"); onPicked: function(v) { root.setSetting("status", "indicatorsAlways", v) } }
              OptRow { label: "Update available"; options: parent.parent.onOff; current: root.setting("status", "update"); onPicked: function(v) { root.setSetting("status", "update", v) } }
              OptRow { label: "Keyboard layout"; options: parent.parent.onOff; current: root.setting("status", "keyboard"); onPicked: function(v) { root.setSetting("status", "keyboard", v) } }
              OptRow { visible: root.batteryPresent; label: "Battery"; options: parent.parent.onOff; current: root.setting("status", "battery"); onPicked: function(v) { root.setSetting("status", "battery", v) } }
              Text { Layout.fillWidth: true; Layout.topMargin: 4; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: "Right under the clock it sits tight against it; drag it anywhere else in the sidebar."; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }
            // SYSTEM
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "system"
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Show in sidebar"; options: parent.parent.onOff; current: root.setting("system", "show"); onPicked: function(v) { root.setSetting("system", "show", v) } }
              EdHeading { text: "DATA POINTS" }
              // one chip per reading, in layout order, scrolling sideways;
              // pick one (here or in the section) to set it up
              Item {
                Layout.fillWidth: true
                Layout.preferredHeight: dpStrip.height + (dpStrip.contentWidth > dpStrip.width ? 12 : 0)
                Flickable {
                  id: dpStrip
                  width: parent.width; height: 40
                  contentWidth: dpRow.implicitWidth; contentHeight: height
                  flickableDirection: Flickable.HorizontalFlick
                  boundsBehavior: Flickable.StopAtBounds
                  clip: true
                  function reveal(item) {
                    var x = item.x
                    if (x < contentX) contentX = x
                    else if (x + item.width > contentX + width) contentX = Math.min(contentWidth - width, x + item.width - width)
                  }
                  Row {
                    id: dpRow
                    spacing: 6
                    Repeater {
                      model: root.statIds.length
                      Rectangle {
                        id: chip
                        required property int index
                        readonly property var avail: root.systemItems.filter(function(it) { return it.avail })
                        readonly property var modelData: avail[index] || ({ id: "", show: false, w: 5, h: 1, style: "value" })
                        visible: index < avail.length
                        readonly property bool sel: root.systemPick === modelData.id
                        width: chipCol.implicitWidth + 18; height: 40
                        radius: 5
                        color: sel ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10) : "transparent"
                        border.width: 1
                        border.color: sel ? root.foreground : (chipMouse.containsMouse ? root.dim : root.faint)
                        opacity: modelData.show ? 1 : 0.5
                        onSelChanged: if (sel) dpStrip.reveal(chip)
                        Column {
                          id: chipCol
                          anchors.centerIn: parent
                          spacing: 2
                          Text { textFormat: Text.PlainText; text: root.statShort[chip.modelData.id] || ""; color: chip.sel ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1 }
                          Text { textFormat: Text.PlainText
                            text: chip.modelData.show ? (chip.modelData.w === 1 ? "full" : "1/" + chip.modelData.w) + " × " + chip.modelData.h + " · " + (chip.modelData.style === "value" ? "number" : chip.modelData.style) : "off"
                            color: root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
                        }
                        MouseArea { id: chipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.systemPick = chip.modelData.id }
                      }
                    }
                  }
                  // the mouse wheel scrolls the strip sideways
                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: function(w) {
                      if (dpStrip.contentWidth <= dpStrip.width) { w.accepted = false; return }
                      var d = w.angleDelta.x !== 0 ? -w.angleDelta.x : -w.angleDelta.y
                      dpStrip.contentX = Math.max(0, Math.min(dpStrip.contentWidth - dpStrip.width, dpStrip.contentX + d / 2))
                    }
                  }
                }
                DragBar { flick: dpStrip; horizontal: true; anchors.top: dpStrip.bottom; width: dpStrip.width; height: 12 }
              }
              EdHeading { text: root.statLong[root.systemPick].toUpperCase() }
              OptRow { label: "Show"; options: parent.parent.onOff
                current: (root.systemItems.filter(function(it) { return it.id === root.systemPick })[0] || {}).show
                onPicked: function(v) { root.setSystemItem(root.systemPick, "show", v) } }
              OptRow { label: "Width"; options: [[5, "1/5"], [3, "1/3"], [2, "1/2"], [1, "full"]]
                current: (root.systemItems.filter(function(it) { return it.id === root.systemPick })[0] || {}).w
                onPicked: function(v) { root.setSystemItem(root.systemPick, "w", v) } }
              OptRow { label: "Height"; options: [[1, "1 row"], [2, "2"], [3, "3"]]
                current: (root.systemItems.filter(function(it) { return it.id === root.systemPick })[0] || {}).h
                onPicked: function(v) { root.setSystemItem(root.systemPick, "h", v) } }
              OptRow { label: "Style"; options: [["value", "number"], ["bar", "bar"], ["graph", "graph"]]
                current: (root.systemItems.filter(function(it) { return it.id === root.systemPick })[0] || {}).style
                onPicked: function(v) { root.setSystemItem(root.systemPick, "style", v) } }
              OptRow { label: "Move"; options: [["-1", "‹ earlier"], ["1", "later ›"]]; current: ""
                onPicked: function(v) { root.nudgeSystemItem(root.systemPick, Number(v)) } }
              Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                text: "Or drag a reading in the section to either side of another one; the lit bar shows where it lands."
                color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
              EdHeading { text: "SECTION" }
              StepRow { label: "Refresh every"; value: root.setting("system", "refresh"); min: 1; max: 10; suffix: " s"; onChanged: function(v) { root.setSetting("system", "refresh", v) } }
            }
            // WORKSPACES
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "workspaces"
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Show in sidebar"; options: parent.parent.onOff; current: root.setting("workspaces", "show"); onPicked: function(v) { root.setSetting("workspaces", "show", v) } }
              StepRow { label: "Always show"; value: root.setting("workspaces", "count"); min: 1; max: 10; onChanged: function(v) { root.setSetting("workspaces", "count", v) } }
              OptRow { label: "Style"; options: [["numbers", "numbers"], ["dots", "dots"]]; current: root.setting("workspaces", "style"); onPicked: function(v) { root.setSetting("workspaces", "style", v) } }
              OptRow { label: "Scroll to switch"; options: parent.parent.onOff; current: root.setting("workspaces", "scroll"); onPicked: function(v) { root.setSetting("workspaces", "scroll", v) } }
              Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: "Workspaces past that appear while they have windows."; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }
            // SEARCH
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "search"
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Show in sidebar"; options: parent.parent.onOff; current: root.setting("search", "show"); onPicked: function(v) { root.setSetting("search", "show", v) } }
              OptRow { label: "CLIP button"; options: parent.parent.onOff; current: root.setting("search", "clip"); onPicked: function(v) { root.setSetting("search", "clip", v) } }
              Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: "Super+Space opens the search either way."; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }
            // APP LIST
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "apps"
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Running apps below pins"; options: parent.parent.onOff; current: root.setting("apps", "running"); onPicked: function(v) { root.setSetting("apps", "running", v) } }
              OptRow { label: "Group windows per app"; options: parent.parent.onOff; current: root.setting("apps", "group"); onPicked: function(v) { root.setSetting("apps", "group", v) } }
              OptRow { label: "Row height"; options: [[true, "compact"], [false, "comfortable"]]; current: root.setting("apps", "compact"); onPicked: function(v) { root.setSetting("apps", "compact", v) } }
              OptRow { label: "Open indicator"; options: [["bar", "bar + dot"], ["dot", "dot"], ["none", "none"]]; current: root.setting("apps", "indicator"); onPicked: function(v) { root.setSetting("apps", "indicator", v) } }
              OptRow { label: "App icons"; options: parent.parent.onOff; current: root.setting("apps", "icons"); onPicked: function(v) { root.setSetting("apps", "icons", v) } }
              OptRow { label: "Window title hint"; options: parent.parent.onOff; current: root.setting("apps", "hints"); onPicked: function(v) { root.setSetting("apps", "hints", v) } }
              OptRow { label: "Status symbols in hints"; options: [[true, "show"], [false, "hide"]]; current: root.setting("apps", "hintSymbols"); onPicked: function(v) { root.setSetting("apps", "hintSymbols", v) } }
              OptRow { label: "Unread badges"; options: parent.parent.onOff; current: root.setting("apps", "badges"); onPicked: function(v) { root.setSetting("apps", "badges", v) } }
              OptRow { label: "Workspace number"; options: parent.parent.onOff; current: root.setting("apps", "workspace"); onPicked: function(v) { root.setSetting("apps", "workspace", v) } }
              Text { Layout.fillWidth: true; Layout.topMargin: 4; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: "Drag apps in the list to reorder or pin them; right-click to unpin."; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }
            // a widget section
            ColumnLayout {
              visible: efCol.secMode && root.editSection.indexOf("w:") === 0
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Show in sidebar"; options: parent.parent.onOff; current: root.setting(root.editSection, "show") !== false; onPicked: function(v) { root.setSetting(root.editSection, "show", v) } }
              OptRow { label: "Title"; options: parent.parent.onOff; current: root.setting(root.editSection, "title") === true; onPicked: function(v) { root.setSetting(root.editSection, "title", v) } }
              OptRow { label: "Fit"; options: [["squeeze", "squeeze"], ["shrink", "shrink"]]; current: root.setting(root.editSection, "fit") === "shrink" ? "shrink" : "squeeze"; onPicked: function(v) { root.setSetting(root.editSection, "fit", v) } }
              HeightRows { sid: root.editSection; fullH: win.sectionFullH(root.editSection) }
              // cut blank space (or unwanted bits) off the top / bottom; also by dragging the outline's edge handles
              StepRow { label: "Trim top"; value: root.cropOf(root.editSection, "top"); step: 4; min: 0; max: 600; suffix: " px"; onChanged: function(v) { root.saveCrop(root.editSection, v, root.cropOf(root.editSection, "bottom")) } }
              StepRow { label: "Trim bottom"; value: root.cropOf(root.editSection, "bottom"); step: 4; min: 0; max: 600; suffix: " px"; onChanged: function(v) { root.saveCrop(root.editSection, root.cropOf(root.editSection, "top"), v) } }
              Text {
                visible: root.cropOf(root.editSection, "top") > 0 || root.cropOf(root.editSection, "bottom") > 0
                textFormat: Text.PlainText; text: "Reset trim"
                color: resetTrimMouse.containsMouse ? root.foreground : root.dim
                font.family: root.fontFamily; font.pixelSize: 10
                MouseArea { id: resetTrimMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.saveCrop(root.editSection, 0, 0) }
              }
              // the widget's own options (from its plugin's settings schema)
              EdHeading {
                readonly property var schema: (function() {
                  var w = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
                  var meta = w && w[root.widgetOf(root.editSection)] ? (w[root.widgetOf(root.editSection)].metadata || {}) : {}
                  var sc = meta.schema || (meta.barWidget && meta.barWidget.schema) || []
                  return Array.isArray(sc) ? sc.filter(function(f) { return f && (f.type === "boolean" || f.type === "enum" || f.type === "integer") }) : []
                })()
                visible: schema.length > 0
                text: "WIDGET OPTIONS"
                id: optHeading
              }
              Repeater {
                model: optHeading.schema
                Loader {
                  required property var modelData
                  Layout.fillWidth: true
                  readonly property var opts: root.setting(root.editSection, "opts") || {}
                  readonly property var cur: opts[modelData.key] !== undefined ? opts[modelData.key] : modelData.defaultValue
                  function set(v) { var o = JSON.parse(JSON.stringify(opts)); o[modelData.key] = v; root.setSetting(root.editSection, "opts", o) }
                  sourceComponent: modelData.type === "integer" ? optStep : optPick
                  Component {
                    id: optPick
                    OptRow {
                      label: modelData.label || modelData.key
                      options: modelData.type === "boolean" ? [[true, "on"], [false, "off"]] : (modelData.options || []).map(function(o) { return [o, String(o)] })
                      current: cur
                      onPicked: function(v) { set(v) }
                    }
                  }
                  Component {
                    id: optStep
                    StepRow {
                      label: modelData.label || modelData.key
                      value: Number(cur || 0)
                      min: modelData.min !== undefined ? modelData.min : 0
                      max: modelData.max !== undefined ? modelData.max : 100
                      step: modelData.step || 1
                      onChanged: function(v) { set(v) }
                    }
                  }
                }
              }
              // the blocks its panel is made of, found by scanning it
              EdHeading {
                id: partsHeading
                readonly property var parts: root.widgetParts[root.editSection] || []
                readonly property var hidden: { var v = root.setting(root.editSection, "hiddenParts"); return Array.isArray(v) ? v : [] }
                visible: parts.length > 0
                text: "PARTS"
              }
              Repeater {
                model: partsHeading.parts
                OptRow {
                  required property var modelData
                  Layout.leftMargin: modelData.depth * 12
                  label: (modelData.depth > 0 ? "› " : "") + modelData.label
                  options: [[true, "on"], [false, "off"]]
                  current: partsHeading.hidden.indexOf(modelData.path) === -1
                  onPicked: function(v) { if (v !== (partsHeading.hidden.indexOf(modelData.path) === -1)) root.togglePart(root.editSection, modelData.path) }
                }
              }
              Text {
                visible: partsHeading.parts.length > 0
                Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                text: "Found by scanning the widget's panel. A part that's only on another tab shows up once that tab is open."
                color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
              }
              Text {
                visible: partsHeading.hidden.length > 0
                textFormat: Text.PlainText; text: "Show all parts again"
                color: showAllMouse.containsMouse ? root.foreground : root.dim
                font.family: root.fontFamily; font.pixelSize: 10
                MouseArea { id: showAllMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setSetting(root.editSection, "hiddenParts", []) }
              }
              Text {
                Layout.topMargin: 4
                textFormat: Text.PlainText; text: "Remove this section"
                color: remMouse.containsMouse ? root.urgent : root.dim
                font.family: root.fontFamily; font.pixelSize: 11
                MouseArea { id: remMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeSection(root.editSection) }
              }
              Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                text: "The widget's own panel, kept open here. Squeeze reflows it to the sidebar's width; shrink scales it down whole (better for fixed-width panels like the calendar)."
                color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }
            // MEDIA
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "media"
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Show in sidebar"; options: parent.parent.onOff; current: root.setting("media", "show"); onPicked: function(v) { root.setSetting("media", "show", v) } }
              OptRow { label: "When nothing plays"; options: [[true, "keep"], [false, "hide"]]; current: root.setting("media", "idle"); onPicked: function(v) { root.setSetting("media", "idle", v) } }
            }
            // NOTIFICATIONS
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "notifications"
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Show in sidebar"; options: parent.parent.onOff; current: root.setting("notifications", "show"); onPicked: function(v) { root.setSetting("notifications", "show", v) } }
              StepRow { label: "How many"; value: root.setting("notifications", "count"); min: 1; max: 10; onChanged: function(v) { root.setSetting("notifications", "count", v) } }
              Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: "The latest from Omarchy's notification history. \"silence\" turns on Do not disturb."; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }
            // TRAY
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "tray"
              Layout.fillWidth: true
              spacing: 6
              OptRow { label: "Show in sidebar"; options: parent.parent.onOff; current: root.setting("tray", "show"); onPicked: function(v) { root.setSetting("tray", "show", v) } }
              OptRow { label: "Align"; options: [["left", "left"], ["right", "right"]]; current: root.setting("tray", "align"); onPicked: function(v) { root.setSetting("tray", "align", v) } }
              EdHeading { visible: SystemTray.items.values.length > 0; text: "TRAY ICONS" }
              Repeater {
                model: SystemTray.items
                OptRow {
                  required property var modelData
                  label: root.trayLabel(modelData)
                  options: [[true, "on"], [false, "off"]]
                  current: !root.isHidden("tray:" + modelData.id)
                  onPicked: function(v) { root.setHidden("tray:" + modelData.id, !v) }
                }
              }
              Text { Layout.fillWidth: true; Layout.topMargin: 4; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: "A tray icon's menu opens just above the tray."; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }
            // PLUGINS (the bottom row)
            ColumnLayout {
              visible: efCol.secMode && root.editSection === "bottom"
              Layout.fillWidth: true
              spacing: 6
              id: bottomForm
              readonly property bool wsMode: root.setting("bottom", "right") === "workspaces"
              OptRow { label: "Right side"; options: [["plugins", "plugins"], ["workspaces", "workspaces"]]; current: root.setting("bottom", "right"); onPicked: function(v) { root.setSetting("bottom", "right", v) } }
              // -- workspaces on the right: the same settings as the workspaces section
              EdHeading { visible: bottomForm.wsMode; text: "WORKSPACES" }
              StepRow { visible: bottomForm.wsMode; label: "Always show"; value: root.setting("workspaces", "count"); min: 1; max: 10; onChanged: function(v) { root.setSetting("workspaces", "count", v) } }
              OptRow { visible: bottomForm.wsMode; label: "Style"; options: [["numbers", "numbers"], ["dots", "dots"]]; current: root.setting("workspaces", "style"); onPicked: function(v) { root.setSetting("workspaces", "style", v) } }
              OptRow { visible: bottomForm.wsMode; label: "Scroll to switch"; options: parent.parent.onOff; current: root.setting("workspaces", "scroll"); onPicked: function(v) { root.setSetting("workspaces", "scroll", v) } }
              OptRow { visible: bottomForm.wsMode; label: "Also as a section"; options: parent.parent.onOff; current: root.setting("workspaces", "show"); onPicked: function(v) { root.setSetting("workspaces", "show", v) } }
              Text { visible: bottomForm.wsMode; Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: "These settings are shared with the workspaces section. Plugin icons are hidden while workspaces take the right side; their keyboard shortcuts still open their panels."; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
              // -- plugins on the right
              EdHeading { visible: !bottomForm.wsMode; text: "PLUGINS" }
              OptRow { visible: !bottomForm.wsMode; label: "All plugin icons"; options: parent.parent.onOff; current: root.setting("bottom", "plugins"); onPicked: function(v) { root.setSetting("bottom", "plugins", v) } }
              // each plugin in the row: on or off (the same switch as quick settings › Sidebar)
              EdHeading { visible: !bottomForm.wsMode && root.pluginEntries.length > 0; text: "IN THE ROW" }
              Repeater {
                model: bottomForm.wsMode ? [] : root.pluginEntries
                OptRow {
                  required property var modelData
                  label: root.widgetName(modelData.id)
                  options: [[true, "on"], [false, "off"]]
                  current: !root.isHidden(modelData.id)
                  onPicked: function(v) { root.setHidden(modelData.id, !v) }
                }
              }
              Text {
                visible: !bottomForm.wsMode && root.pluginEntries.length > 0 && root.setting("bottom", "plugins") === false
                Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
                text: "All plugin icons are off, so none of these show until that's on again."
                color: root.urgent; font.family: root.fontFamily; font.pixelSize: 10
              }
              Text { visible: !bottomForm.wsMode; Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText; text: "The first icon is the sidebar's own: click it for quick settings. To show a plugin's panel in the sidebar instead, add it as a section (+ add section)."; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }

            // every section but the app list and the bottom row: its width on the grid
            EdHeading { visible: efCol.secMode; text: "LAYOUT" }
            OptRow {
              visible: efCol.secMode
              label: "Width"
              options: [[3, "1/4"], [4, "1/3"], [6, "1/2"], [8, "2/3"], [9, "3/4"], [12, "full"]]
              current: [3, 4, 6, 8, 9, 12].indexOf(root.setting(root.editSection, "span")) !== -1 ? root.setting(root.editSection, "span") : 12
              onPicked: function(v) { root.setSetting(root.editSection, "span", v) }
            }
            Text {
              visible: efCol.secMode
              Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
              text: root.setting(root.editSection, "pinned") === true ? "Pinned sections take the full width, without card or padding, once editing ends."
                    : "Sections that fit side by side share a row; drag one to either side of another to pair them."
              color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
            }
            OptRow {
              visible: efCol.secMode
              label: "Align in row"
              options: [["top", "top"], ["middle", "middle"], ["bottom", "bottom"]]
              current: root.setting(root.editSection, "align") || "top"
              onPicked: function(v) { root.setSetting(root.editSection, "align", v) }
            }
            OptRow {
              visible: efCol.secMode
              label: "Background"
              options: [[false, "none"], [true, "card"]]
              current: root.setting(root.editSection, "card") === true
              onPicked: function(v) { root.setSetting(root.editSection, "card", v) }
            }
            StepRow {
              visible: efCol.secMode
              label: "Padding"
              value: { var v = root.setting(root.editSection, "pad"); return typeof v === "number" ? v : (root.setting(root.editSection, "card") === true ? 10 : 0) }
              step: 2; min: 0; max: 32; suffix: " px"
              onChanged: function(v) { root.setSetting(root.editSection, "pad", v) }
            }
            // the app list: height (it isn't trimmed, so it has its own rows)
            HeightRows { visible: efCol.secMode && root.editSection === "apps"; sid: "apps"; fullH: appList.contentHeight }
            Text {
              visible: efCol.secMode && root.editSection === "apps"
              Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
              text: "Fit content also stretches the list down to the bottom row."
              color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
            }
            Text {
              visible: efCol.secMode && root.editSection === "bottom"
              Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
              text: "The bottom row is one row of icons, so it has no height setting."
              color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
            }
            // built-in sections: height (widget sections have it in their own panel above)
            HeightRows { visible: efCol.secMode && win.isTrimmable(root.editSection) && win.isSizable(root.editSection); sid: root.editSection; fullH: win.sectionFullH(root.editSection) }
            // built-in sections: trim (widget sections have it in their own panel above)
            StepRow { visible: efCol.secMode && win.isTrimmable(root.editSection); label: "Trim top"; value: root.cropOf(root.editSection, "top"); step: 2; min: 0; max: 400; suffix: " px"; onChanged: function(v) { root.saveCrop(root.editSection, v, root.cropOf(root.editSection, "bottom")) } }
            StepRow { visible: efCol.secMode && win.isTrimmable(root.editSection); label: "Trim bottom"; value: root.cropOf(root.editSection, "bottom"); step: 2; min: 0; max: 400; suffix: " px"; onChanged: function(v) { root.saveCrop(root.editSection, root.cropOf(root.editSection, "top"), v) } }
            Text {
              visible: efCol.secMode && win.isTrimmable(root.editSection) && (root.cropOf(root.editSection, "top") > 0 || root.cropOf(root.editSection, "bottom") > 0)
              textFormat: Text.PlainText; text: "Reset trim"
              color: resetTrim2Mouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily; font.pixelSize: 10
              MouseArea { id: resetTrim2Mouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.saveCrop(root.editSection, 0, 0) }
            }
            // every section but the app list can be pinned
            OptRow {
              visible: efCol.secMode && root.editSection !== "apps"
              label: "Pin in position"
              options: [[true, "on"], [false, "off"]]
              current: root.setting(root.editSection, "pinned") === true
              onPicked: function(v) { root.setSetting(root.editSection, "pinned", v) }
            }
            Text {
              visible: efCol.secMode && root.editSection !== "apps" && root.setting(root.editSection, "pinned") === true
              Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
              text: "Stays in view when the sidebar scrolls; the rest scrolls behind it. (Pins rest while editing.)"
              color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
            }
            Text {
              visible: efCol.secMode && root.editSection !== "bottom" && root.editSection.indexOf("w:") !== 0
              Layout.topMargin: 4
              textFormat: Text.PlainText; text: "Remove this section"
              color: bRemMouse.containsMouse ? root.urgent : root.dim
              font.family: root.fontFamily; font.pixelSize: 11
              MouseArea { id: bRemMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.removeSection(root.editSection) }
            }
            Text {
              visible: efCol.secMode
              textFormat: Text.PlainText; text: "Reset this section"; color: resetMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily; font.pixelSize: 10
              MouseArea { id: resetMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.resetSection(root.editSection) }
            }

            // THE WHOLE SIDEBAR
            ColumnLayout {
              visible: root.editSection === "_sidebar"
              Layout.fillWidth: true
              spacing: 6
            StepRow { label: "Width"; value: root.sidebarWidth; step: 20; min: 220; max: 400; suffix: " px"; onChanged: function(v) { root.setSetting("", "width", v) } }
            OptRow { label: "Background"; options: [["solid", "solid"], ["glass", "see-through"]]; current: root.setting("general", "background"); onPicked: function(v) { root.setSetting("general", "background", v) } }
            OptRow { label: "Auto-hide"; options: [[true, "on"], [false, "off"]]; current: root.setting("general", "autohide"); onPicked: function(v) { root.setSetting("general", "autohide", v) } }
            OptRow { visible: root.setting("general", "autohide") === true; Layout.leftMargin: 12; label: "› When it appears"; options: [["float", "over windows"], ["push", "push windows"]]; current: root.setting("general", "autohideMode"); onPicked: function(v) { root.setSetting("general", "autohideMode", v) } }
            OptRow { visible: root.setting("general", "autohide") === true; Layout.leftMargin: 12; label: "› Hidden edge"; options: [["show", "show"], ["hide", "hide"]]; current: root.setting("general", "autohideEdge"); onPicked: function(v) { root.setSetting("general", "autohideEdge", v) } }
            // the windows' look (Hyprland), not just the sidebar's
            EdHeading { text: "CORNERS & BORDERS" }
            OptRow { label: "Apply to"; options: [["windows", "windows"], ["sidebar", "sidebar"], ["both", "both"]]; current: root.lookScope; onPicked: function(v) { root.setSetting("general", "lookScope", v) } }
            OptRow { label: "Corners"; options: [[0, "square"], [6, "6"], [10, "10"], [16, "16"]]; current: Number(root.setting("general", "windowRounding")); onPicked: function(v) { root.setSetting("general", "windowRounding", v) } }
            OptRow { label: "Borders"; options: [[0, "none"], [1, "1"], [2, "2"], [3, "3"]]; current: Number(root.setting("general", "windowBorder")); onPicked: function(v) { root.setSetting("general", "windowBorder", v) } }
            Text {
              Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.PlainText
              text: root.lookScope === "windows" ? "Your windows' corners and borders."
                  : root.lookScope === "sidebar" ? "The sidebar is drawn like a window, in your theme's border colour; windows keep your Hyprland config's look."
                  : "Windows and the sidebar alike, in your theme's border colour."
              color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
            }
            // profiles: saved layouts to switch between
            EdHeading { text: "PROFILES" }
            Flow {
              Layout.fillWidth: true
              spacing: 12
              Repeater {
                model: Object.keys(root.profiles).sort()
                Row {
                  required property var modelData
                  spacing: 4
                  Text { textFormat: Text.PlainText; text: modelData; color: prLoad.containsMouse ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 11; font.underline: prLoad.containsMouse
                    MouseArea { id: prLoad; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.loadProfile(modelData) } }
                  Text { textFormat: Text.PlainText; text: "✕"; color: prDel.containsMouse ? root.urgent : root.faint; font.family: root.fontFamily; font.pixelSize: 9
                    MouseArea { id: prDel; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteProfile(modelData) } }
                }
              }
              Text {
                visible: !root.profileNaming
                textFormat: Text.PlainText; text: "+ save current as…"; color: prNew.containsMouse ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 11
                MouseArea { id: prNew; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.profileNaming = true }
              }
            }
            Rectangle {
              visible: root.profileNaming
              Layout.fillWidth: true
              Layout.preferredHeight: 26
              radius: 4; color: "transparent"; border.width: 1; border.color: root.dim
              TextInput {
                id: profileInput
                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: 11; clip: true
                Keys.onReturnPressed: { root.saveProfile(text); text = ""; root.profileNaming = false }
                Keys.onEnterPressed: { root.saveProfile(text); text = ""; root.profileNaming = false }
                Keys.onEscapePressed: { text = ""; root.profileNaming = false }
                Connections { target: root; function onProfileNamingChanged() { if (root.profileNaming) Qt.callLater(function() { profileInput.forceActiveFocus() }) } }
                Text { anchors.verticalCenter: parent.verticalCenter; visible: !parent.text; text: "Profile name, then Enter"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
              }
            }
            RowLayout {
              Layout.fillWidth: true
              Layout.topMargin: 4
              Text {
                textFormat: Text.PlainText; text: "Reset all"; color: resetAllMouse.containsMouse ? root.urgent : root.dim
                font.family: root.fontFamily; font.pixelSize: 10
                MouseArea { id: resetAllMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.resetAll() }
              }
              Item { Layout.fillWidth: true }
              Text {
                visible: JSON.stringify(root.sectionOrder) !== JSON.stringify(root.defaultOrder)
                textFormat: Text.PlainText; text: "Reset order"; color: resetOrderMouse.containsMouse ? root.foreground : root.dim
                font.family: root.fontFamily; font.pixelSize: 10
                MouseArea { id: resetOrderMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setSetting("", "order", root.defaultOrder) }
              }
            }
            }
        }
        }
        // scroll bar while the settings don't all fit: drag it, or click along it
        DragBar { flick: efFlick; x: parent.width - 11; y: efFlick.y + 4; width: 10; height: efFlick.height - 8 }
      }


      // The sections scroll (mouse wheel) when they don't all fit. Mouse drags
      // don't move it, so dragging apps and sections keeps working.
      Flickable {
        id: sideFlick
        anchors.fill: parent
        anchors.leftMargin: 16 + win.panelInnerX
        anchors.topMargin: 16 + win.panelInnerX + (win.editHere ? editHeader.height + 16 : 0)
        anchors.rightMargin: 16 + win.panelBorderW
        anchors.bottomMargin: 10 + win.panelInnerX
        contentWidth: width
        contentHeight: mainCol.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        acceptedButtons: Qt.NoButton
        readonly property bool overflowing: contentHeight > height + 1
        onOverflowingChanged: if (!overflowing) contentY = 0
      }
      // a thin scroll indicator on the edge while it overflows
      Rectangle {
        visible: sideFlick.overflowing
        z: 4
        x: parent.width - 4
        width: 2
        radius: 1
        y: sideFlick.y + sideFlick.contentY / Math.max(1, sideFlick.contentHeight) * sideFlick.height
        height: Math.max(20, sideFlick.height * sideFlick.height / Math.max(1, sideFlick.contentHeight))
        color: root.foreground
        opacity: sideFlick.moving ? 0.5 : 0.18
        Behavior on opacity { NumberAnimation { duration: 200 } }
      }

      ColumnLayout {
        id: mainCol
        parent: sideFlick.contentItem
        width: sideFlick.width
        height: Math.max(sideFlick.height, implicitHeight)
        spacing: 14

        // -- clock --------------------------------------------------------
        RowLayout {
          id: secClock
          visible: root.sectionShown("clock")
          opacity: root.sectionOpacity("clock")
          Layout.fillWidth: true
          Text {
            textFormat: Text.PlainText
            text: Qt.formatTime(clock.date, root.setting("clock", "h24") ? (root.setting("clock", "seconds") ? "HH:mm:ss" : "HH:mm")
                                                                        : (root.setting("clock", "seconds") ? "h:mm:ss AP" : "h:mm AP"))
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: 30
            font.weight: Font.Light
          }
          Item { Layout.fillWidth: true }
          Text {
            visible: root.setting("clock", "date")
            Layout.alignment: Qt.AlignBottom
            Layout.bottomMargin: 5
            textFormat: Text.PlainText
            text: root.clockAlt ? (Qt.locale(Commons.I18n.formatLocale).toString(clock.date, "d MMM").toUpperCase() + "  W" + root.isoWeek(clock.date))
                                : Qt.locale(Commons.I18n.formatLocale).toString(clock.date, "ddd d MMM").toUpperCase()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: 11
            font.letterSpacing: 1
          }
          // click: calendar; right-click: date with the week number
          HoverHandler { cursorShape: root.setting("clock", "calendar") !== false ? Qt.PointingHandCursor : Qt.ArrowCursor }
          TapHandler {
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onTapped: function(point, button) {
              if (button === Qt.RightButton) root.clockAlt = !root.clockAlt
              else if (root.setting("clock", "calendar") !== false) { root.calMonth = new Date(); root.calendarOpen = !root.calendarOpen }
            }
          }
        }

        // -- status: indicators, update available, keyboard layout, battery --
        RowLayout {
          id: secStatus
          readonly property bool anyShown: root.statusBatteryShown || statusRep.shownCount > 0
          // right under a showing clock it tucks up against it, as one block
          readonly property bool underClock: root.sectionShown("clock") && root.sectionOrder.indexOf("status") === root.sectionOrder.indexOf("clock") + 1
          // Stays "visible" while empty and collapses to nothing instead, so the
          // hosted widgets' own visibility (e.g. update available) can be read.
          visible: root.sectionShown("status")
          opacity: root.sectionOpacity("status")
          clip: true
          Layout.fillWidth: true
          Layout.preferredHeight: anyShown ? 24 : 0
          Layout.topMargin: !anyShown ? -mainCol.spacing : (underClock ? -8 : 0)
          spacing: 2
          Repeater {
            id: statusRep
            property int shownCount: 0
            function recount() { var n = 0; for (var i = 0; i < count; i++) { var it = itemAt(i); if (it && it.shown) n++ } shownCount = n }
            model: root.statusIdsShown
            Loader {
              id: shost
              required property var modelData
              readonly property string moduleName: String(modelData)
              // the sidebar's own settings for it (Status settings): handed over again when they change
              readonly property string wanted: JSON.stringify(root.statusWidgetSettings(moduleName))
              onWantedChanged: inject()
              readonly property var registryEntry: {
                var w = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
                return w ? w[moduleName] || null : null
              }
              active: !!registryEntry && !!registryEntry.component
              sourceComponent: registryEntry ? registryEntry.component : null
              readonly property bool shown: !!item && item.visible && (item.implicitWidth || 0) > 0
              onShownChanged: statusRep.recount()
              Layout.preferredWidth: shown ? item.implicitWidth : 0
              Layout.preferredHeight: shown ? Math.max(22, item.implicitHeight || 22) : 0
              function inject() {
                if (!item) return
                if ("fixedEdge" in item) item.fixedEdge = "start"
                if ("bar" in item) item.bar = statusBar
                if ("moduleName" in item) item.moduleName = shost.moduleName
                if ("settings" in item) {
                  var meta = registryEntry && registryEntry.metadata ? registryEntry.metadata : {}
                  var defs = meta.barWidget && meta.barWidget.defaults ? meta.barWidget.defaults : (meta.defaults || {})
                  item.settings = Object.assign(JSON.parse(JSON.stringify(defs)), JSON.parse(shost.wanted))
                }
              }
              onLoaded: { inject(); Qt.callLater(inject); Qt.callLater(statusRep.recount) }
            }
          }
          Item { Layout.fillWidth: true }
          Text {
            visible: root.statusBatteryShown
            textFormat: Text.PlainText
            text: root.batteryGlyph() + " " + root.batteryPct + "%"
            color: !root.batteryCharging && root.batteryPct <= 15 ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: 11
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openSettings("power", win.monitorName) }
          }
        }

        // -- calendar (click the clock) ------------------------------------------
        ColumnLayout {
          id: secCalendar
          visible: root.sectionShown("clock") && root.calendarOpen
          Layout.fillWidth: true
          Layout.topMargin: -6
          spacing: 4
          readonly property var loc: Qt.locale(Commons.I18n.formatLocale)
          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: secCalendar.loc.toString(root.calMonth, "MMMM yyyy")
              color: root.foreground; font.family: root.fontFamily; font.pixelSize: 12; font.bold: true
            }
            Repeater {
              model: [["\uf053", -1], ["\uf111", 0], ["\uf054", 1]]
              Text {
                required property var modelData
                textFormat: Text.PlainText
                text: modelData[0]
                color: navMouse.containsMouse ? root.foreground : root.dim
                font.family: root.fontFamily; font.pixelSize: modelData[1] === 0 ? 6 : 10
                Layout.leftMargin: 8
                MouseArea {
                  id: navMouse
                  anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                  onClicked: root.calMonth = parent.modelData[1] === 0 ? new Date() : new Date(root.calMonth.getFullYear(), root.calMonth.getMonth() + parent.modelData[1], 1)
                }
              }
            }
          }
          Grid {
            id: calGrid
            Layout.fillWidth: true
            columns: 7
            readonly property real cell: width / 7
            Repeater {
              model: 7
              Text {
                required property int index
                width: calGrid.cell; height: 18
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: secCalendar.loc.dayName((secCalendar.loc.firstDayOfWeek + index) % 7, Locale.ShortFormat).substring(0, 2)
                color: root.dim; font.family: root.fontFamily; font.pixelSize: 9
              }
            }
            Repeater {
              model: root.calDays(root.calMonth)
              Rectangle {
                required property var modelData
                readonly property bool today: modelData.toDateString() === clock.date.toDateString()
                readonly property bool inMonth: modelData.getMonth() === root.calMonth.getMonth()
                width: calGrid.cell; height: 22
                radius: 5
                color: today ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14) : "transparent"
                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: parent.modelData.getDate()
                  color: parent.today ? root.foreground : parent.inMonth ? root.dim : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
                  font.family: root.fontFamily; font.pixelSize: 10; font.bold: parent.today
                }
              }
            }
          }
        }

        // -- system: the readings on a grid. Each one is a fifth, a third, half or all
        // of the width and 1-3 rows tall, shown as a number, a bar or a graph; they
        // fill the grid in order, left to right, each going in the first gap it fits.
        // In edit mode, click one to pick it and drag it to either side of another. --
        Item {
          id: secStats
          readonly property var shown: root.systemItems.filter(function(it) { return it.show && it.avail })
          readonly property int cols: 30          // fits fifths, thirds and halves
          readonly property real gap: 8
          readonly property real rowH: 34
          readonly property real unit: (width + gap) / cols
          readonly property var placed: {
            var occ = [], cells = [], r = 0, c = 0, rows = 0, n = cols
            function free(r0, c0, sp, h) {
              for (var y = r0; y < r0 + h; y++) for (var x = c0; x < c0 + sp; x++) if (occ[y] && occ[y][x]) return false
              return true
            }
            shown.forEach(function(it) {
              var sp = n / it.w, h = it.h
              while (true) {
                if (c + sp > n) { r++; c = 0; continue }
                if (free(r, c, sp, h)) break
                c++
              }
              for (var y = r; y < r + h; y++) { occ[y] = occ[y] || []; for (var x = c; x < c + sp; x++) occ[y][x] = true }
              cells.push({ it: it, c: c, r: r, sp: sp, h: h })
              rows = Math.max(rows, r + h)
              c += sp
            })
            return { cells: cells, rows: rows }
          }
          readonly property bool arranging: win.editHere && root.editSection === "system"
          property string dragId: ""
          property string dropId: ""
          property bool dropAfter: false   // land after the target rather than before it
          property var tiles: []
          // the tile nearest the pointer, leaving out the one being dragged
          function tileAt(p) {
            var best = null, bestD = 1e9
            for (var i = 0; i < tiles.length; i++) {
              var t = tiles[i]
              if (!t.visible || t.sid === dragId) continue
              var dx = Math.max(t.x - p.x, 0, p.x - (t.x + t.width))
              var dy = Math.max(t.y - p.y, 0, p.y - (t.y + t.height))
              var d = dx + dy * 3
              if (d < bestD) { bestD = d; best = t }
            }
            return bestD < 60 ? best : null
          }
          // before or after: by x, or by y for one as wide as the section
          function sideOf(t, p) { return t.sp >= cols ? p.y > t.y + t.height / 2 : p.x > t.x + t.width / 2 }
          visible: root.sectionShown("system") && shown.length > 0
          opacity: root.sectionOpacity("system")
          Layout.fillWidth: true
          implicitHeight: placed.rows > 0 ? placed.rows * (rowH + gap) - gap : 0
          Behavior on implicitHeight { enabled: secStats.arranging; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
          // edit mode: the grid's rows and thirds/halves, faintly
          Repeater {
            model: secStats.arranging ? secStats.placed.rows : 0
            Rectangle {
              required property int index
              y: index * (secStats.rowH + secStats.gap); width: secStats.width; height: secStats.rowH
              radius: 3; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
            }
          }
          // a fixed count, so tiles stay put (and can glide) when settings change
          Repeater {
            model: root.statIds.length
            Item {
              id: tile
              required property int index
              readonly property var cell: secStats.placed.cells[index] || null
              readonly property string sid: cell ? cell.it.id : ""
              readonly property int sp: cell ? cell.sp : 0
              readonly property int rows: cell ? cell.h : 1
              readonly property string look: cell ? cell.it.style : "value"
              readonly property bool compact: rows === 1
              readonly property var hist: root.statHist[sid] || []
              readonly property var txt: sid ? root.statText(sid) : ["", ""]
              readonly property real peak: root.statPeak(sid, hist)
              readonly property real frac: sid ? Math.max(0, Math.min(1, root.statValue(sid) / peak)) : 0
              readonly property color ink: sid && root.statHot(sid) ? root.urgent : root.foreground
              property real dragDx: 0
              property real dragDy: 0
              Component.onCompleted: secStats.tiles = secStats.tiles.concat([tile])
              Component.onDestruction: secStats.tiles = secStats.tiles.filter(function(t) { return t !== tile })
              visible: cell !== null
              x: cell ? cell.c * secStats.unit : 0
              y: cell ? cell.r * (secStats.rowH + secStats.gap) : 0
              width: Math.max(0, sp * secStats.unit - secStats.gap)
              height: rows * (secStats.rowH + secStats.gap) - secStats.gap
              Behavior on x { enabled: secStats.arranging && secStats.dragId !== tile.sid; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
              Behavior on y { enabled: secStats.arranging && secStats.dragId !== tile.sid; NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
              z: secStats.dragId === sid ? 10 : 0
              transform: Translate { x: tile.dragDx; y: tile.dragDy }
              opacity: secStats.dragId === sid ? 0.6 : 1
              // caption and figure; big tiles get a big figure
              Text { id: tCap; width: parent.width; elide: Text.ElideRight; textFormat: Text.PlainText; text: root.statShort[tile.sid] || ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1 }
              Row {
                id: tFig
                y: tCap.height + (tile.compact ? 0 : 1)
                spacing: 3
                Text { id: tNum; textFormat: Text.PlainText; text: tile.txt[0]; color: tile.ink; font.family: root.fontFamily; font.pixelSize: tile.compact || tile.width < 70 ? 14 : 22; font.bold: true }
                Text { anchors.baseline: tNum.baseline; textFormat: Text.PlainText; text: tile.txt[1]; color: root.isRate(tile.sid) ? root.dim : tile.ink; font.family: root.fontFamily; font.pixelSize: root.isRate(tile.sid) ? (tile.compact ? 9 : 10) : tNum.font.pixelSize; font.bold: !root.isRate(tile.sid) }
              }
              // bar: along the bottom
              Rectangle {
                visible: tile.look === "bar"
                anchors.bottom: parent.bottom
                width: parent.width; height: tile.compact ? 3 : 4; radius: 2; color: root.faint
                Rectangle { width: parent.width * tile.frac; height: parent.height; radius: 2; color: tile.ink }
              }
              // graph: beside the figure in one row, under it when taller
              Spark {
                readonly property real besideW: tile.width - Math.max(tCap.implicitWidth, tFig.implicitWidth) - 6
                visible: tile.look === "graph" && (!tile.compact || besideW >= 14)
                x: tile.compact ? tile.width - width : 0
                width: tile.compact ? Math.min(besideW, 70) : tile.width
                n: Math.max(6, Math.min(24, Math.floor(width / 4)))
                barH: tile.compact ? tile.height : Math.max(6, tile.height - (tFig.y + tFig.height + 3))
                y: tile.height - barH
                hist: tile.hist; peak: tile.peak
              }
              // edit mode: every tile outlined, the picked one bright
              Rectangle {
                visible: secStats.arranging
                anchors.fill: parent; anchors.margins: -3
                radius: 4; color: "transparent"
                border.width: 1
                border.color: root.systemPick === tile.sid ? root.foreground : root.faint
              }
              // where the dragged reading will land: a bar on that side of this one
              Rectangle {
                readonly property bool vert: tile.sp < secStats.cols
                visible: secStats.dropId !== "" && secStats.dropId === tile.sid
                color: root.urgent; radius: 1.5
                width: vert ? 3 : tile.width + 6
                height: vert ? tile.height + 6 : 3
                x: vert ? (secStats.dropAfter ? tile.width + 3 : -6) : -3
                y: vert ? -3 : (secStats.dropAfter ? tile.height + 3 : -6)
              }
              MouseArea {
                enabled: secStats.arranging && tile.visible
                anchors.fill: parent; anchors.margins: -3
                preventStealing: true
                cursorShape: secStats.dragId !== "" ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property point start
                onPressed: function(m) { start = Qt.point(m.x, m.y); root.systemPick = tile.sid }
                onPositionChanged: function(m) {
                  if (!pressed) return
                  if (secStats.dragId === "" && Math.abs(m.x - start.x) + Math.abs(m.y - start.y) > 6) secStats.dragId = tile.sid
                  if (secStats.dragId === "") return
                  tile.dragDx = m.x - start.x; tile.dragDy = m.y - start.y
                  var p = mapToItem(secStats, m.x, m.y)
                  var c = secStats.tileAt(p)
                  secStats.dropId = c ? c.sid : ""
                  if (c) secStats.dropAfter = secStats.sideOf(c, p)
                }
                function finish() { tile.dragDx = 0; tile.dragDy = 0; secStats.dragId = ""; secStats.dropId = "" }
                onReleased: {
                  if (secStats.dragId !== "" && secStats.dropId !== "") root.moveSystemItem(secStats.dragId, secStats.dropId, secStats.dropAfter)
                  finish()
                }
                onCanceled: finish()
              }
            }
          }
        }
        // (the network readings are tiles in the flow above now)
        Item { id: secNet; visible: false; Layout.preferredHeight: 0 }

        // -- workspaces -------------------------------------------------------
        Flow {
          id: secWs
          visible: root.sectionShown("workspaces")
          opacity: root.sectionOpacity("workspaces")
          Layout.fillWidth: true
          spacing: 6
          // scroll over the workspaces to switch
          WheelHandler {
            enabled: root.setting("workspaces", "scroll") !== false
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(e) { win.wsScroll(e) }
          }
          Repeater {
            model: win.wsIds
            Rectangle {
              id: wsBox
              required property int modelData
              readonly property bool active: win.monitor && win.monitor.activeWorkspace && win.monitor.activeWorkspace.id === modelData
              readonly property bool occupied: {
                var all = Hyprland.workspaces.values
                for (var i = 0; i < all.length; i++) if (all[i].id === modelData) return all[i].toplevels.values.length > 0
                return false
              }
              readonly property bool dots: root.setting("workspaces", "style") === "dots"
              readonly property bool dropHere: win.dragWs === modelData
              width: dots ? 14 : 24; height: dots ? 14 : 24; radius: dots ? 7 : 4
              y: dots ? 5 : 0
              color: dropHere ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35) : (active ? root.foreground : (dots && occupied ? root.dim : "transparent"))
              border.width: 1
              border.color: dropHere ? root.urgent : (active ? root.foreground : (occupied ? root.dim : root.faint))
              Text {
                visible: !wsBox.dots
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: ((wsBox.modelData - 1) % 10 + 1).toString()
                color: wsBox.active ? root.background : (wsBox.occupied ? root.foreground : root.dim)
                font.family: root.fontFamily; font.pixelSize: 11; font.bold: wsBox.active
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: win.focusWs(wsBox.modelData)
              }
            }
          }
        }

        // -- search / Omarchy menu ------------------------------------------------
        Rectangle {
          id: secSearch
          visible: root.sectionShown("search")
          opacity: root.sectionOpacity("search")
          readonly property bool active: root.searching && root.searchMonitor === win.monitorName
          Layout.fillWidth: true
          Layout.preferredHeight: 32
          radius: 6
          color: active ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : (searchMouse.containsMouse ? root.faint : "transparent")
          border.width: 1
          border.color: active ? root.dim : root.faint
          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 6
            spacing: 8
            Text { textFormat: Text.PlainText; text: "\uf002"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 12 }
            Item {
              Layout.fillWidth: true
              Layout.fillHeight: true
              TextInput {
                id: searchInput
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                clip: true
                color: root.foreground
                selectionColor: root.faint
                font.family: root.fontFamily
                font.pixelSize: 12
                enabled: root.searching && root.searchMonitor === win.monitorName
                onTextChanged: if (root.query !== text) root.query = text
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) { root.moveSelection(1); event.accepted = true }
                  else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)) || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) { root.moveSelection(-1); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.activateSearchRow(root.searchRows[root.selectedIndex]); event.accepted = true }
                  // Esc leaves the search at once (Backspace on an empty field / ← go back a level)
                  else if (event.key === Qt.Key_Escape) { root.exitSearch(); event.accepted = true } else if (event.key === Qt.Key_Backspace && text === "" && root.activeMenu !== "root") { root.menuBack(); event.accepted = true }
                  else if (event.key === Qt.Key_Right && text === "") {
                    var r = root.searchRows[root.selectedIndex]
                    if (r && (r.kind === "menu" || r.kind === "link" || r.provider === "apps")) { root.activateSearchRow(r); event.accepted = true }
                  } else if (event.key === Qt.Key_Left && text === "" && root.activeMenu !== "root") { root.menuBack(); event.accepted = true }
                }
                Connections {
                  target: root
                  function onSearchingChanged() {
                    if (root.searching && root.searchMonitor === win.monitorName) Qt.callLater(function() { searchInput.forceActiveFocus() })
                    else searchInput.text = ""
                  }
                  function onQueryChanged() { if (searchInput.text !== root.query) searchInput.text = root.query }
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: searchInput.text === ""
                width: parent.width
                textFormat: Text.PlainText
                text: root.searching && root.activeMenu !== "root" && root.menuItems[root.activeMenu]
                      ? "Search " + (root.menuItems[root.activeMenu].title || root.menuItems[root.activeMenu].label) + "…" : "Search…"
                color: root.dim
                font.family: root.fontFamily; font.pixelSize: 12
                elide: Text.ElideRight
              }
            }
            Rectangle {
              visible: root.setting("search", "clip")
              Layout.preferredHeight: 20
              Layout.preferredWidth: clipText.implicitWidth + 12
              radius: 3
              color: clipMouse.containsMouse ? root.faint : "transparent"
              border.width: 1
              border.color: root.dim
              Text { id: clipText; anchors.centerIn: parent; textFormat: Text.PlainText; text: "CLIP"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 9; font.bold: true }
              MouseArea {
                id: clipMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.exitSearch(); root.run("omarchy-shell shell toggle omarchy.clipboard") }
              }
              z: 2
            }
          }
          MouseArea {
            id: searchMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.IBeamCursor
            visible: !parent.active
            onClicked: root.enterSearch(win.monitorName)
            z: 1
          }
        }

        // -- media (added from "+ add section") ------------------------------------
        ColumnLayout {
          id: secMedia
          visible: root.sectionShown("media") && (!!root.mediaPlayer || root.setting("media", "idle") !== false)
          opacity: root.sectionOpacity("media")
          Layout.fillWidth: true
          spacing: 6
          readonly property var p: root.mediaPlayer
          // only when the player reports a real length (Firefox often doesn't)
          readonly property bool timed: !!p && p.lengthSupported && p.length > 10 && p.position >= 0 && p.position <= p.length + 1
          Text { textFormat: Text.PlainText; text: "MEDIA"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1 }
          Text { visible: !secMedia.p; textFormat: Text.PlainText; text: "Nothing playing"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 11 }
          RowLayout {
            visible: !!secMedia.p
            Layout.fillWidth: true
            spacing: 10
            Rectangle {
              Layout.preferredWidth: 44; Layout.preferredHeight: 44; radius: 6
              color: root.faint
              clip: true
              Image { anchors.fill: parent; source: secMedia.p ? String(secMedia.p.trackArtUrl || "") : ""; fillMode: Image.PreserveAspectCrop; asynchronous: true }
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 1
              Text { Layout.fillWidth: true; textFormat: Text.PlainText; elide: Text.ElideRight; text: secMedia.p ? String(secMedia.p.trackTitle || secMedia.p.identity || "") : ""
                color: root.foreground; font.family: root.fontFamily; font.pixelSize: 12; font.bold: true }
              Text { Layout.fillWidth: true; textFormat: Text.PlainText; elide: Text.ElideRight; text: secMedia.p ? String(secMedia.p.trackArtist || secMedia.p.identity || "") : ""
                color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }
          }
          // progress
          Item {
            visible: secMedia.timed
            Layout.fillWidth: true
            Layout.preferredHeight: 14
            readonly property real frac: secMedia.p && secMedia.p.length > 0 ? Math.max(0, Math.min(1, secMedia.p.position / secMedia.p.length)) : 0
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 3; radius: 2; color: root.faint }
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width * parent.frac; height: 3; radius: 2; color: root.foreground }
            MouseArea {
              anchors.fill: parent
              enabled: !!secMedia.p && secMedia.p.canSeek
              cursorShape: Qt.PointingHandCursor
              onClicked: function(m) { if (secMedia.p) secMedia.p.position = secMedia.p.length * Math.max(0, Math.min(1, m.x / width)) }
            }
          }
          RowLayout {
            visible: !!secMedia.p
            Layout.fillWidth: true
            spacing: 14
            Text { textFormat: Text.PlainText; text: secMedia.timed ? root.fmtTime(secMedia.p.position) + " / " + root.fmtTime(secMedia.p.length) : (secMedia.p && secMedia.p.isPlaying ? "playing" : "paused")
              color: root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
            Item { Layout.fillWidth: true }
            Repeater {
              model: [["\uf048", "prev"], ["play", "toggle"], ["\uf051", "next"]]
              Text {
                required property var modelData
                textFormat: Text.PlainText
                text: modelData[1] === "toggle" ? (secMedia.p && secMedia.p.isPlaying ? "\uf04c" : "\uf04b") : modelData[0]
                color: mbMouse.containsMouse ? root.foreground : root.dim
                font.family: root.fontFamily; font.pixelSize: 14
                MouseArea {
                  id: mbMouse; anchors.fill: parent; anchors.margins: -5; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var p = secMedia.p; if (!p) return
                    if (modelData[1] === "prev" && p.canGoPrevious) p.previous()
                    else if (modelData[1] === "next" && p.canGoNext) p.next()
                    else if (modelData[1] === "toggle" && p.canTogglePlaying) p.togglePlaying()
                  }
                }
              }
            }
          }
        }

        // -- notifications (added from "+ add section") ----------------------------
        ColumnLayout {
          id: secNotif
          visible: root.sectionShown("notifications")
          opacity: root.sectionOpacity("notifications")
          Layout.fillWidth: true
          spacing: 6
          RowLayout {
            Layout.fillWidth: true
            Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: "NOTIFICATIONS"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1 }
            Text {
              textFormat: Text.PlainText; text: root.dnd ? "silenced" : "silence"
              color: dndMouse.containsMouse || root.dnd ? root.foreground : root.dim
              font.family: root.fontFamily; font.pixelSize: 9; font.bold: root.dnd
              MouseArea { id: dndMouse; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.qsToggle("dnd") }
            }
          }
          Text { visible: root.notifHistory.length === 0; textFormat: Text.PlainText; text: "No notifications"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 11 }
          Repeater {
            model: root.notifHistory.slice(0, Math.max(1, root.setting("notifications", "count")))
            ColumnLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: 0
              RowLayout {
                Layout.fillWidth: true
                Text { Layout.fillWidth: true; textFormat: Text.PlainText; elide: Text.ElideRight; text: String(modelData.summary || modelData.app || "")
                  color: root.foreground; font.family: root.fontFamily; font.pixelSize: 11 }
                Text { textFormat: Text.PlainText; text: (root.agoTick, root.agoText(modelData.ts)); color: root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
              }
              Text { Layout.fillWidth: true; visible: !!modelData.body; textFormat: Text.PlainText; elide: Text.ElideRight; text: String(modelData.body || "").replace(/\s+/g, " ")
                color: root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
            }
          }
        }

        // -- menu results (replace the app list while searching) ---------------
        ListView {
          id: menuList
          visible: root.searching && root.searchMonitor === win.monitorName
          Layout.fillWidth: true
          // takes the app list's place: the room that's left, or the list's set height
          Layout.fillHeight: root.heightMode("apps") === "auto"
          Layout.preferredHeight: root.heightMode("apps") === "auto" ? 0 : root.heightPx("apps")
          Layout.minimumHeight: 0
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds
          model: visible ? root.searchRows : []
          currentIndex: root.selectedIndex
          onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

          delegate: Item {
            id: mrow
            required property var modelData
            required property int index
            readonly property bool selected: index === root.selectedIndex
            width: menuList.width
            height: modelData.detail && root.query ? 40 : 32
            opacity: modelData.disabled ? 0.45 : 1

            Rectangle {
              anchors.fill: parent
              radius: 6
              color: mrow.selected ? root.faint : "transparent"
            }
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 10
              anchors.rightMargin: 10
              spacing: 10
              Text {
                Layout.preferredWidth: 16
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: mrow.modelData.kind === "back" ? "‹" : (mrow.modelData.icon || "")
                color: mrow.selected ? root.foreground : root.dim
                font.family: mrow.modelData.iconFont || root.fontFamily
                font.pixelSize: 13
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: mrow.modelData.label
                  color: root.foreground
                  font.family: root.fontFamily; font.pixelSize: 12
                  font.bold: mrow.modelData.kind === "back"
                  elide: Text.ElideRight
                }
                Text {
                  Layout.fillWidth: true
                  visible: !!mrow.modelData.detail && !!root.query
                  textFormat: Text.PlainText
                  text: mrow.modelData.detail || ""
                  color: root.dim
                  font.family: root.fontFamily; font.pixelSize: 9
                  elide: Text.ElideRight
                }
              }
              Text {
                visible: mrow.modelData.kind === "menu" || mrow.modelData.kind === "link" || mrow.modelData.provider === "apps"
                textFormat: Text.PlainText
                text: "›"
                color: root.dim
                font.family: root.fontFamily; font.pixelSize: 13
              }
            }
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: mrow.modelData.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
              onEntered: if (!mrow.modelData.disabled) root.selectedIndex = mrow.index
              onClicked: root.activateSearchRow(mrow.modelData)
            }
          }
        }

        // -- apps: pinned first, then anything else that is running ---------------
        ListView {
          id: appList
          // insertion line while dragging an app within the sidebar
          Rectangle {
            visible: !!win.listDrop && !!win.dragItem
            z: 10
            x: 6
            width: appList.width - 12
            height: 2
            radius: 1
            y: win.listDrop ? win.listDrop.y - appList.contentY : 0
            color: root.urgent
          }
          visible: !(root.searching && root.searchMonitor === win.monitorName)
          readonly property string hmode: root.heightMode("apps")
          Layout.fillWidth: true
          // fit content: all of it, and the room that's left (when the sidebar runs out
          // of room it scrolls as a whole); up to / fixed: that tall, scrolling inside
          Layout.fillHeight: hmode === "auto"
          Layout.preferredHeight: hmode === "auto" ? 0 : root.heightFor("apps", contentHeight)
          Layout.maximumHeight: hmode === "auto" ? Number.POSITIVE_INFINITY : root.heightFor("apps", contentHeight)
          Layout.minimumHeight: hmode === "auto" ? contentHeight : root.heightFor("apps", contentHeight)
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds
          model: root.appItems(win.monitorName)

          delegate: Item {
            id: row
            required property var modelData
            readonly property var entry: modelData.entry
            readonly property var windows: modelData.windows
            readonly property bool running: windows.length > 0
            readonly property bool focused: windows.some(function(t) { return t.activated })
            readonly property bool multi: windows.length > 1 && root.setting("apps", "group")
            readonly property bool expanded: multi && !!root.expandedApps[modelData.key]
            width: appList.width
            height: modelData.separator ? 18 : root.rowH + (expanded ? windows.length * 30 + 4 : 0)

            Item {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: root.rowH
              visible: !row.modelData.separator

              Rectangle {
                anchors.fill: parent
                radius: 6
                color: win.springKey === "a:" + row.modelData.key ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.18)
                     : row.focused ? root.faint : (rowMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent")
              }
              // focused: accent bar on the sidebar edge; running: small dot
              Rectangle {
                visible: row.focused && root.setting("apps", "indicator") === "bar"
                width: 3; height: 18; radius: 2
                anchors.verticalCenter: parent.verticalCenter
                x: 0
                color: root.urgent
              }
              Rectangle {
                readonly property bool allHidden: row.windows.every(function(t) { return root.isMinimized(t) })
                visible: row.running && (!row.focused || root.setting("apps", "indicator") === "dot") && root.setting("apps", "indicator") !== "none"
                width: 5; height: 5; radius: 2.5
                anchors.verticalCenter: parent.verticalCenter
                x: 0
                color: allHidden ? "transparent" : root.dim
                border.width: allHidden ? 1 : 0
                border.color: root.dim
              }
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 8
                spacing: 10
                IconImage {
                  visible: root.setting("apps", "icons") === true
                  Layout.preferredWidth: 18
                  Layout.preferredHeight: 18
                  source: visible ? root.iconFor(row.entry && row.entry.icon ? row.entry.icon : row.modelData.key) : ""
                  opacity: row.running ? 1 : 0.7
                }
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.displayName(row.modelData)
                    color: row.running ? root.foreground : root.dim
                    font.family: root.fontFamily; font.pixelSize: 12; font.bold: row.focused
                    elide: Text.ElideRight
                  }
                  // what the app is showing (window title), as a hint
                  // Too long to fit: cut off with "…", and while the row is
                  // hovered it slides along to the end and back so it can be read.
                  Item {
                    id: hintBox
                    readonly property string hint: root.setting("apps", "hints") !== false && row.running ? root.hintOf(row.modelData) : ""
                    readonly property real overflow: Math.max(0, hintText.implicitWidth - width)
                    readonly property bool sliding: rowMouse.containsMouse && overflow > 0
                    visible: hint !== ""
                    Layout.fillWidth: true
                    Layout.preferredHeight: hintText.implicitHeight
                    clip: true
                    Text {
                      id: hintText
                      width: hintBox.sliding ? implicitWidth : hintBox.width
                      textFormat: Text.PlainText
                      text: hintBox.hint
                      color: root.dim
                      font.family: root.fontFamily; font.pixelSize: 10
                      elide: hintBox.sliding ? Text.ElideNone : Text.ElideRight
                      maximumLineCount: 1
                    }
                    // a steady reading pace (~40 px/s), pausing at each end
                    SequentialAnimation {
                      running: hintBox.sliding
                      loops: Animation.Infinite
                      onRunningChanged: if (!running) hintText.x = 0
                      PauseAnimation { duration: 700 }
                      NumberAnimation { target: hintText; property: "x"; from: 0; to: -hintBox.overflow; duration: hintBox.overflow * 25; easing.type: Easing.InOutSine }
                      PauseAnimation { duration: 1200 }
                      NumberAnimation { target: hintText; property: "x"; from: -hintBox.overflow; to: 0; duration: hintBox.overflow * 12; easing.type: Easing.InOutSine }
                    }
                  }
                }
                // unread count from the window title, e.g. "(6) Discord"
                Rectangle {
                  readonly property int n: root.setting("apps", "badges") !== false ? root.badgeOf(row.modelData) : 0
                  visible: n > 0
                  Layout.preferredWidth: Math.max(16, badgeText.implicitWidth + 8)
                  Layout.preferredHeight: 16
                  radius: 8
                  color: root.foreground
                  Text { id: badgeText; anchors.centerIn: parent; textFormat: Text.PlainText; text: parent.n > 99 ? "99+" : String(parent.n); color: root.background; font.family: root.fontFamily; font.pixelSize: 9; font.bold: true }
                }
                Text {
                  readonly property var wsIds: (row.windows || []).filter(function(t) { return t.workspace && t.workspace.id > 0 }).map(function(t) { return t.workspace.id })
                    .filter(function(v, i, a) { return a.indexOf(v) === i })
                  visible: root.setting("apps", "workspace") === true && wsIds.length > 0
                  textFormat: Text.PlainText
                  text: wsIds.map(function(id) { return (id - 1) % 10 + 1 }).join(",")
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: 9
                }
                // several windows: a count that opens the window list
                Rectangle {
                  visible: row.multi
                  Layout.preferredWidth: countText.implicitWidth + 12
                  Layout.preferredHeight: 20
                  radius: 4
                  color: countMouse.containsMouse || row.expanded ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10) : "transparent"
                  Text {
                    id: countText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: (row.expanded ? "▾ " : "▸ ") + row.windows.length
                    color: row.expanded ? root.foreground : root.dim
                    font.family: root.fontFamily; font.pixelSize: 10
                  }
                  MouseArea {
                    id: countMouse
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleExpanded(row.modelData.key)
                  }
                }
              }
              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                cursorShape: dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                preventStealing: true
                z: -1
                property real pressX: 0
                property real pressY: 0
                property bool dragging: false
                property bool dragged: false
                onPressed: function(mouse) { pressX = mouse.x; pressY = mouse.y; dragged = false }
                onPositionChanged: function(mouse) {
                  if (!(pressedButtons & Qt.LeftButton) || !row.modelData || row.modelData.separator) return
                  var p = mapToItem(win.contentItem, mouse.x, mouse.y)
                  if (!dragging && Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) > 12) {
                    dragging = true; dragged = true
                    win.beginDrag(row.modelData)
                  }
                  if (dragging) win.updateDrag(p.x, p.y)
                }
                onReleased: function(mouse) {
                  if (!dragging) return
                  dragging = false
                  var p = mapToItem(win.contentItem, mouse.x, mouse.y)
                  win.endDrag(p.x, p.y)
                }
                onCanceled: if (dragging) { dragging = false; win.dragItem = null }
                onClicked: function(mouse) {
                  if (dragged) { dragged = false; return }
                  if (mouse.button === Qt.RightButton) win.openAppMenu(row.modelData, row)
                  else if (mouse.button === Qt.MiddleButton) { var nl = root.launchCommandFor(row.modelData); if (nl) root.run(nl) }
                  else root.activateApp(row.modelData, root.shiftHeld || (mouse.modifiers & Qt.ShiftModifier) !== 0)
                }
              }
            }

            // the app's windows, when expanded
            Column {
              visible: row.expanded
              x: 0
              y: root.rowH + 2
              width: parent.width
              spacing: 2
              Repeater {
                model: row.expanded ? row.windows : []
                Item {
                  id: wrow
                  required property var modelData
                  readonly property bool hidden: root.isMinimized(modelData)
                  readonly property bool front: !hidden && modelData.activated
                  width: parent.width
                  height: 28
                  Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    radius: 5
                    color: win.springKey === "w:" + root.addrOf(wrow.modelData) ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.18)
                         : wrow.front ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
                         : (wMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent")
                  }
                  // same indicators as apps: bar = in front, dot = open, ring = minimized
                  Rectangle {
                    visible: wrow.front
                    x: 14; width: 2; height: 14; radius: 1
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.urgent
                  }
                  Rectangle {
                    visible: !wrow.front
                    x: 15; width: 4; height: 4; radius: 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: wrow.hidden ? "transparent" : root.dim
                    border.width: wrow.hidden ? 1 : 0
                    border.color: root.dim
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 26
                    width: parent.width - 34
                    textFormat: Text.PlainText
                    text: String(wrow.modelData.title || "Window")
                    color: wrow.hidden ? root.dim : root.foreground
                    font.family: root.fontFamily; font.pixelSize: 11; font.bold: wrow.front
                    elide: Text.ElideRight
                  }
                  MouseArea {
                    id: wMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    cursorShape: wdragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                    preventStealing: true
                    property real pressX: 0
                    property real pressY: 0
                    property bool wdragging: false
                    property bool wdragged: false
                    onPressed: function(mouse) { pressX = mouse.x; pressY = mouse.y; wdragged = false }
                    onPositionChanged: function(mouse) {
                      if (!(pressedButtons & Qt.LeftButton)) return
                      var p = mapToItem(win.contentItem, mouse.x, mouse.y)
                      if (!wdragging && Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) > 12) {
                        wdragging = true; wdragged = true
                        win.beginDrag(root.windowDragItem(row.modelData, wrow.modelData))
                      }
                      if (wdragging) win.updateDrag(p.x, p.y)
                    }
                    onReleased: function(mouse) {
                      if (!wdragging) return
                      wdragging = false
                      var p = mapToItem(win.contentItem, mouse.x, mouse.y)
                      win.endDrag(p.x, p.y)
                    }
                    onCanceled: if (wdragging) { wdragging = false; win.dragItem = null }
                    onClicked: function(mouse) {
                      if (wdragged) { wdragged = false; return }
                      if (mouse.button === Qt.MiddleButton) root.closeWindow(wrow.modelData)
                      else root.activateWindow(wrow.modelData, root.shiftHeld || (mouse.modifiers & Qt.ShiftModifier) !== 0)
                    }
                  }
                }
              }
            }
          }
        }

        // -- a plugin's panel, docked in the sidebar (opens above the bottom row) --
        ColumnLayout {
          id: dockCol
          visible: root.dockedPanel !== null && root.dockMonitor === win.monitorName
          Layout.fillWidth: true
          spacing: 4

          Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; Layout.bottomMargin: 4; color: root.faint }
          RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            Text { Layout.fillWidth: true; Layout.leftMargin: 6; textFormat: Text.PlainText; text: root.dockedName; elide: Text.ElideRight
              color: root.foreground; font.family: root.fontFamily; font.pixelSize: 12; font.bold: true }
            Text {
              visible: root.pluginEntries.some(function(e) { return e.id === root.dockedId })
              textFormat: Text.PlainText; text: "Hide"; color: dockHideMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily; font.pixelSize: 10
              MouseArea {
                id: dockHideMouse; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: { var id = root.dockedId; root.closeDockedPanel(); root.setHidden(id, true) }
              }
            }
            Text {
              Layout.leftMargin: 8
              Layout.rightMargin: 6
              textFormat: Text.PlainText; text: "✕"; color: dockCloseMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily; font.pixelSize: 11
              MouseArea { id: dockCloseMouse; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeDockedPanel() }
            }
          }
          Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(root.dockHeight, win.height * 0.6)
            contentWidth: width
            contentHeight: root.dockHeight
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            Item {
              id: dockBody
              width: parent.width
              height: root.dockHeight
              Component.onCompleted: root.registerDockBody(win.monitorName, dockBody)
            }
          }
        }

        // -- tray icon menu (opens above the bottom row, like settings) ---------
        ColumnLayout {
          id: trayPanel
          visible: win.trayHere
          Layout.fillWidth: true
          spacing: 2

          Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; Layout.bottomMargin: 4; color: root.faint }

          // header: app name (or submenu with a back arrow) and a close button
          RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            spacing: 8
            Item {
              Layout.fillWidth: true
              Layout.preferredHeight: 30
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 6
                spacing: 8
                IconImage { visible: !root.trayMenuSub; Layout.preferredWidth: 14; Layout.preferredHeight: 14; source: root.trayMenuItem ? root.trayMenuItem.icon : "" }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: root.trayMenuSub ? "‹ " + String(root.trayMenuSub.text || "").replace(/_/g, "")
                        : (root.trayMenuItem ? String(root.trayMenuItem.tooltipTitle || root.trayMenuItem.title || root.trayMenuItem.id) : "")
                  color: root.foreground; font.family: root.fontFamily; font.pixelSize: 12; font.bold: true
                }
              }
              MouseArea { anchors.fill: parent; enabled: !!root.trayMenuSub; cursorShape: Qt.PointingHandCursor; onClicked: root.trayMenuSub = null }
            }
            Text {
              textFormat: Text.PlainText; text: "✕"; color: trayCloseMouse.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily; font.pixelSize: 11
              Layout.rightMargin: 6
              MouseArea { id: trayCloseMouse; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeTrayMenu() }
            }
          }

          Rectangle {
            visible: !root.trayMenuSub && !!root.trayMenuItem && !root.trayMenuItem.onlyMenu
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 30 : 0
            radius: 6
            color: openMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent"
            Text {
              anchors.verticalCenter: parent.verticalCenter
              x: 6
              textFormat: Text.PlainText
              text: "Open " + (root.trayMenuItem ? String(root.trayMenuItem.tooltipTitle || root.trayMenuItem.title || root.trayMenuItem.id) : "")
              color: root.foreground; font.family: root.fontFamily; font.pixelSize: 12
            }
            MouseArea {
              id: openMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { var it = root.trayMenuItem; root.closeTrayMenu(); if (it) it.activate() }
            }
          }
          Rectangle { visible: !root.trayMenuSub && !!root.trayMenuItem && !root.trayMenuItem.onlyMenu; Layout.fillWidth: true; Layout.leftMargin: 6; Layout.rightMargin: 6; Layout.preferredHeight: 1; color: root.faint }

          ListView {
            id: trayList
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, win.height * 0.5)
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            model: win.trayEntries
            delegate: Item {
              id: tRow
              required property var modelData
              readonly property bool sep: !!modelData.isSeparator
              readonly property bool checkable: modelData.buttonType !== undefined && modelData.buttonType !== QsMenuButtonType.None
              width: trayList.width
              height: sep ? 9 : 30
              Rectangle { visible: tRow.sep; anchors.centerIn: parent; width: parent.width - 12; height: 1; color: root.faint }
              Rectangle {
                visible: !tRow.sep
                anchors.fill: parent
                radius: 6
                color: tMouse.containsMouse && tRow.modelData.enabled ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent"
                opacity: tRow.modelData.enabled ? 1 : 0.4
                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: 6
                  anchors.rightMargin: 6
                  spacing: 8
                  Text { visible: tRow.checkable; Layout.preferredWidth: 10; textFormat: Text.PlainText; text: tRow.modelData.checkState === Qt.Checked ? "✓" : ""; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 11 }
                  IconImage { visible: !!tRow.modelData.icon; Layout.preferredWidth: 14; Layout.preferredHeight: 14; source: tRow.modelData.icon || "" }
                  Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: String(tRow.modelData.text || "").replace(/_/g, ""); color: root.foreground; font.family: root.fontFamily; font.pixelSize: 12; elide: Text.ElideRight }
                  Text { visible: tRow.modelData.hasChildren; textFormat: Text.PlainText; text: "›"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 12 }
                }
                MouseArea {
                  id: tMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: tRow.modelData.enabled
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var entry = tRow.modelData
                    if (entry.hasChildren) { root.trayMenuSub = entry; return }
                    entry.triggered()
                    Qt.callLater(root.closeTrayMenu)
                  }
                }
              }
            }
          }
        }

        // -- settings (opens above the gear) -------------------------------------
        component SectionHeader: Rectangle {
          id: sh
          property string sectionId: ""
          property string icon: ""
          property string label: ""
          property string status: ""
          property bool opens: false     // clicking runs activated() instead of expanding
          signal activated()
          readonly property bool expanded: root.qsSection === sectionId
          Layout.fillWidth: true
          implicitHeight: 34
          radius: 6
          color: shMouse.containsMouse && !expanded ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent"
          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            spacing: 10
            Text { Layout.preferredWidth: 16; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText; text: sh.icon; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 13 }
            Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: sh.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 12; font.bold: sh.expanded }
            Text { textFormat: Text.PlainText; text: sh.status; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10; elide: Text.ElideRight; Layout.maximumWidth: 110 }
            Text { textFormat: Text.PlainText; text: sh.expanded ? "˅" : "›"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 12 }
          }
          MouseArea { id: shMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: sh.opens ? sh.activated() : root.toggleSection(sh.sectionId) }
        }
        component SwitchRow: Item {
          id: sw
          property string label: ""
          property string hint: ""
          property bool on: false
          signal toggled()
          Layout.fillWidth: true
          implicitHeight: 28
          RowLayout {
            anchors.fill: parent
            spacing: 8
            Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: sw.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 11; elide: Text.ElideRight }
            Text { visible: sw.hint !== ""; textFormat: Text.PlainText; text: sw.hint; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10; elide: Text.ElideRight; Layout.maximumWidth: 120 }
            Rectangle {
              Layout.preferredWidth: 30; Layout.preferredHeight: 16; radius: 8
              color: sw.on ? root.foreground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
              Rectangle { width: 12; height: 12; radius: 6; anchors.verticalCenter: parent.verticalCenter; x: sw.on ? parent.width - width - 2 : 2
                color: sw.on ? root.background : root.dim
                Behavior on x { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } } }
            }
          }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: sw.toggled() }
        }
        component SliderRow: Item {
          id: sl
          property string label: ""
          property real value: 0
          property bool muted: false
          property string valueText: ""     // replaces the percentage when set
          signal moved(real v)
          signal muteClicked()
          Layout.fillWidth: true
          implicitHeight: 24
          RowLayout {
            anchors.fill: parent
            spacing: 8
            Text { Layout.preferredWidth: 26; textFormat: Text.PlainText; text: sl.label; color: sl.muted ? root.urgent : root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: sl.muteClicked() } }
            Item {
              id: track
              Layout.fillWidth: true
              Layout.preferredHeight: 18
              Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 4; radius: 2; color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16) }
              Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width * Math.max(0, Math.min(1, sl.value)); height: 4; radius: 2; color: sl.muted ? root.dim : root.foreground }
              Rectangle { anchors.verticalCenter: parent.verticalCenter; x: parent.width * Math.max(0, Math.min(1, sl.value)) - 6; width: 12; height: 12; radius: 6; color: sl.muted ? root.dim : root.foreground }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                preventStealing: true
                onPressed: function(m) { sl.moved(Math.max(0, Math.min(1, m.x / width))) }
                onPositionChanged: function(m) { if (pressed) sl.moved(Math.max(0, Math.min(1, m.x / width))) }
                onWheel: function(w) { sl.moved(Math.max(0, Math.min(1, sl.value + (w.angleDelta.y > 0 ? 0.05 : -0.05)))) }
              }
            }
            Text { Layout.preferredWidth: sl.valueText !== "" ? 44 : 30; horizontalAlignment: Text.AlignRight; textFormat: Text.PlainText; text: sl.muted ? "mute" : sl.valueText !== "" ? sl.valueText : Math.round(sl.value * 100) + "%"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
          }
        }
        component ChoiceRow: Rectangle {
          id: ch
          property string label: ""
          property string hint: ""
          property bool selected: false
          property bool radio: true          // false: a plain action row (no dot)
          signal chosen()
          Layout.fillWidth: true
          implicitHeight: 26
          radius: 5
          color: selected ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : (chMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent")
          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 8
            Rectangle { visible: ch.radio; Layout.preferredWidth: 6; Layout.preferredHeight: 6; radius: 3; color: ch.selected ? root.foreground : "transparent"; border.width: ch.selected ? 0 : 1; border.color: root.dim }
            Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: ch.label; color: ch.selected ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 11; elide: Text.ElideRight }
            Text { visible: ch.hint !== ""; textFormat: Text.PlainText; text: ch.hint; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
          }
          MouseArea { id: chMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ch.chosen() }
        }
        component LinkRow: Item {
          id: lk
          property string label: ""
          signal activated()
          Layout.fillWidth: true
          implicitHeight: 24
          Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: lk.label + " ›"; color: lkMouse.containsMouse ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
          MouseArea { id: lkMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: lk.activated() }
        }
        // a row that opens an Omarchy menu entry: a submenu in the sidebar (›) or its action (↗)
        component MenuLinkRow: Rectangle {
          id: ml
          property string itemId: ""     // an Omarchy menu id, e.g. "setup.monitors"
          property string text: ""       // overrides the menu's label
          property string hint: ""       // shown dim on the right (e.g. the current choice)
          readonly property var row: root.menuRowById(itemId) || ({})
          readonly property bool sub: row.kind === "menu" || row.kind === "link" || (row.childCount || 0) > 0 || !!row.provider
          visible: row.itemId !== undefined
          Layout.fillWidth: true
          implicitHeight: 26
          radius: 5
          color: mlMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent"
          opacity: row.disabled ? 0.4 : 1
          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            spacing: 10
            Text { Layout.preferredWidth: 16; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText; text: ml.row.icon || ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: 12 }
            Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: ml.text || ml.row.label || ""; color: mlMouse.containsMouse ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 11; elide: Text.ElideRight }
            Text { visible: ml.hint !== ""; textFormat: Text.PlainText; text: ml.hint; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; elide: Text.ElideRight; Layout.maximumWidth: 110 }
            Text { textFormat: Text.PlainText; text: ml.sub ? "›" : "↗"; color: root.dim; font.family: root.fontFamily; font.pixelSize: ml.sub ? 12 : 10 }
          }
          MouseArea {
            id: mlMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              // hold on to everything first: closing quick settings destroys this row
              var r = root, row = ml.row, sub = ml.sub, mon = win.monitorName
              if (row.disabled) return
              r.closeQuickSettings()
              // a submenu opens in the sidebar's menu; an action just runs
              if (sub) { r.enterSearch(mon); r.activateSearchRow(row) }
              else { r.activateSearchRow(row); guardsLater.restart() }
            }
          }
        }
        // a row that expands in place (one at a time per section, via root.qsSub)
        component Expander: ColumnLayout {
          id: ex
          property string subId: ""
          property string icon: ""
          property string text: ""
          property string hint: ""
          default property alias content: exBody.data
          readonly property bool open: root.qsSub === subId
          Layout.fillWidth: true
          spacing: 2
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: 26
            radius: 5
            color: exMouse.containsMouse || ex.open ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent"
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 6
              anchors.rightMargin: 6
              spacing: 10
              Text { Layout.preferredWidth: 16; horizontalAlignment: Text.AlignHCenter; textFormat: Text.PlainText; text: ex.icon; color: root.dim; font.family: root.fontFamily; font.pixelSize: 12 }
              Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: ex.text; color: exMouse.containsMouse || ex.open ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 11; font.bold: ex.open; elide: Text.ElideRight }
              Text { visible: ex.hint !== ""; textFormat: Text.PlainText; text: ex.hint; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; elide: Text.ElideRight; Layout.maximumWidth: 120 }
              Text { textFormat: Text.PlainText; text: ex.open ? "˅" : "›"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 12 }
            }
            MouseArea { id: exMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.qsSub = ex.open ? "" : ex.subId }
          }
          ColumnLayout { id: exBody; visible: ex.open; Layout.fillWidth: true; Layout.leftMargin: 22; spacing: 2 }
        }
        // an Omarchy submenu (Browser, Security …) opened in place: picks run here
        component InlineMenu: Expander {
          id: imenu
          property string itemId: ""
          property string title: ""          // overrides the menu's label
          readonly property var row: root.menuRowById(itemId) || ({})
          readonly property var kids: imenu.open ? root.menuChildren(itemId) : []
          visible: row.itemId !== undefined
          subId: itemId
          icon: row.icon || ""
          text: imenu.title || row.label || ""
          Repeater {
            model: imenu.kids
            ChoiceRow {
              required property var modelData
              radio: modelData.checkable
              label: modelData.label
              selected: modelData.checkable && modelData.checked
              hint: modelData.checkable ? "" : (modelData.hasKids ? "›" : "↗")
              opacity: modelData.disabled ? 0.4 : 1
              onChosen: root.runMenuEntry(modelData)
            }
          }
        }
        // a one-line text field; Enter saves, Esc cancels
        component FieldRow: RowLayout {
          id: fr
          property string fieldId: ""
          property string label: ""
          property string value: ""
          property string placeholder: ""
          signal saved(string text)
          readonly property bool editing: root.qsTyping === fieldId
          Layout.fillWidth: true
          spacing: 8
          Text { Layout.preferredWidth: 44; textFormat: Text.PlainText; text: fr.label; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 26
            radius: 5
            color: "transparent"
            border.width: 1
            border.color: fr.editing ? root.dim : root.faint
            TextInput {
              id: frInput
              anchors.fill: parent
              anchors.leftMargin: 8
              anchors.rightMargin: 8
              verticalAlignment: TextInput.AlignVCenter
              color: root.foreground
              font.family: root.fontFamily; font.pixelSize: 11
              clip: true
              readOnly: !fr.editing
              text: fr.value
              Keys.onReturnPressed: fr.saved(text)
              Keys.onEnterPressed: fr.saved(text)
              Keys.onEscapePressed: { text = fr.value; root.qsTyping = "" }
              onActiveFocusChanged: if (!activeFocus && fr.editing) { text = fr.value; root.qsTyping = "" }
              Text { anchors.verticalCenter: parent.verticalCenter; visible: !parent.text; text: fr.placeholder; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
            }
            MouseArea {
              anchors.fill: parent
              visible: !fr.editing
              cursorShape: Qt.IBeamCursor
              onClicked: { root.qsTyping = fr.fieldId; Qt.callLater(function() { frInput.forceActiveFocus(); frInput.selectAll() }) }
            }
          }
        }
        component SectionBody: Rectangle {
          default property alias content: bodyColumn.data
          Layout.fillWidth: true
          implicitHeight: bodyColumn.implicitHeight + 20
          radius: 8
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
          ColumnLayout { id: bodyColumn; anchors.fill: parent; anchors.margins: 10; spacing: 6 }
        }


        // -- tray: icons of running apps (their menus open just above) -----------
        RowLayout {
          id: secTray
          // while editing it stays (with a placeholder) when there are no icons, so it can be picked and moved
          visible: root.sectionShown("tray") && (root.trayItemsShown.length > 0 || root.editing)
          opacity: root.sectionOpacity("tray")
          Layout.fillWidth: true
          Layout.preferredHeight: 28
          spacing: 0
          Item { visible: root.setting("tray", "align") !== "left"; Layout.fillWidth: true }
          Text {
            visible: root.trayItemsShown.length === 0
            textFormat: Text.PlainText; text: "no tray icons right now"
            color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
          }
          Row {
            spacing: 4
                Repeater {
                  model: root.trayItemsShown
                  Item {
                    id: trayItem
                    required property var modelData
                    width: 28; height: 28
                    IconImage {
                      anchors.centerIn: parent
                      width: 16; height: 16
                      source: trayItem.modelData.icon
                    }
                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                      onEntered: tooltip.show(trayItem, trayItem.modelData.tooltipTitle || trayItem.modelData.title || trayItem.modelData.id)
                      onExited: tooltip.hide(trayItem)
                      onClicked: function(mouse) {
                        var item = trayItem.modelData
                        if (mouse.button === Qt.MiddleButton) { root.closeTrayMenu(); item.activate() }
                        else if (item.hasMenu) {
                          if (root.trayMenuItem === item) root.closeTrayMenu()
                          else root.openTrayMenu(item, win.monitorName)
                        } else { root.closeTrayMenu(); item.activate() }
                      }
                    }
                  }
                }
          }
          Item { visible: root.setting("tray", "align") === "left"; Layout.fillWidth: true }
        }
        Rectangle { id: bottomSep; Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.faint }

        // -- bottom row: quick settings (left), system tray (right) -------------
        Item {
          id: secBottom
          Layout.fillWidth: true
          Layout.preferredHeight: 28

          Flow {
            // Omarchy's widgets, kept loaded but hidden so their full panels
            // (and Super+Ctrl+A/B/D) open from here, beside the sidebar.
            anchors.fill: parent
            opacity: 0
            enabled: false
            spacing: 2
          Repeater {
            model: root.widgetIds
            Loader {
              id: host
              required property var modelData
              readonly property string moduleName: String(modelData)
              readonly property var registryEntry: {
                var w = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
                return w ? w[moduleName] || null : null
              }
              active: !!registryEntry && !!registryEntry.component
              sourceComponent: registryEntry ? registryEntry.component : null
              readonly property bool shown: !!item && item.visible && (item.implicitWidth || 0) > 0 && (item.implicitHeight || 0) > 0
              width: shown ? Math.max(Style.bar.sizeVertical, item.implicitWidth) : 0
              height: shown ? Math.max(Style.bar.sizeVertical, item.implicitHeight) : 0

              function inject() {
                if (!item) return
                if ("fixedEdge" in item) item.fixedEdge = "start"
                if ("bar" in item) item.bar = widgetBar
                if ("moduleName" in item) item.moduleName = host.moduleName
                if ("settings" in item) {
                  var meta = registryEntry && registryEntry.metadata ? registryEntry.metadata : {}
                  var defs = meta.barWidget && meta.barWidget.defaults ? meta.barWidget.defaults : (meta.defaults || {})
                  item.settings = JSON.parse(JSON.stringify(defs))
                }
              }
              onLoaded: {
                inject()
                Qt.callLater(inject)
                root.hostedItems = root.hostedItems.concat([host])
                if (root.pendingSummon === host.moduleName) {
                  root.pendingSummon = ""
                  Qt.callLater(function() { if (host.item && typeof host.item.open === "function") host.item.open() })
                }
              }
              Component.onDestruction: root.hostedItems = root.hostedItems.filter(function(h) { return h !== host })
            }
          }
        }

          RowLayout {
            anchors.fill: parent
            spacing: 6
            Rectangle {
              Layout.preferredWidth: 28
              Layout.preferredHeight: 28
              radius: 6
              color: win.qsHere ? root.faint : (gearMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent")
              // The sidebar's own icon, first among the plugins: a gear cut
              // down the middle with its left half gone (a panel's edge).
              // a settings gear, as bright as the plugin icons beside it
              Shape {
                id: sideIcon
                readonly property color tint: root.foreground
                anchors.centerIn: parent
                width: 18; height: 18
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                  fillColor: sideIcon.tint
                  strokeColor: "transparent"
                  fillRule: ShapePath.OddEvenFill
                  PathSvg { path: root.gearPath(9, 9, 8.5, 6.4, 2.9, 8) }
                }
              }
              MouseArea { id: gearMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleQuickSettings(win.monitorName) }
            }
            Item { Layout.fillWidth: true }
            // right side, option 1: workspace chips (same look and settings as the
            // workspaces section, shrunk to fit if there are many)
            Row {
              id: bottomWs
              visible: root.setting("bottom", "right") === "workspaces"
              Layout.alignment: Qt.AlignVCenter
              spacing: 4
              readonly property bool dots: root.setting("workspaces", "style") === "dots"
              readonly property real avail: secBottom.width - 28 - 12
              readonly property real chip: Math.max(12, Math.min(dots ? 14 : 24, (avail - (win.wsIds.length - 1) * spacing) / Math.max(1, win.wsIds.length)))
              WheelHandler {
                enabled: root.setting("workspaces", "scroll") !== false
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function(e) { win.wsScroll(e) }
              }
              Repeater {
                model: bottomWs.visible ? win.wsIds : []
                Rectangle {
                  id: bwsBox
                  required property int modelData
                  readonly property bool active: win.monitor && win.monitor.activeWorkspace && win.monitor.activeWorkspace.id === modelData
                  readonly property bool occupied: {
                    var all = Hyprland.workspaces.values
                    for (var i = 0; i < all.length; i++) if (all[i].id === modelData) return all[i].toplevels.values.length > 0
                    return false
                  }
                  readonly property bool dropHere: win.dragWs === modelData
                  width: bottomWs.chip; height: bottomWs.chip
                  radius: bottomWs.dots ? width / 2 : 4
                  anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                  color: dropHere ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35) : (active ? root.foreground : (bottomWs.dots && occupied ? root.dim : "transparent"))
                  border.width: 1
                  border.color: dropHere ? root.urgent : (active ? root.foreground : (occupied ? root.dim : root.faint))
                  Text {
                    visible: !bottomWs.dots
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: ((bwsBox.modelData - 1) % 10 + 1).toString()
                    color: bwsBox.active ? root.background : (bwsBox.occupied ? root.foreground : root.dim)
                    font.family: root.fontFamily; font.pixelSize: bottomWs.chip < 20 ? 9 : 11; font.bold: bwsBox.active
                  }
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: win.focusWs(bwsBox.modelData) }
                }
              }
            }
            // right side, option 2: plugin widgets, in cells the size of tray icons
            Row {
              visible: root.setting("bottom", "right") !== "workspaces"
              spacing: 4
              Repeater {
                model: !root.setting("bottom", "plugins") || root.setting("bottom", "right") === "workspaces" ? [] : root.pluginEntries.filter(function(e) { return !root.isHidden(e.id) })
                Item {
                  id: pcell
                  required property var modelData
                  // one 28px cell like the tray icons (wider only if the widget shows text)
                  width: phost.shown ? Math.max(28, phost.width * phost.scale) : 0
                  height: 28
                Loader {
                  id: phost
                  anchors.centerIn: parent
                  // Bar widgets draw icons at Omarchy's bar size; scale them up to
                  // the tray icons' 16px so the row reads as one size.
                  scale: 16 / Math.max(1, Style.bar.iconSize)
                  readonly property var modelData: pcell.modelData
                  readonly property string moduleName: String(modelData.id)
                  readonly property var registryEntry: {
                    var w = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
                    return w ? w[moduleName] || null : null
                  }
                  active: !!registryEntry && !!registryEntry.component
                  sourceComponent: registryEntry ? registryEntry.component : null
                  // (not item.visible: that follows this cell's own visibility)
                  readonly property bool shown: !!item && (item.implicitWidth || 0) > 0
                  width: shown ? item.implicitWidth : 0
                  height: shown ? Math.min(28, Math.max(16, item.implicitHeight || 28)) : 0
                  function inject() {
                    if (!item) return
                    if ("fixedEdge" in item) item.fixedEdge = "end"
                    // (a delayed call can land after this cell went away, e.g. the plugin moved to a section)
                    if (typeof widgetBar === "undefined" || !widgetBar) return
                    if ("bar" in item) item.bar = widgetBar
                    if ("moduleName" in item) item.moduleName = phost.moduleName
                    if ("settings" in item) {
                      var meta = registryEntry && registryEntry.metadata ? registryEntry.metadata : {}
                      var defs = meta.barWidget && meta.barWidget.defaults ? meta.barWidget.defaults : (meta.defaults || {})
                      var merged = JSON.parse(JSON.stringify(defs))
                      for (var k in phost.modelData) if (k !== "id") merged[k] = phost.modelData[k]
                      item.settings = merged
                    }
                  }
                  onLoaded: {
                    inject()
                    Qt.callLater(inject)
                    root.hostedItems = root.hostedItems.concat([phost])
                    reinject.restart()
                  }
                  // once more a moment later: a cell made while the row was being rebuilt
                  // can miss its setup and stay 0 px wide (so it wouldn't show)
                  Timer { id: reinject; interval: 2000; onTriggered: phost.inject() }
                  onModelDataChanged: inject()
                  Component.onDestruction: root.hostedItems = root.hostedItems.filter(function(h) { return h !== phost })
                }
                }
              }

            }
          }
        }
      }

      // -- quick settings: drawn over the sidebar content, just above the bottom row --
      Rectangle {
        id: qsOverlay
        visible: win.qsHere
        z: 20
        readonly property real bottomY: win.bottomEdgeY
        x: win.panelInnerX
        width: win.panelInnerW
        height: Math.min(settingsPanel.implicitHeight + 7, bottomY - sideFlick.y)
        y: bottomY - height
        color: win.color.a < 1 ? root.background : win.color
        // the separator line the panel always had above it (lined up with the
        // sections: this box already starts inside the panel's gap and border)
        Rectangle { x: sideFlick.x - win.panelInnerX; width: sideFlick.width; height: 1; color: root.faint }
        // swallow clicks and scrolls so they don't reach the sections underneath
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: function(w) { w.accepted = true } }
        Flickable {
          id: qsFlick
          anchors.fill: parent
          anchors.leftMargin: sideFlick.x - win.panelInnerX
          anchors.rightMargin: qsOverlay.width - anchors.leftMargin - sideFlick.width
          anchors.topMargin: 7
          clip: true
          contentHeight: settingsPanel.implicitHeight
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds
          ColumnLayout {
            id: settingsPanel
            width: qsFlick.width
            spacing: 2


            ColumnLayout {
              id: accordion
              Layout.fillWidth: true
              spacing: 2

              // Network
              SectionHeader { sectionId: "network"; icon: ""; label: "Network"
                status: root.qsState.netType === "wifi" ? root.qsState.netName : root.qsState.netType === "ethernet" ? "Ethernet" : root.qsState.netType ? root.qsState.netType : "Offline" }
              SectionBody {
                visible: root.qsSection === "network"
                SwitchRow { label: "Wi-Fi"; on: root.qsState.wifi; onToggled: root.qsToggle("wifi") }
                Text { Layout.fillWidth: true; visible: root.qsState.netType === "ethernet" || !root.qsState.wifi
                  textFormat: Text.PlainText; elide: Text.ElideRight; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
                  text: root.qsState.netType === "ethernet" ? "Connected by Ethernet" : root.qsState.netName ? "Connected: " + root.qsState.netName : "Not connected" }
                Caption { text: root.wifiDevice ? "WI-FI NETWORKS" : "NO WI-FI ADAPTER"; visible: !root.wifiDevice || root.qsState.wifi }
                ListView {
                  id: wifiList
                  visible: !!root.wifiDevice && root.qsState.wifi
                  Layout.fillWidth: true
                  Layout.preferredHeight: Math.min(contentHeight, win.height * 0.3)
                  clip: true
                  interactive: contentHeight > height
                  boundsBehavior: Flickable.StopAtBounds
                  model: root.wifiNetworks
                  delegate: ColumnLayout {
                    id: wrow
                    required property var modelData
                    width: wifiList.width
                    spacing: 2
                    ChoiceRow {
                      label: wrow.modelData.name
                      hint: (root.secured(wrow.modelData) ? "🔒︎ " : "") + root.bars(wrow.modelData)
                      selected: wrow.modelData.connected
                      onChosen: root.wifiClick(wrow.modelData)
                    }
                    Rectangle {
                      visible: root.pwSsid === wrow.modelData.name
                      Layout.fillWidth: true
                      Layout.preferredHeight: 28
                      radius: 5
                      color: "transparent"
                      border.width: 1
                      border.color: root.dim
                      TextInput {
                        id: pwInput
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        echoMode: TextInput.Password
                        color: root.foreground
                        font.family: root.fontFamily; font.pixelSize: 11
                        clip: true
                        onVisibleChanged: if (visible) { text = ""; Qt.callLater(function() { pwInput.forceActiveFocus() }) }
                        Keys.onReturnPressed: root.wifiConnectWithPassword(text)
                        Keys.onEnterPressed: root.wifiConnectWithPassword(text)
                        Keys.onEscapePressed: root.pwSsid = ""
                        Text { anchors.verticalCenter: parent.verticalCenter; visible: !parent.text; text: "Password, then Enter"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
                      }
                    }
                  }
                }
                Caption { text: "DNS" }
                Segmented {
                  options: [["DHCP", "DHCP"], ["Cloudflare", "Cloudflare"], ["Google", "Google"]]
                  current: root.dnsProvider
                  onPicked: function(v) { root.setDns(v) }
                }
                MenuLinkRow { itemId: "setup.network.dns.custom"; text: "Custom DNS"; hint: root.dnsProvider === "Custom" ? "in use" : "" }
                MenuLinkRow { itemId: "setup.network.qr"; text: "Share Wi-Fi as QR code" }
              }

              // Bluetooth
              SectionHeader { sectionId: "bluetooth"; icon: ""; label: "Bluetooth"
                status: !root.btAdapter || !root.btAdapter.enabled ? "Off" : (function() { var n = root.btDevices.filter(function(d) { return d.connected }).length; return n > 0 ? n + " connected" : "On" })() }
              SectionBody {
                visible: root.qsSection === "bluetooth"
                SwitchRow { label: "Bluetooth"; on: !!root.btAdapter && root.btAdapter.enabled; onToggled: root.qsToggle("bt") }
                Caption { text: "MY DEVICES"; visible: root.btDevices.length > 0 }
                Repeater {
                  model: root.btDevices
                  RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 4
                    ChoiceRow {
                      label: String(modelData.name || modelData.deviceName || modelData.address)
                      hint: modelData.connected ? (modelData.batteryAvailable ? Math.round(modelData.battery * 100) + "%" : "connected") : ""
                      selected: modelData.connected
                      onChosen: root.btToggleDevice(modelData)
                    }
                    Text {
                      textFormat: Text.PlainText; text: "forget"; color: fgMouse.containsMouse ? root.urgent : root.dim
                      font.family: root.fontFamily; font.pixelSize: 9
                      MouseArea { id: fgMouse; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.btForget(modelData) }
                    }
                  }
                }
                Caption { text: root.btAdapter && root.btAdapter.discovering ? "NEARBY · SCANNING…" : "NEARBY" }
                Text {
                  visible: root.btNearby.length === 0
                  textFormat: Text.PlainText; text: root.btAdapter && root.btAdapter.enabled ? "Looking for devices…" : "Turn Bluetooth on to scan"
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
                }
                Repeater {
                  model: root.btNearby
                  ChoiceRow {
                    required property var modelData
                    label: String(modelData.name || modelData.deviceName)
                    hint: "pair"
                    onChosen: root.btPair(modelData)
                  }
                }
              }

              // Sound
              SectionHeader { sectionId: "sound"; icon: ""; label: "Sound"
                status: root.sink && root.sink.audio ? (root.sink.audio.muted ? "Muted" : Math.round(root.sink.audio.volume * 100) + "%") : "" }
              SectionBody {
                visible: root.qsSection === "sound"
                SliderRow { label: "OUT"; value: root.sink && root.sink.audio ? root.sink.audio.volume : 0; muted: !!root.sink && !!root.sink.audio && root.sink.audio.muted
                  onMoved: function(v) { if (root.sink && root.sink.audio) root.sink.audio.volume = v }
                  onMuteClicked: if (root.sink && root.sink.audio) root.sink.audio.muted = !root.sink.audio.muted }
                SliderRow { label: "MIC"; visible: !!root.source && !!root.source.audio; value: root.source && root.source.audio ? root.source.audio.volume : 0; muted: !!root.source && !!root.source.audio && root.source.audio.muted
                  onMoved: function(v) { if (root.source && root.source.audio) root.source.audio.volume = v }
                  onMuteClicked: if (root.source && root.source.audio) root.source.audio.muted = !root.source.audio.muted }
                Caption { text: "OUTPUT" }
                Repeater {
                  model: root.sinkNodes
                  ChoiceRow { required property var modelData; label: root.nodeName(modelData); selected: !!root.sink && root.sink.id === modelData.id; onChosen: root.setSink(modelData) }
                }
                Caption { text: "INPUT"; visible: root.sourceNodes.length > 0 }
                Repeater {
                  model: root.sourceNodes
                  ChoiceRow { required property var modelData; label: root.nodeName(modelData); selected: !!root.source && root.source.id === modelData.id; onChosen: root.setSource(modelData) }
                }
              }

              // Display
              SectionHeader { sectionId: "display"; icon: ""; label: "Display"
              status: root.displayCountdown > 0 ? "Keep? " + root.displayCountdown + " s" : root.displayPending ? "Not applied" : root.enabledDisplays.length > 1 ? root.enabledDisplays.length + " displays" : root.refreshRate > 0 ? root.resLabel(root.modeRes) + " · " + Math.round(root.refreshRate) + " Hz" : (root.qsState.night ? "Night on" : "Night off") }
              SectionBody {
                visible: root.qsSection === "display"
                // every connected display; the settings below act on the selected one
                Caption { text: "DISPLAYS" }
                Repeater {
                  model: root.displays
                  Rectangle {
                    id: dRow
                    required property var modelData
                    readonly property bool sel: modelData.name === root.selName
                    readonly property bool lastOn: !modelData.disabled && root.enabledDisplays.length < 2
                    Layout.fillWidth: true
                    implicitHeight: 38
                    radius: 5
                    color: sel ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : (dMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06) : "transparent")
                    MouseArea { id: dMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.selDisplay = dRow.modelData.name }
                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: 8
                      anchors.rightMargin: 8
                      spacing: 8
                      Text { textFormat: Text.PlainText; text: dRow.modelData.internal ? "\uf109" : "\uf108"; color: dRow.sel ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 12 }
                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: dRow.modelData.label; color: dRow.sel ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 11; font.bold: dRow.sel; elide: Text.ElideRight }
                        Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: dRow.modelData.name + " · " + root.displaySummary(dRow.modelData) + (dRow.modelData.focused ? " · focused" : ""); color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; elide: Text.ElideRight }
                      }
                      // on/off (the last display that's on can't be turned off)
                      Rectangle {
                        visible: root.displays.length > 1
                        opacity: dRow.lastOn ? 0.35 : 1
                        Layout.preferredWidth: 30; Layout.preferredHeight: 16; radius: 8
                        color: !dRow.modelData.disabled ? root.foreground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
                        Rectangle { width: 12; height: 12; radius: 6; anchors.verticalCenter: parent.verticalCenter; x: !dRow.modelData.disabled ? parent.width - width - 2 : 2
                          color: !dRow.modelData.disabled ? root.background : root.dim }
                        MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: dRow.lastOn ? Qt.ArrowCursor : Qt.PointingHandCursor
                          onClicked: if (!dRow.lastOn) root.setDisplayEnabled(dRow.modelData.name, dRow.modelData.disabled) }
                      }
                    }
                  }
                }
                // arrangement: drag a display; it snaps edge to edge with the others
                Caption { text: "ARRANGEMENT · DRAG TO MOVE"; visible: arrange.visible }
                Item {
                  id: arrange
                  visible: root.enabledDisplays.length > 1
                  Layout.fillWidth: true
                  Layout.preferredHeight: 110
                  readonly property var box: DisplayModel.bounds(root.displays)
                  readonly property real k: Math.min((width - 16) / Math.max(1, box.w), (height - 16) / Math.max(1, box.h))
                  readonly property real ox: (width - box.w * k) / 2
                  readonly property real oy: (height - box.h * k) / 2
                  Rectangle { anchors.fill: parent; radius: 6; color: "transparent"; border.width: 1; border.color: root.faint }
                  Repeater {
                    model: root.enabledDisplays
                    Rectangle {
                      id: tile
                      required property var modelData
                      readonly property var r: DisplayModel.rect(modelData)
                      readonly property real homeX: arrange.ox + (r.x - arrange.box.x) * arrange.k
                      readonly property real homeY: arrange.oy + (r.y - arrange.box.y) * arrange.k
                      readonly property bool sel: modelData.name === root.selName
                      x: homeX; y: homeY
                      width: Math.max(8, r.w * arrange.k - 2); height: Math.max(8, r.h * arrange.k - 2)
                      radius: 4
                      color: sel ? root.foreground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, tMouse.containsMouse ? 0.24 : 0.14)
                      border.width: tMouse.drag.active ? 1 : 0; border.color: root.foreground
                      z: tMouse.drag.active ? 2 : 1
                      Text { anchors.centerIn: parent; width: parent.width - 6; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; textFormat: Text.PlainText
                        text: tile.modelData.name; color: tile.sel ? root.background : root.foreground; font.family: root.fontFamily; font.pixelSize: 9 }
                      MouseArea {
                        id: tMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        preventStealing: true
                        cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        drag.target: tile
                        drag.threshold: 3
                        onPressed: root.selDisplay = tile.modelData.name
                        onReleased: {
                          if (!drag.active && Math.abs(tile.x - tile.homeX) < 1 && Math.abs(tile.y - tile.homeY) < 1) return
                          var lx = arrange.box.x + (tile.x - arrange.ox) / arrange.k
                          var ly = arrange.box.y + (tile.y - arrange.oy) / arrange.k
                          var name = tile.modelData.name
                          tile.x = Qt.binding(function() { return tile.homeX })
                          tile.y = Qt.binding(function() { return tile.homeY })
                          root.moveDisplay(name, lx, ly)
                        }
                      }
                    }
                  }
                }
                Caption { text: "BRIGHTNESS"; visible: root.brightness >= 0 }
                SliderRow { visible: root.brightness >= 0; label: ""; value: Math.max(0, root.brightness) / 100; onMoved: function(v) { root.setBrightness(v) } }
                Caption { text: "RESOLUTION" + (root.modeSize ? " · " + root.modeSize : ""); visible: root.resolutionOptions.length > 1 }
                Segmented {
                  visible: root.resolutionOptions.length > 1
                  options: root.resolutionOptions
                  current: root.modeRes
                  onPicked: function(v) { root.setResolution(v) }
                }
                Caption { text: "REFRESH RATE" + (root.resolutionOptions.length > 1 ? "" : (root.modeSize ? " · " + root.modeSize : "")); visible: root.refreshOptions.length > 0 }
                Segmented {
                  visible: root.refreshOptions.length > 0
                  options: root.refreshOptions
                  current: root.refreshCurrent
                  onPicked: function(v) { root.setRefresh(v) }
                }
                Caption { text: "SCALE" }
                Segmented {
                  options: [["1", "1×"], ["1.25", "1.25×"], ["1.6", "1.6×"], ["2", "2×"]]
                  current: root.displayScale
                  onPicked: function(v) { root.setScale(v) }
                }
                Caption { text: "ROTATION" }
                Segmented {
                  options: [["0", "0°"], ["1", "90°"], ["2", "180°"], ["3", "270°"]]
                  current: root.displayTransform
                  onPicked: function(v) { root.setTransform(v) }
                }
                // display changes above wait for Apply (brightness and text size change at once)
                RowLayout {
                  Layout.fillWidth: true
                  Layout.topMargin: 4
                  spacing: 6
                  Text { Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.WordWrap
                    text: root.displayCountdown > 0 ? "Keep these settings? Reverting in " + root.displayCountdown + " s"
                        : root.displayPending ? "Changes not applied yet" : "No changes"
                    color: root.displayPending || root.displayCountdown > 0 ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
                  // after Apply: Revert / Keep
                  Rectangle {
                    visible: root.displayCountdown > 0
                    Layout.preferredWidth: 64; Layout.preferredHeight: 26; radius: 5
                    color: rvMouse.containsMouse ? root.faint : "transparent"; border.width: 1; border.color: root.faint
                    Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: "Revert"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
                    MouseArea { id: rvMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.revertDisplayChanges() }
                  }
                  Rectangle {
                    visible: root.displayCountdown > 0
                    Layout.preferredWidth: 64; Layout.preferredHeight: 26; radius: 5
                    color: kpMouse.containsMouse ? Qt.lighter(root.foreground, 1.15) : root.foreground
                    Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: "Keep"; color: root.background; font.family: root.fontFamily; font.pixelSize: 10; font.bold: true }
                    MouseArea { id: kpMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.keepDisplayChanges() }
                  }
                  Rectangle {
                    visible: root.displayPending && root.displayCountdown === 0
                    Layout.preferredWidth: 64; Layout.preferredHeight: 26; radius: 5
                    color: dcMouse.containsMouse ? root.faint : "transparent"; border.width: 1; border.color: root.faint
                    Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: "Discard"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 10 }
                    MouseArea { id: dcMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.discardDisplayChanges() }
                  }
                  Rectangle {
                    visible: root.displayCountdown === 0
                    Layout.preferredWidth: 64; Layout.preferredHeight: 26; radius: 5
                    opacity: root.displayPending ? 1 : 0.35
                    color: root.displayPending ? (apMouse.containsMouse ? Qt.lighter(root.foreground, 1.15) : root.foreground) : "transparent"
                    border.width: root.displayPending ? 0 : 1; border.color: root.faint
                    Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: "Apply"; color: root.displayPending ? root.background : root.dim; font.family: root.fontFamily; font.pixelSize: 10; font.bold: root.displayPending }
                    MouseArea { id: apMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: root.displayPending ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: root.applyDisplayChanges() }
                  }
                }
                Caption { text: "TEXT SIZE" }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 6
                  Repeater {
                    model: [["−", -1], ["+", 1]]
                    Rectangle {
                      required property var modelData
                      Layout.preferredWidth: 30; Layout.preferredHeight: 26; radius: 5
                      color: tsMouse.containsMouse ? root.faint : "transparent"
                      border.width: 1; border.color: root.faint
                      Text { anchors.centerIn: parent; text: modelData[0]; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 13 }
                      MouseArea { id: tsMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setTextPx(root.textPx + modelData[1]) }
                    }
                  }
                  Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: root.textPx + " px"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 11 }
                }
                SwitchRow { label: "Night light"; on: root.qsState.night; onToggled: root.qsToggle("night") }
                MenuLinkRow { itemId: "setup.config.hyprsunset"; text: "Night light settings" }
                MenuLinkRow { itemId: "setup.monitors"; text: "Monitor setup" }
                LinkRow { label: "Theme & background"; onActivated: { root.closeQuickSettings(); root.enterSearch(win.monitorName); root.openMenu("appearance") } }
              }

              // Keyboard & mouse: settings saved by input.sh (a marked block in ~/.config/hypr/input.lua)
              SectionHeader { sectionId: "input"; icon: "\uf11c"; label: "Keyboard & mouse" }
              SectionBody {
                visible: root.qsSection === "input"
                Caption { text: "KEYBOARD · REPEAT" }
                SliderRow { label: "RATE"; value: (root.inputVal("repeat_rate", 40) - 10) / 70; valueText: root.inputVal("repeat_rate", 40) + "/s"
                  onMoved: function(v) { root.setInput("repeat_rate", Math.round(10 + v * 70)) } }
                SliderRow { label: "DELAY"; value: (root.inputVal("repeat_delay", 250) - 150) / 650; valueText: root.inputVal("repeat_delay", 250) + " ms"
                  onMoved: function(v) { root.setInput("repeat_delay", Math.round((150 + v * 650) / 10) * 10) } }
                SwitchRow { label: "Num Lock on at login"; on: root.inputVal("numlock_by_default", true) === true; onToggled: root.setInput("numlock_by_default", !(root.inputVal("numlock_by_default", true) === true)) }
                MenuLinkRow { itemId: "setup.typing.keyboard"; text: "Keyboard layouts" }
                MenuLinkRow { itemId: "setup.typing.input"; text: "Input methods" }
                MenuLinkRow { itemId: "setup.language" }
                Caption { text: "MOUSE" }
                SliderRow { label: "SPEED"; value: (Number(root.inputVal("sensitivity", 0)) + 1) / 2
                  valueText: (Number(root.inputVal("sensitivity", 0)) > 0 ? "+" : "") + Number(root.inputVal("sensitivity", 0)).toFixed(2)
                  onMoved: function(v) { root.setInput("sensitivity", Math.round((v * 2 - 1) * 20) / 20) } }
                Segmented {
                  readonly property string acc: String(root.inputVal("accel_profile", ""))
                  options: [["adaptive", "Acceleration"], ["flat", "Flat (raw)"]]
                  current: acc === "flat" ? "flat" : "adaptive"
                  onPicked: function(v) { root.setInput("accel_profile", v === "flat" ? "flat" : "default") }
                }
                SliderRow { label: "SCROLL"; value: (Number(root.inputVal("scroll_factor", 1)) - 0.2) / 2.8; valueText: Number(root.inputVal("scroll_factor", 1)).toFixed(1) + "×"
                  onMoved: function(v) { root.setInput("scroll_factor", Math.round((0.2 + v * 2.8) * 10) / 10) } }
                SwitchRow { label: "Natural scrolling"; on: root.inputVal("natural_scroll", false) === true; onToggled: root.setInput("natural_scroll", !(root.inputVal("natural_scroll", false) === true)) }
                Caption { text: "TOUCHPAD"; visible: root.inputVal("touchpad", false) === true }
                ColumnLayout {
                  visible: root.inputVal("touchpad", false) === true
                  Layout.fillWidth: true
                  spacing: 6
                  SwitchRow { label: "Tap to click"; on: root.inputVal("touchpad.tap_to_click", true) === true; onToggled: root.setInput("touchpad.tap_to_click", !(root.inputVal("touchpad.tap_to_click", true) === true)) }
                  SwitchRow { label: "Natural scrolling"; on: root.inputVal("touchpad.natural_scroll", false) === true; onToggled: root.setInput("touchpad.natural_scroll", !(root.inputVal("touchpad.natural_scroll", false) === true)) }
                  SwitchRow { label: "Off while typing"; on: root.inputVal("touchpad.disable_while_typing", true) === true; onToggled: root.setInput("touchpad.disable_while_typing", !(root.inputVal("touchpad.disable_while_typing", true) === true)) }
                  SliderRow { label: "SCROLL"; value: (Number(root.inputVal("touchpad.scroll_factor", 0.4)) - 0.1) / 1.9; valueText: Number(root.inputVal("touchpad.scroll_factor", 0.4)).toFixed(1) + "×"
                    onMoved: function(v) { root.setInput("touchpad.scroll_factor", Math.round((0.1 + v * 1.9) * 10) / 10) } }
                }
                Caption { text: "CONFIG" }
                MenuLinkRow { itemId: "setup.keybindings" }
                MenuLinkRow { itemId: "setup.input"; text: "Edit input.lua" }
                MenuLinkRow { itemId: "setup.config.xcompose"; text: "Compose key (XCompose)" }
                LinkRow { label: Object.keys(root.inputVal("saved", {})).length ? "Reset keyboard & mouse to Omarchy defaults" : ""; visible: label !== ""; onActivated: root.resetInput() }
              }

              // Notifications
              SectionHeader { sectionId: "notifications"; icon: ""; label: "Notifications"; status: root.dnd ? "Silenced" : "On" }
              SectionBody {
                visible: root.qsSection === "notifications"
                SwitchRow { label: "Do not disturb"; on: root.dnd; onToggled: root.qsToggle("dnd") }
              }

              // Default apps (from Omarchy's Setup menu), each with what's chosen now
              SectionHeader { sectionId: "defaults"; icon: "\uf005"; label: "Default apps"
                status: root.checkedChildLabel("setup.default.browser") }
              SectionBody {
                visible: root.qsSection === "defaults"
                Repeater {
                  model: ["agent", "browser", "terminal", "editor", "dictation"]
                  InlineMenu { required property string modelData; itemId: "setup.default." + modelData; hint: root.checkedChildLabel("setup.default." + modelData) }
                }
              }

              // Sidebar: opens Edit sidebar (plugin icons are set in the bottom row's
              // settings there, tray icons in the tray's)
              SectionHeader { sectionId: "sidebar"; icon: "\uf0db"; label: "Sidebar"; opens: true
                status: (root.hiddenNow.length > 0 ? root.hiddenNow.length + " hidden · " : "") + "Edit"
                onActivated: root.startEditing(win.monitorName) }

              // System: plugins, security and config files (from Omarchy's Setup menu)
              SectionHeader { sectionId: "system"; icon: "\uf085"; label: "System" }
              SectionBody {
                visible: root.qsSection === "system"
                // plugins: switch them on and off here
                Expander {
                  subId: "plugins"
                  icon: "\uf12e"
                  text: "Plugins"
                  hint: root.pluginsShown.filter(function(p) { return p.enabled }).length + " on" + (root.pluginBusy ? " · …" : "")
                  Repeater {
                    model: root.pluginsShown
                    SwitchRow {
                      required property var modelData
                      label: String(modelData.name || modelData.id)
                      hint: modelData.firstParty ? "" : String(modelData.id).split(".")[0]
                      on: modelData.enabled === true
                      opacity: modelData.enabled && !modelData.canDisable ? 0.4 : 1
                      onToggled: root.setPluginEnabled(modelData, !modelData.enabled)
                    }
                  }
                  Caption { text: "MORE" }
                  Repeater {
                    model: ["setup.plugin.add", "setup.plugin.clone", "setup.plugin.remove"]
                    ChoiceRow {
                      required property string modelData
                      readonly property var e: root.menuItems[modelData]
                      visible: !!e && root.visibleEntry(e)
                      radio: false
                      label: e ? String(e.label) + "…" : ""
                      hint: "↗"
                      onChosen: root.runMenuEntry({ id: modelData, action: e.action, checkable: false, hasKids: false })
                    }
                  }
                }
                InlineMenu { itemId: "setup.security" }
                // git: name and email for commits, edited here
                Expander {
                  subId: "git"
                  icon: "\uf1d3"
                  text: "Git"
                  hint: root.gitName
                  FieldRow { fieldId: "git.name"; label: "Name"; value: root.gitName; placeholder: "Your name"; onSaved: function(t) { root.setGit("name", t) } }
                  FieldRow { fieldId: "git.email"; label: "Email"; value: root.gitEmail; placeholder: "you@example.com"; onSaved: function(t) { root.setGit("email", t) } }
                  Text { Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.WordWrap; text: "Click a field, type, then Enter."; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9 }
                  MenuLinkRow { itemId: "setup.config.git"; text: "Sign in to GitHub (full git setup)" }
                }
                Caption { text: "CONFIG" }
                MenuLinkRow { itemId: "setup.config.hyprland"; text: "Hyprland config" }
                Caption { text: "STARTUP & RESET" }
                MenuLinkRow { itemId: "setup.direct-boot" }
                MenuLinkRow { itemId: "setup.reset" }
              }

              // Power
              SectionHeader { sectionId: "power"; icon: ""; label: "Power"; status: root.profileLabel(root.qsState.profile) + (root.batteryPresent ? " · " + root.batteryPct + "%" : "") }
              SectionBody {
                visible: root.qsSection === "power"
                Caption { text: "POWER MODE"; visible: root.qsState.profile !== "" }
                Segmented {
                  visible: root.qsState.profile !== ""
                  options: [["power-saver", "Saver"], ["balanced", "Balanced"], ["performance", "Performance"]]
                  current: root.qsState.profile
                  onPicked: function(v) { root.setProfile(v) }
                }
                SwitchRow { label: "Stay awake"; on: root.qsState.idle; onToggled: root.qsToggle("idle") }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 2
                  Repeater {
                    model: [["", "Lock", "omarchy-system-lock"], ["", "Sleep", "systemctl suspend"], ["", "Logout", "omarchy-system logout"],
                            ["", "Reboot", "omarchy-system reboot"], ["", "Off", "omarchy-system shutdown"]]
                    Rectangle {
                      required property var modelData
                      Layout.fillWidth: true
                      Layout.preferredHeight: 40
                      radius: 6
                      color: sMouse.containsMouse ? root.faint : "transparent"
                      Column {
                        anchors.centerIn: parent
                        spacing: 2
                        Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: modelData[0]; color: root.foreground; font.family: root.fontFamily; font.pixelSize: 13 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: modelData[1]; color: root.dim; font.family: root.fontFamily; font.pixelSize: 8 }
                      }
                      MouseArea { id: sMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.systemAction(modelData[2]) }
                    }
                  }
                }
              }
            }

            // ---- shared pieces of the sections ----------------------------------
            component Caption: Text {
              Layout.fillWidth: true
              Layout.topMargin: 4
              textFormat: Text.PlainText
              color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1
            }
            component Segmented: RowLayout {
              id: seg
              property var options: []      // [[value, label], ...]
              property string current: ""
              signal picked(string value)
              Layout.fillWidth: true
              spacing: 4
              Repeater {
                model: seg.options
                Rectangle {
                  required property var modelData
                  readonly property bool sel: seg.current === modelData[0]
                  Layout.fillWidth: true
                  Layout.preferredHeight: 26
                  radius: 5
                  color: sel ? root.foreground : (sgMouse.containsMouse ? root.faint : "transparent")
                  border.width: sel ? 0 : 1
                  border.color: root.faint
                  Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: modelData[1]; color: parent.sel ? root.background : root.dim; font.family: root.fontFamily; font.pixelSize: 10; font.bold: parent.sel }
                  MouseArea { id: sgMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: seg.picked(modelData[0]) }
                }
              }
            }

            Rectangle {
              id: updBtn
              readonly property bool ready: Number(root.updateCount) > 0 && !root.updating
              readonly property bool busy: root.updating || root.updateCount === ""
              Layout.fillWidth: true
              Layout.topMargin: 6
              implicitHeight: 28
              radius: 6
              color: updBtn.ready ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, updMouse.containsMouse ? 0.3 : 0.18)
                     : updMouse.containsMouse && !updBtn.busy ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                     : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              Row {
                anchors.centerIn: parent
                spacing: 6
                Text {
                  anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText
                  text: updBtn.busy ? "\uf110" : root.updateCount === "0" ? "\uf00c" : root.updateCount === "?" ? "\uf071" : "\uf019"
                  color: updBtn.ready ? root.foreground : root.dim; font.family: root.fontFamily; font.pixelSize: 11
                  RotationAnimator on rotation { running: updBtn.busy && root.qsOpen; from: 0; to: 360; duration: 1200; loops: Animation.Infinite }
                  onTextChanged: if (!updBtn.busy) rotation = 0
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText
                  text: root.updating ? "Updating\u2026"
                        : root.updateCount === "" ? "Checking for updates\u2026"
                        : root.updateCount === "0" ? "Rice up to date"
                        : root.updateCount === "?" ? "Can\u2019t check for updates"
                        : "Update rice \u00b7 " + root.updateCount + " new"
                  color: updBtn.ready || updMouse.containsMouse ? root.foreground : root.dim
                  font.family: root.fontFamily; font.pixelSize: 10; font.bold: updBtn.ready
                }
              }
              MouseArea {
                id: updMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: updBtn.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                onClicked: {
                  if (updBtn.busy) return
                  if (updBtn.ready) root.runUpdate()
                  else root.checkForUpdates(true)
                }
              }
            }
          }
        }
      }
    }
  }
}
