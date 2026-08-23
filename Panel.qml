import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "softroni.portfolio"
  ipcTarget: "softroni.portfolio"
  manageIpc: false

  readonly property string configPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/portfolio.json"

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    configFile.reload()
    root.chartRetries = 0
    root.refresh(false)
    root.fetchCharts(false)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    configFile.reload()
    root.chartRetries = 0
    root.refresh(false)
    root.fetchCharts(false)
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingHoldings) root.editingHoldings = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  property string label: ""
  property var portfolio: ({ totalValue: 0, items: [] })
  property bool loading: false
  property var holdings: []
  property bool editingHoldings: false
  // Index of the holding loaded into the form via a row click;
  // -1 means the form is adding a new ticker.
  property int editingIndex: -1

  // Trend charts. chartFocus "" = total portfolio series; otherwise ticker.
  readonly property string chartUserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
  property string chartRange: "1y" // "1mo" | "1y"
  property var chartData: ({}) // ticker -> closes[]
  property bool chartsLoading: false
  property int chartRetries: 0
  property string chartFocus: ""

  // Computed imperatively (rebuildChartSeries); a declarative binding here
  // trips Qt's binding-loop detector.
  property var chartSeries: []
  property var chartStamps: [] // epoch seconds aligned with chartSeries

  onChartDataChanged: root.rebuildChartSeries()
  onChartFocusChanged: root.rebuildChartSeries()

  function rebuildChartSeries() {
    if (root.chartFocus !== "") {
      var entry = root.chartData[root.chartFocus]
      root.chartSeries = entry && entry.closes ? entry.closes : []
      root.chartStamps = entry && entry.timestamps ? entry.timestamps : []
      return
    }
    var out = Model.totalSeries(root.chartData, root.holdings)
    root.chartSeries = out
    root.chartStamps = []
    // Total stamps: borrow the aligned slice from any holding that has data.
    if (out.length > 1) {
      for (var i = 0; i < root.holdings.length; i++) {
        var e = root.chartData[root.holdings[i].ticker]
        if (e && e.timestamps && e.timestamps.length >= out.length) {
          root.chartStamps = e.timestamps.slice(e.timestamps.length - out.length)
          break
        }
      }
    }
  }

  readonly property bool chartTrendingUp: {
    var s = root.chartSeries
    if (!s || s.length < 2) return true
    return s[s.length - 1] >= s[0]
  }
  readonly property string chartPeriodChange: {
    var s = root.chartSeries
    if (!s || s.length < 2) return ""
    var first = s[0]
    var last = s[s.length - 1]
    if (!(first > 0)) return ""
    return Model.formatChange((last - first) / first * 100)
  }

  onChartRangeChanged: {
    root.chartData = {}
    root.chartRetries = 0
    root.fetchCharts()
  }

  function fetchCharts(forced) {
    if (forced === undefined) forced = true
    var tickers = []
    for (var i = 0; i < holdings.length; i++) {
      if (holdings[i].ticker) tickers.push(holdings[i].ticker)
    }
    if (tickers.length === 0) {
      root.chartData = {}
      return
    }
    var now = new Date().getTime()
    var hasData = Object.keys(root.chartData).length > 0
    var fresh = hasData && now - lastChartsAt < chartTtlMs
    if (!forced && fresh) return
    if (!hasData) chartsLoading = true
    // Weekly candles keep multi-year payloads light.
    var interval = root.chartRange === "5y" ? "1wk" : "1d"
    var script = 'for t in ' + tickers.join(' ') + '; do '
      + 'curl -fsS --max-time 8 -H "User-Agent: ' + root.chartUserAgent + '" '
      + '"https://query1.finance.yahoo.com/v8/finance/chart/$t?interval=' + interval + '&range=' + root.chartRange + '"; echo; done'
    chartProc.command = ["bash", "-c", script]
    chartProc.running = true
  }

  Process {
    id: chartProc
    stdout: SplitParser {
      onRead: function(line) {
        var entry = Model.parseChartLine(String(line))
        if (!entry || !entry.symbol || entry.closes.length < 2) return
        root.chartRetries = 0
        root.lastChartsAt = new Date().getTime()
        var next = {}
        for (var k in root.chartData) next[k] = root.chartData[k]
        next[entry.symbol] = entry // { closes[], timestamps[] }
        root.chartData = next
      }
    }
    onExited: {
      root.chartsLoading = false
      // Startup often races the network coming up; retry a few times
      // whenever we ended the round with nothing usable.
      if ((!root.chartSeries || root.chartSeries.length < 2) && root.chartRetries < 3) {
        root.chartRetries++
        chartRetryTimer.restart()
      }
    }
  }

  Timer {
    id: chartRetryTimer
    interval: 4000
    onTriggered: root.fetchCharts()
  }

  // Leaving or re-entering edit mode always starts from a clean Add form.
  onEditingHoldingsChanged: {
    root.editingIndex = -1
    tickerField.text = ""
    sharesField.text = ""
  }

  // Config file loads async; refetch whenever holdings load or change on disk.
  onHoldingsChanged: {
    root.refresh(true)
    root.chartFocus = ""
    root.fetchCharts(true)
    root.rebuildChartSeries()
  }

  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 30), 10) || 30)

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseConfig(text())
    onLoadFailed: root.holdings = []
  }

  function parseConfig(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      root.holdings = Array.isArray(data.holdings) ? data.holdings : []
    } catch (e) {
      root.holdings = []
    }
  }

  // Freshness windows: reopening the panel within these shows cached data
  // instead of flashing "Fetching…"/"Loading trend…".
  readonly property int priceTtlMs: 5 * 60 * 1000   // 5 min
  readonly property int chartTtlMs: 60 * 60 * 1000  // 60 min (daily/weekly candles)
  property double lastPricesAt: 0
  property double lastChartsAt: 0

  // Default is forced=true: bare refresh() really fetches. Internal callers
  // (open, timers, holdings reload) pass false to honor the TTL cache.
  function refresh(forced) {
    if (forced === undefined) forced = true
    if (holdings.length === 0) {
      root.label = Model.formatCurrency(0)
      root.portfolio = { totalValue: 0, items: [] }
      return
    }
    var now = new Date().getTime()
    if (!forced && lastPricesAt > 0 && now - lastPricesAt < priceTtlMs) return
    // Busy text only when nothing is rendered yet; otherwise update silently.
    if (root.portfolio.items.length === 0) loading = true
    root.lastPricesAt = new Date().getTime()
    var tickers = []
    for (var i = 0; i < holdings.length; i++) {
      if (holdings[i].ticker) tickers.push(holdings[i].ticker)
    }
    var symbols = tickers.join(",")
    var url = "https://query1.finance.yahoo.com/v7/finance/spark?symbols=" + encodeURIComponent(symbols) + "&range=1d&interval=1d"
    // Yahoo rejects requests without a browser-like User-Agent (HTTP 429).
    priceFetchProc.command = ["curl", "-fsS", "--max-time", "10",
      "-H", "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36", url]
    priceFetchProc.running = true
  }

  Process {
    id: priceFetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.loading = false
          return
        }
        root.portfolio = Model.calculatePortfolio(root.holdings, Model.parsePriceResponse(raw))
        root.label = Model.formatCurrency(root.portfolio.totalValue)
        root.loading = false
        root.lastPricesAt = new Date().getTime()
      }
    }
  }

  // Persist edits by shelling out; argv passing avoids all quoting issues.
  Process {
    id: saveProc
  }

  function persistHoldings() {
    var json = JSON.stringify({ holdings: root.holdings }, null, 2) + "\n"
    saveProc.command = ["sh", "-c", 'printf "%s" "$1" > "$2"', "sh", json, root.configPath]
    saveProc.running = true
  }

  function commitForm() {
    var ticker = tickerField.text.trim().toUpperCase()
    var shares = parseFloat(sharesField.text.replace(",", "."))
    if (ticker === "" || isNaN(shares) || shares <= 0) return

    var list = root.holdings.slice()
    var targetIndex = root.editingIndex
    if (targetIndex < 0) {
      // Fresh entry typed by hand: still update in place when the
      // ticker already exists instead of duplicating it.
      for (var i = 0; i < list.length; i++) {
        if (list[i].ticker === ticker) { targetIndex = i; break }
      }
    }
    if (targetIndex >= 0 && targetIndex < list.length)
      list[targetIndex] = { ticker: ticker, shares: shares }
    else
      list.push({ ticker: ticker, shares: shares })

    root.editingIndex = -1
    root.holdings = list
    persistHoldings()
    tickerField.text = ""
    sharesField.text = ""
    Qt.callLater(function() { tickerField.forceActiveFocus() })
  }

  function removeHolding(index) {
    var list = root.holdings.slice()
    if (index < 0 || index >= list.length) return
    list.splice(index, 1)
    root.holdings = list
    persistHoldings()
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function edit(): void { root.openFromHotkey(); root.editingHoldings = true }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(portfolioColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingHoldings
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: portfolioColumn
        width: parent.width
        spacing: Style.space(12)

        // ---- Header: title left; refresh + edit buttons right.
        Item {
          width: parent.width
          height: Style.space(24)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "PORTFOLIO"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Row {
            visible: root.holdings.length > 0
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            // Chart range toggle.
            Repeater {
              model: [
                { label: "1M", range: "1mo" },
                { label: "3M", range: "3mo" },
                { label: "6M", range: "6mo" },
                { label: "1Y", range: "1y" },
                { label: "5Y", range: "5y" }
              ]

              delegate: Rectangle {
                required property var modelData
                width: Style.space(30)
                height: Style.space(22)
                radius: Math.min(4, Style.cornerRadius)
                color: root.chartRange === modelData.range
                    || rangeArea.containsMouse
                  ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: parent.modelData.label
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: root.chartRange === parent.modelData.range
                  color: Qt.darker(root.bar.foreground, 1.3)
                }

                MouseArea {
                  id: rangeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.chartRange = parent.modelData.range
                }
              }
            }

            // Refresh button; becomes a spinner while fetching.
            Rectangle {
              id: refreshBtn
              width: Style.space(22)
              height: Style.space(22)
              radius: Math.min(4, Style.cornerRadius)
              color: !refreshBtn.fetching && refreshBtn.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

              // Spin whenever any network fetch is actually in flight,
              // including silent background revalidations.
              readonly property bool fetching: priceFetchProc.running || chartProc.running

              Text {
                anchors.centerIn: parent
                // nf-fa-arrows-rotate.
                text: "\uf021"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                color: refreshBtn.fetching ? Qt.darker(root.bar.foreground, 1.2) : root.bar.foreground

                RotationAnimator on rotation {
                  running: refreshBtn.fetching
                  from: 0; to: 360
                  duration: 900
                  loops: Animation.Infinite
                }
              }

              MouseArea {
                anchors.fill: parent
                enabled: !refreshBtn.fetching
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.BusyCursor
                onClicked: {
                  root.refresh()
                  root.fetchCharts()
                }
              }
            }

            // Edit toggle.
            Rectangle {
              width: Style.space(22)
              height: Style.space(22)
              radius: Math.min(4, Style.cornerRadius)
              color: editArea.containsMouse || root.editingHoldings ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

              Text {
                anchors.centerIn: parent
                text: root.editingHoldings ? "✓" : "✎"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                color: root.bar.foreground
              }

              MouseArea {
                id: editArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.editingHoldings = !root.editingHoldings
              }
            }
          }
        }

        Text {
          visible: root.holdings.length > 0
          text: root.loading && root.portfolio.items.length === 0 ? "Fetching…" : Model.formatCurrencyDetailed(portfolio.totalValue)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Rectangle {
          visible: root.holdings.length > 0
          width: parent.width
          height: Style.spacing.hairline
          color: root.bar.foreground
          opacity: 0.12
        }

        // ---- Empty state: friendly intro + direct path to adding holdings.
        Column {
          visible: root.holdings.length === 0 && !root.editingHoldings
          width: parent.width
          spacing: Style.space(10)

          Item { width: 1; height: Style.space(8) }

          Text {
            text: "\uf080" // nf-fa-chart_line
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: 40
            anchors.horizontalCenter: parent.horizontalCenter
          }

          Text {
            text: "No holdings yet"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.horizontalCenter: parent.horizontalCenter
          }

          Text {
            width: parent.width - Style.space(48)
            text: "Add the tickers you own — stocks, ETFs, index funds — with your share counts, and follow their total value and trend here."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            anchors.horizontalCenter: parent.horizontalCenter
          }

          Rectangle {
            width: Style.space(190)
            height: Style.space(32)
            radius: Math.min(4, Style.cornerRadius)
            anchors.horizontalCenter: parent.horizontalCenter
            color: firstAddArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : Qt.alpha(root.bar.foreground, 0.08)

            Row {
              anchors.centerIn: parent
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "＋"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                color: root.bar.foreground
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Add first holding"
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                color: root.bar.foreground
              }
            }

            MouseArea {
              id: firstAddArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.editingHoldings = true
            }
          }
        }

        Repeater {
          model: root.portfolio.items

          Item {
            id: holdingRow
            required property var modelData
            required property int index
            width: portfolioColumn.width
            height: contentCol.implicitHeight

            // Hover highlight; steady tint while this row is the chart focus.
            Rectangle {
              anchors.fill: parent
              radius: Math.min(4, Style.cornerRadius)
              color: root.chartFocus === modelData.ticker
                  || rowArea.containsMouse
                ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
            }

            // Normal mode: click focuses/unfocuses that ticker's trend chart.
            // Edit mode: click loads the row into the form for updating.
            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.editingHoldings) {
                  root.editingIndex = index
                  tickerField.text = modelData.ticker
                  sharesField.text = String(modelData.shares)
                  Qt.callLater(function() {
                    sharesField.forceActiveFocus()
                    sharesField.selectAll()
                  })
                } else {
                  root.chartFocus = root.chartFocus === modelData.ticker ? "" : modelData.ticker
                }
              }
            }

            Column {
              id: contentCol
              width: parent.width
              spacing: Style.space(6)

              Row {
                id: rowLayout
                spacing: Style.space(8)

              // Remove button (edit mode only).
              Rectangle {
                visible: root.editingHoldings
                width: visible ? Style.space(20) : 0
                height: Style.space(20)
                anchors.verticalCenter: parent.verticalCenter
                radius: Math.min(4, Style.cornerRadius)
                color: removeArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                Text {
                  anchors.centerIn: parent
                  text: "✕"
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  color: root.bar.foreground
                }

                MouseArea {
                  id: removeArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.removeHolding(index)
                }
              }

              Text {
                text: modelData.ticker
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                width: Style.space(46)
              }

              Text {
                text: modelData.shares.toFixed(3)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: Style.space(56)
                horizontalAlignment: Text.AlignRight
              }

              Text {
                text: "@"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                text: Model.formatCurrencyDetailed(modelData.price)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: Style.space(70)
                horizontalAlignment: Text.AlignRight
              }

              Item { width: Style.space(2); height: 1 }

                Text {
                  text: Model.formatCurrencyDetailed(modelData.value)
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  width: Style.space(80)
                  horizontalAlignment: Text.AlignRight
                }
              }
            }
          }
        }

        Text {
          visible: root.holdings.length === 0 && !root.editingHoldings
          text: "No holdings — click ✎ to add some"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Rectangle {
          visible: root.holdings.length > 0
          width: parent.width
          height: Style.spacing.hairline
          color: root.bar.foreground
          opacity: 0.12
        }

        // ---- Add / update form (edit mode only).
        Row {
          visible: root.editingHoldings
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: tickerField
            width: Style.space(110)
            placeholderText: "TICKER"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                sharesField.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.editingHoldings = false
                root.editingIndex = -1
                event.accepted = true
              }
            }
          }

          TextField {
            id: sharesField
            width: Style.space(90)
            placeholderText: "Shares"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.commitForm()
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.editingHoldings = false
                root.editingIndex = -1
                event.accepted = true
              }
            }
          }

          Rectangle {
            width: Style.space(64)
            height: Style.space(28)
            radius: Math.min(4, Style.cornerRadius)
            color: addArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : Qt.alpha(root.bar.foreground, 0.08)

            Text {
              anchors.centerIn: parent
              text: root.editingIndex >= 0 ? "Update" : "Add"
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              color: root.bar.foreground
            }

            MouseArea {
              id: addArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.commitForm()
            }
          }
        }

        // ---- Trend chart: total portfolio by default; click any holding
        //      row (outside edit mode) to focus it, click again for total.
        Column {
          visible: !root.editingHoldings && root.holdings.length > 0
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            height: Style.space(16)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.chartFocus === "" ? "TOTAL TREND" : root.chartFocus + " TREND"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.chartPeriodChange !== ""
              text: root.chartPeriodChange
              color: root.chartTrendingUp ? Color.accent : Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Canvas {
            id: trendCanvas
            width: parent.width
            height: Style.space(90)

            property var values: root.chartSeries
            property int hoverIndex: -1

            readonly property real plotPad: 4
            readonly property real plotW: width - plotPad * 2
            readonly property real xStep: values.length > 1 ? plotW / (values.length - 1) : 0

            function indexAtX(mx) {
              if (!values || values.length < 2 || xStep <= 0) return -1
              var idx = Math.round((mx - plotPad) / xStep)
              if (idx < 0 || idx >= values.length) return -1
              return idx
            }

            onValuesChanged: {
              hoverIndex = -1
              requestPaint()
            }
            onWidthChanged: requestPaint()
            onVisibleChanged: if (visible) requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              if (!values || values.length < 2) return
              var min = values[0]
              var max = values[0]
              for (var i = 1; i < values.length; i++) {
                if (values[i] < min) min = values[i]
                if (values[i] > max) max = values[i]
              }
              var pad = plotPad
              var w = plotW
              var h = height - pad * 2
              var span = max - min > 0 ? max - min : 1
              var stroke = String(root.chartTrendingUp ? Color.accent : Color.urgent)

              // Crosshair at the hovered point.
              if (hoverIndex >= 0 && hoverIndex < values.length) {
                var hx = pad + hoverIndex * xStep
                ctx.beginPath()
                ctx.moveTo(hx, pad)
                ctx.lineTo(hx, pad + h)
                ctx.strokeStyle = Qt.rgba(0.5, 0.5, 0.5, 0.35)
                ctx.lineWidth = 1
                ctx.stroke()
              }

              ctx.beginPath()
              var lastX = 0
              var lastY = 0
              for (var j = 0; j < values.length; j++) {
                var x = pad + j * xStep
                var y = pad + h - ((values[j] - min) / span) * h
                if (j === 0) ctx.moveTo(x, y)
                else ctx.lineTo(x, y)
                lastX = x
                lastY = y
              }
              ctx.strokeStyle = stroke
              ctx.lineWidth = 1.5
              ctx.stroke()

              // Endpoint marker.
              ctx.beginPath()
              ctx.arc(lastX, lastY, 2.5, 0, 2 * Math.PI)
              ctx.fillStyle = stroke
              ctx.fill()

              // Hover marker.
              if (hoverIndex >= 0 && hoverIndex < values.length) {
                var px = pad + hoverIndex * xStep
                var py = pad + h - ((values[hoverIndex] - min) / span) * h
                ctx.beginPath()
                ctx.arc(px, py, 3, 0, 2 * Math.PI)
                ctx.fillStyle = stroke
                ctx.fill()
                ctx.beginPath()
                ctx.arc(px, py, 3, 0, 2 * Math.PI)
                ctx.strokeStyle = String(root.bar.foreground)
                ctx.lineWidth = 1
                ctx.stroke()
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
              cursorShape: Qt.BlankCursor
              onMouseXChanged: function(mouse) {
                trendCanvas.hoverIndex = trendCanvas.indexAtX(mouse.x)
                trendCanvas.requestPaint()
              }
              onExited: {
                trendCanvas.hoverIndex = -1
                trendCanvas.requestPaint()
              }
            }

            // Hover readout: date + value of the nearest data point.
            Item {
              id: hoverTip
              visible: trendCanvas.hoverIndex >= 0 && trendCanvas.values.length > 1
              x: {
                if (!visible) return 0
                var tipW = tipRow.implicitWidth + Style.space(12)
                var px = trendCanvas.plotPad + trendCanvas.hoverIndex * trendCanvas.xStep
                var tx = px - tipW / 2
                return Math.max(0, Math.min(tx, trendCanvas.width - tipW))
              }
              y: 0
              width: tipRow.implicitWidth + Style.space(12)
              height: tipRow.implicitHeight + Style.space(6)

              Rectangle {
                anchors.fill: parent
                radius: Math.min(4, Style.cornerRadius)
                color: root.bar.background
                opacity: 0.95
                border.width: 1
                border.color: Qt.alpha(root.bar.foreground, 0.25)
              }

              Row {
                id: tipRow
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    var idx = trendCanvas.hoverIndex
                    if (idx < 0 || idx >= root.chartStamps.length) return ""
                    return Model.formatDate(root.chartStamps[idx], root.chartRange === "5y")
                  }
                  color: Qt.darker(root.bar.foreground, 1.3)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    var idx = trendCanvas.hoverIndex
                    if (idx < 0 || idx >= trendCanvas.values.length) return ""
                    return Model.formatCurrencyDetailed(trendCanvas.values[idx])
                  }
                  color: root.chartTrendingUp ? Color.accent : Color.urgent
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }

            Text {
              visible: !(root.chartSeries && root.chartSeries.length > 1)
              text: root.chartsLoading ? "Loading trend…" : "No trend data"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
            }
          }
        }
      }
    }
  }
}
