import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let rect = NSRect(x: 40, y: 40, width: 944, height: 944)
let background = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
NSGradient(colors: [NSColor(calibratedRed: 0.08, green: 0.17, blue: 0.45, alpha: 1), NSColor(calibratedRed: 0.13, green: 0.51, blue: 0.79, alpha: 1), NSColor(calibratedRed: 0.25, green: 0.78, blue: 0.78, alpha: 1)])!.draw(in: background, angle: -45)
let bubble = NSBezierPath(roundedRect: NSRect(x: 167, y: 188, width: 690, height: 660), xRadius: 165, yRadius: 165)
NSColor.white.withAlphaComponent(0.14).setFill(); bubble.fill()
NSColor.white.withAlphaComponent(0.35).setStroke(); bubble.lineWidth = 5; bubble.stroke()
func polygon(_ points: [NSPoint], color: NSColor) {
    let p = NSBezierPath(); p.move(to: points[0]); for point in points.dropFirst() { p.line(to: point) }; p.close(); color.setFill(); p.fill()
    NSColor.white.withAlphaComponent(0.7).setStroke(); p.lineWidth = 7; p.lineJoinStyle = .round; p.stroke()
}
polygon([NSPoint(x: 292,y: 611),NSPoint(x: 510,y: 729),NSPoint(x: 734,y: 609),NSPoint(x: 514,y: 486)], color: NSColor.white.withAlphaComponent(0.44))
polygon([NSPoint(x: 292,y: 611),NSPoint(x: 514,y: 486),NSPoint(x: 514,y: 263),NSPoint(x: 292,y: 393)], color: NSColor.white.withAlphaComponent(0.13))
polygon([NSPoint(x: 514,y: 486),NSPoint(x: 734,y: 609),NSPoint(x: 734,y: 392),NSPoint(x: 514,y: 263)], color: NSColor.white.withAlphaComponent(0.25))
let tape = NSBezierPath(); tape.move(to: NSPoint(x: 405,y: 673)); tape.line(to: NSPoint(x: 622,y: 550)); tape.line(to: NSPoint(x: 622,y: 473)); NSColor.white.withAlphaComponent(0.86).setStroke(); tape.lineWidth=25; tape.lineCapStyle = .round; tape.stroke()
let status = NSBezierPath(ovalIn: NSRect(x: 684,y: 149,width: 180,height: 180)); NSColor(calibratedRed: 0.30,green: 0.93,blue: 0.68,alpha: 1).setFill(); status.fill(); NSColor.white.withAlphaComponent(0.8).setStroke();status.lineWidth=8;status.stroke()
let check = NSBezierPath(); check.move(to: NSPoint(x: 730,y: 238));check.line(to: NSPoint(x: 762,y: 207));check.line(to: NSPoint(x: 819,y: 270)); NSColor(calibratedRed: 0.04,green: 0.30,blue: 0.28,alpha: 1).setStroke();check.lineWidth=18;check.lineCapStyle = .round;check.lineJoinStyle = .round;check.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
