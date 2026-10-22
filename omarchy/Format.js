.pragma library

// Display helpers shared by the panes. Numbers come from the CLI as bytes and
// dates as UTC RFC 3339; both are shown in the user's language and time zone.

function bytes(n, lang) {
  n = Number(n) || 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var u = 0
  while (n >= 1024 && u < units.length - 1) { n /= 1024; u++ }
  var s = u === 0 ? String(Math.round(n)) : (n >= 100 ? n.toFixed(0) : n.toFixed(1))
  if (lang && lang !== "en") s = s.replace(".", ",")
  return s + " " + units[u]
}

function signedBytes(n, lang) {
  if (n === null || n === undefined) return "—"
  return (n >= 0 ? "+" : "−") + bytes(Math.abs(n), lang)
}

function localTime(iso, lang) {
  if (!iso) return ""
  var d = new Date(String(iso))
  if (isNaN(d.getTime())) return String(iso)
  var tag = lang === "pt" ? "pt_BR" : (lang === "es" ? "es_ES" : "en_US")
  return Qt.formatDateTime(d, Qt.locale(tag).dateTimeFormat(1))
}

// Same as the CLI's {0}/{1} substitution, in one pass.
function fill(template, args) {
  var s = String(template)
  if (!args) return s
  return s.replace(/\{(\d+)\}/g, function(m, i) { return i < args.length ? String(args[i]) : m })
}
