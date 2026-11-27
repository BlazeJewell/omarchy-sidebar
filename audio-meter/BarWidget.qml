import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Audio meter: the microphone's live level and the speakers' side by side, as
// a split meter (vertical columns or horizontal rows). The filled part is the
// sound right now, the marker is the volume setting. Scroll a side to change
// its volume, click it to mute. In the sidebar this panel is a section; in the
// stock bar it opens from the icon.
Panel {
  id: root
  moduleName: "jake.audio-meter"
  ipcTarget: "jake.audio-meter"
  // jake.sidebar: show this panel's content without the popup's padding
  readonly property bool tightInSidebar: true

  // ---- settings ----
  readonly property bool horizontal: root.setting("orientation", "vertical") === "horizontal"
  readonly property bool oneLine: root.setting("orientation", "vertical") === "line"
  readonly property bool segmented: root.setting("style", "segments") !== "solid"
  readonly property bool showNumbers: root.setting("showNumbers", true) !== false
  readonly property bool showDevice: root.setting("showDevice", true) !== false
  readonly property int barLength: Math.max(40, Math.min(240, Number(root.setting("length", 110)) || 110))

  // ---- look: the theme's text colour at two strengths, the accent for output ----
  readonly property color fg: Commons.Color.bar.text
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property color hot: Commons.Color.urgent
  readonly property color outInk: {
    var a = Commons.Color.accent
    var same = Math.abs(a.r - fg.r) + Math.abs(a.g - fg.g) + Math.abs(a.b - fg.b) < 0.15
    return same ? dim : a
  }
  // the mic side uses the accent too, so both halves match
  readonly property color inInk: outInk
  readonly property string fontFamily: Style.font.family

  // ---- the default mic and speakers ----
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  PwObjectTracker { objects: [root.sink, root.source].filter(function(n) { return !!n }) }
  // a virtual mic has no typed audio in Quickshell: its volume goes through wpctl
  // (Omarchy's UntypedInput) and it has no live level
  readonly property bool inputViaWpctl: UntypedInput.active
  readonly property bool hasIn: !!(source && source.audio) || (inputViaWpctl && UntypedInput.known)
  readonly property bool hasOut: !!(sink && sink.audio)
  readonly property real inVol: inputViaWpctl ? UntypedInput.volume : (source && source.audio ? source.audio.volume : 0)
  readonly property bool inMuted: inputViaWpctl ? UntypedInput.muted : (source && source.audio ? source.audio.muted : false)
  readonly property real outVol: hasOut ? sink.audio.volume : 0
  readonly property bool outMuted: hasOut ? sink.audio.muted : false
  function deviceName(n) { return n ? String(n.description || n.nickname || n.name || "") : "" }

  // ---- live levels: peaks in dB, drawn from -60 dB (empty) to 0 dB (full) ----
  PwNodePeakMonitor { id: inPeak; node: root.inputViaWpctl ? null : root.source; enabled: root.opened && !!root.source && !root.inputViaWpctl }
  PwNodePeakMonitor { id: outPeak; node: root.sink; enabled: root.opened && !!root.sink }
  // the peak monitor reports on PipeWire's cubic volume scale: cube it back to a linear amplitude
  function toDb(p) { var a = p * p * p; return a > 0.000001 ? 20 * Math.log10(a) : -120 }
  function toLevel(p) { return Math.max(0, Math.min(1, (root.toDb(p) + 60) / 60)) }
  // rises at once, falls back gently, like a meter needle
  property real inShown: 0
  property real outShown: 0
  Timer {
    interval: 33
    repeat: true
    running: root.opened
    onTriggered: {
      var a = root.toLevel(inPeak.peak), b = root.toLevel(outPeak.peak)
      root.inShown = a >= root.inShown ? a : Math.max(a, root.inShown - 0.025)
      root.outShown = b >= root.outShown ? b : Math.max(b, root.outShown - 0.025)
    }
  }
  function dbText(p, muted, known) {
    if (muted) return "muted"
    if (!known) return "—"
    var db = root.toDb(p)
    if (db <= -60) return "−∞"
    var r = Math.round(db)
    return r < 0 ? "−" + Math.abs(r) : String(r)
  }

  // ---- actions ----
  function nudgeIn(d) {
    var v = Math.max(0, Math.min(1, root.inVol + d))
    if (root.inputViaWpctl) { if (UntypedInput.known) UntypedInput.setVolume(v) }
    else if (root.source && root.source.audio) root.source.audio.volume = v
  }
  function nudgeOut(d) {
    if (!root.hasOut) return
    var cur = root.sink.audio.volume
    root.sink.audio.volume = Math.max(0, Math.min(Math.max(1, cur), cur + d))
  }
  function toggleIn() {
    if (root.inputViaWpctl) { if (UntypedInput.known) UntypedInput.setMuted(!UntypedInput.muted) }
    else if (root.source && root.source.audio) root.source.audio.muted = !root.source.audio.muted
  }
  function toggleOut() { if (root.hasOut) root.sink.audio.muted = !root.sink.audio.muted }

  // ---- one bar: segments (or a solid fill), the volume marker, stripes when muted ----
  component Meter: Item {
    id: m
    property bool horiz: false
    property real level: 0
    property real vol: 0
    property bool muted: false
    property color ink: root.inInk
    property real thick: 14
    property real len: 110
    property int notch: 0          // which side the volume marker sticks out: -1 before, 1 after, 0 both
    property bool showVol: true    // draw the volume marker
    signal clicked()
    signal wheeled(real step)
    implicitWidth: horiz ? 40 : thick
    implicitHeight: horiz ? thick : len
    readonly property real along: horiz ? width : height
    readonly property real step: 7                       // a 5 px segment and a 2 px gap
    readonly property int count: Math.max(4, Math.floor((along + 2) / step))
    readonly property real seg: (along + 2) / count      // stretched to fill exactly
    // segments, lit from the bottom (or left); the top few run hot
    Repeater {
      model: root.segmented ? m.count : 0
      Rectangle {
        required property int index
        readonly property real at: (index + 1) / m.count
        readonly property bool lit: !m.muted && at <= m.level + 0.0001
        x: m.horiz ? index * m.seg : 0
        y: m.horiz ? 0 : m.height - (index + 1) * m.seg + 2
        width: m.horiz ? m.seg - 2 : m.width
        height: m.horiz ? m.height : m.seg - 2
        radius: 1
        color: lit ? (at > 0.95 ? root.hot : m.ink) : root.faint
      }
    }
    // solid
    Rectangle {
      visible: !root.segmented
      anchors.fill: parent
      radius: 3
      color: root.faint
      Rectangle {
        visible: !m.muted
        radius: 3
        color: m.level > 0.95 ? root.hot : m.ink
        y: m.horiz ? 0 : parent.height - height
        width: m.horiz ? parent.width * m.level : parent.width
        height: m.horiz ? parent.height : parent.height * m.level
      }
    }
    // muted: diagonal stripes over the empty bar
    Canvas {
      id: stripes
      anchors.fill: parent
      visible: m.muted
      onVisibleChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var c = getContext("2d")
        c.reset()
        c.strokeStyle = root.dim
        c.lineWidth = 1
        for (var k = -height; k < width + height; k += 5) { c.beginPath(); c.moveTo(k, height); c.lineTo(k + height, 0); c.stroke() }
      }
    }
    // the volume setting: a line across the bar, sticking out on its outer side
    Rectangle {
      visible: m.showVol
      readonly property real p: Math.max(0, Math.min(1, m.vol))
      readonly property real before: m.notch <= 0 ? 4 : 0
      readonly property real after: m.notch >= 0 ? 4 : 0
      color: root.fg
      radius: 1
      x: m.horiz ? Math.max(0, Math.min(m.width - 2, p * m.width - 1)) : -before
      y: m.horiz ? -before : Math.max(0, Math.min(m.height - 2, m.height - p * m.height - 1))
      width: m.horiz ? 2 : m.width + before + after
      height: m.horiz ? m.height + before + after : 2
    }
    MouseArea {
      anchors.fill: parent
      anchors.margins: -4
      cursorShape: Qt.PointingHandCursor
      onClicked: m.clicked()
      onWheel: function(w) { m.wheeled(w.angleDelta.y > 0 || w.angleDelta.x > 0 ? 0.05 : -0.05) }
    }
  }

  // ---- the numbers beside a bar ----
  component Readout: ColumnLayout {
    id: ro
    property string caption: ""
    property string db: ""
    property bool showUnit: true
    property bool warn: false
    property color ink: root.inInk
    property real vol: 0
    property string device: ""
    property bool alignRight: false
    property bool big: true
    spacing: 1
    Text {
      Layout.fillWidth: true
      horizontalAlignment: ro.alignRight ? Text.AlignRight : Text.AlignLeft
      textFormat: Text.PlainText; text: ro.caption
      color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1
    }
    Row {
      visible: root.showNumbers
      Layout.alignment: ro.alignRight ? Qt.AlignRight : Qt.AlignLeft
      spacing: 3
      Text {
        id: roNum
        textFormat: Text.PlainText; text: ro.db
        color: ro.warn ? root.hot : ro.ink
        font.family: root.fontFamily; font.pixelSize: ro.big ? 22 : 13; font.bold: true
      }
      Text {
        visible: ro.showUnit
        anchors.baseline: roNum.baseline
        textFormat: Text.PlainText; text: "dB"
        color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
      }
    }
    Item { Layout.fillHeight: true; visible: ro.big }
    Text {
      visible: root.showNumbers
      Layout.fillWidth: true
      horizontalAlignment: ro.alignRight ? Text.AlignRight : Text.AlignLeft
      textFormat: Text.StyledText
      text: "vol <b>" + Math.round(ro.vol * 100) + "%</b>"
      color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
    }
    Text {
      visible: root.showDevice && ro.device !== ""
      Layout.fillWidth: true
      horizontalAlignment: ro.alignRight ? Text.AlignRight : Text.AlignLeft
      elide: ro.alignRight ? Text.ElideLeft : Text.ElideRight
      textFormat: Text.PlainText; text: ro.device
      color: root.dim; font.family: root.fontFamily; font.pixelSize: 9
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.outMuted ? "󰝟" : "󰕾"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(600))

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: meterBox.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Item {
        id: meterBox
        width: parent.width
        implicitHeight: root.oneLine ? lineLayout.implicitHeight : root.horizontal ? hLayout.implicitHeight : vLayout.implicitHeight

        // ---- vertical: readouts either side of two columns ----
        RowLayout {
          id: vLayout
          visible: !root.horizontal && !root.oneLine
          width: parent.width
          spacing: 14
          Readout {
            visible: root.showNumbers || root.showDevice
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            alignRight: true
            caption: "MIC IN"
            db: root.dbText(inPeak.peak, root.inMuted, !root.inputViaWpctl)
            showUnit: !root.inMuted && !root.inputViaWpctl
            warn: root.inMuted
            vol: root.inVol
            device: root.deviceName(root.source)
          }
          Item { visible: !(root.showNumbers || root.showDevice); Layout.fillWidth: true }
          ColumnLayout {
            spacing: 4
            Rectangle {
              implicitWidth: vBars.implicitWidth + 10
              implicitHeight: vBars.implicitHeight + 10
              radius: 6
              color: "transparent"
              border.width: 1
              border.color: root.faint
              Row {
                id: vBars
                anchors.centerIn: parent
                spacing: 3
                Meter { len: root.barLength; notch: -1; level: root.inShown; vol: root.inVol; muted: root.inMuted; ink: root.inInk; onClicked: root.toggleIn(); onWheeled: function(s) { root.nudgeIn(s) } }
                Meter { len: root.barLength; notch: 1; level: root.outShown; vol: root.outVol; muted: root.outMuted; ink: root.outInk; onClicked: root.toggleOut(); onWheeled: function(s) { root.nudgeOut(s) } }
              }
            }
            // with no readouts, say which side is which
            Row {
              visible: !(root.showNumbers || root.showDevice)
              Layout.alignment: Qt.AlignHCenter
              spacing: 6
              Text { textFormat: Text.PlainText; text: "IN"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 8; font.letterSpacing: 1 }
              Text { textFormat: Text.PlainText; text: "OUT"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 8; font.letterSpacing: 1 }
            }
          }
          Item { visible: !(root.showNumbers || root.showDevice); Layout.fillWidth: true }
          Readout {
            visible: root.showNumbers || root.showDevice
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            caption: "SOUND OUT"
            db: root.dbText(outPeak.peak, root.outMuted, root.hasOut)
            showUnit: !root.outMuted && root.hasOut
            warn: root.outMuted
            ink: root.outInk
            vol: root.outVol
            device: root.deviceName(root.sink)
          }
        }

        // ---- one line: [ OUT ◀────|────▶ IN ], both filling outward from the middle ----
        RowLayout {
          id: lineLayout
          visible: root.oneLine
          width: parent.width
          spacing: 6
          Text { textFormat: Text.PlainText; text: "OUT"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1 }
          Text {
            visible: root.showNumbers
            Layout.preferredWidth: lineNumW.width
            textFormat: Text.PlainText
            text: root.dbText(outPeak.peak, root.outMuted, root.hasOut)
            color: root.outMuted ? root.hot : root.outInk
            font.family: root.fontFamily; font.pixelSize: 11; font.bold: true
          }
          // sound out: the same meter, mirrored so it fills leftward from the middle
          Meter {
            id: outLine
            horiz: true
            thick: 8
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignVCenter
            Layout.rightMargin: -4
            showVol: false
            transform: Scale { xScale: -1; origin.x: outLine.width / 2 }
            level: root.outShown; vol: root.outVol; muted: root.outMuted; ink: root.outInk
            onClicked: root.toggleOut()
            onWheeled: function(s) { root.nudgeOut(s) }
          }
          Rectangle { implicitWidth: 2; implicitHeight: 14; radius: 1; color: root.dim; Layout.alignment: Qt.AlignVCenter }
          Meter {
            horiz: true
            thick: 8
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignVCenter
            Layout.leftMargin: -4
            showVol: false
            level: root.inShown; vol: root.inVol; muted: root.inMuted; ink: root.inInk
            onClicked: root.toggleIn()
            onWheeled: function(s) { root.nudgeIn(s) }
          }
          Text {
            visible: root.showNumbers
            Layout.preferredWidth: lineNumW.width
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: root.dbText(inPeak.peak, root.inMuted, !root.inputViaWpctl)
            color: root.inMuted ? root.hot : root.inInk
            font.family: root.fontFamily; font.pixelSize: 11; font.bold: true
          }
          Text { textFormat: Text.PlainText; text: "IN"; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1 }
          // fixed number width so the bars don't jump as the level changes
          Text { id: lineNumW; visible: false; text: "muted"; font.family: root.fontFamily; font.pixelSize: 11; font.bold: true }
        }

        // ---- horizontal: a row each, mic on top ----
        ColumnLayout {
          id: hLayout
          visible: root.horizontal && !root.oneLine
          width: parent.width
          spacing: 10
          Repeater {
            model: [
              { key: "in", caption: "MIC IN" },
              { key: "out", caption: "SOUND OUT" }
            ]
            ColumnLayout {
              id: hRow
              required property var modelData
              readonly property bool isIn: modelData.key === "in"
              readonly property bool muted: isIn ? root.inMuted : root.outMuted
              readonly property color ink: isIn ? root.inInk : root.outInk
              Layout.fillWidth: true
              spacing: 4
              RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: hRow.modelData.caption; color: root.dim; font.family: root.fontFamily; font.pixelSize: 9; font.letterSpacing: 1 }
                Text {
                  id: hNum
                  visible: root.showNumbers
                  textFormat: Text.PlainText
                  text: hRow.isIn ? root.dbText(inPeak.peak, root.inMuted, !root.inputViaWpctl) : root.dbText(outPeak.peak, root.outMuted, root.hasOut)
                  color: hRow.muted ? root.hot : hRow.ink
                  font.family: root.fontFamily; font.pixelSize: 13; font.bold: true
                }
                Text {
                  visible: root.showNumbers && !hRow.muted && (hRow.isIn ? !root.inputViaWpctl : root.hasOut)
                  Layout.alignment: Qt.AlignBaseline
                  textFormat: Text.PlainText; text: "dB"
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
                }
              }
              Meter {
                horiz: true
                thick: 10
                Layout.fillWidth: true
                level: hRow.isIn ? root.inShown : root.outShown
                vol: hRow.isIn ? root.inVol : root.outVol
                muted: hRow.muted
                ink: hRow.ink
                onClicked: hRow.isIn ? root.toggleIn() : root.toggleOut()
                onWheeled: function(s) { if (hRow.isIn) root.nudgeIn(s); else root.nudgeOut(s) }
              }
              RowLayout {
                visible: root.showNumbers || root.showDevice
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: 8
                Text {
                  visible: root.showNumbers
                  textFormat: Text.StyledText
                  text: "vol <b>" + Math.round((hRow.isIn ? root.inVol : root.outVol) * 100) + "%</b>"
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: 10
                }
                Text {
                  visible: root.showDevice
                  Layout.fillWidth: true
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.deviceName(hRow.isIn ? root.source : root.sink)
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: 9
                }
              }
            }
          }
        }
      }
    }
  }
}
