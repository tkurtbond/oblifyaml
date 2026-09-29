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
  function procedures can't return records, so returning a Node from
  `Value`/`Item`/`ByPath` needs a pointer. (Call chaining such as
  `n.Value("k").Scalar()` turned out not to be possible at all in
  Oberon-2, since a call's result isn't a designator; see Phase 1.) The cost is one small GC allocation per
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
- **Mutation is the second hazard (Phase 2).** `fy_node_insert` frees
  the node it replaces (or the values of keys it overwrites), and
  `fy_document_set_root` frees the whole previous root tree, so a Node
  taken earlier can point at freed memory, and the binding can't
  cheaply tell which ones. Each Document has a generation count `gen`;
  a Node records it when made, and `InsertAt` (always) and `SetRoot`
  (when it replaces an existing root) bump it. `Live` checks it, so a
  stale Node halts with `AssertInvalid` (61, renamed from
  `AssertClosed`) and `Valid` returns FALSE. This invalidates more
  Nodes than strictly necessary; that's the price of never reading
  freed memory. The Node `InsertAt`/`SetRoot` itself attached gets the
  new `gen` where it survives (SetRoot's root does; InsertAt's node is
  consumed).
- **Unattached nodes (Phase 2).** `fy_document_destroy` frees only the
  tree under the root; a node made by `Create*` and never attached
  leaks (confirmed live: 4 blocks for one scalar, 10 for a mapping
  with one pair). Each Document keeps a list of its unattached created
  nodes (`orphans`); attaching drops a node from it, and `Close` calls
  `fy_node_free` on what's left before destroying the document.
  alibfyaml and slibfyaml have the same leak.

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
  destruction is safe. Phase 1 confirmed that a Node alone keeps its
  Document and buffer alive across forced GCs, and that an
  unreachable Document is finalized (`TestLiveness`). The ordering
  claim itself rests on reading `Heap.Mod`, since the finalizer
  doesn't read the buffer.
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
`n.handle := 0` and `n := NIL` (it takes `VAR n`) in every case. Every
mutating procedure's comment says what happens to each
`Node`/`Document` argument on success and on failure. Confirmed live
in Phase 2:

- `fy_document_insert_at` fails when there is no node at the path, and
  still frees the node. `InsertAt` looks the path up first so it can
  say which failure it was (`PathError`: "no node at this path" or
  "cannot insert here").
- `fy_node_insert` replaces a scalar target, merges a mapping into a
  mapping (new keys added, equal keys' values replaced and freed, the
  rest kept), and appends a sequence's items to a sequence.
- `fy_document_resolve` turns each alias node into a copy of its
  target in place (`fy_node_copy_to_scalar`), but frees every
  merge-key pair (`fy_node_pair_detach_and_free`): a node taken on a
  `<<` value and read after resolving is an invalid read under
  valgrind (Phase 4). So `Resolve` bumps the generation count too.
  alibfyaml's test keeps using a Node taken before `Resolve`; here it
  must be taken again.
- `fy_document_set_root` frees the previous root tree and refuses a
  node that is already attached.
- `fy_node_mapping_append` refuses a duplicate key, an attached node,
  or a node of another document; `fy_node_free` refuses an attached
  node. Of these, only a duplicate key is a data error
  (`DuplicateKey`, both nodes stay unattached and usable); attaching an
  attached node or one from another document is a programmer error
  (`AssertAttach`, 64), as is `Append` on a non-sequence (`AssertKind`).
- `fy_emit_document_to_string` returns NULL for a document with no
  root, so `ToYAML`/`ToFile` report an empty document as `EmitError`
  up front.
- `fy_emit_document_to_file` opens with mode `"wa"`, which in glibc
  truncates like `"w"`: writing a file twice leaves one copy.
  libfyaml prints the open failure on stderr only, so `ToFile` reads
  `errno` itself to give a `FileError` with the OS reason.

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
    kind-: INTEGER;          (* ParseError, FileError, EmitError, PathError, DuplicateKey, MissingKey, DataError *)
    file-: String;           (* never NIL *)
    line-, column-: INTEGER; (* C int; 1-based, 0 = unknown *)
    path-: String;           (* the node concerned, or NIL *)
    msg-: String             (* full "file:line:col: error: text" diagnostic *)
  END;

