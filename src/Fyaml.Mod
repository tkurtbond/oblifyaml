MODULE Fyaml; (* Oberon-2 binding to libfyaml: documents, nodes, errors *)

(* Parse YAML/JSON into a Document and navigate its Nodes.

   Ownership. A Document owns its libfyaml tree. Close it when done:
   Close is idempotent, and a GC finalizer closes any Document that
   becomes unreachable without one -- but the GC runs only when Oberon
   code allocates and cannot see libfyaml's C memory, so don't rely on
   it for documents parsed in a loop.

   Nodes. A Node is a small heap object holding its Document, so the
   GC can never destroy a document that a reachable Node still uses.
   After an explicit Close, every Node from that document is dead:
   calling one of its methods halts (ASSERT code AssertClosed); use
   Valid to test without halting.

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

   Indexes are 0-based, as in By_Path's "/tags/0" and Oberon arrays
   (alibfyaml's Item is 1-based). *)

IMPORT SYSTEM, Heap, FyThin;

CONST
  (* Error kinds *)
  ParseError* = 1;   (* malformed input *)
  FileError* = 2;    (* ParseFile: the file can't be opened (msg gives the OS reason) *)

  (* Node kinds, as returned by Kind *)
  KindScalar* = 0; KindSequence* = 1; KindMapping* = 2;

  (* ASSERT codes for programmer errors (also the exit status) *)
  AssertClosed* = 61;  (* document closed, or node from a closed document *)
  AssertKind* = 62;    (* operation not valid for this node's kind *)
  AssertIndex* = 63;   (* index out of range *)

  stringName = "(string-in-memory)";  (* file name reported for ParseString input *)

TYPE
  String* = POINTER TO ARRAY OF CHAR;

  Error* = POINTER TO ErrorDesc;
  ErrorDesc* = RECORD
    kind-: INTEGER;           (* ParseError, FileError *)
    file-: String;            (* file of the first error; never NIL *)
    line-, column-: INTEGER;  (* of the first error; 1-based, 0 = unknown *)
    msg-: String              (* every error, one "file:line:column: error: text" line each *)
  END;

  Document* = POINTER TO DocumentDesc;
  DocumentDesc* = RECORD
    handle: FyThin.Document;  (* 0 once closed *)
    buffer: String            (* ParseString input: libfyaml's scalars span into it *)
  END;

  Node* = POINTER TO NodeDesc;
  NodeDesc* = RECORD
    handle: FyThin.Node;
    doc: Document             (* owner: liveness check, and keeps it reachable *)
  END;

  (* done: libfyaml's *_iterate ends by resetting the cursor to NULL,
     which is also the "start over" value -- without this flag a Next
     after the end would silently restart from the first item
     (confirmed live, TestNavigate). *)
  ItemIter* = RECORD node: Node; prev: SYSTEM.ADDRESS; done: BOOLEAN END;
  PairIter* = RECORD node: Node; prev: SYSTEM.ADDRESS; done: BOOLEAN END;

VAR
  openDocuments-: LONGINT;  (* documents parsed and not yet closed or finalized *)

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

(* Idempotent: frees the tree once; later calls do nothing. *)
PROCEDURE CloseHandle(d: Document);
  VAR h: FyThin.Document;
BEGIN
  IF d.handle # 0 THEN
    h := d.handle; d.handle := 0;  (* dead before freed: no second free *)
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
  NEW(d); d.handle := h; d.buffer := buffer;
  INC(openDocuments);
  Heap.RegisterFinalizer(d, FinalizeDocument);
  RETURN d
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
  NEW(n); n.handle := h; n.doc := d;
  RETURN n
END NewNode;

(* The root node, or NIL for an empty document. *)
PROCEDURE (d: Document) Root*(): Node;
BEGIN
  ASSERT(d.handle # 0, AssertClosed);
  RETURN NewNode(d, FyThin.DocumentRoot(d.handle))
END Root;

(* ---- Nodes ---- *)

(* TRUE if n is not NIL and its document is still open. *)
PROCEDURE Valid*(n: Node): BOOLEAN;
BEGIN RETURN (n # NIL) & (n.handle # 0) & (n.doc.handle # 0)
END Valid;

PROCEDURE Live(n: Node);
BEGIN ASSERT((n.handle # 0) & (n.doc.handle # 0), AssertClosed)
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

BEGIN openDocuments := 0
END Fyaml.
