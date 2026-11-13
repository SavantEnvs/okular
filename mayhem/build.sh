#!/usr/bin/env bash
#
# mayhem/build.sh — builds the Okular core library and the fuzzed document generators (sanitized and
# SanCov-instrumented shared objects), one libFuzzer binary + one standalone reproducer per document
# format, and (with the project's normal flags) the known-answer probe that mayhem/test.sh runs.
#
# Runs inside the commit image as `mayhem` in /mayhem, offline: every dependency is an apt -dev package
# installed by mayhem/Dockerfile.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# A re-run sees the compiler at a different path than the ccache-prefilled image build did, which makes
# cmake wipe a stale cache half-way through configuring; start from clean build dirs instead.
rm -rf build-fuzz build-tests

# format name | file suffix the generator is opened with | mime type | generator cmake target
FORMATS=(
  "fax|.g3|image/fax-g3|okularGenerator_fax"
  "dvi|.dvi|application/x-dvi|okularGenerator_dvi"
  "fb2|.fb2|application/x-fictionbook+xml|okularGenerator_fb"
  "xps|.xps|application/oxps|okularGenerator_xps"
  "cbz|.cbz|application/x-cbz|okularGenerator_comicbook"
  "txt|.txt|text/plain|okularGenerator_txt"
  "md|.md|text/markdown|okularGenerator_md"
  "epub|.epub|application/epub+zip|okularGenerator_epub"
)
GEN_TARGETS=()
for f in "${FORMATS[@]}"; do IFS='|' read -r _ _ _ tgt <<<"$f"; GEN_TARGETS+=("$tgt"); done

# SanCov counters in the shared objects are what give the fuzzer feedback from the code under test; they
# need the sanitizer runtime to resolve, so they go with the sanitizers. alignment is relaxed: the fax
# decoder (generators/fax/faxdocument.cpp getstrip) stores unaligned 32-bit words for every input.
COV_FLAGS=""
[ -z "$SANITIZER_FLAGS" ] || COV_FLAGS="-fsanitize=fuzzer-no-link -fno-sanitize=alignment"
FUZZ_FLAGS="$SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS -O1"

# Okular's other generators (PDF, DjVu, TIFF, PostScript) wrap third-party libraries that would be
# uninstrumented here, so they stay out of the build.
NOT_BUILT="Qt6TextToSpeech;Poppler;TIFF;LibSpectre;KExiv2Qt6;DjVuLibre"

# Compile definitions and include paths of an already configured build dir, to compile the harnesses with
# the same Qt/KF6 headers as the library.
include_flags() {
  (cd "$1" && ninja -t commands okularcore | awk '/core\/document.cpp/ && !seen {print; seen = 1}' \
     | grep -oE -- '-(D[A-Za-z0-9_=]+|I[^ ]+|isystem [^ ]+)' | grep -v 'okularcore_EXPORTS' | tr '\n' ' ')
}

# 1) Sanitized, instrumented Okular (core library + the fuzzed generators), shared, out of tree.
cmake -S . -B build-fuzz -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_BUILD_TYPE=None \
  -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=ON -DFORCE_NOT_REQUIRED_DEPENDENCIES="$NOT_BUILT" \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$SANITIZER_FLAGS" \
  -DCMAKE_MODULE_LINKER_FLAGS="$SANITIZER_FLAGS"
ninja -C build-fuzz -j"$MAYHEM_JOBS" okularcore "${GEN_TARGETS[@]}"

# 2) One harness source, compiled once per format: the libFuzzer binary and the standalone reproducer.
INC="$(include_flags build-fuzz)"
PLUGIN_DIR="$SRC/build-fuzz/bin"
LIBS="$(pkg-config --libs Qt6Widgets Qt6Xml) -lKF6CoreAddons"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-fuzz/standalone_main.o
for f in "${FORMATS[@]}"; do
  IFS='|' read -r name suffix mime generator <<<"$f"
  harness_flags="-std=c++20 -fPIC $FUZZ_FLAGS $INC -DFORMAT_SUFFIX=\"$suffix\" -DFORMAT_MIME=\"$mime\" -DOKULAR_GENERATOR=\"$generator\" -DOKULAR_PLUGIN_PREFIX=\"$PLUGIN_DIR\""
  link_flags="build-fuzz/lsan_off.o -L$PLUGIN_DIR -lOkular6Core -Wl,-rpath,$PLUGIN_DIR $LIBS"
  # shellcheck disable=SC2086
  $CXX $harness_flags mayhem/fuzz_okular.cc $LIB_FUZZING_ENGINE $link_flags -o "/mayhem/fuzz_$name"
  # shellcheck disable=SC2086
  $CXX $harness_flags mayhem/fuzz_okular.cc build-fuzz/standalone_main.o $link_flags -o "/mayhem/fuzz_$name-standalone"
done

# 3) The known-answer probe, linked against a separate Okular build with the project's normal flags.
cmake -S . -B build-tests -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=ON -DFORCE_NOT_REQUIRED_DEPENDENCIES="$NOT_BUILT" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
ninja -C build-tests -j"$MAYHEM_JOBS" okularcore "${GEN_TARGETS[@]}"
TEST_INC="$(include_flags build-tests)"
TEST_PLUGIN_DIR="$SRC/build-tests/bin"
# shellcheck disable=SC2086
$CXX -std=c++20 -fPIC -O1 $COVERAGE_FLAGS $TEST_INC -DOKULAR_PLUGIN_PREFIX=\"$TEST_PLUGIN_DIR\" \
  mayhem/kat_okular.cc -L"$TEST_PLUGIN_DIR" -lOkular6Core -Wl,-rpath,"$TEST_PLUGIN_DIR" $LIBS \
  -o /mayhem/kat_okular
file /mayhem/kat_okular | grep -q 'dynamically linked'
