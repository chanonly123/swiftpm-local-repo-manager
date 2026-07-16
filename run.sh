#!/bin/bash

# Build and run the repo manager app
# Usage: ./run.sh [-clean]

set -e

CLEAN=false
for arg in "$@"; do
    case "$arg" in
        -clean) CLEAN=true ;;
    esac
done

if [ "$CLEAN" = true ]; then
    echo "Cleaning..."
    xcodebuild -scheme repo_manager \
        -destination 'platform=macOS' \
        -configuration Release \
        -derivedDataPath ./DerivedData \
        clean
fi

echo "Building repo_manager..."
xcodebuild -scheme repo_manager \
    -destination 'platform=macOS' \
    -configuration Release \
    -derivedDataPath ./DerivedData \
    build

echo "Launching app..."
open ./DerivedData/Build/Products/Release/repo_manager.app