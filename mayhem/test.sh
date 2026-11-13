#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the known-answer probe (built by mayhem/build.sh) over one fixture per document format.
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Okular's own autotests are Qt test programs judged by exit code only, so the oracle is a probe
# (mayhem/kat_okular.cc, linked dynamically against the normal-flags libOkular6Core) that opens a fixture
# through Okular::Document and prints what the generator parsed; each output is compared with exact values.
KAT="$SRC/kat_okular"
[ -x "$KAT" ] || { echo "missing $KAT: mayhem/build.sh did not build the probe" >&2; emit_ctrf "okular-kat" 0 1 0; exit 1; }

passed=0; failed=0
# check <name> <expected output> <probe args...>
check() {
  local name="$1" expected="$2" actual; shift 2
  actual="$("$KAT" "$@" 2>/dev/null)"
  if [ "$actual" = "$expected" ]; then
    passed=$((passed + 1)); echo "PASS $name"
  else
    failed=$((failed + 1)); echo "FAIL $name"; printf '  expected:\n%s\n  actual:\n%s\n' "$expected" "$actual"
  fi
}
S="$SRC/mayhem"
export QT_QPA_PLATFORM=offscreen

check fax "open=ok
generator=okularGenerator_fax
pages=1
title=
size0=1728x45
text0=
pix=100x2
px=ffffff
px_corner=ffffff" image/fax-g3 "$S/fax/testsuite/white.g3"

check dvi "open=ok
generator=okularGenerator_dvi
pages=1
title=
size0=827x1169
text0=
pix=100x141
px=ffffff
px_corner=ffffff" application/x-dvi "$S/dvi/testsuite/min.dvi"

check fb2 "open=ok
generator=okularGenerator_fb
pages=1
title=Test Book
size0=600x800
text0=Test BookAnn Author Test Book Chapter 1 First pa
pix=100x133
px=c0c0c0
px_corner=ffffff" application/x-fictionbook+xml "$S/fb2/testsuite/book.fb2"

check xps "open=ok
generator=okularGenerator_xps
pages=1
title=
size0=816x1056
text0=
pix=100x129
px=cc3030
px_corner=ffffff" application/oxps "$S/xps/testsuite/page.xps" 31 19

check cbz "open=ok
generator=okularGenerator_comicbook
pages=2
title=
size0=40x60
text0=
pix=100x150
px=c81e1e
px_corner=c81e1e" application/x-cbz "$S/cbz/testsuite/two-pages.cbz"

check txt "open=ok
generator=okularGenerator_txt
pages=1
title=
size0=600x800
text0=Hello Okular second line of text that is a littl
pix=100x133
px=ffffff
px_corner=ffffff" text/plain "$S/txt/testsuite/hello.txt"

check md "open=ok
generator=okularGenerator_md
pages=1
title=
size0=980x1307
text0=Title Some emphasis and bold text with a link. i
pix=100x133
px=ffffff
px_corner=ffffff" text/markdown "$S/md/testsuite/basic.md"

check epub "open=ok
generator=okularGenerator_epub
pages=4
title=My Demo Epub
size0=600x800
text0=page1.html page2.html page1.html#pa1 page1.html#
pix=100x133
px=000000
px_corner=000004" application/epub+zip "$S/epub/testsuite/contents.epub"

# A document of one format is routed to its own generator even if the caller names another mime type.
check txt-via-xps-mime "open=ok
generator=okularGenerator_txt
pages=1
title=
size0=600x800
text0=Hello Okular second line of text that is a littl
pix=100x133
px=ffffff
px_corner=ffffff" application/oxps "$S/txt/testsuite/hello.txt"

emit_ctrf "okular-kat" "$passed" "$failed" 0
