// Renders the AgentDeck app icon: a fanned deck of session "cards" with an
// attention dot, on a dark slate squircle. Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// background squircle
let bgRect = CGRect(x: 64, y: 64, width: 896, height: 896)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 200, yRadius: 200)
NSColor(red: 0.10, green: 0.13, blue: 0.19, alpha: 1).setFill()
bg.fill()

// subtle top-light gradient on the background
let gradient = NSGradient(
    starting: NSColor(red: 0.16, green: 0.20, blue: 0.27, alpha: 1),
    ending: NSColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1)
)!
gradient.draw(in: bg, angle: -90)

func card(center: CGPoint, angleDeg: CGFloat, color: NSColor, dot: NSColor? = nil) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angleDeg * .pi / 180)
    let rect = CGRect(x: -250, y: -155, width: 500, height: 310)
    ctx.setShadow(
        offset: CGSize(width: 0, height: -16), blur: 40,
        color: NSColor.black.withAlphaComponent(0.5).cgColor
    )
    let path = NSBezierPath(roundedRect: rect, xRadius: 48, yRadius: 48)
    color.setFill()
    path.fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // faint "text lines" so the cards read as sessions
    let lineColor = NSColor.black.withAlphaComponent(0.12)
    lineColor.setFill()
    NSBezierPath(roundedRect: CGRect(x: -190, y: 40, width: 240, height: 34),
                 xRadius: 17, yRadius: 17).fill()
    NSBezierPath(roundedRect: CGRect(x: -190, y: -30, width: 320, height: 34),
                 xRadius: 17, yRadius: 17).fill()
    if let dot {
        dot.setFill()
        NSBezierPath(ovalIn: CGRect(x: 150, y: 55, width: 88, height: 88)).fill()
    }
    ctx.restoreGState()
}

card(center: CGPoint(x: 512, y: 660), angleDeg: 9,
     color: NSColor(red: 0.40, green: 0.48, blue: 0.58, alpha: 1))
card(center: CGPoint(x: 512, y: 530), angleDeg: 3,
     color: NSColor(red: 0.64, green: 0.71, blue: 0.80, alpha: 1))
card(center: CGPoint(x: 512, y: 395), angleDeg: -4,
     color: NSColor(red: 0.94, green: 0.96, blue: 0.98, alpha: 1),
     dot: NSColor(red: 0.95, green: 0.60, blue: 0.20, alpha: 1))

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
