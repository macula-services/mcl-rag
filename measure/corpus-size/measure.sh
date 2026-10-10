#!/bin/sh
# The exact commands behind measure/corpus-size/README.md, for re-running on
# the corpus box (msi00) when the numbers need refreshing. Prints the checkout
# table and the depth tables; clones into $SCRATCH.
#
#   CORPUS=<path to the corpus volume's corpus/> SCRATCH=<scratch dir> ./measure.sh [repo...]
#
# It uses the OS git deliberately: these are measurements of what a clone
# costs, not the service (which clones through the vendored-libgit2 NIF).
set -eu

CORPUS="${CORPUS:?set CORPUS to the corpus directory (holds one checkout per id)}"
SCRATCH="${SCRATCH:?set SCRATCH to a scratch directory for the depth clones}"
REPOS="${*:-kicad rt-thread zephyr esp-idf erlang-otp freertos sdrangel circuitpython micropython librepcb}"

echo "== where the size is (live checkouts under $CORPUS)"
printf '%-16s %8s %8s %8s %10s\n' repo total .git md_bytes md_files
for r in $REPOS; do
  [ -d "$CORPUS/$r" ] || continue
  tot=$(du -sm "$CORPUS/$r" | cut -f1)
  git=$(du -sm "$CORPUS/$r/.git" | cut -f1)
  md=$(find "$CORPUS/$r" -name '*.md' -not -path '*/.git/*' -printf '%s\n' 2>/dev/null | awk '{t+=$1} END {print t+0}')
  n=$(find "$CORPUS/$r" -name '*.md' -not -path '*/.git/*' 2>/dev/null | wc -l)
  printf '%-16s %7sM %7sM %10s %8s\n' "$r" "$tot" "$git" "$md" "$n"
done

# The two branches the README's depth tables used. Same commands for any entry:
# clone the entry's url and branch at the depth, in the table's units.
echo "== depth (fresh clones into $SCRATCH)"
mkdir -p "$SCRATCH"
depth_run() {
  name="$1"; url="$2"; branch="$3"; depth="$4"
  out="$SCRATCH/$name-d$depth"
  rm -rf "$out"
  t0=$(date +%s)
  git clone --quiet --depth "$depth" --branch "$branch" "$url" "$out"
  t1=$(date +%s)
  printf '%-12s depth=%-4s total=%sM git=%sM clone_s=%s\n' "$name" "$depth" \
    "$(du -sm "$out" | cut -f1)" "$(du -sm "$out/.git" | cut -f1)" "$((t1-t0))"
}
for d in 1 50 500; do
  depth_run zephyr https://github.com/zephyrproject-rtos/zephyr.git main "$d"
done
for d in 1 50 500; do
  depth_run kicad https://github.com/KiCad/kicad-source-mirror.git master "$d"
done
