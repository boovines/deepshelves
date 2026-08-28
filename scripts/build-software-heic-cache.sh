#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
version="libheif-1.23.2-x265-4.3-arm64-macos15"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
runtime="$staging/SoftwareHEIC"
sources="$staging/sources"
prefix="$staging/prefix"
mkdir -p "$runtime/bin" "$runtime/lib" "$runtime/licenses"

[[ "$(uname -m)" == "arm64" ]]
source_cache="$repo_root/.dependency-cache/sources"
[[ "$(shasum -a 256 "$source_cache/libheif-1.23.2.tar.gz" | awk '{print $1}')" == \
  "8bd5d41d19dc84536d118b04774709f244df6104ef66d623dad5fa4650143405" ]]
[[ "$(shasum -a 256 "$source_cache/x265-4.3.tar.gz" | awk '{print $1}')" == \
  "83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121" ]]
[[ "$(shasum -a 256 "$source_cache/libde265-1.1.1.tar.gz" | awk '{print $1}')" == \
  "fd48a927e94ed74fc7ce8829d222b9d8599fcbfe8b6448ba66705babc56ab219" ]]

mkdir -p "$sources" "$prefix"
tar -xzf "$source_cache/libheif-1.23.2.tar.gz" -C "$sources"
tar -xzf "$source_cache/x265-4.3.tar.gz" -C "$sources"
tar -xzf "$source_cache/libde265-1.1.1.tar.gz" -C "$sources"

common_cmake=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$prefix"
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
  -DCMAKE_INSTALL_NAME_DIR=@rpath
)

cmake -S "$sources/x265_4.3/source" -B "$staging/x265-build" \
  "${common_cmake[@]}" \
  -DENABLE_SHARED=ON \
  -DENABLE_CLI=OFF \
  -DENABLE_ASSEMBLY=ON \
  -DENABLE_HDR10_PLUS=OFF \
  -DENABLE_LIBVMAF=OFF
cmake --build "$staging/x265-build" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$staging/x265-build"

cmake -S "$sources/libde265-1.1.1" -B "$staging/libde265-build" \
  "${common_cmake[@]}" \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_SDL=OFF \
  -DENABLE_ENCODER=OFF \
  -DENABLE_DECODER=OFF
cmake --build "$staging/libde265-build" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$staging/libde265-build"

PKG_CONFIG_PATH="$prefix/lib/pkgconfig" cmake \
  -S "$sources/libheif-1.23.2" -B "$staging/libheif-build" \
  "${common_cmake[@]}" \
  -DCMAKE_PREFIX_PATH="$prefix" \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_PLUGIN_LOADING=OFF \
  -DWITH_LIBDE265=ON \
  -DWITH_LIBDE265_PLUGIN=OFF \
  -DWITH_X265=ON \
  -DWITH_X265_PLUGIN=OFF \
  -DWITH_X264=OFF \
  -DWITH_AOM_DECODER=OFF \
  -DWITH_AOM_ENCODER=OFF \
  -DWITH_DAV1D=OFF \
  -DWITH_SvtEnc=OFF \
  -DWITH_RAV1E=OFF \
  -DWITH_OpenH264_DECODER=OFF \
  -DWITH_JPEG_DECODER=OFF \
  -DWITH_JPEG_ENCODER=OFF \
  -DWITH_OpenJPEG_ENCODER=OFF \
  -DWITH_OpenJPEG_DECODER=OFF \
  -DWITH_FFMPEG_DECODER=OFF \
  -DWITH_LIBSHARPYUV=OFF \
  -DWITH_EXAMPLES=OFF \
  -DBUILD_TESTING=OFF \
  -DBUILD_DOCUMENTATION=OFF
cmake --build "$staging/libheif-build" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$staging/libheif-build"

