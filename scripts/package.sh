#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Create dist directory
mkdir -p dist

# Build for release
echo "Building XRadar for release..."

# Since xcodebuild is not available, use swift build
swift build -c release

# Find the built product
BUILD_PATH="$(swift build -c release --show-bin-path)"
if [[ -f "$BUILD_PATH/XRadar" ]]; then
    echo "Creating app bundle..."
    mkdir -p dist/XRadar.app/Contents/MacOS
    cp "$BUILD_PATH/XRadar" dist/XRadar.app/Contents/MacOS/

    # Create minimal Info.plist with icon reference
    cat > dist/XRadar.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>XRadar</string>
    <key>CFBundleIdentifier</key>
    <string>com.xradar.app</string>
    <key>CFBundleName</key>
    <string>XRadar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

    # Copy app icon if it exists
    if [[ -f "XRadar/Resources/AppIcon.icns" ]]; then
        mkdir -p dist/XRadar.app/Contents/Resources
        cp "XRadar/Resources/AppIcon.icns" dist/XRadar.app/Contents/Resources/
        echo "✅ App icon included"
    fi

    # Remove quarantine and ad-hoc sign bundle for ARM64 macOS
    xattr -cr dist/XRadar.app
    codesign --force --deep --sign - dist/XRadar.app
    echo "✅ App signed with ad-hoc signature"

    echo "Note: Created minimal app bundle"
fi

# Create ZIP
echo "Creating ZIP archive..."
cd dist
zip -r XRadar-macOS.zip XRadar.app
cd ..

echo ""
echo "Package created in dist/"
echo "  - dist/XRadar.app"
echo "  - dist/XRadar-macOS.zip"
