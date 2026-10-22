.pragma library

// Port of Sources/SniffIdentity/DogMotion.swift: authored sniffs, head search,
// tail wags and hip sway on a 12-second loop. `amount` fades the whole pose
// in and out, so the dog settles to rest instead of freezing mid-motion.

var duration = 12.0

var head = [[0, 0], [0.5, -0.014], [1.9, -0.025], [2.2, -0.025], [2.55, -0.145], [2.9, -0.132],
  [3.5, -0.132], [3.92, -0.018], [5.0, -0.022], [6.35, -0.012], [6.72, -0.065], [7.03, -0.025],
  [8.0, -0.02], [8.65, -0.035], [9.4, -0.008], [10.5, -0.008], [11.0, 0], [12, 0]]

var search = [[0, 0], [0.65, -0.38], [0.9, -0.38], [1.6, 0.63], [1.95, 0.63], [2.4, -0.48],
  [3.45, -0.48], [3.95, -0.08], [5.12, 0.65], [5.45, 0.65], [6.15, -0.72], [6.6, -0.72],
  [7.2, 0.4], [7.75, 0.4], [8.6, -0.25], [9.6, 0.1], [10.45, 0.1], [11.0, 0], [12, 0]]

var sniffs = [[0.68, 0.21, 0.032], [1.12, 0.25, 0.05], [1.53, 0.17, 0.035], [4.18, 0.17, 0.042],
  [4.5, 0.22, 0.035], [5.85, 0.28, 0.045], [6.22, 0.19, 0.03], [7.1, 0.16, 0.05],
  [7.38, 0.23, 0.045], [8.48, 0.25, 0.023]]

// start, length, attack, release, frequency, acceleration, strength, hips
var wags = [[0.35, 1.55, 0.24, 0.4, 1.3, 0.35, 0.12, 0.6],
  [3.55, 2.05, 0.18, 0.55, 2.0, 0.42, 0.31, 2.35],
  [7.1, 1.82, 0.16, 0.5, 2.9, -0.65, 0.28, 1.9],
  [10.35, 0.65, 0.12, 0.28, 1.4, -0.4, 0.08, 0.25]]

// cubic-bezier(0.77, 0, 0.175, 1)
function ease(p) {
  if (p <= 0) return 0
  if (p >= 1) return 1
  var low = 0, high = 1
  for (var i = 0; i < 16; i++) {
    var t = (low + high) / 2, inv = 1 - t
    var x = 3 * inv * inv * t * 0.77 + 3 * inv * t * t * 0.175 + t * t * t
    if (x < p) low = t; else high = t
  }
  var tt = (low + high) / 2
  return 3 * (1 - tt) * tt * tt + tt * tt * tt
}

function pulse(time, start, attack, hold, release) {
  var local = time - start
  if (local <= 0 || local >= attack + hold + release) return 0
  if (local < attack) return ease(local / attack)
  if (local < attack + hold) return 1
  return 1 - ease((local - attack - hold) / release)
}

function track(keys, time) {
  if (time <= keys[0][0]) return keys[0][1]
  for (var i = 1; i < keys.length; i++) {
    if (time < keys[i][0]) {
      var a = keys[i - 1], b = keys[i]
      return a[1] + (b[1] - a[1]) * ease((time - a[0]) / (b[0] - a[0]))
    }
  }
  return keys[keys.length - 1][1]
}

function sniff(time) {
  var sum = 0
  for (var i = 0; i < sniffs.length; i++) {
    var s = sniffs[i]
    sum += s[2] * pulse(time, s[0], s[1] * 0.28, 0, s[1] * 0.72)
  }
  return sum
}

function headAngle(time) { return track(head, time) - sniff(time) }

function wagPhase(w, t) { return 2 * Math.PI * (w[4] * t + w[5] * t * t / 2) }
function wagEnvelope(w, t) { return pulse(t, 0, w[2], w[1] - w[2] - w[3], w[3]) }

function pose(elapsed, amount) {
  amount = Math.min(1, Math.max(0, amount))
  var p = { headAngle: 0, headTurn: 0, tailAngle: 0, tailBend: 0, rumpSway: 0, rumpLift: 0, eyeOpen: 1, scent: 0 }
  if (amount <= 0) return p
  var time = Math.max(0, elapsed) % duration
  var inhale = sniff(time)
  p.headAngle = headAngle(time) * amount
  p.headTurn = track(search, time) * amount
  for (var i = 0; i < wags.length; i++) {
    var w = wags[i]
    var local = time - w[0]
    var env = wagEnvelope(w, local)
    var ph = wagPhase(w, local)
    p.tailAngle += (Math.sin(ph) + 0.08 * Math.sin(2 * ph + 0.6)) * env * w[6] * amount
    p.tailBend += (Math.sin(wagPhase(w, local - 0.065)) - Math.sin(ph)) * wagEnvelope(w, local - 0.035) * 2.2 * amount
    var following = local - 0.1
    var hipPhase = wagPhase(w, following) / 2 - 0.18
    var hipEnv = wagEnvelope(w, following)
    p.rumpSway += (Math.sin(hipPhase) + 0.1 * Math.sin(hipPhase * 2)) * hipEnv * w[7] * amount
    p.rumpLift -= Math.pow(Math.sin(hipPhase), 2) * hipEnv * 0.45 * amount
  }
  var blinks = [2.9, 3.25, 6.95, 10.2]
  var blink = 0
  for (var j = 0; j < blinks.length; j++) blink = Math.max(blink, pulse(time, blinks[j], 0.035, 0.025, 0.085))
  p.eyeOpen = 1 - blink * amount
  p.scent = Math.min(1, inhale / 0.05) * 0.6 * amount
  return p
}
