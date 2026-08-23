// Yahoo v7 spark response -> { SYMBOL: {price, change, changePercent, name} }
function parsePriceResponse(raw) {
  try {
    var parsed = JSON.parse(raw)
    var results = {}
    var rows = parsed.spark && parsed.spark.result ? parsed.spark.result : []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var resp = row.response && row.response[0] ? row.response[0] : null
      var meta = resp ? resp.meta : null
      if (!row.symbol || !meta || meta.regularMarketPrice === undefined) continue
      var price = Number(meta.regularMarketPrice)
      var prevClose = meta.chartPreviousClose !== undefined ? Number(meta.chartPreviousClose) : 0
      results[row.symbol] = {
        price: price,
        change: prevClose > 0 ? price - prevClose : 0,
        changePercent: prevClose > 0 ? ((price - prevClose) / prevClose) * 100 : 0,
        name: row.symbol
      }
    }
    return results
  } catch (e) {
    return {}
  }
}

function calculatePortfolio(holdings, prices) {
  var totalValue = 0
  var items = []

  for (var i = 0; i < holdings.length; i++) {
    var h = holdings[i]
    var ticker = h.ticker
    var shares = parseFloat(String(h.shares)) || 0
    var priceData = prices[ticker]
    var price = priceData ? priceData.price : 0
    var value = shares * price
    var change = priceData ? priceData.change : 0
    var changePercent = priceData ? priceData.changePercent : 0
    var dailyChange = shares * change

    totalValue += value
    items.push({
      ticker: ticker,
      shares: shares,
      price: price,
      value: value,
      change: change,
      changePercent: changePercent,
      dailyChange: dailyChange,
      name: priceData ? priceData.name : ticker
    })
  }

  return {
    totalValue: totalValue,
    items: items
  }
}

function formatCurrency(value) {
  if (value === undefined || value === null || isNaN(value)) return "$—"
  return "$" + Math.round(value).toLocaleString()
}

function formatCurrencyDetailed(value) {
  if (value === undefined || value === null || isNaN(value)) return "$—"
  return "$" + value.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function formatChange(value) {
  if (value === undefined || value === null || isNaN(value)) return "—"
  var sign = value >= 0 ? "+" : ""
  return sign + value.toFixed(2) + "%"
}

// One v8 chart JSON line -> { symbol, closes[], timestamps[] } or null.
// Closes with null values are dropped together with their timestamp so the
// two arrays stay index-aligned.
function parseChartLine(raw) {
  try {
    var d = JSON.parse(String(raw))
    var r = d.chart && d.chart.result && d.chart.result[0] ? d.chart.result[0] : null
    if (!r) return null
    var q = r.indicators && r.indicators.quote && r.indicators.quote[0] ? r.indicators.quote[0].close : null
    var ts = r.timestamp || []
    if (!q || !ts.length) return null
    var closes = []
    var stamps = []
    for (var i = 0; i < q.length; i++) {
      if (q[i] === null || q[i] === undefined) continue
      closes.push(Number(q[i]))
      stamps.push(Number(ts[i]))
    }
    return {
      symbol: r.meta && r.meta.symbol ? r.meta.symbol : "",
      closes: closes,
      timestamps: stamps
    }
  } catch (e) {
    return null
  }
}

function formatDate(stamp, withYear) {
  var d = new Date(stamp * 1000)
  if (isNaN(d.getTime())) return ""
  return Qt.formatDate(d, withYear ? "d MMM yyyy" : "d MMM")
}

// Weighted total-value series across all holdings, aligned to the shortest
// close array. Falls back to [] when any ticker is missing data.
function totalSeries(chartData, holdings) {
  var rows = []
  var len = -1
  for (var i = 0; i < holdings.length; i++) {
    var t = holdings[i] && holdings[i].ticker
    if (!t) continue
    var c = chartData[t]
    if (!c || !c.closes || c.closes.length < 2) return []
    len = len === -1 ? c.closes.length : Math.min(len, c.closes.length)
    rows.push({ ticker: t, shares: parseFloat(String(holdings[i].shares)) || 0 })
  }
  if (len <= 0) return []

    var out = []
    for (var j = 0; j < len; j++) {
      var sum = 0
      for (var k = 0; k < rows.length; k++) {
        var arr = chartData[rows[k].ticker].closes
        sum += rows[k].shares * arr[arr.length - len + j]
      }
      out.push(sum)
    }
    return out
  }

if (typeof module !== "undefined") {
  module.exports = {
    parsePriceResponse: parsePriceResponse,
    parseChartLine: parseChartLine,
    totalSeries: totalSeries,
    calculatePortfolio: calculatePortfolio,
    formatCurrency: formatCurrency,
    formatCurrencyDetailed: formatCurrencyDetailed,
    formatChange: formatChange
  }
}