PROCEDURE ParseString*(text: ARRAY OF CHAR; VAR err: Error): Document;  (* NIL + err on failure *)
PROCEDURE ParseFile*(path: ARRAY OF CHAR; VAR err: Error): Document;
PROCEDURE (n: Node) LongIntValue*(VAR v: LONGINT; VAR err: Error): BOOLEAN;
PROCEDURE (m: Node) LongIntField*(key: ARRAY OF CHAR; VAR v: LONGINT; VAR err: Error): BOOLEAN;
PROCEDURE (m: Node) LongIntFieldOr*(key: ARRAY OF CHAR; default: LONGINT; VAR v: LONGINT; VAR err: Error): BOOLEAN;
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

- **Nulls:** `IsNullValue` accepts an empty plain scalar (`key:` with
  nothing after, via `fy_node_is_null`) and the plain texts `~`,
  `null`, `Null`, `NULL`. A quoted scalar, `''` or `'null'`, is a
  string, as in the core schema. (This departs from alibfyaml, which
  counts a quoted `"null"` as null; `fy_node_is_null` itself is FALSE
  for both quoted forms, confirmed live.) It **returns FALSE for an
  alias node without calling `fy_node_is_null`**. That port of the
  alibfyaml/slibfyaml fix avoids an uninitialised read inside libfyaml
  on unresolved aliases from streams.
- **Booleans:** `true`/`True`/`TRUE` and `false`/`False`/`FALSE` only.
- **Integers:** decimal, `0x`, and `0o` (plus the `0b` and `_`
  extensions), with a sign allowed before a prefix (`-0x1A`). Parsed
  in Oberon, with overflow checking, into 64-bit `LONGINT`
  (`LongIntValue`) and 32-bit `INTEGER` (`IntegerValue`,
  range-checked). Under `-OC`, those are the Oberon equivalents of C's
  `long` and `int`. The names follow the Oberon type names
  (`LongInt`, `Integer`, `Real`, `LongReal`, `Boolean`, `String`)
  rather than the `IntValue` sketched earlier, so the type each
  returns is never in doubt.
- **Floats:** validate the core-schema grammar in Oberon, strip `_`,
  then convert with C `strtod` in a code procedure, for correct
  rounding without depending on how well voc's `Reals`/`Strings`
  convert. Return `LONGREAL` (`LongRealValue`) and `REAL`
  (`RealValue`, out of range beyond `MAX(REAL)`). Unlike alibfyaml,
  `.5` and `5.` are accepted: the core schema allows them, and Ada
  excluded them only because `Float'Value` doesn't. `.inf` and `.nan`
  are deferred, as in Ada.
- **Quoted text is resolved too** (`port: '8080'` reads as 8080),
  as in alibfyaml: a caller who asks for an integer has said what
  they want. Only `IsNullValue` looks at the style.
- **Predicates** `IsInteger`/`IsReal`/`IsBoolean` check the grammar
  only (not the range), and return FALSE for a sequence or mapping.
  The per-node value accessors halt with `AssertKind` on one
  (alibfyaml's precondition); the field forms report it as a
  `DataError`.
- **Mapping-key forms:** `Required(key; VAR err): Node`, plus a
  `…Field`/`…FieldOr` pair per type. A missing key is `MissingKey`; a
  malformed value, a number out of range, or a value that isn't a
  scalar is `DataError`, in both forms: a default stands in only for
  a missing key. On failure the `VAR` result is unchanged.
- **Errors carry `path` and a location.** The message is
  `file:line:column: error: path: text`, located at the offending
  scalar, or at its key when the value isn't a scalar (only scalars
  have a location in libfyaml: `fy_node_get_scalar_token`). A
  `MissingKey` has no location. A document from `NewDocument` has no
  file, so its messages read `path: error: text`, the same as
  `DuplicateKey`'s.

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

0. **`[done]` Skeleton.** `Makefile` with a `VOC` path, `-OC` on
   every voc invocation, `LDLIBS` from pkg-config, generated files in
   `build/`, and `all`/`test`/`valgrind`/`clean` targets. Also
   `.gitignore`, `test/Check.Mod`, and a minimal `src/FyThin.Mod`
   covering only the spike's calls (build from string, destroy, root,
   `fy_node_is_mapping`, by-path, get-scalar). `test/TestThin.Mod`
   (6 checks) passes. It checks exact scalar bytes, including a
   double-quoted `"x\0y"` scalar that keeps all 3 bytes with its
   embedded 0X. Clean under valgrind (0 errors, nothing definitely or
   indirectly lost). A deliberately broken check was confirmed to make
   `make test` fail.

   Found while doing it, all now in AGENTS.md:
   - voc's symbol search path starts at `.` (`OPM.InitOptions`), so
     running voc inside `build/` on `../src/X.Mod` finds earlier
     modules' `.sym` there. Confirmed.
   - voc leaves an unchanged `.sym` file untouched, so `.sym` make
     targets recompiled on every run. The targets are the `.o` files
     now, and a no-op `make` does nothing. Module import order has
     to be written into the Makefile as explicit `.o` dependencies.
   - `*)` inside a comment ends it: `(fy_node_is_*)` broke the first
     build.
   - `Platform.Exit` calls C `exit()` and skips `Heap.FINALL`, so
     `Check.Summary` exits only on failure. A passing run ends
     normally, so GC finalizers run before valgrind's leak check.
   - Valgrind always shows one ~256 KB "still reachable" block: voc's
     own GC heap chunk (`Heap_InitHeap`). It's harmless and already
     left out by the chosen `--show-leak-kinds`.