clang -std=c11 -O2 -Wall -Wextra -Werror \
  -I"$prefix/include" \
  "$repo_root/Tools/SoftwareHEICCodec/main.c" \
  -L"$prefix/lib" -lheif \
  -Wl,-rpath,@executable_path/../lib \
  -mmacosx-version-min=15.0 \
  -o "$runtime/bin/lm-software-heic"

clang -std=c11 -O2 -Wall -Wextra -Werror \
  "$repo_root/Tools/SoftwareHEICCodec/normalize_macho_uuid.c" \
  -o "$staging/normalize-macho-uuid"

cp "$prefix/lib/libheif.1.23.2.dylib" "$runtime/lib/"
cp "$prefix/lib/libx265.217.dylib" "$runtime/lib/"
cp "$prefix/lib/libde265.0.2.1.dylib" "$runtime/lib/"

install_name_tool -change \
  "@rpath/libheif.1.dylib" \
  "@rpath/libheif.1.23.2.dylib" \
  "$runtime/bin/lm-software-heic"

install_name_tool -id "@rpath/libheif.1.23.2.dylib" \
  "$runtime/lib/libheif.1.23.2.dylib"
install_name_tool -change "@rpath/libx265.217.dylib" \
  "@rpath/libx265.217.dylib" "$runtime/lib/libheif.1.23.2.dylib"
install_name_tool -change "@rpath/libde265.0.dylib" \
  "@rpath/libde265.0.2.1.dylib" "$runtime/lib/libheif.1.23.2.dylib"

install_name_tool -id "@rpath/libx265.217.dylib" "$runtime/lib/libx265.217.dylib"
install_name_tool -id "@rpath/libde265.0.2.1.dylib" "$runtime/lib/libde265.0.2.1.dylib"

for binary in "$runtime/bin/lm-software-heic" "$runtime/lib/"*.dylib; do
  "$staging/normalize-macho-uuid" "$binary"
done

cp "$sources/libheif-1.23.2/COPYING" "$runtime/licenses/libheif-COPYING"
cp "$sources/x265_4.3/COPYING" "$runtime/licenses/x265-COPYING"
cp "$sources/libde265-1.1.1/COPYING" "$runtime/licenses/libde265-COPYING"

if { otool -L "$runtime/bin/lm-software-heic"; otool -L "$runtime/lib/"*.dylib; } \
  | rg 'VideoToolbox|ImageIO|AVFoundation|MediaToolbox'; then
  echo "Forbidden Apple media framework in software HEIC closure" >&2
  exit 1
fi

for binary in "$runtime/bin/lm-software-heic" "$runtime/lib/"*.dylib; do
  minimum=$(otool -l "$binary" | awk '/LC_BUILD_VERSION/{found=1} found&&/minos/{print $2; exit}')
  [[ -n "$minimum" ]]
  awk -v value="$minimum" 'BEGIN { exit !(value + 0 <= 15.0) }'
done

for binary in "$runtime/lib/"*.dylib "$runtime/bin/lm-software-heic"; do
  codesign --force --sign - "$binary"
done

find "$runtime" -type f -exec chmod 0644 {} +
chmod 0755 "$runtime/bin/lm-software-heic"
find "$runtime" -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 \
  | sed "s#  $runtime/#  #" > "$runtime/SHA256SUMS"
find "$runtime" -exec touch -t 202601010000 {} +

cache_directory="$repo_root/.dependency-cache/binaries"
mkdir -p "$cache_directory"
archive="$cache_directory/software-heic-$version.tar.gz"
archive_partial="$archive.partial"
(
  cd "$staging"
  find SoftwareHEIC -type f -print | LC_ALL=C sort > archive-files.txt
  COPYFILE_DISABLE=1 tar -cf - -T archive-files.txt | gzip -n > "$archive_partial"
)
mv "$archive_partial" "$archive"
echo "archive=$archive"
echo "size=$(stat -f '%z' "$archive")"
echo "sha256=$(shasum -a 256 "$archive" | awk '{print $1}')"
