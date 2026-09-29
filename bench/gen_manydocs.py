#!/usr/bin/env python3
# Generates a multi-document YAML stream: N small "---"-separated documents
# -- stresses Document creation/destruction (alibfyaml: one Owner_Liveness alloc/
# mark-dead per document), not node-navigation volume within any single
# one. Shared with alibfyaml (bench_streams.adb there, BenchStreams.Mod here).
import sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
out = sys.argv[2] if len(sys.argv) > 2 else "manydocs.yaml"

with open(out, "w") as f:
    for i in range(n):
        f.write("---\n")
        f.write(f"id: {i}\n")
        f.write(f"name: doc_{i}\n")
        f.write(f"value: {i * 1.25}\n")

print(f"wrote {n} documents to {out}")