1. **`[done]` Read-only parse and navigate.** `src/Fyaml.Mod`:
   `ParseString`/`ParseFile` (input copied from day one), `Close`
   (idempotent) plus the GC finalizer, `IsOpen`, `Root`, `Valid`,
   `Kind`/`IsScalar`/`IsSequence`/`IsMapping` (via the inline
   `fy_node_is_*`), `Scalar`/`ScalarLen`/`ScalarInto`/`ScalarIs`,
   `Length`/`Item` (0-based), `Value`/`HasKey`, `ItemIter`/`PairIter`,
   `ByPath`/`Path`, and `Error` (kinds `ParseError`, `FileError`) in
   gcc diagnostic format. Also `openDocuments-`, a count of open
   documents, which the finalizer test reads. `FyThin` grew to the
   diag, sequence, mapping and path calls, plus `fopen`/`strerror`/
   `strlen`/`free`. Tests:
   - `TestParseErrors` (15 checks), `TestQuickstart` (read side, 6),
     `TestNavigate` (25), `TestPath` (9) and `TestLiveness` (12),
     ported from alibfyaml on its own `config.yaml`, `navigate.yaml`
     and `malformed.yaml`.
   - Halt tests `HaltClosed`/`HaltKind`/`HaltIndex`, which must exit
     with 61/62/63.
   - All pass, and all are clean under valgrind: 0 errors, nothing
     lost, and only voc's own heap chunk still reachable.
     `TestLiveness` passed 50 of 50 repeated runs, which matters
     because its finalizer check depends on a conservative stack scan.

   Anchor resolution is **always on** here (`FYPCF_RESOLVE_DOCUMENT`),
   so aliases never read back as their raw reference text. Phase 4
   adds the option to turn it off.

   Found while doing it, all confirmed live and now in AGENTS.md:
   - **No call chaining in Oberon-2**: `d.Root().Value("k")` doesn't
     compile, because a call's result isn't a designator. Code uses a
     variable per step, or `ByPath` for several levels at once.
   - **libfyaml's `*_iterate` restarts after the end**: it signals the
     end by setting the cursor to NULL, which also means "start". A
     `done` flag in each iterator fixes this.
   - **libfyaml doesn't collect "can't open file"**: it prints
     `[ERR]: failed to open ...` on stderr, and the diag collects
     nothing. `ParseFile` now `fopen`s first and returns a
     `FileError` with the OS reason
     (`no-such-file.yaml: error: No such file or directory`). A
     directory still gets libfyaml's stderr line and a generic
     `ParseError` naming the path.
   - **Valgrind reports uninitialised values from voc's GC**: once a GC
     runs, its conservative stack scan produces many (663,006 in
     `TestLiveness`), all in four `Heap_*` functions.
     `test/voc-gc.supp` suppresses exactly those.
   - **A leak can hide as "still reachable"**: an unfreed document is
     reachable through voc's heap chunk, so check the still-reachable
     total, which should be only voc's 256,024-byte heap chunk. As a
     control, disabling the finalizer made that grow and made the
     finalizer check fail.
   - voc exit statuses: `ASSERT` failure = its code; NIL method call =
     246. voc rejects an `ASSERT` it can prove false at compile time.
