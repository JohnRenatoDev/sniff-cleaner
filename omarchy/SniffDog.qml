import QtQuick
import "DogMotion.js" as Motion

// The Sniff dachshund (Resources/Sniff.svg), drawn with the theme's ink.
// It moves only while `active` is true, i.e. while a real scan or cleanup
// runs, and eases back to rest afterwards. With `reduceMotion` it stays
// still. The frame timer stops whenever the dog is at rest.
Canvas {
  id: dog

  property bool active: false
  property bool reduceMotion: false
  property color ink: "white"
  property real lineWidth: 2.65

  property real elapsed: 0
  property real amount: 0
  property double startedAt: 0
  readonly property bool animating: !reduceMotion && (active || amount > 0.001)

  implicitWidth: 180
  implicitHeight: 110
  antialiasing: true

  Accessible.role: Accessible.Animation
  Accessible.name: active ? qsTr("Sniffing dog. Operation in progress.") : qsTr("Sniff, a dog sniffing")

  onActiveChanged: {
    if (active) startedAt = Date.now()
    requestPaint()
  }
  onReduceMotionChanged: { amount = 0; requestPaint() }
  onInkChanged: requestPaint()

  Timer {
    interval: 33
    repeat: true
    running: dog.animating && dog.visible
    onTriggered: {
      dog.elapsed = (Date.now() - dog.startedAt) / 1000
      var target = dog.active ? 1 : 0
      dog.amount += (target - dog.amount) * 0.12
      if (!dog.active && dog.amount < 0.002) dog.amount = 0
      dog.requestPaint()
    }
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    var scale = Math.min(width / 180, height / 110)
    ctx.translate((width - 180 * scale) / 2, (height - 110 * scale) / 2)
    ctx.scale(scale, scale)
    ctx.strokeStyle = ink
    ctx.fillStyle = ink
    ctx.lineWidth = lineWidth
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    var p = Motion.pose(elapsed, reduceMotion ? 0 : amount)

    function stroke(fn) { ctx.beginPath(); fn(); ctx.stroke() }

    // Tail: pivots at the rump and follows the hips.
    ctx.save()
    ctx.translate(p.rumpSway, p.rumpLift)
    ctx.translate(39, 43); ctx.rotate(p.tailAngle); ctx.translate(-39, -43)
    function tp(x, y) {
      var w = Math.pow(Math.max(0, (43 - y) / 26), 2)
      return [x + p.tailBend * w, y + Math.abs(p.tailBend) * w * 0.1]
    }
    stroke(function() {
      var a = tp(40, 41), c1 = tp(27, 42), c2 = tp(17, 28), b = tp(20, 17)
      var d1 = tp(10, 25), d2 = tp(15, 44), e = tp(38, 45)
      ctx.moveTo(a[0], a[1])
      ctx.bezierCurveTo(c1[0], c1[1], c2[0], c2[1], b[0], b[1])
      ctx.bezierCurveTo(d1[0], d1[1], d2[0], d2[1], e[0], e[1])
    })
    ctx.restore()

    // Hind legs and rump follow the hips; paws stay planted.
    ctx.save()
    ctx.translate(p.rumpSway * 0.6, p.rumpLift * 0.6)
    stroke(function() {
      ctx.moveTo(37.5, 72); ctx.bezierCurveTo(35, 74.5, 41.5, 77, 43, 81)
      ctx.bezierCurveTo(44.5, 84.5, 49, 83.8, 52, 83); ctx.bezierCurveTo(55.7, 82, 53.5, 78, 48, 78.5)
      ctx.bezierCurveTo(45.5, 75, 45, 74.5, 47.3, 71)
    })
    stroke(function() {
      ctx.moveTo(38, 45); ctx.bezierCurveTo(32, 53, 34.7, 56.7, 34.2, 62.3)
      ctx.bezierCurveTo(34, 67, 27, 67.4, 25, 71.4); ctx.bezierCurveTo(23, 75, 22, 80, 22.5, 83.4)
      ctx.bezierCurveTo(22.8, 86, 28.8, 85.8, 31.3, 84.8); ctx.bezierCurveTo(33, 83.5, 31.8, 80.4, 29, 80)
      ctx.bezierCurveTo(30, 74, 33.5, 72, 39.5, 71.5); ctx.bezierCurveTo(51, 70.7, 57.5, 64.9, 58.8, 57.4)
    })
    ctx.restore()

    // Back and belly.
    stroke(function() {
      ctx.moveTo(40 + p.rumpSway, 41 + p.rumpLift)
      ctx.bezierCurveTo(53.75, 34.5, 63.5, 36.875, 75.25, 41)
      ctx.bezierCurveTo(86.25, 44.625, 93.125, 47, 104.625, 44.75)
      ctx.bezierCurveTo(115.625, 42.875, 117.25, 47.25, 131.5, 53.375)
    })
    stroke(function() { ctx.moveTo(57.5, 63); ctx.bezierCurveTo(70, 62, 77, 75, 95, 73.5) })
    // Front legs.
    stroke(function() {
      ctx.moveTo(98.25, 63); ctx.bezierCurveTo(94, 66, 92, 70, 94, 72)
      ctx.bezierCurveTo(96, 74.5, 101, 76, 102.5, 80); ctx.bezierCurveTo(103.5, 85, 108, 85, 113.5, 84.7)
      ctx.bezierCurveTo(118, 84.7, 116, 78.5, 110, 79); ctx.bezierCurveTo(109, 76.5, 108, 74, 107, 71)
    })
    stroke(function() {
      ctx.moveTo(107, 73.3); ctx.bezierCurveTo(112, 72.8, 117, 70.4, 117.25, 65.125)
      ctx.moveTo(115, 69.5); ctx.bezierCurveTo(117, 70, 118.5, 70.8, 120, 71.5)
    })
    ctx.save()
    ctx.lineWidth = lineWidth * 0.55
    stroke(function() {
      ctx.moveTo(27.5, 83); ctx.bezierCurveTo(28.1, 83.2, 28.3, 84.5, 28.2, 85.3)
      ctx.moveTo(29.6, 82.6); ctx.bezierCurveTo(30.3, 82.8, 30.5, 84, 30.4, 85)
      ctx.moveTo(49, 81.7); ctx.bezierCurveTo(49.7, 81.8, 50, 82.6, 50, 83.4)
      ctx.moveTo(51, 81.1); ctx.bezierCurveTo(51.7, 81.2, 52.1, 82.2, 52, 83)
      ctx.moveTo(111, 82); ctx.bezierCurveTo(111.8, 82.2, 112.1, 83.6, 112, 84.7)
      ctx.moveTo(113.2, 81.6); ctx.bezierCurveTo(114, 81.8, 114.3, 83.3, 114.2, 84.4)
    })
    ctx.restore()

    // Head: pivots at the neck, sniffs down and searches side to side.
    ctx.save()
    var yaw = p.headTurn * 0.09
    ctx.translate(130, 54)
    ctx.rotate(p.headAngle)
    ctx.transform(1, 0, yaw, 1, 0, 0)
    ctx.translate(-130, -54)
    stroke(function() {
      ctx.moveTo(131, 54); ctx.bezierCurveTo(136, 50, 141, 52.5, 146, 57)
      ctx.bezierCurveTo(153, 62.5, 150.5, 67.5, 153, 71); ctx.bezierCurveTo(155, 74, 159, 77, 162.3, 79.4)
      ctx.moveTo(162, 84); ctx.bezierCurveTo(156, 87, 149, 85.5, 143, 81)
      ctx.bezierCurveTo(139, 78.5, 138, 78, 136, 77.5)
    })
    stroke(function() {
      ctx.moveTo(129, 55.7); ctx.bezierCurveTo(119.5, 60, 118.5, 70.5, 122, 77.5)
      ctx.bezierCurveTo(125.5, 83.5, 132.5, 86, 136, 78); ctx.bezierCurveTo(140, 72, 136.5, 62, 141, 60)
    })
    ctx.beginPath(); ctx.ellipse(160.25 - 3.75, 81.65 - 3.25, 7.5, 6.5); ctx.fill()
    ctx.beginPath(); ctx.ellipse(145 - 2.1, 68.25 - 2.1 * p.eyeOpen, 4.2, Math.max(0.6, 4.2 * p.eyeOpen)); ctx.fill()
    // Scent wisps while inhaling.
    if (p.scent > 0.01) {
      ctx.globalAlpha = p.scent
      ctx.lineWidth = lineWidth * 0.5
      stroke(function() {
        ctx.moveTo(167, 88); ctx.bezierCurveTo(170, 86, 171, 90, 174, 88)
        ctx.moveTo(166, 93); ctx.bezierCurveTo(169, 91, 171, 95, 175, 93)
      })
    }
    ctx.restore()
  }
}
