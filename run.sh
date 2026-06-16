#!/bin/bash

# Build and run the repo manager app

set -e

echo "Building repo_manager..."
xcodebuild -scheme repo_manager \
    -destination 'platform=macOS' \
    -configuration Debug \
    -derivedDataPath ./DerivedData \
    build

echo "Launching app..."
open ./DerivedData/Build/Products/Debug/repo_manager.app