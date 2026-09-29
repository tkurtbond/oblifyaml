# olibfyaml design plan

An Oberon-2 binding, for Vishap Oberon (`voc`), to libfyaml's core
parser/emitter/document API: parse YAML/JSON into a document tree,
navigate it, mutate it, and emit it back out. The goal is feature
parity with the Ada binding (`~/Repos/Ada/alibfyaml`), reached in the
same order, while taking design choices from the Chicken Scheme
binding (`~/Repos/Scheme/Chicken/5/slibfyaml`) wherever voc's
garbage-collected, exception-free model sits closer to Scheme than to
Ada.

AGENTS.md has the operational notes: tool paths, build commands, and
the confirmed voc facts this plan relies on.

## Scope

In scope (same as alibfyaml):

- document lifecycle: parse from a string or file, build from scratch,
  destroy
- node predicates, scalar/sequence/mapping access, iteration, path
  lookup (`By_Path`) and its inverse (`Path`)
- construction and mutation: create scalar/sequence/mapping, append,
  set root, insert at path
- emission to a string or file, with the emitter flags
- diagnostics collection: parse errors with file, line, and column
- anchors, aliases, and merge keys (resolve), tags, and styles
- multi-document streams
- source location of scalar nodes
- typed scalar accessors (YAML 1.2 core schema), with required and
  optional-with-default mapping-key forms

Out of scope, for the same reasons as alibfyaml:

- **Generics** (`fy_generic`, C11 `_Generic`/variadic macros) and
  **reflection** (libclang-driven C struct serdes).
- **Variadic entry points** (`fy_document_scanf`, `fy_node_buildf`,
  `fy_node_report`, ...). voc *could* call one with a fixed argument
  list inside a code procedure, but not generically, so the typed API
  covers these uses instead.

## Target versions

- libfyaml 1.0.0-beta1 API, as provided by the system package on this
  machine (`libfyaml-devel-0.8-9.fc44`; the version label is
  misleading, see AGENTS.md). Local source for reading implementations:
  `/usr/local/sw/src/lang/C/libfyaml` (tag `v1.0.0-beta1`).
- voc 2.1.0 at `/usr/local/sw/versions/voc/git`, LP64, **`-OC` size
  model** (decided; see "Integer model" under Open questions). Code
  using the binding must be built with `-OC` too.

## Phase 0 spike: already confirmed

A throwaway spike, compiled in the scratchpad and deleted afterwards,
parsed `a: {b: hello}`, looked up `/a/b`, read the scalar, and
destroyed the document. It linked with `LDLIBS=-lfyaml`. Three
findings, all confirmed live:

1. **Exported code procedures break across modules.** voc emits a code
   procedure as a C macro, and an exported one expands in the
   *importer's* `.c` file, which lacks `#include <libfyaml.h>`, so gcc
   fails with "implicit declaration of function". The fix, and voc's
   own idiom in `Platformunix.Mod`, is unexported code procedures
   wrapped by exported ordinary procedures.
2. **Inline C gives access to `static inline` helpers and struct
   fields.** `fy_node_is_mapping`, a header-only inline that
   alibfyaml could not bind, worked directly. This settles the
   ABI-drift open question in alibfyaml's PLAN.md in favour of the
   slibfyaml approach: **no hand-mirrored C structs**, with fields
   read through code procedures such as `"((struct fy_diag_error*)e)->line"`.
3. **voc's value `ARRAY OF CHAR` copy breaks zero-copy parsing, and
   valgrind can't see it.** Passing the YAML text as a value
   `ARRAY OF CHAR` parameter to a wrapper that calls
   `fy_document_build_from_string` produced an **empty** scalar
   instead of `hello`. voc's `__DUP` had copied the argument into
   `alloca` memory, which died when the wrapper returned, and
   libfyaml's scalar span pointed into it. Valgrind reported 0 errors.
   Passing the address of a GC-heap buffer
   (`NEW(b, n); COPY(text, b^)`) returned `5: hello` correctly. See
   "Buffer lifetime" below; this is the single most important design
   constraint.

## Module structure

Oberon modules are flat (no child packages), and a type-bound
procedure must be declared in the same module as its receiver's type.
Mutual references between types (a `Node` points to its `Document`)
therefore argue for keeping `Document` and `Node` in one module.
Proposed:

