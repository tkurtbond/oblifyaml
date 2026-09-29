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
VALGRIND ?= valgrind --leak-check=full --show-leak-kinds=definite,indirect --error-exitcode=99 --suppressions=voc-gc.supp

# voc reads LDLIBS from the environment itself when linking a main module.
export LDLIBS := $(shell pkg-config --libs libfyaml)

BUILD := build

# Library modules, in import order.
LIBMODS := FyThin Fyaml
# Test support modules, in import order.
TESTSUPPORT := Check
# Test programs (test/<name>.Mod, each a main module).
TESTS := TestThin TestParseErrors TestQuickstart TestNavigate TestPath TestLiveness TestBuild TestMutate TestScalars
# Programs that must halt (test/<name>.Mod), as name:required-exit-status;
# the status is one of Fyaml's Assert* codes.
HALTTESTS := HaltClosed:61 HaltKind:62 HaltIndex:63 HaltStale:61 HaltAttach:64 HaltAttached:64 HaltTyped:62

LIBOBJS  := $(LIBMODS:%=$(BUILD)/%.o)
SUPPOBJS := $(TESTSUPPORT:%=$(BUILD)/%.o)
TESTBINS := $(TESTS:%=$(BUILD)/%)
HALTBINS := $(foreach h,$(HALTTESTS),$(BUILD)/$(firstword $(subst :, ,$(h))))

.PHONY: all lib tests test valgrind clean

all: lib tests

lib: $(LIBOBJS)

tests: $(TESTBINS) $(HALTBINS)

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
$(SUPPOBJS): $(LIBOBJS)

# Test programs: main modules (-m); voc links the imported modules'
# .o files from $(BUILD) and $(LDLIBS).
$(BUILD)/Test%: test/Test%.Mod $(LIBOBJS) $(SUPPOBJS) | $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) ../$< -m

$(BUILD)/Halt%: test/Halt%.Mod $(LIBOBJS) | $(BUILD)
	cd $(BUILD) && $(VOC) $(VOCFLAGS) ../$< -m

# Run every test from test/ (fixtures are relative to it); report all,
# fail at the end if any failed. Each halt test must exit with exactly
# its listed status.
test: tests
	@status=0; for t in $(TESTS); do \
	  echo "== $$t"; (cd test && ../$(BUILD)/$$t) || status=1; \
	done; \
	for h in $(HALTTESTS); do \
	  t=$${h%%:*}; want=$${h##*:}; echo "== $$t (must halt with $$want)"; \
	  (cd test && ../$(BUILD)/$$t); got=$$?; \
	  if [ $$got -eq $$want ]; then echo "ok   - $$t halted with $$got"; \
	  else echo "FAIL - $$t exited with $$got, not $$want"; status=1; fi; \
	done; exit $$status

# Besides definite/indirect leaks, still-reachable must be exactly
# voc's one heap chunk: leaked libfyaml memory whose address is still
# held in the Oberon heap (e.g. unfreed orphan nodes) shows up only as
# extra still-reachable blocks.
REACHABLE := still reachable: 256,024 bytes in 1 blocks
valgrind: tests
	@status=0; for t in $(TESTS); do \
	  echo "== valgrind $$t"; \
	  (cd test && $(VALGRIND) --log-file=../$(BUILD)/$$t.vg ../$(BUILD)/$$t) || status=1; \
	  grep -E 'ERROR SUMMARY|lost:|reachable:' $(BUILD)/$$t.vg; \
	  grep -q '$(REACHABLE)' $(BUILD)/$$t.vg || { echo "FAIL - $$t: expected '$(REACHABLE)'"; status=1; }; \
	done; exit $$status

clean:
	rm -rf $(BUILD)
