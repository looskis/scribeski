#!/bin/sh
# Builds the llama-server helper the app ships in Contents/Helpers (BUILD_PLAN P4.1), from
# pinned llama.cpp source: arm64, Metal with the shader library embedded, statically linked
# (no dylibs to sign or hijack), no network client, no web UI assets needed at runtime.
#
#   scripts/build-llama-server.sh          → App/Helpers/llama-server (+ .version)
#
# Needs cmake (brew install cmake) and git. The Xcode build copies and signs the result.
set -eu
cd "$(dirname "$0")/.."

TAG=b10964
COMMIT=b29c606e2                     # what `llama-server --version` reports for $TAG
SRC=.build/llama.cpp-$TAG
OUT=App/Helpers

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$SRC"
fi
HEAD=$(git -C "$SRC" rev-parse HEAD)
case "$HEAD" in
  "$COMMIT"*) ;;
  *) echo "llama.cpp $TAG is $HEAD, expected $COMMIT: refusing to build" >&2; exit 1 ;;
esac

cmake -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_BLAS=ON \
  -DLLAMA_CURL=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_NUMBER="${TAG#b}" >/dev/null
cmake --build "$SRC/build" --target llama-server -j "$(sysctl -n hw.ncpu)" >/dev/null

mkdir -p "$OUT"
cp "$SRC/build/bin/llama-server" "$OUT/llama-server"
strip -x "$OUT/llama-server"
chmod 755 "$OUT/llama-server"

# Only system libraries and frameworks: nothing from Homebrew or the build tree.
if otool -L "$OUT/llama-server" | tail -n +2 | grep -v -E '^\s+/(usr/lib|System/Library)/'; then
  echo "llama-server links something outside the OS (above): refusing" >&2; exit 1
fi
"$OUT/llama-server" --version 2>&1 | head -2 > "$OUT/llama-server.version"
cat "$OUT/llama-server.version"
echo "→ $OUT/llama-server ($(du -h "$OUT/llama-server" | cut -f1))"
