#!/bin/bash
# Generate app icon from SVG using sips and iconutil

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/../XRadar/Resources"
ICONSET_DIR="$RESOURCES_DIR/Icon.iconset"

echo "Generating app icon..."

# Create iconset directory
mkdir -p "$ICONSET_DIR"

# Generate different sizes from SVG
# Note: macOS sips doesn't handle SVG directly, so we'll create a placeholder
# In production, you'd use ImageMagick or Sketch/Photoshop

# Create a simple colored square as placeholder icon for now
echo "Creating placeholder icon..."

# Generate a simple PNG using Swift
cat > /tmp/generate_icon.swift << 'SWIFTEOF'
import Cocoa

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

// Draw background
let context = NSGraphicsContext.current!
let cgContext = context.cgContext

// Gradient background
let colorSpace = CGColorSpaceCreateDeviceRGB()
let colors = [
    NSColor(red: 0.114, green: 0.631, blue: 0.949, alpha: 1.0).cgColor,  // Twitter blue
    NSColor(red: 0.051, green: 0.545, blue: 0.851, alpha: 1.0).cgColor   // Darker blue
]
let locations: [CGFloat] = [0.0, 1.0]
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!

cgContext.drawRadialGradient(gradient,
    startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 512), endRadius: 512,
    options: .drawsBeforeStartLocation)

// Draw radar circles
NSColor.white.setStroke()
let circle1 = NSBezierPath()
circle1.appendOval(in: NSRect(x: 234, y: 234, width: 556, height: 556))
circle1.lineWidth = 24
circle1.stroke()

let circle2 = NSBezierPath()
circle2.appendOval(in: NSRect(x: 334, y: 334, width: 356, height: 356))
circle2.lineWidth = 20
circle2.stroke()

let circle3 = NSBezierPath()
circle3.appendOval(in: NSRect(x: 434, y: 434, width: 156, height: 156))
NSColor.white.setFill()
circle3.fill()

// Draw radar line
let line = NSBezierPath()
line.move(to: NSPoint(x: 512, y: 512))
line.line(to: NSPoint(x: 512, y: 232))
line.lineWidth = 20
line.lineCapStyle = .round
line.stroke()

// Draw pulse dots
let dot1 = NSBezierPath()
dot1.appendOval(in: NSRect(x: 688, y: 288, width: 48, height: 48))
dot1.fill()

let dot2 = NSBezierPath()
dot2.appendOval(in: NSRect(x: 296, y: 396, width: 32, height: 32))
dot2.fill()

let dot3 = NSBezierPath()
dot3.appendOval(in: NSRect(x: 592, y: 692, width: 40, height: 40))
dot3.fill()

image.unlockFocus()

// Save as PNG
if let tiffData = image.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    try? pngData.write(to: URL(fileURLWithPath: "/tmp/xradar_icon_1024.png"))
    print("Icon generated successfully")
}
SWIFTEOF

# Run Swift script
swift /tmp/generate_icon.swift

# Generate icon sizes
sips -z 16 16 /tmp/xradar_icon_1024.png --out "$ICONSET_DIR/icon_16x16.png"
sips -z 32 32 /tmp/xradar_icon_1024.png --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -z 32 32 /tmp/xradar_icon_1024.png --out "$ICONSET_DIR/icon_32x32.png"
sips -z 64 64 /tmp/xradar_icon_1024.png --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -z 128 128 /tmp/xradar_icon_1024.png --out "$ICONSET_DIR/icon_128x128.png"
sips -z 256 256 /tmp/xradar_icon_1024.png --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -z 256 256 /tmp/xradar_icon_1024.png --out "$ICONSET_DIR/icon_256x256.png"
sips -z 512 512 /tmp/xradar_icon_1024.png --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -z 512 512 /tmp/xradar_icon_1024.png --out "$ICONSET_DIR/icon_512x512.png"
cp /tmp/xradar_icon_1024.png "$ICONSET_DIR/icon_512x512@2x.png"

# Convert to icns
cd "$RESOURCES_DIR"
iconutil -c icns Icon.iconset -o AppIcon.icns

echo "✅ App icon created: $RESOURCES_DIR/AppIcon.icns"