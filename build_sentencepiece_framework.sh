#!/bin/bash
# Build SentencePiece as an XCFramework for Swift integration

set -e

# Clone SentencePiece if not present
if [ ! -d "sentencepiece" ]; then
    git clone https://github.com/google/sentencepiece.git
fi

cd sentencepiece

# Create build directories
mkdir -p build-ios build-macos

# Build for macOS
echo "Building for macOS..."
cd build-macos
cmake .. -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
         -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
         -DCMAKE_CXX_STANDARD=17 \
         -DSPM_ENABLE_SHARED=OFF \
         -DSPM_ENABLE_TCMALLOC=OFF
make -j8
cd ..

# Build for iOS using Xcode generator
echo "Building for iOS..."
cd build-ios
cmake .. -G Xcode \
         -DCMAKE_TOOLCHAIN_FILE=../cmake/ios.toolchain.cmake \
         -DPLATFORM=OS64COMBINED \
         -DSPM_ENABLE_SHARED=OFF \
         -DSPM_ENABLE_TCMALLOC=OFF

# Build using xcodebuild instead of make
xcodebuild -project sentencepiece.xcodeproj \
           -scheme ALL_BUILD \
           -configuration Release \
           -sdk iphoneos

# Also build for iOS Simulator
xcodebuild -project sentencepiece.xcodeproj \
           -scheme ALL_BUILD \
           -configuration Release \
           -sdk iphonesimulator
cd ..

# Create framework structure
FRAMEWORK_NAME="SentencePiece"
FRAMEWORK_DIR="${FRAMEWORK_NAME}.framework"

rm -rf "${FRAMEWORK_DIR}"
mkdir -p "${FRAMEWORK_DIR}/Headers"
mkdir -p "${FRAMEWORK_DIR}/Modules"

# Copy headers - include all necessary headers for the bridge
echo "Copying headers..."
cp src/sentencepiece_processor.h "${FRAMEWORK_DIR}/Headers/"
cp src/sentencepiece_trainer.h "${FRAMEWORK_DIR}/Headers/"

# Also copy any other headers that might be needed
for header in src/*.h; do
    if [ -f "$header" ]; then
        basename=$(basename "$header")
        # Skip internal/private headers
        if [[ ! "$basename" =~ ^_ ]] && [[ "$basename" != *"internal"* ]]; then
            cp "$header" "${FRAMEWORK_DIR}/Headers/"
        fi
    fi
done

# Copy the protobuf headers that SentencePiece includes
if [ -d "src/builtin_pb" ]; then
    mkdir -p "${FRAMEWORK_DIR}/Headers/builtin_pb"
    cp src/builtin_pb/*.h "${FRAMEWORK_DIR}/Headers/builtin_pb/" 2>/dev/null || true
fi

# Create module map
echo "Creating module map..."
cat > "${FRAMEWORK_DIR}/Modules/module.modulemap" << EOF
framework module SentencePiece {
    umbrella header "SentencePiece.h"
    
    export *
    module * { export * }
    
    link "sentencepiece"
    link "c++"
}
EOF

# Create umbrella header that includes all public headers
cat > "${FRAMEWORK_DIR}/Headers/SentencePiece.h" << EOF
//
//  SentencePiece.h
//  Umbrella header for SentencePiece framework
//

#ifndef SENTENCEPIECE_H
#define SENTENCEPIECE_H

#include <sentencepiece_processor.h>
#include <sentencepiece_trainer.h>

#endif /* SENTENCEPIECE_H */
EOF

# Create XCFramework
echo "Creating XCFramework..."

# Find the iOS libraries (Xcode puts them in different locations)
IOS_LIB_PATH=""
IOS_SIM_LIB_PATH=""

# Check common locations for iOS device library
for path in "build-ios/src/Release-iphoneos/libsentencepiece.a" \
            "build-ios/src/sentencepiece-static/Release-iphoneos/libsentencepiece.a" \
            "build-ios/Release-iphoneos/libsentencepiece.a"; do
    if [ -f "$path" ]; then
        IOS_LIB_PATH="$path"
        echo "Found iOS library at: $path"
        break
    fi
