#!/bin/sh
# Compares the simulated prints of two zslice builds by their statistics
# (see compare.py): the calibration parts, the overhang and bridge parts
# of the stress corpus, and the parts given after the builds.
#
# Usage: tools/simcheck/run.sh OLD_ZSLICE NEW_ZSLICE [PART.stl ...]
# Writes its files to a new folder under $TMPDIR (or /tmp).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
old=$1
new=$2
shift 2
here=$(dirname "$0")
work=$(mktemp -d "${TMPDIR:-/tmp}/simcheck.XXXXXX")
python3 -I "$here/../calib/gen.py" "$work/calib" >/dev/null
python3 -I "$here/../stress/gen.py" "$work/stress" --quick >/dev/null
parts="$work/calib/overhang.stl $work/calib/bridges.stl $work/calib/ledges.stl"
for s in ramp30 ramp50 ramp70 bridge5 bridge20 bridge80 cantilever; do
  f=$(ls "$work"/stress/"$s"__t0_s1.stl 2>/dev/null | head -n 1)
  [ -n "$f" ] && parts="$parts $f"
done
status=0
for p in $parts "$@"; do
  name=$(basename "$p" .stl)
  for b in old new; do
    eval bin=\$$b
    "$bin" bench "$p" --only sim --runs 1 -o "$work/$name.$b.csv" 2>"$work/$name.$b.log" >/dev/null
    t=$(grep -o 'simulate *wall median *[0-9.]*' "$work/$name.$b.log" | awk '{print $NF}')
    eval "t_$b=\$t"
  done
  echo "== $name: $t_old ms, then $t_new ms"
  python3 -I "$here/compare.py" "$work/$name.old.csv" "$work/$name.new.csv" || status=1
done
exit $status
