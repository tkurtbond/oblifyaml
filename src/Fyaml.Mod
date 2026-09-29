MODULE Fyaml; (* Oberon-2 binding to libfyaml: documents, nodes, errors *)

(* Parse YAML/JSON into a Document, navigate and change its Nodes,
   and emit it back out.

   Ownership. A Document owns its libfyaml tree. Close it when done:
   Close is idempotent, and a GC finalizer closes any Document that
   becomes unreachable without one -- but the GC runs only when Oberon
   code allocates and cannot see libfyaml's C memory, so don't rely on
   it for documents parsed in a loop.

   Nodes. A Node is a small heap object holding its Document, so the
   GC can never destroy a document that a reachable Node still uses.
   A Node dies when its Document is closed, and ALSO when InsertAt
   (or SetRoot replacing an existing root) is called on its Document:
   libfyaml frees the nodes those calls replace, and this binding
   can't tell which ones, so it invalidates every Node taken from the
   document before the call (a per-document generation count). Get
   Nodes again from Root/ByPath afterwards. Calling a method of a dead
   Node halts (ASSERT code AssertInvalid) instead of reading freed
   memory; use Valid to test without halting.

   Building. NewDocument gives an empty document; Create* make
   unattached nodes; Append, AppendPair and SetRoot attach them. A node
   can be attached only once, and only within its own document.

   Errors. Bad input and missing files are ordinary results: calls
   that can fail on them return NIL/FALSE and hand back an Error in a
   VAR parameter (NIL on success). Programmer errors -- a closed
   document, a node of the wrong kind, an index out of range -- are
   ASSERT failures that halt with one of the Assert* codes below.
   Calling a method on a NIL Node halts with voc's own "NIL access".

   Strings. String is POINTER TO ARRAY OF CHAR, always 0X-terminated,
   UTF-8 bytes as libfyaml gives them. A YAML scalar can contain 0X
   (a double-quoted "\0"); Scalar copies all of its bytes, so use
   ScalarLen for the real length rather than stopping at the first 0X.

   Indexes are 0-based, as in ByPath's "/tags/0" and Oberon arrays
   (alibfyaml's Item is 1-based). *)

IMPORT SYSTEM, Heap, FyThin;

CONST
  (* Error kinds *)
  ParseError* = 1;   (* malformed input *)
  FileError* = 2;    (* ParseFile/ToFile: the file can't be opened (msg gives the OS reason) *)
  EmitError* = 3;    (* ToYAML/ToFile: libfyaml failed to emit *)
  PathError* = 4;    (* InsertAt: no node at the path, or it can't take the insert *)
  DuplicateKey* = 5; (* AppendPair: the mapping already has an equal key *)

  (* Node kinds, as returned by Kind *)
  KindScalar* = 0; KindSequence* = 1; KindMapping* = 2;

  (* ASSERT codes for programmer errors (also the exit status) *)
  AssertInvalid* = 61; (* document closed, or node dead (closed, or before InsertAt/SetRoot) *)
  AssertKind* = 62;    (* operation not valid for this node's kind *)
  AssertIndex* = 63;   (* index out of range *)
  AssertAttach* = 64;  (* node already attached, or from another document *)

  stringName = "(string-in-memory)";  (* file name reported for ParseString input *)

TYPE
  String* = POINTER TO ARRAY OF CHAR;
  Handles = POINTER TO ARRAY OF SYSTEM.ADDRESS;

  Error* = POINTER TO ErrorDesc;
  ErrorDesc* = RECORD
    kind-: INTEGER;           (* ParseError, FileError, EmitError, PathError, DuplicateKey *)
    file-: String;            (* file of the first error; never NIL *)
    line-, column-: INTEGER;  (* of the first error; 1-based, 0 = unknown *)
    msg-: String              (* every error, one "file:line:column: error: text" line each *)
  END;

  Document* = POINTER TO DocumentDesc;
  DocumentDesc* = RECORD
    handle: FyThin.Document;  (* 0 once closed *)
    buffer: String;           (* ParseString input: libfyaml's scalars span into it *)
    gen: LONGINT;             (* bumped by InsertAt/SetRoot: older Nodes are dead *)
    (* Nodes made by Create* and not attached yet: libfyaml frees only
       the tree when a document is destroyed, so Close frees these. *)
    orphans: Handles;
    norphans: LONGINT
  END;

  Node* = POINTER TO NodeDesc;
  NodeDesc* = RECORD
    handle: FyThin.Node;      (* 0 once consumed by InsertAt *)
    doc: Document;            (* owner: liveness check, and keeps it reachable *)
    gen: LONGINT              (* doc.gen when made; dead once they differ *)
  END;

  (* done: libfyaml's *_iterate ends by resetting the cursor to NULL,
     which is also the "start over" value -- without this flag a Next
     after the end would silently restart from the first item
     (confirmed live, TestNavigate). *)
  ItemIter* = RECORD node: Node; prev: SYSTEM.ADDRESS; done: BOOLEAN END;
  PairIter* = RECORD node: Node; prev: SYSTEM.ADDRESS; done: BOOLEAN END;

VAR
  openDocuments-: LONGINT;  (* documents made and not yet closed or finalized *)

  (* Emitter flags for ToYAML/ToFile, read from libfyaml's header at
     start-up. Combine with +: at most one emitMode*, plus
     emitSortKeys. emitDefault is libfyaml's default (original mode,
     unlimited line width); 0 is original mode, width 80. *)
  emitDefault-, emitSortKeys-, emitModeOriginal-, emitModeBlock-,
  emitModeFlow-, emitModeFlowOneline-, emitModeJson-: INTEGER;

(* ---- Strings ---- *)

PROCEDURE Length(VAR s: ARRAY OF CHAR): LONGINT;
  VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END; RETURN n
END Length;

(* A new String holding exactly len bytes from adr, plus a 0X. *)
PROCEDURE FromBytes(adr, len: SYSTEM.ADDRESS): String;
  VAR s: String;
BEGIN
  NEW(s, len + 1);
  IF len > 0 THEN SYSTEM.MOVE(adr, SYSTEM.ADR(s[0]), len) END;
  s[len] := 0X;
  RETURN s
END FromBytes;

PROCEDURE FromChars(a: ARRAY OF CHAR): String;
  VAR s: String; n, i: LONGINT;
BEGIN
  n := Length(a); NEW(s, n + 1);
  FOR i := 0 TO n - 1 DO s[i] := a[i] END;
  s[n] := 0X;
  RETURN s
END FromChars;

(* A C string (0X-terminated), or "" for 0. *)
PROCEDURE FromCString(p: SYSTEM.ADDRESS): String;
BEGIN
  IF p = 0 THEN RETURN FromBytes(0, 0) ELSE RETURN FromBytes(p, FyThin.Strlen(p)) END
END FromCString;

(* Appends to a growing String; len is its current length. *)
PROCEDURE Append(VAR s: String; VAR len: LONGINT; a: ARRAY OF CHAR);
  VAR n, i: LONGINT; t: String;
BEGIN
  n := Length(a);
  IF (s = NIL) OR (len + n + 1 > LEN(s^)) THEN
    NEW(t, 2 * (len + n) + 16);
    FOR i := 0 TO len - 1 DO t[i] := s[i] END;
    s := t
  END;
  FOR i := 0 TO n - 1 DO s[len + i] := a[i] END;
  INC(len, n); s[len] := 0X
END Append;

PROCEDURE AppendInt(VAR s: String; VAR len: LONGINT; x: LONGINT);
  VAR d: ARRAY 24 OF CHAR; i, j: INTEGER; r: ARRAY 24 OF CHAR;
BEGIN
  IF x < 0 THEN Append(s, len, "-"); x := -x END;
  i := 0; REPEAT d[i] := CHR(ORD("0") + x MOD 10); x := x DIV 10; INC(i) UNTIL x = 0;
  j := 0; WHILE i > 0 DO DEC(i); r[j] := d[i]; INC(j) END; r[j] := 0X;
  Append(s, len, r)
END AppendInt;

(* ---- Errors ---- *)

(* An Error of kind with a one-line message "file: error: text". *)
PROCEDURE NewError(kind: INTEGER; file: String; text: ARRAY OF CHAR): Error;
  VAR err: Error; len: LONGINT;
BEGIN
  NEW(err); err.kind := kind; err.file := file; err.line := 0; err.column := 0;
  len := 0;
  Append(err.msg, len, file^); Append(err.msg, len, ": error: ");
  Append(err.msg, len, text); Append(err.msg, len, 0AX);
  RETURN err
END NewError;

(* The errors collected in diag, as one Error. fileOverride, when not
   "", replaces libfyaml's own file name -- for string input libfyaml
   reports a synthetic "<memory-@...>" label (alibfyaml confirmed).
   name is the file named when nothing was collected: libfyaml reports
   some failures (e.g. a directory given as a file) only on stderr. *)
PROCEDURE Collected(diag: FyThin.Diag; fileOverride: ARRAY OF CHAR; name: String): Error;
  VAR err: Error; e: FyThin.DiagError; prev: SYSTEM.ADDRESS;
    msg, file, text: String; len: LONGINT; line, column: INTEGER;
BEGIN
  NEW(err); err.kind := ParseError; err.line := 0; err.column := 0;
  msg := NIL; len := 0; prev := 0;
  LOOP
    e := FyThin.DiagErrorsIterate(diag, prev);
    IF e = 0 THEN EXIT END;
    IF fileOverride # "" THEN file := FromChars(fileOverride)
    ELSIF FyThin.ErrorFile(e) # 0 THEN file := FromCString(FyThin.ErrorFile(e))
    ELSE file := name
    END;
    text := FromCString(FyThin.ErrorMsg(e));
    line := FyThin.ErrorLine(e); column := FyThin.ErrorColumn(e);
    IF msg = NIL THEN err.file := file; err.line := line; err.column := column END;
    (* gcc diagnostic format: every collected entry is an error *)
    Append(msg, len, file^); Append(msg, len, ":"); AppendInt(msg, len, line);
    Append(msg, len, ":"); AppendInt(msg, len, column);
    Append(msg, len, ": error: "); Append(msg, len, text^); Append(msg, len, 0AX)
  END;
  IF msg = NIL THEN RETURN NewError(ParseError, name, "document failed to parse") END;
  err.msg := msg;
  RETURN err
END Collected;

(* ---- Documents ---- *)

(* Records h as a created, not yet attached node of d. *)
PROCEDURE AddOrphan(d: Document; h: FyThin.Node);
  VAR a: Handles; i: LONGINT;
BEGIN
  IF d.orphans = NIL THEN NEW(d.orphans, 16)
  ELSIF d.norphans = LEN(d.orphans^) THEN
    NEW(a, 2 * d.norphans);
    FOR i := 0 TO d.norphans - 1 DO a[i] := d.orphans[i] END;
    d.orphans := a
  END;
  d.orphans[d.norphans] := h; INC(d.norphans)
END AddOrphan;

(* Forgets h once it is attached or freed. Searches from the end: a
   node is usually attached soon after it is created. *)
PROCEDURE DropOrphan(d: Document; h: FyThin.Node);
  VAR i: LONGINT;
BEGIN
  i := d.norphans - 1;
  WHILE (i >= 0) & (d.orphans[i] # h) DO DEC(i) END;
  IF i >= 0 THEN
    DEC(d.norphans); d.orphans[i] := d.orphans[d.norphans]
  END
END DropOrphan;

(* Idempotent: frees the tree once; later calls do nothing. *)
PROCEDURE CloseHandle(d: Document);
  VAR h: FyThin.Document; i: LONGINT;
BEGIN
  IF d.handle # 0 THEN
    h := d.handle; d.handle := 0;  (* dead before freed: no second free *)
    FOR i := 0 TO d.norphans - 1 DO
      ASSERT(FyThin.NodeFree(d.orphans[i]) = 0)  (* unattached by construction *)
    END;
    d.orphans := NIL; d.norphans := 0;
    FyThin.DocumentDestroy(h);
    DEC(openDocuments)
  END;
  d.buffer := NIL
END CloseHandle;

(* GC finalizer. voc's Heap.CheckFin marks everything an unreachable
   finalizable object references before sweeping, so d.buffer is
   still intact here. *)
PROCEDURE FinalizeDocument(obj: SYSTEM.PTR);
BEGIN CloseHandle(SYSTEM.VAL(Document, obj))
END FinalizeDocument;

(* Wraps a new libfyaml document handle, registering the finalizer. *)
PROCEDURE NewDoc(h: FyThin.Document; buffer: String): Document;
  VAR d: Document;
BEGIN
  NEW(d); d.handle := h; d.buffer := buffer; d.gen := 0; d.orphans := NIL; d.norphans := 0;
  INC(openDocuments);
  Heap.RegisterFinalizer(d, FinalizeDocument);
  RETURN d
END NewDoc;

(* Parses from the string (buffer # NIL, len bytes) or from the file
   named by path. name labels errors when libfyaml gives no file name.
   The diag is created and destroyed here, exactly once on every path
   (alibfyaml's Parse_Common double-free). *)
PROCEDURE Build(buffer: String; len: SYSTEM.ADDRESS; path: String;
                fileOverride: ARRAY OF CHAR; name: String; VAR err: Error): Document;
  VAR diag: FyThin.Diag; h: FyThin.Document; d: Document;
BEGIN
  err := NIL;
  diag := FyThin.DiagCreate();
  ASSERT(diag # 0);  (* allocation failure: nothing sensible to return *)
  FyThin.DiagSetCollectErrors(diag, TRUE);
  IF buffer # NIL THEN
    h := FyThin.DocumentBuildFromString(SYSTEM.ADR(buffer[0]), len, TRUE, diag)
  ELSE
    h := FyThin.DocumentBuildFromFile(SYSTEM.ADR(path[0]), TRUE, diag)
  END;
  IF h = 0 THEN err := Collected(diag, fileOverride, name) END;
  FyThin.DiagDestroy(diag);
  IF h = 0 THEN RETURN NIL END;
  RETURN NewDoc(h, buffer)
END Build;

(* Parses text (up to its first 0X) as one YAML document. Anchors,
   aliases, and merge keys are resolved. Returns NIL and sets err on a
   parse error. text is copied: libfyaml doesn't copy its input, and
   voc's copy of a value ARRAY OF CHAR dies when a procedure returns
   (PLAN.md, "Buffer lifetime"). Parses only the first of several
   "---" documents. *)
PROCEDURE ParseString*(text: ARRAY OF CHAR; VAR err: Error): Document;
BEGIN RETURN Build(FromChars(text), Length(text), NIL, stringName, FromChars(stringName), err)
END ParseString;

(* Parses the file at path as one YAML document, like ParseString.
   A file that can't be opened gives a FileError with the OS reason,
   checked here first: libfyaml itself only prints "[ERR]: failed to
   open" on stderr and collects nothing (confirmed live). *)
PROCEDURE ParseFile*(path: ARRAY OF CHAR; VAR err: Error): Document;
  VAR p: String; e: INTEGER; reason: String;
BEGIN
  p := FromChars(path);
  e := FyThin.OpenErrno(SYSTEM.ADR(p[0]));
  IF e # 0 THEN
    reason := FromCString(FyThin.Strerror(e));
    err := NewError(FileError, p, reason^);
    RETURN NIL
  END;
  RETURN Build(NIL, 0, p, "", p, err)
END ParseFile;

(* Frees the document's tree now. Idempotent. Every Node from it
   becomes dead (see Valid). *)
PROCEDURE (d: Document) Close*;
BEGIN CloseHandle(d)
END Close;

PROCEDURE (d: Document) IsOpen*(): BOOLEAN;
BEGIN RETURN d.handle # 0
END IsOpen;

PROCEDURE NewNode(d: Document; h: FyThin.Node): Node;
  VAR n: Node;
BEGIN
  IF h = 0 THEN RETURN NIL END;
  NEW(n); n.handle := h; n.doc := d; n.gen := d.gen;
  RETURN n
END NewNode;

(* The root node, or NIL for an empty document. *)
PROCEDURE (d: Document) Root*(): Node;
BEGIN
  ASSERT(d.handle # 0, AssertInvalid);
  RETURN NewNode(d, FyThin.DocumentRoot(d.handle))
END Root;

(* ---- Nodes ---- *)

(* TRUE if n is not NIL and still usable: its document is open, and
   n was not consumed by, or taken before, an InsertAt/SetRoot on it. *)
PROCEDURE Valid*(n: Node): BOOLEAN;
BEGIN RETURN (n # NIL) & (n.handle # 0) & (n.doc.handle # 0) & (n.gen = n.doc.gen)
END Valid;

PROCEDURE Live(n: Node);
BEGIN ASSERT((n.handle # 0) & (n.doc.handle # 0) & (n.gen = n.doc.gen), AssertInvalid)
END Live;

PROCEDURE (n: Node) IsScalar*(): BOOLEAN;
BEGIN Live(n); RETURN FyThin.NodeIsScalar(n.handle)
END IsScalar;

PROCEDURE (n: Node) IsSequence*(): BOOLEAN;
BEGIN Live(n); RETURN FyThin.NodeIsSequence(n.handle)
END IsSequence;

PROCEDURE (n: Node) IsMapping*(): BOOLEAN;
BEGIN Live(n); RETURN FyThin.NodeIsMapping(n.handle)
END IsMapping;

(* KindScalar, KindSequence, or KindMapping. *)
PROCEDURE (n: Node) Kind*(): INTEGER;
BEGIN
  IF n.IsScalar() THEN RETURN KindScalar
  ELSIF n.IsSequence() THEN RETURN KindSequence
  ELSE ASSERT(n.IsMapping(), AssertKind); RETURN KindMapping
  END
END Kind;

(* The scalar's bytes without copying: address and length, valid only
   while the document is open. *)
PROCEDURE ScalarBytes(n: Node; VAR len: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
  VAR p: SYSTEM.ADDRESS;
BEGIN
  ASSERT(n.IsScalar(), AssertKind);
  p := FyThin.NodeGetScalar(n.handle, len);
  IF p = 0 THEN len := 0 END;
  RETURN p
END ScalarBytes;

(* A copy of the scalar's text, all ScalarLen bytes of it. *)
PROCEDURE (n: Node) Scalar*(): String;
  VAR p, len: SYSTEM.ADDRESS;
BEGIN p := ScalarBytes(n, len); RETURN FromBytes(p, len)
END Scalar;

(* The scalar's length in bytes, counting any embedded 0X. *)
PROCEDURE (n: Node) ScalarLen*(): LONGINT;
  VAR p, len: SYSTEM.ADDRESS;
BEGIN p := ScalarBytes(n, len); RETURN len
END ScalarLen;

(* Copies the scalar into s, 0X-terminated. Returns FALSE, with s
   holding as much as fits, if it was truncated. *)
PROCEDURE (n: Node) ScalarInto*(VAR s: ARRAY OF CHAR): BOOLEAN;
  VAR p, len, m: SYSTEM.ADDRESS;
BEGIN
  p := ScalarBytes(n, len);
  m := len; IF m > LEN(s) - 1 THEN m := LEN(s) - 1 END;
  IF m > 0 THEN SYSTEM.MOVE(p, SYSTEM.ADR(s[0]), m) END;
  s[m] := 0X;
  RETURN m = len
END ScalarInto;

(* TRUE if the scalar's text is exactly s (up to s's first 0X). *)
PROCEDURE (n: Node) ScalarIs*(s: ARRAY OF CHAR): BOOLEAN;
  VAR p, len, i: SYSTEM.ADDRESS; c: CHAR;
BEGIN
  p := ScalarBytes(n, len);
  IF len # Length(s) THEN RETURN FALSE END;
  i := 0;
  WHILE i < len DO
    SYSTEM.GET(p + i, c);
    IF c # s[i] THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END ScalarIs;

(* Number of items in a sequence, or of pairs in a mapping. *)
PROCEDURE (n: Node) Length*(): LONGINT;
BEGIN
  IF n.IsSequence() THEN RETURN FyThin.NodeSequenceItemCount(n.handle) END;
  ASSERT(n.IsMapping(), AssertKind);
  RETURN FyThin.NodeMappingItemCount(n.handle)
END Length;

(* Item i (0-based) of a sequence. *)
PROCEDURE (n: Node) Item*(i: LONGINT): Node;
BEGIN
  ASSERT(n.IsSequence(), AssertKind);
  ASSERT((i >= 0) & (i < FyThin.NodeSequenceItemCount(n.handle)), AssertIndex);
  RETURN NewNode(n.doc, FyThin.NodeSequenceGetByIndex(n.handle, SHORT(i)))
END Item;

(* The value for key in a mapping, or NIL if there is no such key. *)
PROCEDURE (n: Node) Value*(key: ARRAY OF CHAR): Node;
BEGIN
  ASSERT(n.IsMapping(), AssertKind);
  RETURN NewNode(n.doc,
    FyThin.NodeMappingLookupValueByString(n.handle, SYSTEM.ADR(key[0]), Length(key)))
END Value;

PROCEDURE (n: Node) HasKey*(key: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN n.Value(key) # NIL
END HasKey;

(* The node at path below n ("/a/0/b"), or NIL if there is none. *)
PROCEDURE (n: Node) ByPath*(path: ARRAY OF CHAR): Node;
BEGIN
  Live(n);
  RETURN NewNode(n.doc, FyThin.NodeByPath(n.handle, SYSTEM.ADR(path[0]), Length(path)))
END ByPath;

(* n's path from the document root, in ByPath syntax; "/" for the root. *)
PROCEDURE (n: Node) Path*(): String;
  VAR p: SYSTEM.ADDRESS; s: String;
BEGIN
  Live(n);
  p := FyThin.NodeGetPath(n.handle);
  s := FromCString(p);
  IF p # 0 THEN FyThin.Free(p) END;
  RETURN s
END Path;

(* ---- Iteration ---- *)

(* Starts iterating a sequence's items:
     n.Items(it); WHILE it.Next(item) DO ... END *)
PROCEDURE (n: Node) Items*(VAR it: ItemIter);
BEGIN ASSERT(n.IsSequence(), AssertKind); it.node := n; it.prev := 0; it.done := FALSE
END Items;

(* The next item, or FALSE (item = NIL) once exhausted, and from then on. *)
PROCEDURE (VAR it: ItemIter) Next*(VAR item: Node): BOOLEAN;
BEGIN
  Live(it.node);
  item := NIL;
  IF ~it.done THEN
    item := NewNode(it.node.doc, FyThin.NodeSequenceIterate(it.node.handle, it.prev));
    it.done := item = NIL
  END;
  RETURN item # NIL
END Next;

(* Starts iterating a mapping's pairs, in document order:
     n.Pairs(it); WHILE it.Next(key, value) DO ... END *)
PROCEDURE (n: Node) Pairs*(VAR it: PairIter);
BEGIN ASSERT(n.IsMapping(), AssertKind); it.node := n; it.prev := 0; it.done := FALSE
END Pairs;

(* The next pair, or FALSE (key = value = NIL) once exhausted, and
   from then on. *)
PROCEDURE (VAR it: PairIter) Next*(VAR key, value: Node): BOOLEAN;
  VAR p: FyThin.NodePair;
BEGIN
  Live(it.node);
  key := NIL; value := NIL;
  IF it.done THEN RETURN FALSE END;
  p := FyThin.NodeMappingIterate(it.node.handle, it.prev);
  IF p = 0 THEN it.done := TRUE; RETURN FALSE END;
  key := NewNode(it.node.doc, FyThin.NodePairKey(p));
  value := NewNode(it.node.doc, FyThin.NodePairValue(p));
  RETURN TRUE
END Next;

(* ---- Building and changing ---- *)

(* A new empty document (no root), to fill with Create* and SetRoot. *)
PROCEDURE NewDocument*(): Document;
  VAR h: FyThin.Document;
BEGIN
  h := FyThin.DocumentCreate();
  ASSERT(h # 0);  (* allocation failure *)
  RETURN NewDoc(h, NIL)
END NewDocument;

(* A new unattached node in d; a copy of text up to its first 0X. *)
PROCEDURE (d: Document) CreateScalar*(text: ARRAY OF CHAR): Node;
  VAR h: FyThin.Node;
BEGIN
  ASSERT(d.handle # 0, AssertInvalid);
  h := FyThin.NodeCreateScalarCopy(d.handle, SYSTEM.ADR(text[0]), Length(text));
  ASSERT(h # 0); AddOrphan(d, h);
  RETURN NewNode(d, h)
END CreateScalar;

PROCEDURE (d: Document) CreateSequence*(): Node;
  VAR h: FyThin.Node;
BEGIN
  ASSERT(d.handle # 0, AssertInvalid);
  h := FyThin.NodeCreateSequence(d.handle); ASSERT(h # 0); AddOrphan(d, h);
  RETURN NewNode(d, h)
END CreateSequence;

PROCEDURE (d: Document) CreateMapping*(): Node;
  VAR h: FyThin.Node;
BEGIN
  ASSERT(d.handle # 0, AssertInvalid);
  h := FyThin.NodeCreateMapping(d.handle); ASSERT(h # 0); AddOrphan(d, h);
  RETURN NewNode(d, h)
END CreateMapping;

(* Halts unless n is a live, unattached node of d. *)
PROCEDURE Attachable(d: Document; n: Node);
BEGIN
  Live(n);
  ASSERT((n.doc = d) & ~FyThin.NodeIsAttached(n.handle), AssertAttach)
END Attachable;

(* Makes n (unattached, from d) the root. If d already has a root,
   libfyaml frees that whole tree, so every Node taken from d before
   this call dies -- except n, which stays usable. Unattached nodes
   built before the call die too in that case: attach them first. On a
   NewDocument (no root yet) nothing dies. *)
PROCEDURE (d: Document) SetRoot*(n: Node);
  VAR hadRoot: BOOLEAN;
BEGIN
  ASSERT(d.handle # 0, AssertInvalid);
  Attachable(d, n);
  hadRoot := FyThin.DocumentRoot(d.handle) # 0;
  ASSERT(FyThin.DocumentSetRoot(d.handle, n.handle) = 0);  (* preconditions checked above *)
  DropOrphan(d, n.handle);
  IF hadRoot THEN INC(d.gen); n.gen := d.gen END
END SetRoot;

(* Merges n into the node at path, by libfyaml's rules: a scalar, or a
   node of a different kind, replaces the target; a mapping into a
   mapping adds its pairs (replacing the values of equal keys); a
   sequence into a sequence appends its items. n is copied in and then
   FREED by libfyaml whatever the outcome, so n is set to NIL (and any
   other copy of it dies). Every Node taken from d before this call
   dies too, since the replaced nodes are freed. Returns FALSE with a
   PathError if there is no node at path or libfyaml refuses. *)
PROCEDURE (d: Document) InsertAt*(path: ARRAY OF CHAR; VAR n: Node; VAR err: Error): BOOLEAN;
  VAR rc: INTEGER; target: FyThin.Node; len: LONGINT; file: String;
BEGIN
  ASSERT(d.handle # 0, AssertInvalid);
  Live(n);
  ASSERT(n.doc = d, AssertAttach);
  err := NIL;
  len := Length(path);
  target := FyThin.NodeByPath(FyThin.DocumentRoot(d.handle), SYSTEM.ADR(path[0]), len);
  rc := FyThin.DocumentInsertAt(d.handle, SYSTEM.ADR(path[0]), len, n.handle);
  DropOrphan(d, n.handle);  (* freed by libfyaml *)
  n.handle := 0; n := NIL;
  INC(d.gen);
  IF rc # 0 THEN
    file := FromChars(path);
    IF target = 0 THEN err := NewError(PathError, file, "no node at this path")
    ELSE err := NewError(PathError, file, "cannot insert here")
    END
  END;
  RETURN rc = 0
END InsertAt;

(* Attaches item (unattached, same document) at the end of sequence n. *)
PROCEDURE (n: Node) Append*(item: Node);
BEGIN
  ASSERT(n.IsSequence(), AssertKind);
  Attachable(n.doc, item);
  ASSERT(FyThin.NodeSequenceAppend(n.handle, item.handle) = 0);  (* preconditions checked above *)
  DropOrphan(n.doc, item.handle)
END Append;

(* Attaches key and value (unattached, same document) as the last pair
   of mapping n. Returns FALSE with a DuplicateKey error, attaching
   nothing, if n already has an equal key; key and value stay usable. *)
PROCEDURE (n: Node) AppendPair*(key, value: Node; VAR err: Error): BOOLEAN;
  VAR path, k: String; len: LONGINT;
BEGIN
  ASSERT(n.IsMapping(), AssertKind);
  Attachable(n.doc, key); Attachable(n.doc, value);
  ASSERT(key # value, AssertAttach);
  err := NIL;
  IF FyThin.NodeMappingAppend(n.handle, key.handle, value.handle) = 0 THEN
    DropOrphan(n.doc, key.handle); DropOrphan(n.doc, value.handle);
    RETURN TRUE
  END;
  (* The only failure left after the checks above is a duplicate key. *)
  path := n.Path();
  NEW(err); err.kind := DuplicateKey; err.file := path; err.line := 0; err.column := 0;
  len := 0;
  Append(err.msg, len, path^); Append(err.msg, len, ": error: duplicate key");
  IF key.IsScalar() THEN
    k := key.Scalar(); Append(err.msg, len, ' "'); Append(err.msg, len, k^); Append(err.msg, len, '"')
  END;
  Append(err.msg, len, 0AX);
  RETURN FALSE
END AppendPair;

(* ---- Emitting ---- *)

(* d as YAML text (or JSON, with emitModeJson). flags: see emitDefault.
   Returns NIL with an EmitError if libfyaml fails, or if d is empty
   (no root): libfyaml emits nothing for one (confirmed live). *)
PROCEDURE (d: Document) ToYAML*(flags: INTEGER; VAR err: Error): String;
  VAR p: SYSTEM.ADDRESS; s: String;
BEGIN
  ASSERT(d.handle # 0, AssertInvalid);
  err := NIL;
  IF FyThin.DocumentRoot(d.handle) = 0 THEN
    err := NewError(EmitError, FromChars("(emit)"), "document is empty (no root)"); RETURN NIL
  END;
  p := FyThin.EmitDocumentToString(d.handle, flags);
  IF p = 0 THEN err := NewError(EmitError, FromChars("(emit)"), "emitting the document failed"); RETURN NIL END;
  s := FromCString(p); FyThin.Free(p);
  RETURN s
END ToYAML;

(* Writes d to the file at path, created or truncated (libfyaml opens
   it "wa", which glibc treats as "w": confirmed live). Returns FALSE
   with a FileError (the OS reason) or EmitError on failure, including
   an empty document. *)
PROCEDURE (d: Document) ToFile*(path: ARRAY OF CHAR; flags: INTEGER; VAR err: Error): BOOLEAN;
  VAR p, reason: String; rc: INTEGER;
BEGIN
  ASSERT(d.handle # 0, AssertInvalid);
  err := NIL;
  p := FromChars(path);
  IF FyThin.DocumentRoot(d.handle) = 0 THEN
    err := NewError(EmitError, p, "document is empty (no root)"); RETURN FALSE
  END;
  rc := FyThin.EmitDocumentToFile(d.handle, flags, SYSTEM.ADR(p[0]));
  IF rc > 0 THEN reason := FromCString(FyThin.Strerror(rc)); err := NewError(FileError, p, reason^)
  ELSIF rc < 0 THEN err := NewError(EmitError, p, "emitting the document failed")
  END;
  RETURN rc = 0
END ToFile;

BEGIN
  openDocuments := 0;
  emitDefault := FyThin.FlagDefault();
  emitSortKeys := FyThin.FlagSortKeys();
  emitModeOriginal := FyThin.FlagModeOriginal();
  emitModeBlock := FyThin.FlagModeBlock();
  emitModeFlow := FyThin.FlagModeFlow();
  emitModeFlowOneline := FyThin.FlagModeFlowOneline();
  emitModeJson := FyThin.FlagModeJson()
END Fyaml.
