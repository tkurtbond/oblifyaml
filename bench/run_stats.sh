#!/usr/bin/env bash
# Runs a benchmark command N times, extracts elapsed_seconds, prints
# mean/min/max/stddev. From alibfyaml's, changed to take any command.
# Usage: run_stats.sh <N> <command> [args...]
set -euo pipefail
N="$1"; shift

times=()
for ((i=0; i<N; i++)); do
  line=$("$@" | grep elapsed_seconds)
  val=$(echo "$line" | sed -E 's/.*elapsed_seconds= *([0-9.]+).*/\1/')
  times+=("$val")
done

printf '%s\n' "${times[@]}" | awk '
{
  sum += $1; sumsq += $1*$1; n++;
  if (NR==1 || $1<min) min=$1;
  if (NR==1 || $1>max) max=$1;
}
END {
  mean = sum/n;
  var = sumsq/n - mean*mean;
  if (var < 0) var = 0;
  sd = sqrt(var);
  printf "n=%d mean=%.6f min=%.6f max=%.6f stddev=%.6f\n", n, mean, min, max, sd;
}'
