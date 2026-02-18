import AppKit
import Foundation

struct Options {
  var inputPath: String
  var outputPath: String
  var lightningThreshold: Double
  var batteryAlpha: Double
  var batteryImagePath: String?
  var batteryLuminanceThreshold: Double
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

func parseArgs() -> Options {
  var inputPath: String?
  var outputPath: String?
  var lightningThreshold: Double = 0.40
  var batteryAlpha: Double = 0.92
  var batteryImagePath: String?
  var batteryLuminanceThreshold: Double = 0.80

  var it = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = it.next() {
    switch arg {
    case "--input":
      inputPath = it.next()
    case "--output":
      outputPath = it.next()
    case "--threshold":
      guard let raw = it.next(), let v = Double(raw) else { fail("Invalid --threshold") }
      lightningThreshold = v
    case "--battery-alpha":
      guard let raw = it.next(), let v = Double(raw) else { fail("Invalid --battery-alpha") }
      batteryAlpha = v
    case "--battery-image":
      batteryImagePath = it.next()
    case "--battery-threshold":
      guard let raw = it.next(), let v = Double(raw) else { fail("Invalid --battery-threshold") }
      batteryLuminanceThreshold = v
    default:
      fail("Unknown arg: \(arg)")
    }
  }

  guard let inputPath else { fail("Missing --input <path>") }
  guard let outputPath else { fail("Missing --output <path>") }

  return Options(
    inputPath: inputPath,
    outputPath: outputPath,
    lightningThreshold: lightningThreshold,
    batteryAlpha: batteryAlpha,
    batteryImagePath: batteryImagePath,
    batteryLuminanceThreshold: batteryLuminanceThreshold
  )
}

func srgbToLuminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
  let rf = Double(r) / 255.0
  let gf = Double(g) / 255.0
  let bf = Double(b) / 255.0
  return 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
}

func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ) else {
    fail("Failed to create bitmap")
  }
  return rep
}

let options = parseArgs()

let inputURL = URL(fileURLWithPath: options.inputPath)
guard let inputImage = NSImage(contentsOf: inputURL) else {
  fail("Failed to read image at: \(options.inputPath)")
}