| Module | Contents | Ada counterpart |
|---|---|---|
| `FyThin` | Unexported code procedures plus thin exported wrappers. Handles are `SYSTEM.ADDRESS`. No policy. | `Libfyaml.Thin` |
| `Fyaml` | `Document`, `Node`, `Error`, iterators, parse/emit/build/mutate, typed scalars, location and path | `Libfyaml`, `.Nodes`, `.Documents` |
| `FyamlStreams` | `Stream`: multi-document input | `Libfyaml.Documents.Streams` |
| `FyamlTimestamps` (later, optional) | YAML 1.1 timestamp parsing | part of the Ada Timestamps plan |

In generated C, module names become identifier prefixes
(`Fyaml_Parse`), so short names cost nothing. Naming is an open
question below.

## Data model

```oberon
TYPE
  String* = POINTER TO ARRAY OF CHAR;   (* 0X-terminated; see "Strings" *)

  Document* = POINTER TO DocumentDesc;
  DocumentDesc* = RECORD
    handle: SYSTEM.ADDRESS;   (* struct fy_document*; 0 once closed *)
    buffer: String            (* keeps a string-parsed input alive *)
  END;

  Node* = POINTER TO NodeDesc;
  NodeDesc* = RECORD
    handle: SYSTEM.ADDRESS;   (* struct fy_node* *)
    doc: Document             (* owning document: liveness check + GC root *)
  END;
```

- **`Node` is a small heap object**, not a record value. Oberon-2
  function procedures can't return records, and `n.Value("k").Scalar()`-style
  chaining needs a pointer. The cost is one small GC allocation per
  navigation step; measure it with a benchmark in the Phase 6 hardening
  pass, the same way alibfyaml's `bench/` measured its liveness
  overhead.
- Methods are type-bound procedures (`PROCEDURE (n: Node) Value*(key:
  ARRAY OF CHAR): Node;`), which gives the dotted style of the Ada API.
  Plain procedure forms may be added only if they turn out to be
  needed.

## Memory model

### Document ownership: explicit Close, with a GC finalizer as backstop

