#!/usr/bin/env python3
# Generates a single large YAML document: a top-level sequence of N small
# mappings, each with a handful of scalar fields -- stresses Node
# creation/navigation (many Value/Iterate calls, each a Node allocation here) within ONE
# Document. Shared with alibfyaml (bench_wide.adb there, BenchWide.Mod here).
import sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 200000
out = sys.argv[2] if len(sys.argv) > 2 else "wide.yaml"

with open(out, "w") as f:
    for i in range(n):
        f.write(f"- id: {i}\n")
        f.write(f"  name: entity_{i}\n")
        f.write(f"  value: {i * 3.5}\n")
        f.write(f"  active: {'true' if i % 2 == 0 else 'false'}\n")

print(f"wrote {n} entities to {out}")