let size = 1024
let rep = makeBitmap(width: size, height: size)
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
  fail("Failed to create graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high
NSColor.clear.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
inputImage.draw(
  in: NSRect(x: 0, y: 0, width: size, height: size),
  from: NSRect(origin: .zero, size: inputImage.size),
  operation: .sourceOver,
  fraction: 1.0,
  respectFlipped: true,
  hints: [.interpolation: NSImageInterpolation.high]
)
NSGraphicsContext.restoreGraphicsState()

guard let baseData = rep.bitmapData else {
  fail("Missing bitmapData")
}

let bytesPerRow = rep.bytesPerRow

func clamp01(_ v: Double) -> Double { max(0.0, min(1.0, v)) }

// Detect the lightning region (dark pixels) to place a battery silhouette behind it.
var minX = size
var minY = size
var maxX = 0
var maxY = 0
var lightningCount = 0

let inset = Int(Double(size) * 0.18)
let start = inset
let end = size - inset

let totalSampled = (end - start) * (end - start)

for y in start..<end {
  let row = y * bytesPerRow
  for x in start..<end {
    let i = row + x * 4
    let a = Double(baseData[i + 3]) / 255.0
    if a <= 0.5 { continue }
    let r = baseData[i + 0]
    let g = baseData[i + 1]
    let b = baseData[i + 2]
    let lum = srgbToLuminance(r: r, g: g, b: b)
    if lum < options.lightningThreshold {
      lightningCount += 1
      if x < minX { minX = x }
      if y < minY { minY = y }
      if x > maxX { maxX = x }
      if y > maxY { maxY = y }
    }
  }
}

let darkFraction = totalSampled > 0 ? (Double(lightningCount) / Double(totalSampled)) : 1.0

let fallbackRect = NSRect(
  x: CGFloat(size) * 0.34,
  y: CGFloat(size) * 0.24,
  width: CGFloat(size) * 0.32,
  height: CGFloat(size) * 0.52
)

let lightningRect: NSRect = {
  if lightningCount < 500 || minX >= maxX || minY >= maxY {
    return fallbackRect
  }

  // Heuristics: if the image has lots of dark pixels (e.g. complex illustration),
  // don't try to infer a "lightning" bounding box; use a conservative fallback.
  if darkFraction > 0.06 {
    return fallbackRect
  }

  let pad = CGFloat(size) * 0.02
  let rect = NSRect(
    x: CGFloat(minX) - pad,
    y: CGFloat(minY) - pad,
    width: CGFloat((maxX - minX) + 1) + (pad * 2),
    height: CGFloat((maxY - minY) + 1) + (pad * 2)
  )
  let rectAreaFraction = (rect.width * rect.height) / (CGFloat(totalSampled))
  if rectAreaFraction > 0.25 {
    return fallbackRect
  }
  return rect
}()

let centerX = lightningRect.midX
let centerY = lightningRect.midY

// Build a battery mask by drawing the battery shape into another bitmap.
let maskRep = makeBitmap(width: size, height: size)
guard let maskCtx = NSGraphicsContext(bitmapImageRep: maskRep) else {
  fail("Failed to create mask context")
}
guard let maskData = maskRep.bitmapData else {
  fail("Missing mask bitmapData")
}
let maskBytesPerRow = maskRep.bytesPerRow

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = maskCtx
maskCtx.imageInterpolation = .high
NSColor.clear.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

if let batteryImagePath = options.batteryImagePath {
  let batteryURL = URL(fileURLWithPath: batteryImagePath)
  guard let batteryImage = NSImage(contentsOf: batteryURL) else {
    fail("Failed to read battery image at: \(batteryImagePath)")
  }

  // Fit the battery silhouette around the lightning (slightly larger than the bolt).
  let maxCanvas = CGFloat(size) * 0.80
  let baseW = min(maxCanvas, lightningRect.width * 1.60)

  let srcSize = batteryImage.size
  let srcAspect = srcSize.width > 0 && srcSize.height > 0 ? (srcSize.width / srcSize.height) : 1.0
  var drawW = baseW
  var drawH = baseW / max(0.0001, srcAspect)
  let minH = min(maxCanvas, lightningRect.height * 0.52)
  if drawH < minH {
    drawH = minH
    drawW = min(maxCanvas, drawH * srcAspect)
  }

  let drawRect = NSRect(
    x: centerX - drawW / 2.0,
    y: centerY - drawH / 2.0 - (drawH * 0.05),
    width: drawW,
    height: drawH
  )

  let bw = max(1, Int(drawRect.width.rounded(.toNearestOrAwayFromZero)))
  let bh = max(1, Int(drawRect.height.rounded(.toNearestOrAwayFromZero)))
  let batteryRep = makeBitmap(width: bw, height: bh)
  guard let batteryCtx = NSGraphicsContext(bitmapImageRep: batteryRep) else {
    fail("Failed to create battery context")
  }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = batteryCtx
  batteryCtx.imageInterpolation = .high
  NSColor.clear.setFill()
  NSBezierPath(rect: NSRect(x: 0, y: 0, width: bw, height: bh)).fill()
  batteryImage.draw(
    in: NSRect(x: 0, y: 0, width: bw, height: bh),
    from: NSRect(origin: .zero, size: srcSize),
    operation: .sourceOver,
    fraction: 1.0,
    respectFlipped: true,
    hints: [.interpolation: NSImageInterpolation.high]
  )
  NSGraphicsContext.restoreGraphicsState()

  guard let batteryData = batteryRep.bitmapData else {
    fail("Missing battery bitmapData")
  }

  let ox = Int(drawRect.minX.rounded(.down))
  let oy = Int(drawRect.minY.rounded(.down))
  let batteryBytesPerRow = batteryRep.bytesPerRow

  let bgThreshold = options.batteryLuminanceThreshold
  var isBgLike = Array(repeating: false, count: bw * bh)
  var visited = Array(repeating: false, count: bw * bh)

  func idx(_ x: Int, _ y: Int) -> Int { y * bw + x }

  // Estimate background luminance from corners, then treat pixels near that as background.
  func luminanceAt(_ x: Int, _ y: Int) -> Double {
    let bi = (y * batteryBytesPerRow) + x * 4
    let r = batteryData[bi + 0]
    let g = batteryData[bi + 1]
    let b = batteryData[bi + 2]
    return srgbToLuminance(r: r, g: g, b: b)
  }

  let cornerPts = [(0, 0), (bw - 1, 0), (0, bh - 1), (bw - 1, bh - 1)]
  var bgLum = 0.0
  for (x, y) in cornerPts {
    bgLum += luminanceAt(x, y)
  }
  bgLum /= Double(cornerPts.count)
  let bgDelta = max(0.05, 1.0 - bgThreshold) // default ~0.20 when threshold=0.80
  let bgCutoff = max(0.0, bgLum - bgDelta)

  for y in 0..<bh {
    let by = y * batteryBytesPerRow
    for x in 0..<bw {
      let bi = by + x * 4
      let alpha = Double(batteryData[bi + 3]) / 255.0
      if alpha <= 0.001 { continue }
      let r = batteryData[bi + 0]
      let g = batteryData[bi + 1]
      let b = batteryData[bi + 2]
      let lum = srgbToLuminance(r: r, g: g, b: b)
      if lum >= bgCutoff {
        isBgLike[idx(x, y)] = true
      }
    }
  }

  var stack: [(Int, Int)] = []
  func pushIfBg(_ x: Int, _ y: Int) {
    guard x >= 0, x < bw, y >= 0, y < bh else { return }
    let p = idx(x, y)
    guard !visited[p], isBgLike[p] else { return }
    visited[p] = true
    stack.append((x, y))
  }

  pushIfBg(0, 0)
  pushIfBg(bw - 1, 0)
  pushIfBg(0, bh - 1)
  pushIfBg(bw - 1, bh - 1)

  while let (x, y) = stack.popLast() {
    pushIfBg(x + 1, y)
    pushIfBg(x - 1, y)
    pushIfBg(x, y + 1)
    pushIfBg(x, y - 1)
  }

  for y in 0..<bh {
    let by = y * batteryBytesPerRow
    let my = (oy + y) * maskBytesPerRow
    if oy + y < 0 || oy + y >= size { continue }
    for x in 0..<bw {
      let mx = ox + x
      if mx < 0 || mx >= size { continue }

      let bi = by + x * 4
      let alpha = Double(batteryData[bi + 3]) / 255.0
      if alpha <= 0.001 { continue }

      // If this pixel is not background-connected, it's part of the battery silhouette (filled).
      let p = idx(x, y)
      if visited[p] { continue }

      let mi = my + mx * 4
      let existingA = Double(maskData[mi + 3]) / 255.0
      let a = clamp01(alpha)
      let outA = max(existingA, a)
      maskData[mi + 0] = 255
      maskData[mi + 1] = 255
      maskData[mi + 2] = 255
      maskData[mi + 3] = UInt8(outA * 255.0)
    }
  }
} else {
  let bodyW = min(CGFloat(size) * 0.72, lightningRect.width * 1.55)
  let bodyH = min(CGFloat(size) * 0.80, lightningRect.height * 1.85)
  let radius = min(bodyW, bodyH) * 0.14

  let bodyRect = NSRect(
    x: centerX - bodyW / 2.0,
    y: centerY - bodyH / 2.0 - (bodyH * 0.06),
    width: bodyW,
    height: bodyH
  )

  let nubW = bodyW * 0.28
  let nubH = bodyH * 0.10
  let nubRect = NSRect(
    x: centerX - nubW / 2.0,
    y: bodyRect.maxY - (nubH * 0.15),
    width: nubW,
    height: nubH
  )

  let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)
  let nubPath = NSBezierPath(roundedRect: nubRect, xRadius: radius * 0.5, yRadius: radius * 0.5)

  NSColor.white.setFill()
  bodyPath.fill()
  nubPath.fill()
}
NSGraphicsContext.restoreGraphicsState()