2. **`[done]` Emit and build/mutate.** `ToYAML(flags)` and `ToFile`,
   with the emitter flags (`emitDefault-`, `emitSortKeys-`,
   `emitModeOriginal-`/`Block-`/`Flow-`/`FlowOneline-`/`Json-`) read
   from the header's `#define`s through code procedures into
   read-only variables. `NewDocument`,
   `CreateScalar`/`Sequence`/`Mapping` (copying:
   `fy_node_create_scalar_copy`), `Append`, `AppendPair`, `SetRoot`,
   and `InsertAt` with its unconditional-consume contract. New error
   kinds `EmitError`, `PathError`, `DuplicateKey`; new halt code
   `AssertAttach` (64); `AssertClosed` renamed `AssertInvalid` since it
   now also covers stale Nodes. Tests:
   - `TestBuild` (23 checks): build a tree, exact `ToYAML` output in
     each mode (taken from libfyaml's actual output), a round trip
     through `ParseString`, `DuplicateKey`, `ToFile` twice then
     `ParseFile`, `ToFile` into a missing directory, the empty-document
     `EmitError`, and SetRoot killing old Nodes.
   - `TestMutate` (11): alibfyaml's port plus stale-Node checks:
     scalar replace, mapping merge, sequence append, missing path.
   - `TestQuickstart` in full (10): the `{timeout: 45}` patch merged
     into `/server` and emitted with `emitSortKeys`.
   - Halt tests `HaltStale` (61), `HaltAttach` (64, other document),
     `HaltAttached` (64, attached twice).
   - alibfyaml's `test_sequence` is a read-only demo whose checks
     `TestNavigate` already makes, so it wasn't ported separately.

   All pass, and all are clean under valgrind, with still-reachable at
   exactly voc's heap chunk. Found while doing it (see also Memory
   model and Consumption contracts above):
   - **Created-but-unattached nodes leak** through
     `fy_document_destroy`; fixed with the orphan list.
   - **That leak shows only as still-reachable**, because the Oberon
     heap still holds the node addresses, so the old `make valgrind`
     passed with the fix disabled. `make valgrind` now also fails
     unless each test's still-reachable is exactly
     `256,024 bytes in 1 blocks`; with the orphan free disabled it
     fails on `TestBuild` (14 blocks), and it passes with it enabled.
3. **`[done]` Typed scalars.** Everything under "Typed scalars", with
   the path and location in errors (`Error.path`, new kinds
   `MissingKey` and `DataError`). `FyThin` gained `fy_node_is_null`,
   `fy_node_is_alias`, the plain-style check, the scalar token's start
   mark, `fy_node_mapping_lookup_key_by_string`, and `strtod`. Tests:
   `TestScalars` (107 checks), all of alibfyaml's `test_scalars` on
   its `scalars.yaml` plus exact messages and locations, the
   `LONGINT`/`INTEGER` limits in decimal and hex, the float forms,
   `IsNullValue`, and a built document's errors; halt test
   `HaltTyped` (62). All pass, and all are clean under valgrind.
   Sabotaging the `MIN(LONGINT)` limit and the boolean result made 7
   checks fail, so the test notices.

   Found while doing it, confirmed live:
   - **voc's `DIV` overflows near `MIN(LONGINT)`**:
     `(MIN(LONGINT) + 9) DIV 10` came out positive. `ParseInt` builds
     the value negatively (so `MIN(LONGINT)` parses) and divides only
     `MAX(LONGINT)`.
   - **An unsuffixed real literal is a `REAL`**, so
     `x = 1234.56` compares a `LONGREAL` with a widened 32-bit value
     and fails. With the `D` suffix (`1234.56D0`) voc's literals match
     glibc's `strtod` bit for bit, so tests compare exactly.
   - **A created scalar's location is line 0, column 0**, the same as
     a parsed scalar at the very first byte, and no public libfyaml
     call tells them apart. A document that has had `CreateScalar`
     called on it reports no location for 0:0.
   - `fy_node_is_null` is TRUE for an empty plain scalar, FALSE for
     `''`, `~` and `'null'`; a mapping or sequence has no scalar token
     (so no location); `fy_token_start_mark` is 0-based.
