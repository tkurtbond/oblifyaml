# AGENTS.md

Oberon-2 binding to libfyaml's core parser/emitter/document API,
compiled with Vishap Oberon (`voc`). See PLAN.md for the design,
phased roadmap, and open questions; this file is operational notes
for an agent working in this repo, not a design doc.

This binding is a port of the Ada binding in `~/Repos/Ada/alibfyaml`
(and borrows from the Chicken Scheme binding in
`~/Repos/Scheme/Chicken/5/slibfyaml`, which, like voc, runs on a
garbage-collected host). Read their `AGENTS.md`/`PLAN.md` before
redesigning anything: most of their text is hard-won, confirmed
behavior of libfyaml itself, and applies here unchanged.

## Reference material

| What | Where |
|---|---|
| libfyaml source (v1.0.0-beta1) | `/usr/local/sw/src/lang/C/libfyaml/` (`include/libfyaml.h`, `src/lib/`) |
| Installed libfyaml | system package `libfyaml-devel-0.8-9.fc44`; `/usr/include/libfyaml.h`, `pkg-config --libs libfyaml` = `-lfyaml` |
| voc compiler | `/usr/local/sw/versions/voc/git/bin/voc` (v2.1.0, LP64); this binding uses the `-OC` model: runtime `lib/libvoc-OC.{a,so}`, headers/symbols under `C/` (`-O2`'s are `libvoc-O2`/`2/`) |
| voc source | `/usr/local/sw/src/lang/Oberon/vishap/compiler/` (runtime in `src/runtime/`, docs in `doc/`, C-library binding examples in `src/test/newt`, `src/test/gtk`) |
| Oberon-2 report | `~/Reference/Computer/Languages/Oberon/Oberon2.pdf`; plain text: `Oberon2-layout.text` (keeps tables/columns readable) and `Oberon2-no-layout.text` |
| Ada binding | `~/Repos/Ada/alibfyaml/` |
| Scheme binding | `~/Repos/Scheme/Chicken/5/slibfyaml/` |

As with alibfyaml: the system package's `0.8` version label is
misleading. It already exposes the 1.0-beta1 API. Confirm a symbol
before assuming it's missing, e.g.
`nm -D $(pkg-config --variable=libdir libfyaml)/libfyaml.so | grep fy_document_build_from_string`.

## Build

`voc` is not on the default `PATH`:

```sh
export PATH=/usr/local/sw/versions/voc/git/bin:$PATH
```

Use the `Makefile`; don't invoke voc by hand:

```sh
make            # library, test programs and examples, into build/
make test       # every test (from test/), halt test, and example (from examples/)
make valgrind   # the test programs, each under valgrind
make bench      # benchmarks (bench/); not part of `make` or `make test`
make clean      # rm -rf build
```

What it wraps: voc translates each module to C (`Mod.c`, `Mod.h`,
`Mod.sym`, `Mod.o`) **in the current directory**, so every voc call
runs inside `build/`, and voc's symbol search path starts at `.`,
which is how later modules find earlier ones' `.sym`. Modules must be
compiled in import order, and main modules with `-m`. `-s` lets voc
create or change a `.sym` (without it, a changed interface is a
compile error). voc reads extra flags from the environment itself
(`src/compiler/extTools.Mod`): `CFLAGS` for every compile, and
`LDFLAGS`/`LDLIBS` only when linking a main module. The Makefile
exports `LDLIBS=$(pkg-config --libs libfyaml)`. Add `-V` to a voc
command to see the exact gcc command it runs.

**Make targets are the `.o` files, not the `.sym` files.** voc leaves
an unchanged `.sym` untouched (old mtime), so a `.sym` target never
looks up to date. **Adding a module takes Makefile edits**: append it
to `LIBMODS` (or `TESTSUPPORT`) in import order, and add an explicit
`$(BUILD)/New.o: $(BUILD)/Imported.o` line for each module it
imports. Make has no other way to learn the import order.

Integer size model: **build every module with `-OC`**, as the first
option on the voc command line so it applies to every file. This is
decided; see PLAN.md, "Integer model". Under `-OC`, voc's types match
LP64 C one-to-one: `SHORTINT` = `short` (16 bits), `INTEGER` = `int`
(32), `LONGINT` = `long`/`size_t`/`ssize_t` (64), and `SET` = the
32-bit `unsigned int` flag masks. `LEN()` returns a 64-bit `LONGINT`.
Code using the binding must also be compiled with `-OC`: `.sym` files
and the runtime library differ between models, so **never mix models**.
A forgotten `-OC` shows up as a `.sym` mismatch or as silently wrong
integer widths. In `FyThin`, still write the explicit-size types
(`SYSTEM.INT32` for `int`, `SYSTEM.ADDRESS` for pointers and `size_t`)
so every C-boundary signature says what it means whatever the model.
The thick layer (`Fyaml`, `FyamlStreams`) uses plain `INTEGER`/`LONGINT`.

## Test

Each test is its own main module in `test/` (`TestThin`,
`TestParseErrors`, `TestQuickstart`, `TestNavigate`, `TestPath`,
`TestLiveness`, `TestBuild`, `TestMutate`, `TestScalars`,
`TestAnchors`, `TestLocation`, `TestStreams`, `TestStdin`,
`TestStdinError`, `TestStdinStream`), printing `ok   - <label>` / `FAIL - <label>` per check through the
shared `test/Check.Mod`, and ending with `All checks passed.` or
`<N> check(s) failed.` A failing run exits 1, so `make test` fails. To
judge a run, grep for `FAIL` or read the last line. **Adding a test
means adding its name to `TESTS` in the Makefile.** YAML fixtures go
in `test/` (tests run with `test/` as their working directory), copied
from `~/Repos/Ada/alibfyaml/test/*.yaml` where one fits, so all three
bindings are tested against the same inputs.

**Stdin tests.** `make test` and `make valgrind` run each test with
stdin redirected from `test/<name>.stdin` if that file exists, else
from `/dev/null`. A process can read stdin only once, so each stdin
case (`TestStdin`, `TestStdinError`, `TestStdinStream`) is its own
program with its own `.stdin` file. To run one by hand, from `test/`:
`../build/TestStdin < TestStdin.stdin`.

`Check.Summary` calls `Platform.Exit(1)` **only** on failure. That
calls C `exit()` directly and skips `Heap.FINALL`, the exit-time run
of GC finalizers. A passing run returns normally from the main module
body so the finalizers run and valgrind's leak report stays meaningful.
Keep it that way, and never end a test with `Platform.Exit(0)`.

**Halt tests.** A programmer error must halt with the right `Fyaml.Assert*`
code, and a program can't catch its own halt. So each such case is a
separate small main module, `test/Halt*.Mod` (`HaltClosed`,
`HaltKind`, `HaltIndex`, `HaltStale`, `HaltAttach`, `HaltAttached`,
`HaltTyped`, `HaltResolved`, `HaltStream`), listed in the Makefile's `HALTTESTS` as
`name:status`. `make test` fails unless each one exits with exactly
that status. voc prints `Assertion failure. ASSERT code N.` and exits
with `N`, and a method call on a NIL pointer prints `NIL access.` and
exits with 246 (both confirmed live). voc refuses to compile an
`ASSERT` it can prove false (`err 99 ASSERT fault`), so a probe needs
a condition that is false only at run time.

Expected stderr noise: libfyaml prints some failures itself,
bypassing the collected diagnostics. `ParseFile` checks for an
unopenable file first, so that case is quiet, but a directory given as
a file still prints `[ERR]: fy_parse_load_document() failed`, and so
does a cyclic reference found while parsing with resolve on
(`TestAnchors`). Neither is a test failure.

### Valgrind: necessary, but NOT sufficient here

Run anything that touches ownership or lifetime under

```sh
make valgrind
# or, for one test, from test/:
valgrind --leak-check=full --show-leak-kinds=definite,indirect --error-exitcode=99 --suppressions=voc-gc.supp --suppressions=libfyaml.supp ../build/TestWhatever
```

before calling it done, the same rule as alibfyaml. `libfyaml.supp`
covers one known bug in the installed libfyaml: `realloc(buf, 0)` on
empty stream input, which Memcheck reports as `ReallocZero` and which
doesn't leak (PLAN.md, "Standard input"). Keep its entries narrow, and
add one only after confirming the bug is in libfyaml. Two voc-specific
things to know when reading the output:

- **`test/voc-gc.supp` is required** for any program where a GC runs.
  voc's collector scans the stack conservatively, reading words that
  were never written. Without the suppressions, `TestLiveness` shows
  663,006 "uninitialised value" errors, all inside `Heap_MarkStack`,
  `Heap_HeapSort`, `Heap_Sift` and `Heap_MarkCandidates`. The file
  suppresses only that error kind, and only when the top frame is one
  of those four functions.
- **Check "still reachable", not just "definitely lost".** A libfyaml
  document that is never freed is pointed to from inside voc's heap
  chunk, which stays reachable, so valgrind may classify the leak as
  "still reachable" rather than "definitely lost". The only expected
  still-reachable memory is voc's own heap chunk: exactly
  `256,024 bytes in 1 blocks` (`Heap_InitHeap`) in every test.
  Anything more means a document or other C memory wasn't freed.
  `make valgrind` enforces this (it greps each test's log for that
  exact line); for a single run use `--show-leak-kinds=all`. As
  controls, disabling the document finalizer grew it to 29 blocks and
  made `TestLiveness` fail, and disabling the orphan-node free at
  `Close` grew `TestBuild`'s to 14 blocks with nothing "lost".

**But valgrind
cannot see one bug class that is specific to voc, and it has already
happened once (confirmed live in the Phase 0 spike):**

voc passes a value `ARRAY OF CHAR` parameter by copying it into
`alloca` memory (`__DUP` in `SYSTEM.h`), which is released when the
procedure returns. A string handed to `fy_document_build_from_string`
this way leaves the document holding zero-copy spans into a dead stack
frame. `fy_node_get_scalar` then silently returns garbage or empty
text. Valgrind reports **0 errors**, because this is stack memory, not
heap. The only defence is design plus tests that check actual values:
never pass memory to libfyaml that doesn't outlive the libfyaml object
which may keep pointing into it. See PLAN.md, "Buffer lifetime".

## Layout

- `src/FyThin.Mod`: low-level libfyaml calls. No ownership or error
  policy.
- `src/Fyaml.Mod`: `Document`, `Node`, `Error`, iterators (Phase 1);
  emit, build and mutate (Phase 2); typed scalar accessors and
  mapping fields (Phase 3); parse options, `Resolve`, aliases, tags,
  styles and locations (Phase 4).
- `src/FyamlStreams.Mod`: multi-document streams (Phase 5). It
  builds `Fyaml.Document`s through `Fyaml`'s exported "For
  FyamlStreams" hooks (`Adopt`, `DiagErrors`, `Unreadable`), which
  exist only because Oberon has no friend modules; keep other code
  off them.
- `Makefile`: build and test; see Build above.
- `test/`: one main module per concern, plus `Check.Mod` and the YAML
  fixtures.
- `examples/`: example programs with fixtures and `<name>.expected`
  output. `make test` requires each one's exit status (listed as
  `name:status` in the Makefile's `EXAMPLES`) and exact output, so a
  changed message fails there. `ExampleConfig` is the README's example;
  keep the README's copy in step with it. After changing an example
  or a message, check the new output by hand, then regenerate its
  `.expected` from the program.
- `bench/`: `BenchWide`, `BenchStreams`, the shared `Timing` module,
  alibfyaml's input generators, and `run_stats.sh`. `make bench`
  generates the (large) inputs into `build/`, prints checksums (which
  must match alibfyaml's: 55002038890 and 200158890), then 10-run
  timing stats (`RUNS=n` to change). Record numbers in PLAN.md when
  a change touches a hot path.
- `README.md`: the user-facing guide.
- `build/`: voc/gcc output (gitignored).
- `PLAN.md`: design, decisions, confirmed findings, and open
  questions, organized by section. Append to the relevant section
  rather than starting a new document. Mark a finished section
  `[done]`, and strike through an open question once it's decided.

## voc / Oberon-2 facts this binding depends on (confirmed)

- **Oberon-2 has no call chaining.** A function call's result isn't a
  designator (report §8.1), so `d.Root().Value("k")` doesn't compile
  (`err 113 incompatible assignment`). Assign each step to a variable,
  or use `ByPath` to go several levels in one call.
- **libfyaml's `*_iterate` ends by resetting the cursor to NULL, which
  also means "start over".** A naive `Next` after the end silently
  restarts from the first item (confirmed live). `ItemIter`/`PairIter`
  keep a `done` flag for this reason.
- **`*)` ends a comment anywhere inside it**, including in text like
  `fy_node_is_*)`. The first `FyThin` build failed on exactly that
  (`err 41 END missing`, pointing at the comment line). Write "and
  friends" rather than a C wildcard ending in `*` before a `)`.
  (Inside a code procedure's C *string*, `(struct fy_node*)` is fine.)
- **`(*` inside a comment opens a nested one** (Oberon comments
  nest), so text like "an alias (*name)" swallows the rest of the
  module (`err 5 comment not closed`). Quote it: `("*name")`.
- **C is bound with "code procedures"**: `PROCEDURE -name(params): T
  "C expression";`. voc emits these as C *macros*, not functions, and
  a header is pulled in with `PROCEDURE -Aname '#include <libfyaml.h>';`
  (voc's own `Platformunix.Mod` does exactly this).
- **An exported code procedure expands in the importing module's C
  file**, where `<libfyaml.h>` was never included, so gcc fails with
  "implicit declaration of function fy_...". (Confirmed in the spike.)
  So `FyThin`'s code procedures are **unexported**, and each is wrapped
  in an ordinary exported procedure. Don't "simplify" this by
  exporting the macros.
- **Because code procedures are inline C, `static inline` header
  helpers ARE callable** (`fy_node_is_mapping`, `fy_node_is_alias`,
  ...), and so are C struct fields (`e->line`) and `#define`
  constants (`FYNWF_DONT_FOLLOW`). This removes two of alibfyaml's
  workarounds: it had to reimplement the inline predicates, and it
  hand-mirrored `fy_parse_cfg`/`fy_diag_error` as Ada records, which
  its PLAN.md flags as an ABI-drift risk. **Don't mirror C structs as
  Oberon records.** Read their fields through code procedures, so gcc
  computes the offsets against the installed header.
- Casts in code-procedure text: Oberon-side handles are
  `SYSTEM.ADDRESS` (the C type `ADDRESS`, a signed integer the width
  of a pointer), so cast explicitly on the way into C
  (`(struct fy_node*)n`) and back out (`(ADDRESS)fy_...(...)`).
  `CHAR` is `unsigned char` and `BOOLEAN` is `signed char` in voc's C.
- **voc's GC** (`src/runtime/Heap.Mod`) is non-moving mark-sweep.
  It scans the stack conservatively and module globals precisely, and
  **cannot see pointers stored only in C memory**. Anything libfyaml
  points into must also be reachable from an Oberon pointer, e.g. a
  field of the owning `Document`.
- **Finalizers**: `Heap.RegisterFinalizer(obj, proc)`. Before
  sweeping, `CheckFin` marks each unreachable finalizable object *and
  everything it references*, so a `Document`'s buffer field is still
  valid while that `Document`'s finalizer runs. `Heap.FINALL` runs
  every pending finalizer at normal program exit (`__FINI`), so
  valgrind's end-of-run leak report is meaningful. The GC only runs
  on Oberon allocation and cannot see libfyaml's C-side memory
  pressure, which is why explicit `Close` is the primary cleanup path
  and finalizers are only a backstop.
- **voc's `DIV` overflows on operands near `MIN(LONGINT)`**
  (`(MIN(LONGINT) + 9) DIV 10` is positive, confirmed live). Divide
  only non-negative values there; see `Fyaml.ParseInt`.
- **Real literals are `REAL` unless suffixed `D`**: `1234.56` is a
  32-bit `REAL` and never equals the `LONGREAL` 1234.56, but
  `1234.56D0` does, bit for bit with glibc's `strtod`. Write `D`
  literals when comparing `LONGREAL` results.
- **voc's `Out` buffers until `Out.Ln` or `Out.Flush`, and
  `Platform.Exit` doesn't flush it.** Printing `err.msg` (which ends in
  its own newline) and then calling `Platform.Exit` loses the message
  (confirmed live). Call `Out.Flush` before `Platform.Exit`.
- **voc compiles to C, where argument evaluation order is
  unspecified**: `Report(Fyaml.ParseFile(p, err), err)` may pass `err`
  before `ParseFile` sets it. Assign the result first.
- **Allocation is what makes voc programs slow.** voc collects
  whenever its small heap fills (it keeps only a fifth free), and each
  collection has a large fixed cost: a conservative scan of the whole
  stack, including `Heap.GC`'s own 10,000-word candidate array, plus
  a heap sort. On hot paths inside the binding, don't allocate objects
  the caller never sees: use `FyThin` handles rather than `Node`s,
  and stack buffers rather than `String`s (see `Fyaml.GetText`).
  PLAN.md, Phase 6, has the measurements.
- **Oberon-2 has no exceptions**, no generics, no closures, and
  function procedures can't return arrays or records. That shapes the
  API: results come back as `BOOLEAN` plus `VAR` out parameters or
  an error object, strings are `POINTER TO ARRAY OF CHAR`, and
  iteration uses explicit iterator records. See PLAN.md.
  `ASSERT`/`HALT` end the program, so reserve them for programmer
  errors (a closed document, a NIL node), never for bad input data.

## Conventions

- **Comments explain *why*, and only claim what has been verified.**
  Where a comment or a decision depends on how libfyaml or voc
  actually behaves, test it: write a throwaway program in the
  scratchpad, run it (under valgrind if lifetime is in question, and
  check the actual *values* too, per the `__DUP` note above), then
  write the result down as a confirmed fact. libfyaml's header
  comments have been wrong or misleading several times (see
  alibfyaml's PLAN.md: `fy_node_get_path` on the root, the
  `fy_document_insert_at` unref, the `fy_parser_set_input_file`
  filename lifetime).
- **Bind only what the thick layer calls.** Before adding a new entry
  point to `FyThin`, confirm it exists (in the header for inline
  helpers, or with `nm -D` for exported symbols).
- **Document what every mutating operation does to each
  `Node`/`Document` argument, on success and on failure.** libfyaml
  itself can consume or invalidate handles; `fy_document_insert_at`
  always unrefs its node, whatever the outcome, and `fy_node_insert`/
  `fy_document_set_root` free the nodes they replace. That's why
  `InsertAt`, `Resolve` and a replacing `SetRoot` bump the document's
  generation count and so kill every earlier Node (see PLAN.md, "Node
  validity"); a new mutating call that can free nodes must do the
  same. A node made by `Create*` must go through the orphan list
  (`AddOrphan`/`DropOrphan`), since `fy_document_destroy` doesn't
  free unattached nodes.
- **Cleanup must be idempotent.** An explicit `Close` and the GC
  finalizer can both run on the same object, so `Close` must set the
  handle to 0 before or when it frees, and do nothing if it's already
  0. That rules out double frees.
- Record decisions and findings in PLAN.md as they happen, the same
  way alibfyaml does.
