# olibfyaml -- Oberon-2 (voc) binding to libfyaml.  See AGENTS.md.
#
# voc writes each module's .c/.h/.sym/.o into the current directory, so
# every voc invocation runs inside $(BUILD); voc's symbol search path
# starts at ".", which is how later modules find earlier ones' .sym.
# Modules must be compiled in import order.
#
# Targets are the .o files, not the .sym files: voc leaves an unchanged
# .sym untouched (old mtime), so a .sym target would never look up to
# date and would recompile on every make. gcc rewrites the .o each time.

VOC      ?= /usr/local/sw/versions/voc/git/bin/voc
VOCFLAGS := -OC            # size model: decided in PLAN.md; never mix models
VALGRIND ?= valgrind --leak-check=full --show-leak-kinds=definite,indirect --error-exitcode=99 --suppressions=voc-gc.supp --suppressions=libfyaml.supp

# voc reads LDLIBS from the environment itself when linking a main module.
export LDLIBS := $(shell pkg-config --libs libfyaml)

BUILD := build

# Library modules, in import order.
LIBMODS := FyThin Fyaml FyamlStreams
# Test support modules, in import order.
TESTSUPPORT := Check
# Test programs (test/<name>.Mod, each a main module).
TESTS := TestThin TestParseErrors TestQuickstart TestNavigate TestPath TestLiveness TestBuild TestMutate TestScalars TestAnchors TestLocation TestStreams TestStdin TestStdinError TestStdinStream
# Programs that must halt (test/<name>.Mod), as name:required-exit-status;
# the status is one of Fyaml's Assert* codes.
HALTTESTS := HaltClosed:61 HaltKind:62 HaltIndex:63 HaltStale:61 HaltAttach:64 HaltAttached:64 HaltTyped:62 HaltResolved:61 HaltStream:61

# Example programs (examples/<name>.Mod), as name:required-exit-status.
# `make test` runs each from examples/ and requires that status and
# stdout identical to examples/<name>.expected. The Example*Error ones
# report a deliberate error in their fixture, so exit 1.
EXAMPLES := ExampleConfig:0 ExampleSyntaxError:1 ExampleValueError:1 ExampleMissingField:1

LIBOBJS  := $(LIBMODS:%=$(BUILD)/%.o)
SUPPOBJS := $(TESTSUPPORT:%=$(BUILD)/%.o)
TESTBINS := $(TESTS:%=$(BUILD)/%)
HALTBINS := $(foreach h,$(HALTTESTS),$(BUILD)/$(firstword $(subst :, ,$(h))))
EXAMPLEBINS := $(foreach e,$(EXAMPLES),$(BUILD)/$(firstword $(subst :, ,$(e))))

# Benchmarks (bench/), built by `make bench`, not by `all`.
BENCHES := BenchWide BenchStreams
BENCHBINS := $(BENCHES:%=$(BUILD)/%)
# Generated inputs, the same sizes as alibfyaml's; large, so in build/.
WIDE := $(BUILD)/wide.yaml
MANYDOCS := $(BUILD)/manydocs.yaml
RUNS ?= 10

.PHONY: all lib tests test valgrind bench clean

all: lib tests

lib: $(LIBOBJS)

tests: $(TESTBINS) $(HALTBINS) $(EXAMPLEBINS)

$(BUILD):
	mkdir -p $@

# Library and support modules: -s lets voc create or change the .sym.
$(BUILD)/%.o: src/%.Mod | $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) -s ../$<

$(BUILD)/%.o: test/%.Mod | $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) -s ../$<

# Import dependencies: a module must be compiled after, and recompiled
# when, each module it imports. Add a line here for every new import
# between library/support modules, e.g.
#   $(BUILD)/Fyaml.o: $(BUILD)/FyThin.o
$(BUILD)/Fyaml.o: $(BUILD)/FyThin.o
$(BUILD)/FyamlStreams.o: $(BUILD)/Fyaml.o $(BUILD)/FyThin.o
$(SUPPOBJS): $(LIBOBJS)

# Test programs: main modules (-m); voc links the imported modules'
# .o files from $(BUILD) and $(LDLIBS).
$(BUILD)/Test%: test/Test%.Mod $(LIBOBJS) $(SUPPOBJS) | $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) ../$< -m

