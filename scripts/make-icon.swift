// Renders the app icon to a 1024 px PNG: swift scripts/make-icon.swift out.png
// Off-white device face, a thin black progress arc, one amber status lamp.
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset = size * 0.1
let face = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: face, xRadius: size * 0.18, yRadius: size * 0.18)
NSColor(srgbRed: 0.965, green: 0.973, blue: 0.969, alpha: 1).setFill()
shape.fill()
NSColor(white: 0.85, alpha: 1).setStroke()
shape.lineWidth = size * 0.004
shape.stroke()

let center = NSPoint(x: size / 2, y: size / 2 - size * 0.02)
let radius = size * 0.25
let track = NSBezierPath()
track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
track.lineWidth = size * 0.006
NSColor(white: 0.82, alpha: 1).setStroke()
track.stroke()

let arc = NSBezierPath()
arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -160, clockwise: true)
arc.lineWidth = size * 0.022
arc.lineCapStyle = .butt
NSColor.black.setStroke()
arc.stroke()

let lamp = size * 0.06
NSColor(srgbRed: 0.941, green: 0.659, blue: 0, alpha: 1).setFill()
NSRect(x: face.maxX - size * 0.17, y: face.maxY - size * 0.17, width: lamp, height: lamp).fill()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
