#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "Building XRadar..."

echo "Using Swift Package Manager..."
swift build --disable-sandbox

echo "Build complete!"