$(BUILD)/Halt%: test/Halt%.Mod $(LIBOBJS) | $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) ../$< -m

$(BUILD)/Example%: examples/Example%.Mod $(LIBOBJS) | $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) ../$< -m

$(BUILD)/Timing.o: bench/Timing.Mod | $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) -s ../$<

$(BUILD)/Bench%: bench/Bench%.Mod $(LIBOBJS) $(BUILD)/Timing.o | $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) ../$< -m

$(WIDE): bench/gen_wide.py | $(BUILD)
	python3 bench/gen_wide.py 200000 $@

$(MANYDOCS): bench/gen_manydocs.py | $(BUILD)
	python3 bench/gen_manydocs.py 20000 $@

# Each benchmark $(RUNS) times: n/mean/min/max/stddev of elapsed_seconds.
bench: $(BENCHBINS) $(WIDE) $(MANYDOCS)
	@$(BUILD)/BenchWide $(WIDE) | grep -v elapsed
	@$(BUILD)/BenchStreams $(MANYDOCS) | grep -v elapsed
	@for p in typed nav thin parse; do \
	  printf 'BenchWide %-6s ' $$p; bench/run_stats.sh $(RUNS) $(BUILD)/BenchWide $(WIDE) $$p; \
	done
	@printf 'BenchStreams       '; bench/run_stats.sh $(RUNS) $(BUILD)/BenchStreams $(MANYDOCS)
	@printf 'BenchStreams gc    '; bench/run_stats.sh $(RUNS) $(BUILD)/BenchStreams $(MANYDOCS) gc

# Shell function, called from within test/: a test's stdin --
# <name>.stdin if there is one (TestStdin and friends), else /dev/null.
STDIN := stdin() { if [ -f $$1.stdin ]; then echo $$1.stdin; else echo /dev/null; fi; }

# Run every test from test/ (fixtures are relative to it); report all,
# fail at the end if any failed. Each halt test must exit with exactly
# its listed status.
test: tests
	@$(STDIN); status=0; for t in $(TESTS); do \
	  echo "== $$t"; (cd test && ../$(BUILD)/$$t < $$(stdin $$t)) || status=1; \
	done; \
	for h in $(HALTTESTS); do \
	  t=$${h%%:*}; want=$${h##*:}; echo "== $$t (must halt with $$want)"; \
	  (cd test && ../$(BUILD)/$$t); got=$$?; \
	  if [ $$got -eq $$want ]; then echo "ok   - $$t halted with $$got"; \
	  else echo "FAIL - $$t exited with $$got, not $$want"; status=1; fi; \
	done; \
	for x in $(EXAMPLES); do \
	  e=$${x%%:*}; want=$${x##*:}; \
	  echo "== $$e (must exit $$want with examples/$$e.expected)"; \
	  (cd examples && ../$(BUILD)/$$e) > $(BUILD)/$$e.out; got=$$?; \
	  if [ $$got -eq $$want ] && cmp -s $(BUILD)/$$e.out examples/$$e.expected; then echo "ok   - $$e"; \
	  else echo "FAIL - $$e: exit $$got, output:"; diff examples/$$e.expected $(BUILD)/$$e.out; status=1; fi; \
	done; exit $$status

# Besides definite/indirect leaks, still-reachable must be exactly
# voc's one heap chunk: leaked libfyaml memory whose address is still
# held in the Oberon heap (e.g. unfreed orphan nodes) shows up only as
# extra still-reachable blocks.
REACHABLE := still reachable: 256,024 bytes in 1 blocks
valgrind: tests
	@$(STDIN); status=0; for t in $(TESTS); do \
	  echo "== valgrind $$t"; \
	  (cd test && $(VALGRIND) --log-file=../$(BUILD)/$$t.vg ../$(BUILD)/$$t < $$(stdin $$t)) || status=1; \
	  grep -E 'ERROR SUMMARY|lost:|reachable:' $(BUILD)/$$t.vg; \
	  grep -q '$(REACHABLE)' $(BUILD)/$$t.vg || { echo "FAIL - $$t: expected '$(REACHABLE)'"; status=1; }; \
	done; exit $$status

clean:
	rm -rf $(BUILD)
