#!/bin/bash
# usage: deps/eflame/stacks_to_flames.sh stacks.out

me="$(dirname $0)"
f=${1:-stacks.out}
maxwidth=${maxwidth:-1430}

awk -F';' '{print $1}' $f | uniq -c | tr -d '<>' | sort -rn -k1 | while read width pid; do
  : ${max:=$width.0}
  grep "$pid" "$f" | uniq -c | awk '{ print $2, " ", $1}' | $me/flamegraph.pl --title="$title ($pid)" --width=$(<<<"$maxwidth * $width / $max" bc)
  echo "<br/ ><br/ >"
done