done

# Check common locations for iOS simulator library
for path in "build-ios/src/Release-iphonesimulator/libsentencepiece.a" \
            "build-ios/src/sentencepiece-static/Release-iphonesimulator/libsentencepiece.a" \
            "build-ios/Release-iphonesimulator/libsentencepiece.a"; do
    if [ -f "$path" ]; then
        IOS_SIM_LIB_PATH="$path"
        echo "Found iOS Simulator library at: $path"
        break
    fi
done

# First, remove any existing XCFramework
rm -rf "../SentencePiece.xcframework"

# Create temporary directories for each platform's framework
mkdir -p temp-frameworks/macos
mkdir -p temp-frameworks/ios  
mkdir -p temp-frameworks/ios-sim

MAC_FRAMEWORK="temp-frameworks/macos/${FRAMEWORK_NAME}.framework"
IOS_FRAMEWORK="temp-frameworks/ios/${FRAMEWORK_NAME}.framework"
IOS_SIM_FRAMEWORK="temp-frameworks/ios-sim/${FRAMEWORK_NAME}.framework"

# Function to create a framework for a specific platform
create_platform_framework() {
    local lib_path=$1
    local framework_dir=$2
    local framework_name=$(basename "$framework_dir" .framework)
    
    rm -rf "$framework_dir"
    mkdir -p "$framework_dir/Headers"
    mkdir -p "$framework_dir/Modules"
    
    # Copy library with standard framework executable name
    cp "$lib_path" "$framework_dir/SentencePiece"
    
    # Copy headers and module map
    cp -r "${FRAMEWORK_DIR}/Headers/"* "$framework_dir/Headers/"
    cp -r "${FRAMEWORK_DIR}/Modules/"* "$framework_dir/Modules/"
    
    # Create Info.plist for the framework
    cat > "$framework_dir/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SentencePiece</string>
    <key>CFBundleIdentifier</key>
    <string>com.sentencepiece.$framework_name</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SentencePiece</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST
}

# Create platform-specific frameworks
echo "Creating platform-specific frameworks..."
create_platform_framework "build-macos/src/libsentencepiece.a" "$MAC_FRAMEWORK"

# Create XCFramework based on what we found
if [ -n "$IOS_LIB_PATH" ] && [ -n "$IOS_SIM_LIB_PATH" ]; then
    create_platform_framework "$IOS_LIB_PATH" "$IOS_FRAMEWORK"
    create_platform_framework "$IOS_SIM_LIB_PATH" "$IOS_SIM_FRAMEWORK"
    
    # All platforms: macOS, iOS device, iOS simulator
    echo "Creating XCFramework with macOS, iOS device, and iOS simulator..."
    xcodebuild -create-xcframework \
        -framework "$MAC_FRAMEWORK" \
        -framework "$IOS_FRAMEWORK" \
        -framework "$IOS_SIM_FRAMEWORK" \
        -output "../SentencePiece.xcframework"
        
    # Clean up temporary frameworks
    rm -rf temp-frameworks
elif [ -n "$IOS_LIB_PATH" ]; then
    create_platform_framework "$IOS_LIB_PATH" "$IOS_FRAMEWORK"
    
    # macOS and iOS device only
    echo "Creating XCFramework with macOS and iOS device..."
    xcodebuild -create-xcframework \
        -framework "$MAC_FRAMEWORK" \
        -framework "$IOS_FRAMEWORK" \
        -output "../SentencePiece.xcframework"
        
    # Clean up temporary frameworks  
    rm -rf temp-frameworks
else
    # macOS only
    echo "Creating XCFramework with macOS only..."
    echo "Warning: iOS libraries not found. Building macOS-only XCFramework."
    xcodebuild -create-xcframework \
        -framework "$MAC_FRAMEWORK" \
        -output "../SentencePiece.xcframework"
        
    # Clean up temporary framework
    rm -rf temp-frameworks
fi

echo "✅ SentencePiece.xcframework created successfully!"