4. **`[done]` Anchors, tags, location.** Parse options as a `SET`:
   `ParseStringWith`/`ParseFileWith(…, options, err)`, with
   `NoResolve` the only element so far (Oberon has no default
   parameters, and a `SET` leaves room for Phase 5's options);
   `ParseString`/`ParseFile` are the `{}` forms, with resolve on as
   alibfyaml decided. `(d) Resolve(VAR err): BOOLEAN` (new kind
   `ResolveError`; it kills earlier Nodes, see Consumption
   contracts), `IsAlias`, `Tag` (`""` for none), `Style` (constants
   `StyleFlow` … `StyleAlias`, mapped from the header's enum at run
   time rather than retyped), and `Location(VAR line, column):
   BOOLEAN`/`HasLocation`. The alias-safe `IsNullValue` came in
   Phase 3. Tests: `TestAnchors` (30 checks) and `TestLocation` (14)
   on alibfyaml's `anchors.yaml`, `anchors_cycle.yaml` and
   `location.yaml` plus a new `styles.yaml`; halt test
   `HaltResolved` (61). All pass and are clean under valgrind.
   Removing `Resolve`'s generation bump made one check and
   `HaltResolved` fail.

   Found while doing it, confirmed live:
   - **`Resolve` frees merge-key pairs** (above), so it must kill
     earlier Nodes.
   - **Resolve errors need a fresh diag.** A document keeps a
     reference to its parse diag, which `DiagDestroy` has already
     silenced (`fy_diag_destroy` sets `destroyed` and unrefs).
     `Resolve` gives the document a new collecting diag with
     `fy_document_set_diag`, reads its errors, then destroys (silences)
     it the same way. The cycle fixture gives
     `anchors_cycle.yaml:2:8: error: cyclic reference detected`.
   - **No leak on the cycle.** alibfyaml saw a small leak inside
     libfyaml's diag reporting when resolving `anchors_cycle.yaml`;
     with a collecting diag valgrind shows none, in C and here.
   - With resolve on, the same cycle is a `ParseError` at parse time,
     and libfyaml also prints `[ERR]: fy_parse_load_document()
     failed` on stderr.
   - Locations: an alias is located at its name, after the `*`; a
     quoted scalar after its opening quote; a block scalar at its
     first content line; a mapping or sequence has none. A created
     scalar has none here, where alibfyaml reports (1, 1).
   - **Oberon comments nest**: `(*name)` inside a comment opened a
     new one (`err 5 comment not closed`).
5. **`[done]` Streams.** `FyamlStreams.Stream`:
   `OpenString`/`OpenFile` and the `…With(…, options, err)` forms
   (the same `SET` as `Fyaml.ParseStringWith`), `HasNext(VAR err)`
   with a one-document read-ahead, `Next(VAR err)`, `Close`, `IsOpen`,
   a GC finalizer, and `openStreams-`. `Next` returns NIL at the end
   (err NIL) or on a malformed document (a `ParseError`), so a loop
   can use `Next` alone; alibfyaml's `Next` past the end is a
   `Program_Error`. An unopenable file is a `FileError` from
   `OpenFile`. Each document is an ordinary `Fyaml.Document`, labelled
   with the stream's file name or `(string-in-memory)` for errors.
   Tests: `TestStreams` (27 checks), alibfyaml's cases on its
   `streams.yaml` plus finalization, documents outliving closed and
   collected streams, `NoResolve`, and exact error text; halt test
   `HaltStream` (61). All pass and are clean under valgrind. Controls:
   not freeing the read-ahead document at `Close` showed as
   `definitely lost: 160 bytes`, and not sharing the text buffer with
   documents made the outlives-its-stream check fail.

   Found while doing it, confirmed live:
   - **Oberon has no friend modules**, so `Fyaml` exports three hooks
     for `FyamlStreams`, in a section saying other clients shouldn't
     use them: `Adopt` (wrap a loaded document handle), `DiagErrors`
     and `Unreadable` (build its errors); plus the constant
     `stringName`.
   - **A `finished` flag replaces alibfyaml's diag swap.** After an
     error `fy_parse_load_document` only returns NULL (no resync), and
     `fy_diag_got_error` stays set. alibfyaml swapped in a fresh diag
     so later calls wouldn't repeat the stale error; here the stream
     just stops calling libfyaml once it has hit the end or an error.
   - `fy_parser_create` copies its config (`fyp->cfg = *cfg`), so the
     config is a compound literal, as for single documents.
     `fy_parser_set_string` doesn't copy its input (`fyit_memory`), so
     the stream copies the text and every document shares that copy.
     A document from a file stream needs neither the parser nor the
     path once loaded (valgrind), but the parser needs the path while
     in use (alibfyaml).
   - `FYPCF_RESOLVE_DOCUMENT` works through the parser config: a
     stream resolves each document as it is loaded.
   - An unterminated flow sequence is reported at the start of the
     next line (`(string-in-memory):5:1`), not where it opened.
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
- **`Node` as heap object versus record.** It is a heap object, because
  functions can't return records. Revisit only if Phase 6 benchmarks
  show allocation dominating.
- **Timestamps.** alibfyaml's plan covers them (YAML 1.1 grammar), but
  voc has no standard date/time type to return. `ethDates` exists in
  voc's library. Defer until there's a consumer.
- **Warn on extra documents in `ParseString`/`ParseFile`?** Still open
  in alibfyaml too. Default: stay silent, and point multi-document
  input at `FyamlStreams`.
