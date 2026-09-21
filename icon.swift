// Генератор іконки SysPulse.
//
// Іконку тримаємо як код, а не як бінарник у git: її видно в diff, легко
// підправити колір чи лінію й перезібрати. Запуск — через ./icon.sh.
//
// Малюємо всі розміри з вектора (без масштабування растру), бо крива пульсу
// на 16 px мусить мати товщину, пропорційну полотну, інакше зникає.

import AppKit

/// Іконка macOS має «безпечні» поля: сам squircle займає ~80% полотна,
/// решта — прозорі відступи, які система враховує у сітці Dock.
let inset: CGFloat = 0.0586

func drawIcon(side: CGFloat, into context: CGContext) {
  let rect = CGRect(
    x: side * inset, y: side * inset,
    width: side * (1 - 2 * inset), height: side * (1 - 2 * inset))
  // 22.37% — радіус скруглення в сітці іконок Apple (continuous corner).
  let squircle = NSBezierPath(
    roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)

  context.saveGState()
  context.addPath(squircle.cgPath)
  context.clip()

  // Градієнт: темна основа, щоб світла крива пульсу читалась і на світлій,
  // і на темній підкладці Dock.
  let colors =
    [
      CGColor(red: 0.13, green: 0.16, blue: 0.22, alpha: 1),
      CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1),
    ] as CFArray
  if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
  {
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: rect.minX, y: rect.maxY),
      end: CGPoint(x: rect.maxX, y: rect.minY),
      options: [])
  }
  context.restoreGState()

  // Крива пульсу: спокійна лінія — різкий пік — спокійна лінія. Пропорції в
  // частках сторони, тому форма однакова на 16 і на 1024 px.
  let w = rect.width
  let midY = rect.midY
  // Вісь Y у Core Graphics росте вгору: пік — це +, провал — −.
  let points: [CGPoint] = [
    CGPoint(x: rect.minX + w * 0.13, y: midY),
    CGPoint(x: rect.minX + w * 0.34, y: midY),
    CGPoint(x: rect.minX + w * 0.43, y: midY - w * 0.06),
    CGPoint(x: rect.minX + w * 0.52, y: midY + w * 0.24),
    CGPoint(x: rect.minX + w * 0.60, y: midY - w * 0.15),
    CGPoint(x: rect.minX + w * 0.67, y: midY),
    CGPoint(x: rect.minX + w * 0.87, y: midY),
  ]

  let line = CGMutablePath()
  line.move(to: points[0])
  for point in points.dropFirst() { line.addLine(to: point) }

  context.setLineCap(.round)
  context.setLineJoin(.round)

  // Підсвітка під кривою: дає відчуття світіння без окремого blur-проходу.
  context.setStrokeColor(CGColor(red: 0.20, green: 0.85, blue: 0.60, alpha: 0.30))
  context.setLineWidth(w * 0.115)
  context.addPath(line)
  context.strokePath()

  context.setStrokeColor(CGColor(red: 0.35, green: 0.97, blue: 0.68, alpha: 1))
  context.setLineWidth(w * 0.055)
  context.addPath(line)
  context.strokePath()

  // Легкий відблиск згори — градієнтом, а не заливкою половини полотна:
  // та лишала видиму горизонтальну межу посередині іконки.
  context.saveGState()
  context.addPath(squircle.cgPath)
  context.clip()
  let sheen =
    [
      CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
      CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray
  if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen, locations: [0, 1])
  {
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: rect.midX, y: rect.maxY),
      end: CGPoint(x: rect.midX, y: rect.midY),
      options: [])
  }
  context.restoreGState()
}

func writePNG(side: Int, to path: String) {
  guard
    let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { fatalError("не вдалось створити контекст \(side)px") }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  drawIcon(side: CGFloat(side), into: context)
  NSGraphicsContext.restoreGraphicsState()

  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
  else { fatalError("не вдалось записати \(path)") }
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
}

// iconutil очікує саме цей набір: базовий розмір і @2x для кожного.
let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for base in [16, 32, 128, 256, 512] {
  writePNG(side: base, to: "\(outputDirectory)/icon_\(base)x\(base).png")
  writePNG(side: base * 2, to: "\(outputDirectory)/icon_\(base)x\(base)@2x.png")
}