voc has no RAII (unlike Ada's controlled types). So, as in slibfyaml:

1. **`Close(doc)`** is the primary path. It is idempotent: it sets
   `doc.handle := 0` and then calls `fy_document_destroy`, and does
   nothing if the handle is already 0.
2. **`Heap.RegisterFinalizer`** is the backstop for documents never
   explicitly closed. It runs when the GC notices the document is
   unreachable, or at program exit via `Heap.FINALL`. voc's GC runs
   only when Oberon code allocates and cannot see libfyaml's C-side
   memory, so a loop that parses and never calls `Close` can pile up
   C memory. Document this; don't rely on the finalizer.

`Heap` is a voc runtime module, not standard Oberon. That's acceptable
because this binding is voc-specific anyway (code procedures are a voc
extension).

### Node validity: simpler than both earlier bindings

Every `Node` holds its `Document` pointer. So:

- **While any `Node` is reachable, its `Document` is reachable**, and
  the GC finalizer cannot destroy the tree underneath it. Garbage
  collection makes the "Document finalized while a Node survives"
  case impossible, with no refcounting. alibfyaml's `Owner_Liveness`
  cost it +11–15%; slibfyaml needed a separate "liveness box" because
  its modules couldn't reference each other in both directions. Here
  both types share a module, so neither is needed.
- **The only remaining hazard is an explicit `Close`.** Every `Node`
  accessor starts with `ASSERT((n # NIL) & (n.handle # 0) &
  (n.doc.handle # 0), <code>)`, which makes use-after-close a clean,
  labelled halt instead of a silent read of freed memory. Give each
  assertion a distinct code so a halt can be traced to its cause
  (codes listed in `Fyaml`'s header comment).

### Buffer lifetime

The rule: **never give libfyaml a pointer to anything that doesn't
outlive the libfyaml object that may keep pointing into it.** In
practice:

- `ParseString(text: ARRAY OF CHAR; ...)` copies `text` into a fresh
  `String` (`NEW(buf, len+1)`), passes `SYSTEM.ADR(buf[0])` and the
  real length to libfyaml, and stores `buf` in `doc.buffer`. Because
  voc's GC doesn't move objects, the address stays valid, and the GC
  keeps `buf` alive for as long as `doc` is. `CheckFin` also marks
  `buf` before the document's finalizer runs, so the order of
  destruction is safe. **Confirm this ordering live in Phase 1**,
  with a test that drops the only reference and forces `Heap.GC`.
- Taking `text` as a `VAR` parameter instead would avoid voc's copy.
  But the caller's variable can still change or go out of scope while
  the document lives, so always copy. Copying costs one `memcpy` per
  parse; slibfyaml made the same trade.
- **Streams:** the stream holds the `String` buffer, and every
  `Document` taken from it points to the *same* `String`. The GC
  keeps it alive while any of them does, which removes the need for
  alibfyaml's `Buffer_Ref` refcounting. For an `OpenFile` stream the
  **filename** must also live as long as the parser (alibfyaml bug:
  libfyaml opens the file lazily), so store it in the stream too.
- **Files:** `fy_document_build_from_file` mmaps and owns its input,
  so there is no buffer to keep (confirmed in alibfyaml).
- **Strings coming out of libfyaml** (`fy_node_get_scalar`, `get_tag`)
  are spans with a length, and are **not** NUL-terminated. Copy
  exactly `len` bytes, using `SYSTEM.MOVE` or a `memcpy` code
  procedure, into a new `String`. Never scan for a 0X terminator.
  `fy_node_get_path` and `fy_emit_document_to_string` return
  `malloc`'d memory that the binding copies and then frees with
  `free()`.

### Consumption contracts

As in alibfyaml: `fy_document_insert_at` **always** unrefs its node,
whether it succeeds or fails. `InsertAt` therefore sets
`n.handle := 0` in every case. Every mutating procedure's comment says
what happens to each `Node`/`Document` argument on success and on
failure.

## Error handling (Oberon-2 has no exceptions)

There are two classes of error, handled differently:

1. **Programmer errors**: a closed document, a NIL or invalid node,
   `Item` on a non-sequence, or an index out of range. These are
   `ASSERT` failures with distinct codes. voc halts with the code,
   which matches Ada's `Assertion_Error` under `-gnata`.
2. **Data and environment errors**: malformed YAML, a missing file, a
   missing key, a malformed scalar, a resolve loop, or an emit
   failure. These are ordinary results the caller must be able to
   handle:

```oberon
TYPE
  Error* = POINTER TO ErrorDesc;
  ErrorDesc* = RECORD
    kind-: INTEGER;          (* parseError, missingKey, dataError, resolveError, emitError, ioError *)
    file-: String;           (* may be NIL *)
    line-, column-: INTEGER; (* C int; 1-based, 0 = unknown *)
    msg-: String             (* full "file:line:col: error: text" diagnostic *)
  END;

PROCEDURE ParseString*(text: ARRAY OF CHAR; VAR err: Error): Document;  (* NIL + err on failure *)
PROCEDURE ParseFile*(path: ARRAY OF CHAR; VAR err: Error): Document;
PROCEDURE (n: Node) IntValue*(VAR v: LONGINT): BOOLEAN;                   (* FALSE: not an int *)
PROCEDURE (m: Node) IntField*(key: ARRAY OF CHAR; VAR v: LONGINT; VAR err: Error): BOOLEAN;
PROCEDURE (m: Node) IntFieldOr*(key: ARRAY OF CHAR; default: LONGINT; VAR v: LONGINT; VAR err: Error): BOOLEAN;
```

- `err` is NIL on success. Error messages use the gcc diagnostic
  format `file:line:column: error: message`, which alibfyaml
  eventually settled on (its PLAN.md, "Parse_Error message
  reformatted"). Lines and columns are 1-based: convert `fy_mark`'s
  0-based values, and keep `fy_diag_error`'s 1-based values unchanged
  (alibfyaml confirmed that libfyaml mixes the two conventions).
- **Attach `Path`, and `Location` where one exists, to
  `missingKey`/`dataError` errors from the start.** alibfyaml left
  this as an open question; slibfyaml did it and it cost nothing at
  the point of failure. Here it's just two more fields to fill in.
- Parse errors: create one `fy_diag` per parse with
  `fy_diag_set_collect_errors(TRUE)`, and on failure read the errors
  back with `fy_diag_errors_iterate`. **Destroy the diag in exactly
  one place** (see alibfyaml's `Parse_Common` double-free).

## Strings

`String = POINTER TO ARRAY OF CHAR`, always 0X-terminated, so values
work with `COPY`, `Strings`, `Out.String`, and comparison operators.

- YAML scalars can contain NUL (`"\0"` in double-quoted style). Every
  string accessor therefore also has a length-reporting form
  (`ScalarLen`), and the returned `String` is allocated as `len+1`
  with the bytes copied exactly, so embedded 0X survives even though
  `Out.String` stops at it.
- `ScalarInto(VAR s: ARRAY OF CHAR): BOOLEAN` copies into the caller's
  buffer without allocating. It returns FALSE if the value was
  truncated.
- Text is passed through as UTF-8 bytes (voc's `CHAR` is 8-bit, which
  voc recommends for UTF-8).

## Iteration (no closures)

```oberon
TYPE ItemIter* = RECORD ... END;  PairIter* = RECORD ... END;
PROCEDURE (n: Node) Items*(VAR it: ItemIter);
PROCEDURE (VAR it: ItemIter) Next*(VAR item: Node): BOOLEAN;
PROCEDURE (n: Node) Pairs*(VAR it: PairIter);
PROCEDURE (VAR it: PairIter) Next*(VAR key, value: Node): BOOLEAN;
```

These wrap `fy_node_sequence_iterate`/`fy_node_mapping_iterate`,
whose `void **prevp` cursor lives in the record as a
`SYSTEM.ADDRESS`. The record is a caller-owned `VAR`, not heap
allocated. There is also index access: `Length()`, `Item(i)`.

## Typed scalars

The semantics port directly from alibfyaml's PLAN.md and README:
YAML 1.2 core schema, plus the two documented extensions (`0b`
binary, and `_` between digits).

- **Nulls:** `IsNullValue` accepts `""`, `~`, `null`, `Null`, and
  `NULL`. It **returns FALSE for an alias node without calling
  `fy_node_is_null`**. That port of the alibfyaml/slibfyaml fix avoids
  an uninitialised read inside libfyaml on unresolved aliases from
  streams.
- **Booleans:** `true`/`True`/`TRUE` and `false`/`False`/`FALSE` only.
- **Integers:** decimal, `0x`, and `0o` (plus the `0b` and `_`
  extensions). Parse them in Oberon, with overflow checking, into
  64-bit `LONGINT` (`IntValue`) and 32-bit `INTEGER` (`IntegerValue`,
  range-checked). Under `-OC`, those are the Oberon equivalents of C's
  `long` and `int`.
- **Floats:** validate the core-schema grammar in Oberon, strip `_`,
  then convert with C `strtod` in a code procedure, for correct
  rounding without depending on how well voc's `Reals`/`Strings`
  convert. Return `LONGREAL` (and `REAL`). `.inf` and `.nan` are
  deferred, as in Ada.
- **Mapping-key forms:** `Required(key): Node`, plus the
  `…Field`/`…FieldOr` pairs shown above. A missing key and a
  malformed value give different `Error.kind` values.

## Test strategy

- A shared `test/Check.Mod`: `Check(cond: BOOLEAN; label: ARRAY OF
  CHAR)` prints `ok   - label` or `FAIL - label`, and `Summary`
  prints the final line and exits nonzero if anything failed.
- One main module per concern, mirroring the alibfyaml test names:
  `TestQuickstart`, `TestSequence`, `TestNavigate`, `TestScalars`,
  `TestStreams`, `TestMutate`, `TestAnchors`, `TestParseErrors`,
  `TestLocation`, `TestPath`, `TestLiveness`. Copy the YAML fixtures
  from `~/Repos/Ada/alibfyaml/test/` so all three bindings are
  checked against the same inputs.
- Every test also runs under valgrind (`make valgrind`). Because
  valgrind can't see voc's `alloca` copies, **each lifetime test must
  also check actual values**: string content, not just "non-empty" or
  "no crash".
- Liveness and GC tests force the scenarios directly: drop the last
  reference to a document while a node survives, then call
  `Heap.GC(TRUE)` and check the node still reads correctly. Close a
  document, then confirm a node accessor halts. That second test runs
  as a subprocess that is *expected* to halt with a known code, driven
  by the Makefile.

## Phased roadmap

Each phase ends with every test passing and running clean under
valgrind, with findings written into this file.

0. **Skeleton.** `Makefile` with a `VOC` path, `-OC` on every voc
   invocation, `LDLIBS` from
   pkg-config, generated files in `build/`, and `test`, `valgrind`,
   and `clean` targets. Also `.gitignore`, `Check.Mod`, and a
   minimal `FyThin` covering only the spike's calls. **Confirm first**
   that voc resolves `.sym` imports when invoked from `build/` on
   `../src/*.Mod`, since generated files land in the current
   directory.
1. **Read-only parse and navigate.** `ParseString`/`ParseFile` (copy
   the input buffer from day one), `Close` plus the finalizer, `Root`,
   kind predicates (via the inline `fy_node_is_*`), `Scalar`/`ScalarLen`/
   `ScalarInto`, `Length`/`Item`, `Value`/`HasKey`, the iterators,
   `ByPath`/`Path`, and the `parseError` diagnostics. Port
   `TestQuickstart` (read side), `TestNavigate`, `TestPath`,
   `TestParseErrors`, and `TestLiveness` (including the forced-GC
   finalizer-ordering check described under "Buffer lifetime").
2. **Emit and build/mutate.** `ToYAML(flags)` and `ToFile`, with the
   emitter flag constants taken from the header through code
   procedures rather than retyped. `NewDocument`,
   `CreateScalar`/`Sequence`/`Mapping` (copying: `fy_node_create_scalar_copy`),
   `Append`, `AppendPair`, `SetRoot`, and `InsertAt` with its
   unconditional-consume contract. Port `TestQuickstart` in full,
   `TestSequence`, and `TestMutate`.
3. **Typed scalars.** Everything under "Typed scalars", with `Path`
   and `Location` in errors. Port `TestScalars` using
   alibfyaml's `scalars.yaml`.
4. **Anchors, tags, location.** A `resolve` parse option (default
   TRUE, as alibfyaml decided), `Resolve(doc, VAR err)`, `IsAlias`,
   `Tag`, `Style`, `HasLocation`/`Location`, and the alias-safe
   `IsNullValue`. Port `TestAnchors` (including alibfyaml's note that
   the merge-key cycle leaks a small amount *inside libfyaml*, which
   is not ours to fix) and `TestLocation`.
5. **Streams.** `FyamlStreams`: `OpenString`/`OpenFile`,
   `HasNext`/`Next` with one-ahead read-ahead, and a mid-stream parse
   error reported as an error rather than a clean end. Swap in a fresh
   diag after an error, and treat the stream as exhausted once an
   error has occurred (both alibfyaml findings). Check a document
   outliving its stream. Port `TestStreams`.
6. **Hardening and docs.** Benchmarks like alibfyaml's `bench/`
   (wide document, many documents) to measure the per-navigation
   `Node` allocation. A README with a usage example, and example
   programs showing gcc-style error reporting. Decide whether to add
   `ParseFromFile` for an open `Files.File` or stdin (the counterpart
   of alibfyaml's `Text_IO`), and timestamps.

## Open questions

- ~~**Module names.**~~ Decided: `FyThin`/`Fyaml`/`FyamlStreams`.
- ~~**Error-reporting shape.**~~ Decided: an `Error` object handed back
  on each call (`VAR err: Error`, NIL on success), as sketched under
  "Error handling". No per-document or module-global "last error".
- ~~**Halting on programmer errors.**~~ Decided: programmer errors
  (closed document, NIL/invalid node, wrong node kind, index out of
  range) are `ASSERT` failures with distinct codes and halt the
  program. Only data/environment errors come back as `Error` objects.
- ~~**Integer model.**~~ Decided: `-OC`. Measured on this voc install (`SIZE()` of each
  type compiled under each model): `-O2` gives SHORTINT/INTEGER/
  LONGINT/SET = 1/2/4/4 bytes, and `-OC` gives 2/4/8/4. `-OV` can't be
  used, because this install ships only `libvoc-O2` and `libvoc-OC`.
  The C types in the linked `/usr/include/libfyaml.h` are, by count,
  `int` 118, `size_t` 66, `bool` 58, `double` 8, `unsigned int`
  (flag masks) 7, `short` 4, `ssize_t` 2, and `long` 1. `-OC` matches
  LP64 C one-to-one: `short` = SHORTINT, `int` = INTEGER,
  `long`/`size_t`/`ssize_t` = LONGINT, the 32-bit `unsigned int` flag
  masks = SET, and `LEN()` returns a 64-bit LONGINT that matches
  `size_t` lengths. Under `-O2`, only `int` has a plain equivalent
  (LONGINT), and every `size_t` needs HUGEINT or SYSTEM.ADDRESS.
  Consequence: code using the binding must be compiled with `-OC`
  too, because models can't be mixed; say so in the README.
- **`Node` as heap object versus record.** The proposal is a heap
  object, for chaining and type-bound procedures. Revisit only if
  Phase 6 benchmarks show allocation dominating.
- **Timestamps.** alibfyaml's plan covers them (YAML 1.1 grammar), but
  voc has no standard date/time type to return. `ethDates` exists in
  voc's library. Defer until there's a consumer.
- **Warn on extra documents in `ParseString`/`ParseFile`?** Still open
  in alibfyaml too. Default: stay silent, and point multi-document
  input at `FyamlStreams`.