// Composite black battery behind the lightning by masking out lightning pixels.
for y in 0..<size {
  let row = y * bytesPerRow
  let maskRow = y * maskBytesPerRow
  for x in 0..<size {
    let i = row + x * 4
    let mi = maskRow + x * 4

    let a = Double(baseData[i + 3]) / 255.0
    if a <= 0.001 { continue }

    let r = baseData[i + 0]
    let g = baseData[i + 1]
    let b = baseData[i + 2]
    let lum = srgbToLuminance(r: r, g: g, b: b)

    // Battery shape alpha from mask bitmap.
    let batteryShapeA = Double(maskData[mi + 3]) / 255.0
    if batteryShapeA <= 0.001 { continue }

    // Don't draw on top of the lightning itself (keep original lightning pixels).
    if lum < options.lightningThreshold { continue }

    let mask = clamp01(batteryShapeA * options.batteryAlpha)
    if mask <= 0.001 { continue }

    // Source-over blend with a pure black battery.
    let inv = 1.0 - mask
    baseData[i + 0] = UInt8(Double(baseData[i + 0]) * inv)
    baseData[i + 1] = UInt8(Double(baseData[i + 1]) * inv)
    baseData[i + 2] = UInt8(Double(baseData[i + 2]) * inv)
    // Keep original alpha.
    baseData[i + 3] = UInt8(a * 255.0)
  }
}

guard let pngData = rep.representation(using: .png, properties: [:]) else {
  fail("Failed to encode PNG")
}

let outURL = URL(fileURLWithPath: options.outputPath)
do {
  try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try pngData.write(to: outURL, options: .atomic)
} catch {
  fail("Failed to write PNG: \(error)")
}
