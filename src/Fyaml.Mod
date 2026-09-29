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
   A Node dies when its Document is closed, and ALSO when InsertAt,
   Resolve, or SetRoot replacing an existing root is called on its
   Document: libfyaml frees the nodes those calls replace, and this binding
   can't tell which ones, so it invalidates every Node taken from the
   document before the call (a per-document generation count). Get
   Nodes again from Root/ByPath afterwards. Calling a method of a dead
   Node halts (ASSERT code AssertInvalid) instead of reading freed
   memory; use Valid to test without halting.

   Building. NewDocument gives an empty document; Create* make
   unattached nodes; Append, AppendPair and SetRoot attach them. A node
   can be attached only once, and only within its own document.

   Typed values. LongIntValue, IntegerValue, RealValue, LongRealValue
   and BooleanValue resolve a scalar's text as YAML 1.2's core schema
   does; the ...Field/...FieldOr forms look a key up in a mapping
   first, with or without a default. See "Typed scalars" below.

   Errors. Bad input, missing files, missing keys and malformed values
   are ordinary results: calls that can fail on them return NIL/FALSE
   and hand back an Error in a VAR parameter (NIL on success). Programmer errors -- a closed
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
  MissingKey* = 6;   (* Required and the ...Field accessors: no such key *)
  DataError* = 7;    (* typed accessors: not a scalar, malformed, or out of range *)
  ResolveError* = 8; (* Resolve: e.g. a cyclic reference *)

  (* Options for ParseStringWith/ParseFileWith, elements of a SET *)
  NoResolve* = 0;    (* leave anchors, aliases and merge keys as written; see Resolve *)

  (* Node styles, as returned by Style *)
  StyleFlow* = 0; StyleBlock* = 1;  (* collections: [a] {k: v}, or indented *)
  StylePlain* = 2; StyleSingleQuoted* = 3; StyleDoubleQuoted* = 4;
  StyleLiteral* = 5; StyleFolded* = 6;  (* block scalars: | and > *)
  StyleAlias* = 7;   (* an unresolved *alias *)

  (* Node kinds, as returned by Kind *)
  KindScalar* = 0; KindSequence* = 1; KindMapping* = 2;

  (* ASSERT codes for programmer errors (also the exit status) *)
  AssertInvalid* = 61; (* document closed, or node dead (closed, or before InsertAt/SetRoot) *)
  AssertKind* = 62;    (* operation not valid for this node's kind *)
  AssertIndex* = 63;   (* index out of range *)
  AssertAttach* = 64;  (* node already attached, or from another document *)

  stringName* = "(string-in-memory)";  (* file name reported for string input *)
  stdinName* = "<stdin>";               (* file name reported for standard input, as gcc does *)

TYPE
  String* = POINTER TO ARRAY OF CHAR;
  Handles = POINTER TO ARRAY OF SYSTEM.ADDRESS;

  Error* = POINTER TO ErrorDesc;
  ErrorDesc* = RECORD
    kind-: INTEGER;           (* one of the error kinds above *)
    file-: String;            (* file of the first error; never NIL *)
    line-, column-: INTEGER;  (* of the first error; 1-based, 0 = unknown *)
    path-: String;            (* the node concerned, in ByPath syntax, or NIL *)
    msg-: String              (* every error, one "file:line:column: error: text" line each *)
  END;

  Document* = POINTER TO DocumentDesc;
  DocumentDesc* = RECORD
    handle: FyThin.Document;  (* 0 once closed *)
    buffer: String;           (* ParseString input: libfyaml's scalars span into it *)
    gen: LONGINT;             (* bumped by InsertAt/SetRoot: older Nodes are dead *)
    name: String;             (* file name for errors: ParseFile's path, or stringName; NIL if built *)
    created: BOOLEAN;         (* CreateScalar was called: a 0:0 location may be a created scalar's *)
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
  (* A scalar's trimmed text, for the typed accessors; see GetText. *)
  Text = RECORD buf: ARRAY 64 OF CHAR; big: String; len: LONGINT END;

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
  NEW(err); err.kind := kind; err.file := file; err.line := 0; err.column := 0; err.path := NIL;
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
PROCEDURE Collected(kind: INTEGER; diag: FyThin.Diag; fileOverride: ARRAY OF CHAR; name: String;
                    fallback: ARRAY OF CHAR): Error;
  VAR err: Error; e: FyThin.DiagError; prev: SYSTEM.ADDRESS;
    msg, file, text: String; len: LONGINT; line, column: INTEGER;
BEGIN
  NEW(err); err.kind := kind; err.line := 0; err.column := 0; err.path := NIL;
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
  IF msg = NIL THEN RETURN NewError(kind, name, fallback) END;
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
  d.name := NIL; d.created := FALSE;
  INC(openDocuments);
  Heap.RegisterFinalizer(d, FinalizeDocument);
  RETURN d
END NewDoc;

(* Parses from the string (buffer # NIL, len bytes), from the file
   named by path (path # NIL), or else from standard input. name labels errors when libfyaml gives no file name.
   The diag is created and destroyed here, exactly once on every path
   (alibfyaml's Parse_Common double-free). *)
PROCEDURE Build(buffer: String; len: SYSTEM.ADDRESS; path: String;
                fileOverride: ARRAY OF CHAR; name: String; options: SET; VAR err: Error): Document;
  VAR diag: FyThin.Diag; h: FyThin.Document; d: Document;
BEGIN
  err := NIL;
  diag := FyThin.DiagCreate();
  ASSERT(diag # 0);  (* allocation failure: nothing sensible to return *)
  FyThin.DiagSetCollectErrors(diag, TRUE);
  IF buffer # NIL THEN
    h := FyThin.DocumentBuildFromString(SYSTEM.ADR(buffer[0]), len, ~(NoResolve IN options), diag)
  ELSIF path # NIL THEN
    h := FyThin.DocumentBuildFromFile(SYSTEM.ADR(path[0]), ~(NoResolve IN options), diag)
  ELSE
    h := FyThin.DocumentBuildFromStdin(~(NoResolve IN options), diag)
  END;
  IF h = 0 THEN err := Collected(ParseError, diag, fileOverride, name, "document failed to parse") END;
  FyThin.DiagDestroy(diag);
  IF h = 0 THEN RETURN NIL END;
  d := NewDoc(h, buffer); d.name := name;
  RETURN d
END Build;

(* ---- For FyamlStreams ----

   Exported only because Oberon has no friend modules: these pass raw
   libfyaml handles across. Other clients should not call them. *)

(* NIL if the file at path (0X-terminated) opens for reading, else a
   FileError with the OS reason. libfyaml reports an unopenable file
   only on stderr and collects nothing (confirmed live). *)
PROCEDURE Unreadable*(path: String): Error;
  VAR e: INTEGER; reason: String;
BEGIN
  e := FyThin.OpenErrno(SYSTEM.ADR(path[0]));
  IF e = 0 THEN RETURN NIL END;
  reason := FromCString(FyThin.Strerror(e));
  RETURN NewError(FileError, path, reason^)
END Unreadable;

(* Takes ownership of h, a document loaded by a streaming parser:
   Close or the GC finalizer destroys it. buffer is the stream's
   text, which h's scalars span into (NIL for a file stream); name
   labels errors. *)
PROCEDURE Adopt*(h: FyThin.Document; buffer, name: String): Document;
  VAR d: Document;
BEGIN
  ASSERT(h # 0);
  d := NewDoc(h, buffer); d.name := name;
  RETURN d
END Adopt;

(* The errors collected in diag, as one ParseError. fromString reports
   stringName instead of libfyaml's synthetic "<memory-@...>" label. *)
PROCEDURE DiagErrors*(diag: FyThin.Diag; fromString: BOOLEAN; name: String): Error;
BEGIN
  IF fromString THEN RETURN Collected(ParseError, diag, stringName, name, "document failed to parse")
  ELSE RETURN Collected(ParseError, diag, "", name, "document failed to parse")
  END
END DiagErrors;

(* ---- Parsing ---- *)

(* Parses text (up to its first 0X) as one YAML document, with
   options (a SET of NoResolve; {} for none). Unless NoResolve is
   given, anchors, aliases and merge keys are resolved, and a cyclic
   reference is a ParseError. Returns NIL and sets err on a parse
   error. text is copied: libfyaml doesn't copy its input, and voc's
   copy of a value ARRAY OF CHAR dies when a procedure returns
   (PLAN.md, "Buffer lifetime"). Parses only the first of several
   "---" documents. *)
PROCEDURE ParseStringWith*(text: ARRAY OF CHAR; options: SET; VAR err: Error): Document;
BEGIN RETURN Build(FromChars(text), Length(text), NIL, stringName, FromChars(stringName), options, err)
END ParseStringWith;

(* ParseStringWith(text, {}, err): anchors resolved. *)
PROCEDURE ParseString*(text: ARRAY OF CHAR; VAR err: Error): Document;
BEGIN RETURN ParseStringWith(text, {}, err)
END ParseString;

(* Parses the file at path as one YAML document, like ParseStringWith.
   A file that can't be opened gives a FileError with the OS reason,
   checked here first: libfyaml itself only prints "[ERR]: failed to
   open" on stderr and collects nothing (confirmed live). *)
PROCEDURE ParseFileWith*(path: ARRAY OF CHAR; options: SET; VAR err: Error): Document;
  VAR p: String;
BEGIN
  p := FromChars(path);
  err := Unreadable(p);
  IF err # NIL THEN RETURN NIL END;
  RETURN Build(NIL, 0, p, "", p, options, err)
END ParseFileWith;

(* ParseFileWith(path, {}, err): anchors resolved. *)
PROCEDURE ParseFile*(path: ARRAY OF CHAR; VAR err: Error): Document;
BEGIN RETURN ParseFileWith(path, {}, err)
END ParseFile;

(* Parses standard input as one YAML document, like ParseStringWith;
   errors name the file stdinName. It reads stdin to its end, so a
   second call finds nothing and returns a ParseError, and only the
   first of several "---" documents is kept (use
   FyamlStreams.OpenStdin for all of them). It reads through C's
   stdio, so don't also read stdin with voc's In module. *)
PROCEDURE ParseStdinWith*(options: SET; VAR err: Error): Document;
BEGIN RETURN Build(NIL, 0, NIL, stdinName, FromChars(stdinName), options, err)
END ParseStdinWith;

(* ParseStdinWith({}, err): anchors resolved. *)
PROCEDURE ParseStdin*(VAR err: Error): Document;
BEGIN RETURN ParseStdinWith({}, err)
END ParseStdin;

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

(* Resolves anchors, aliases and merge keys, for a document parsed
   with NoResolve (or built): each alias becomes a copy of its
   anchored node, and each "<<" merge key is replaced by the pairs it
   merges. libfyaml frees the merge-key pairs, so, as with InsertAt,
   every Node taken from d before the call is dead afterwards; get
   them again from Root. FALSE and a ResolveError if it fails (e.g.
   "cyclic reference detected"), which can leave d partly resolved. *)
PROCEDURE (d: Document) Resolve*(VAR err: Error): BOOLEAN;
  VAR diag: FyThin.Diag; rc: INTEGER; name: String;
BEGIN
  ASSERT(d.handle # 0, AssertInvalid);
  err := NIL;
  diag := FyThin.DiagCreate();
  ASSERT(diag # 0);
  FyThin.DiagSetCollectErrors(diag, TRUE);
  ASSERT(FyThin.DocumentSetDiag(d.handle, diag) = 0);
  rc := FyThin.DocumentResolve(d.handle);
  INC(d.gen);
  IF rc # 0 THEN
    name := d.name; IF name = NIL THEN name := FromChars("(built document)") END;
    IF d.buffer # NIL THEN  (* libfyaml's label for string input is synthetic *)
      err := Collected(ResolveError, diag, stringName, name, "document failed to resolve")
    ELSE
      err := Collected(ResolveError, diag, "", name, "document failed to resolve")
    END
  END;
  FyThin.DiagDestroy(diag);  (* d keeps a reference; this only silences it *)
  RETURN rc = 0
END Resolve;

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

(* ---- Typed scalars ----

   libfyaml's core API gives scalars as text; these resolve it the way
   YAML 1.2's core schema does (null, bool, int, float), as alibfyaml
   does. The text is first trimmed of blanks. Accepted:

   - integers: [+-] then decimal digits, or 0x/0o/0b and hex, octal
     or binary digits. 0b, and "_" between two digits in any base
     ("1_000_000", "0xFF_FF"), are extensions beyond the core schema,
     as in alibfyaml; a leading, trailing or doubled "_" is rejected.
   - floats: [+-] then digits, ".digits", "digits." or
     "digits.digits", then an optional exponent; any integer written
     in decimal is also a float. "_" as for integers. .inf and .nan
     are not accepted (deferred, as in alibfyaml).
   - booleans: true/True/TRUE and false/False/FALSE only.
   - null: see IsNullValue.

   Each typed accessor returns FALSE and sets err (a DataError) when the
   text doesn't fit the type, including a number out of range; v is
   then unchanged. On success err is NIL. The error carries the node's
   path and, where the node has one, its line and column. *)

(* Where a DataError points: a scalar's 1-based location, or FALSE.
   A scalar made by CreateScalar reports 0:0, which can't be told from
   a parsed one at the very start of the input (confirmed live), so in
   a document that has had scalars created 0:0 counts as no location. *)
PROCEDURE ScalarLocation(d: Document; h: FyThin.Node; VAR line, column: INTEGER): BOOLEAN;
  VAR l, c: SYSTEM.INT32;
BEGIN
  IF (h = 0) OR ~FyThin.NodeScalarMark(h, l, c) OR (d.created & (l = 0) & (c = 0)) THEN
    RETURN FALSE
  END;
  line := l + 1; column := c + 1;
  RETURN TRUE
END ScalarLocation;

(* An Error of kind about node n, located at the scalar at (n itself,
   or a key; 0 for none). Message: "file:line:column: error: path:
   text"; without a location "file: error: path: text"; and for a
   built document, which has no file, "path: error: text". *)
PROCEDURE NodeError(kind: INTEGER; n: Node; at: FyThin.Node; text: ARRAY OF CHAR): Error;
  VAR err: Error; len: LONGINT; d: Document;
BEGIN
  d := n.doc;
  NEW(err); err.kind := kind; err.path := n.Path(); err.line := 0; err.column := 0;
  IF ~ScalarLocation(d, at, err.line, err.column) THEN err.line := 0; err.column := 0 END;
  IF d.name # NIL THEN err.file := d.name ELSE err.file := err.path END;
  len := 0; Append(err.msg, len, err.file^);
  IF err.line > 0 THEN
    Append(err.msg, len, ":"); AppendInt(err.msg, len, err.line);
    Append(err.msg, len, ":"); AppendInt(err.msg, len, err.column)
  END;
  Append(err.msg, len, ": error: ");
  IF d.name # NIL THEN Append(err.msg, len, err.path^); Append(err.msg, len, ": ") END;
  Append(err.msg, len, text); Append(err.msg, len, 0AX);
  RETURN err
END NodeError;

(* A scalar's trimmed text, held for conversion. Text up to
   LEN(buf) - 1 bytes (every realistic number or boolean) is copied
   into buf, on the stack, so converting it allocates nothing; longer
   text goes into big. Converting allocates only on failure, to build
   the Error: allocation drives voc's GC, which was about half of the
   typed accessors' time before this (PLAN.md, Phase 6). *)
PROCEDURE GetText(h: FyThin.Node; VAR t: Text);
  VAR p, len: SYSTEM.ADDRESS; c: CHAR;
BEGIN
  p := FyThin.NodeGetScalar(h, len);
  IF p = 0 THEN len := 0 END;
  LOOP IF len = 0 THEN EXIT END; SYSTEM.GET(p, c); IF c # " " THEN EXIT END; INC(p); DEC(len) END;
  LOOP IF len = 0 THEN EXIT END; SYSTEM.GET(p + len - 1, c); IF c # " " THEN EXIT END; DEC(len) END;
  t.len := len; t.big := NIL;
  IF len < LEN(t.buf) THEN
    IF len > 0 THEN SYSTEM.MOVE(p, SYSTEM.ADR(t.buf[0]), len) END;
    t.buf[len] := 0X
  ELSE
    t.big := FromBytes(p, len)
  END
END GetText;

PROCEDURE TextString(VAR t: Text): String;
BEGIN
  IF t.big # NIL THEN RETURN t.big END;
  RETURN FromBytes(SYSTEM.ADR(t.buf[0]), t.len)
END TextString;

(* A DataError about scalar h of d: 'what: "text"'. *)
PROCEDURE ValueError(d: Document; h: FyThin.Node; what: ARRAY OF CHAR; VAR t: Text): Error;
  VAR m, s: String; len: LONGINT;
BEGIN
  m := NIL; len := 0; s := TextString(t);
  Append(m, len, what); Append(m, len, ': "'); Append(m, len, s^); Append(m, len, '"');
  RETURN NodeError(DataError, NewNode(d, h), h, m^)
END ValueError;

(* The n bytes of s equal lit. An embedded 0X makes them differ. *)
PROCEDURE Is(VAR s: ARRAY OF CHAR; n: LONGINT; lit: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF n # Length(lit) THEN RETURN FALSE END;
  FOR i := 0 TO n - 1 DO IF s[i] # lit[i] THEN RETURN FALSE END END;
  RETURN TRUE
END Is;

PROCEDURE TextIs(VAR t: Text; lit: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF t.big = NIL THEN RETURN Is(t.buf, t.len, lit) ELSE RETURN Is(t.big^, t.len, lit) END
END TextIs;

(* A digit's value, or 99 for anything else. *)
PROCEDURE DigitVal(c: CHAR): INTEGER;
BEGIN
  IF (c >= "0") & (c <= "9") THEN RETURN ORD(c) - ORD("0")
  ELSIF (c >= "a") & (c <= "f") THEN RETURN ORD(c) - ORD("a") + 10
  ELSIF (c >= "A") & (c <= "F") THEN RETURN ORD(c) - ORD("A") + 10
  ELSE RETURN 99
  END
END DigitVal;

(* The length of the run digit {["_"] digit} of base-digits at s[i],
   within the first n bytes of s, or 0 if s[i] isn't one. *)
PROCEDURE DigitRun(VAR s: ARRAY OF CHAR; n, i: LONGINT; base: INTEGER): LONGINT;
  VAR j: LONGINT;
BEGIN
  j := i;
  IF (j >= n) OR (DigitVal(s[j]) >= base) THEN RETURN 0 END;
  INC(j);
  LOOP
    IF j >= n THEN EXIT
    ELSIF DigitVal(s[j]) < base THEN INC(j)
    ELSIF (s[j] = "_") & (j + 1 < n) & (DigitVal(s[j + 1]) < base) THEN INC(j, 2)
    ELSE EXIT
    END
  END;
  RETURN j - i
END DigitRun;

(* Parses the n bytes of s as an integer. FALSE if they don't match
   the grammar; otherwise TRUE, with overflow set if the value is
   outside LONGINT.

   The value is built negatively, Java's Long.parseLong way, so that
   MIN(LONGINT) parses. voc's DIV of a negative number near
   MIN(LONGINT) overflows ((MIN(LONGINT) + 9) DIV 10 came out
   positive, confirmed live), so every DIV here is of MAX(LONGINT). *)
PROCEDURE ParseInt(VAR s: ARRAY OF CHAR; n: LONGINT; VAR v: LONGINT; VAR overflow: BOOLEAN): BOOLEAN;
  VAR i, r, limit, multmin: LONGINT; neg: BOOLEAN; base, d: INTEGER;
BEGIN
  i := 0; neg := FALSE; overflow := FALSE;
  IF (n > 0) & ((s[0] = "+") OR (s[0] = "-")) THEN neg := s[0] = "-"; i := 1 END;
  base := 10;
  IF (n - i >= 2) & (s[i] = "0") THEN
    IF s[i + 1] = "x" THEN base := 16; INC(i, 2)
    ELSIF s[i + 1] = "o" THEN base := 8; INC(i, 2)
    ELSIF s[i + 1] = "b" THEN base := 2; INC(i, 2)
    END
  END;
  IF (i = n) OR (DigitRun(s, n, i, base) # n - i) THEN RETURN FALSE END;
  IF neg THEN   (* limit = MIN(LONGINT); multmin = limit / base, truncated *)
    limit := MIN(LONGINT);
    multmin := -(MAX(LONGINT) DIV base + (MAX(LONGINT) MOD base + 1) DIV base)
  ELSE
    limit := -MAX(LONGINT); multmin := -(MAX(LONGINT) DIV base)
  END;
  r := 0;
  WHILE i < n DO
    IF s[i] # "_" THEN
      d := DigitVal(s[i]);
      IF r < multmin THEN overflow := TRUE; RETURN TRUE END;
      r := r * base;
      IF r < limit + d THEN overflow := TRUE; RETURN TRUE END;
      r := r - d
    END;
    INC(i)
  END;
  IF neg THEN v := r ELSE v := -r END;
  RETURN TRUE
END ParseInt;

PROCEDURE TextInt(VAR t: Text; VAR v: LONGINT; VAR overflow: BOOLEAN): BOOLEAN;
BEGIN
  IF t.big = NIL THEN RETURN ParseInt(t.buf, t.len, v, overflow)
  ELSE RETURN ParseInt(t.big^, t.len, v, overflow)
  END
END TextInt;

(* TRUE if the n bytes of s match the float grammar. *)
PROCEDURE IsFloat(VAR s: ARRAY OF CHAR; n: LONGINT): BOOLEAN;
  VAR i, k, intLen, fracLen: LONGINT;
BEGIN
  i := 0;
  IF (n > 0) & ((s[0] = "+") OR (s[0] = "-")) THEN i := 1 END;
  intLen := DigitRun(s, n, i, 10); INC(i, intLen);
  fracLen := 0;
  IF (i < n) & (s[i] = ".") THEN INC(i); fracLen := DigitRun(s, n, i, 10); INC(i, fracLen) END;
  IF intLen + fracLen = 0 THEN RETURN FALSE END;
  IF (i < n) & ((s[i] = "e") OR (s[i] = "E")) THEN
    INC(i);
    IF (i < n) & ((s[i] = "+") OR (s[i] = "-")) THEN INC(i) END;
    k := DigitRun(s, n, i, 10);
    IF k = 0 THEN RETURN FALSE END;
    INC(i, k)
  END;
  RETURN i = n
END IsFloat;

(* strtod of the n bytes of s (already checked by IsFloat) without
   their "_"s, via out, which must hold n + 1 bytes. *)
PROCEDURE Strtod(VAR s: ARRAY OF CHAR; n: LONGINT; VAR out: ARRAY OF CHAR): LONGREAL;
  VAR i, k: LONGINT;
BEGIN
  k := 0;
  FOR i := 0 TO n - 1 DO IF s[i] # "_" THEN out[k] := s[i]; INC(k) END END;
  out[k] := 0X;
  RETURN FyThin.Strtod(SYSTEM.ADR(out[0]))
END Strtod;

(* The float value of t, or FALSE if it doesn't match the grammar. *)
PROCEDURE TextFloat(VAR t: Text; VAR x: LONGREAL): BOOLEAN;
  VAR out: ARRAY 64 OF CHAR; big: String;
BEGIN
  IF t.big = NIL THEN
    IF ~IsFloat(t.buf, t.len) THEN RETURN FALSE END;
    x := Strtod(t.buf, t.len, out)  (* t.len < LEN(t.buf) = LEN(out) *)
  ELSE
    IF ~IsFloat(t.big^, t.len) THEN RETURN FALSE END;
    NEW(big, t.len + 1); x := Strtod(t.big^, t.len, big^)
  END;
  RETURN TRUE
END TextFloat;

PROCEDURE IsNullText(VAR t: Text): BOOLEAN;
BEGIN RETURN TextIs(t, "~") OR TextIs(t, "null") OR TextIs(t, "Null") OR TextIs(t, "NULL")
END IsNullText;

PROCEDURE IsTrueText(VAR t: Text): BOOLEAN;
BEGIN RETURN TextIs(t, "true") OR TextIs(t, "True") OR TextIs(t, "TRUE")
END IsTrueText;

PROCEDURE IsFalseText(VAR t: Text): BOOLEAN;
BEGIN RETURN TextIs(t, "false") OR TextIs(t, "False") OR TextIs(t, "FALSE")
END IsFalseText;

(* The conversions, on scalar h of d. FALSE and a DataError if the
   text doesn't fit; v is then unchanged. *)
PROCEDURE LongIntOf(d: Document; h: FyThin.Node; VAR v: LONGINT; VAR err: Error): BOOLEAN;
  VAR t: Text; x: LONGINT; overflow: BOOLEAN;
BEGIN
  err := NIL; GetText(h, t);
  IF ~TextInt(t, x, overflow) THEN err := ValueError(d, h, "not a valid integer", t); RETURN FALSE END;
  IF overflow THEN err := ValueError(d, h, "integer out of range", t); RETURN FALSE END;
  v := x;
  RETURN TRUE
END LongIntOf;

PROCEDURE IntegerOf(d: Document; h: FyThin.Node; VAR v: INTEGER; VAR err: Error): BOOLEAN;
  VAR x: LONGINT; t: Text;
BEGIN
  IF ~LongIntOf(d, h, x, err) THEN RETURN FALSE END;
  IF (x < MIN(INTEGER)) OR (x > MAX(INTEGER)) THEN
    GetText(h, t); err := ValueError(d, h, "integer out of range", t); RETURN FALSE
  END;
  v := SHORT(x);
  RETURN TRUE
END IntegerOf;

PROCEDURE LongRealOf(d: Document; h: FyThin.Node; VAR v: LONGREAL; VAR err: Error): BOOLEAN;
  VAR t: Text; x: LONGREAL;
BEGIN
  err := NIL; GetText(h, t);
  IF ~TextFloat(t, x) THEN err := ValueError(d, h, "not a valid float", t); RETURN FALSE END;
  IF ABS(x) > MAX(LONGREAL) THEN err := ValueError(d, h, "float out of range", t); RETURN FALSE END;
  v := x;
  RETURN TRUE
END LongRealOf;

(* A value beyond MAX(REAL) is out of range even if it would round
   down to MAX(REAL). *)
PROCEDURE RealOf(d: Document; h: FyThin.Node; VAR v: REAL; VAR err: Error): BOOLEAN;
  VAR x: LONGREAL; t: Text;
BEGIN
  IF ~LongRealOf(d, h, x, err) THEN RETURN FALSE END;
  IF ABS(x) > MAX(REAL) THEN GetText(h, t); err := ValueError(d, h, "float out of range", t); RETURN FALSE END;
  v := SHORT(x);
  RETURN TRUE
END RealOf;

PROCEDURE BooleanOf(d: Document; h: FyThin.Node; VAR v: BOOLEAN; VAR err: Error): BOOLEAN;
  VAR t: Text;
BEGIN
  err := NIL; GetText(h, t);
  IF IsTrueText(t) THEN v := TRUE
  ELSIF IsFalseText(t) THEN v := FALSE
  ELSE err := ValueError(d, h, "not a valid boolean", t); RETURN FALSE
  END;
  RETURN TRUE
END BooleanOf;

(* TRUE if n is null: an empty plain scalar ("key:" with nothing
   after), or a plain scalar whose text is ~, null, Null or NULL. A
   quoted scalar is a string, never null, as in YAML's core schema
   (alibfyaml counts a quoted "null" as null). Any kind of node may be
   asked; an alias is never null (its text is the anchor's name, and
   asking libfyaml reads uninitialised memory -- slibfyaml, under
   valgrind). *)
PROCEDURE (n: Node) IsNullValue*(): BOOLEAN;
  VAR t: Text;
BEGIN
  Live(n);
  IF FyThin.NodeIsAlias(n.handle) THEN RETURN FALSE END;
  IF FyThin.NodeIsNull(n.handle) THEN RETURN TRUE END;
  IF ~FyThin.NodeIsScalar(n.handle) OR ~FyThin.NodeIsPlain(n.handle) THEN RETURN FALSE END;
  GetText(n.handle, t);
  RETURN IsNullText(t)
END IsNullValue;

(* Whether the text fits each grammar (without checking the range).
   FALSE for a sequence or mapping. *)
PROCEDURE (n: Node) IsInteger*(): BOOLEAN;
  VAR t: Text; v: LONGINT; overflow: BOOLEAN;
BEGIN
  IF ~n.IsScalar() THEN RETURN FALSE END;
  GetText(n.handle, t);
  RETURN TextInt(t, v, overflow)
END IsInteger;

PROCEDURE (n: Node) IsReal*(): BOOLEAN;
  VAR t: Text;
BEGIN
  IF ~n.IsScalar() THEN RETURN FALSE END;
  GetText(n.handle, t);
  IF t.big = NIL THEN RETURN IsFloat(t.buf, t.len) ELSE RETURN IsFloat(t.big^, t.len) END
END IsReal;

PROCEDURE (n: Node) IsBoolean*(): BOOLEAN;
  VAR t: Text;
BEGIN
  IF ~n.IsScalar() THEN RETURN FALSE END;
  GetText(n.handle, t);
  RETURN IsTrueText(t) OR IsFalseText(t)
END IsBoolean;

(* The typed value of scalar n (halts with AssertKind for a sequence
   or mapping). FALSE and a DataError if the text doesn't fit. *)
PROCEDURE (n: Node) LongIntValue*(VAR v: LONGINT; VAR err: Error): BOOLEAN;
BEGIN ASSERT(n.IsScalar(), AssertKind); RETURN LongIntOf(n.doc, n.handle, v, err)
END LongIntValue;

PROCEDURE (n: Node) IntegerValue*(VAR v: INTEGER; VAR err: Error): BOOLEAN;
BEGIN ASSERT(n.IsScalar(), AssertKind); RETURN IntegerOf(n.doc, n.handle, v, err)
END IntegerValue;

PROCEDURE (n: Node) LongRealValue*(VAR v: LONGREAL; VAR err: Error): BOOLEAN;
BEGIN ASSERT(n.IsScalar(), AssertKind); RETURN LongRealOf(n.doc, n.handle, v, err)
END LongRealValue;

(* A value beyond MAX(REAL) is out of range even if it would round
   down to MAX(REAL). *)
PROCEDURE (n: Node) RealValue*(VAR v: REAL; VAR err: Error): BOOLEAN;
BEGIN ASSERT(n.IsScalar(), AssertKind); RETURN RealOf(n.doc, n.handle, v, err)
END RealValue;

PROCEDURE (n: Node) BooleanValue*(VAR v: BOOLEAN; VAR err: Error): BOOLEAN;
BEGIN ASSERT(n.IsScalar(), AssertKind); RETURN BooleanOf(n.doc, n.handle, v, err)
END BooleanValue;

(* ---- Mapping fields ----

   Value(key) plus a typed accessor, split into a required form
   (...Field: a missing key is a MissingKey error) and an optional one
   (...FieldOr: a missing key gives default). A default stands in only
   for a missing key: a key that is present but whose value isn't a
   scalar, or doesn't fit the type, is a DataError in both forms. The
   receiver must be a mapping (else AssertKind). *)

PROCEDURE Missing(m: Node; VAR key: ARRAY OF CHAR): Error;
  VAR t: String; len: LONGINT;
BEGIN
  t := NIL; len := 0;
  Append(t, len, 'missing required key "'); Append(t, len, key); Append(t, len, '"');
  RETURN NodeError(MissingKey, m, 0, t^)
END Missing;

(* The scalar value for key, as a handle: no Node is made, since the
   caller only converts it. 0 if there is none, with err: a MissingKey
   if required, else NIL. 0 and a DataError if the value isn't a
   scalar, located at its key. *)
PROCEDURE FieldHandle(m: Node; VAR key: ARRAY OF CHAR; required: BOOLEAN; VAR err: Error): FyThin.Node;
  VAR h: FyThin.Node;
BEGIN
  err := NIL;
  ASSERT(m.IsMapping(), AssertKind);
  h := FyThin.NodeMappingLookupValueByString(m.handle, SYSTEM.ADR(key[0]), Length(key));
  IF h = 0 THEN
    IF required THEN err := Missing(m, key) END;
    RETURN 0
  END;
  IF ~FyThin.NodeIsScalar(h) THEN
    err := NodeError(DataError, NewNode(m.doc, h),
      FyThin.NodeMappingLookupKeyByString(m.handle, SYSTEM.ADR(key[0]), Length(key)),
      "not a scalar value");
    RETURN 0
  END;
  RETURN h
END FieldHandle;

(* The value for key, of any kind; NIL and a MissingKey error if there
   is none. *)
PROCEDURE (m: Node) Required*(key: ARRAY OF CHAR; VAR err: Error): Node;
  VAR v: Node;
BEGIN
  err := NIL; v := m.Value(key);
  IF v = NIL THEN err := Missing(m, key) END;
  RETURN v
END Required;

PROCEDURE (m: Node) LongIntField*(key: ARRAY OF CHAR; VAR v: LONGINT; VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN h := FieldHandle(m, key, TRUE, err); RETURN (h # 0) & LongIntOf(m.doc, h, v, err)
END LongIntField;

PROCEDURE (m: Node) LongIntFieldOr*(key: ARRAY OF CHAR; default: LONGINT; VAR v: LONGINT;
                                     VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN
  h := FieldHandle(m, key, FALSE, err);
  IF h # 0 THEN RETURN LongIntOf(m.doc, h, v, err) END;
  IF err = NIL THEN v := default END;
  RETURN err = NIL
END LongIntFieldOr;

PROCEDURE (m: Node) IntegerField*(key: ARRAY OF CHAR; VAR v: INTEGER; VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN h := FieldHandle(m, key, TRUE, err); RETURN (h # 0) & IntegerOf(m.doc, h, v, err)
END IntegerField;

PROCEDURE (m: Node) IntegerFieldOr*(key: ARRAY OF CHAR; default: INTEGER; VAR v: INTEGER;
                                     VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN
  h := FieldHandle(m, key, FALSE, err);
  IF h # 0 THEN RETURN IntegerOf(m.doc, h, v, err) END;
  IF err = NIL THEN v := default END;
  RETURN err = NIL
END IntegerFieldOr;

PROCEDURE (m: Node) LongRealField*(key: ARRAY OF CHAR; VAR v: LONGREAL; VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN h := FieldHandle(m, key, TRUE, err); RETURN (h # 0) & LongRealOf(m.doc, h, v, err)
END LongRealField;

PROCEDURE (m: Node) LongRealFieldOr*(key: ARRAY OF CHAR; default: LONGREAL; VAR v: LONGREAL;
                                      VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN
  h := FieldHandle(m, key, FALSE, err);
  IF h # 0 THEN RETURN LongRealOf(m.doc, h, v, err) END;
  IF err = NIL THEN v := default END;
  RETURN err = NIL
END LongRealFieldOr;

PROCEDURE (m: Node) RealField*(key: ARRAY OF CHAR; VAR v: REAL; VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN h := FieldHandle(m, key, TRUE, err); RETURN (h # 0) & RealOf(m.doc, h, v, err)
END RealField;

PROCEDURE (m: Node) RealFieldOr*(key: ARRAY OF CHAR; default: REAL; VAR v: REAL;
                                  VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN
  h := FieldHandle(m, key, FALSE, err);
  IF h # 0 THEN RETURN RealOf(m.doc, h, v, err) END;
  IF err = NIL THEN v := default END;
  RETURN err = NIL
END RealFieldOr;

PROCEDURE (m: Node) BooleanField*(key: ARRAY OF CHAR; VAR v: BOOLEAN; VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN h := FieldHandle(m, key, TRUE, err); RETURN (h # 0) & BooleanOf(m.doc, h, v, err)
END BooleanField;

PROCEDURE (m: Node) BooleanFieldOr*(key: ARRAY OF CHAR; default: BOOLEAN; VAR v: BOOLEAN;
                                     VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN
  h := FieldHandle(m, key, FALSE, err);
  IF h # 0 THEN RETURN BooleanOf(m.doc, h, v, err) END;
  IF err = NIL THEN v := default END;
  RETURN err = NIL
END BooleanFieldOr;

(* A copy of scalar h's text, untrimmed, as Scalar gives it. *)
PROCEDURE ScalarString(h: FyThin.Node): String;
  VAR p, len: SYSTEM.ADDRESS;
BEGIN
  p := FyThin.NodeGetScalar(h, len);
  IF p = 0 THEN len := 0 END;
  RETURN FromBytes(p, len)
END ScalarString;

(* The scalar's text as Scalar gives it (not trimmed). *)
PROCEDURE (m: Node) StringField*(key: ARRAY OF CHAR; VAR s: String; VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN
  h := FieldHandle(m, key, TRUE, err);
  IF h = 0 THEN RETURN FALSE END;
  s := ScalarString(h);
  RETURN TRUE
END StringField;

PROCEDURE (m: Node) StringFieldOr*(key: ARRAY OF CHAR; default: ARRAY OF CHAR; VAR s: String;
                                    VAR err: Error): BOOLEAN;
  VAR h: FyThin.Node;
BEGIN
  h := FieldHandle(m, key, FALSE, err);
  IF h # 0 THEN s := ScalarString(h); RETURN TRUE END;
  IF err = NIL THEN s := FromChars(default) END;
  RETURN err = NIL
END StringFieldOr;

(* ---- Aliases, tags, styles, locations ---- *)

(* TRUE for an unresolved alias ("*name"), which exists only in a
   document parsed with NoResolve and not yet resolved. An alias
   counts as a scalar whose text is the anchor's name ("b" for *b). *)
PROCEDURE (n: Node) IsAlias*(): BOOLEAN;
BEGIN Live(n); RETURN FyThin.NodeIsAlias(n.handle)
END IsAlias;

(* The explicit tag, verbatim ("!mytag", "!!str"), or "" if n has
   none. libfyaml doesn't resolve implicit tags. *)
PROCEDURE (n: Node) Tag*(): String;
  VAR p, len: SYSTEM.ADDRESS;
BEGIN
  Live(n);
  p := FyThin.NodeGetTag(n.handle, len);
  IF p = 0 THEN len := 0 END;
  RETURN FromBytes(p, len)
END Tag;

(* How n is written: one of the Style* constants. *)
PROCEDURE (n: Node) Style*(): INTEGER;
  VAR s: INTEGER;
BEGIN
  Live(n);
  s := FyThin.NodeGetStyle(n.handle);
  IF s = FyThin.StyleFlow() THEN RETURN StyleFlow
  ELSIF s = FyThin.StyleBlock() THEN RETURN StyleBlock
  ELSIF s = FyThin.StylePlain() THEN RETURN StylePlain
  ELSIF s = FyThin.StyleSingleQuoted() THEN RETURN StyleSingleQuoted
  ELSIF s = FyThin.StyleDoubleQuoted() THEN RETURN StyleDoubleQuoted
  ELSIF s = FyThin.StyleLiteral() THEN RETURN StyleLiteral
  ELSIF s = FyThin.StyleFolded() THEN RETURN StyleFolded
  ELSE ASSERT(s = FyThin.StyleAlias()); RETURN StyleAlias
  END
END Style;

(* The 1-based line and column where scalar n's text starts in the
   input; FALSE if n has no location. Only scalars (and aliases: the
   name after "*") have one. A block scalar's (| or >) is where its
   first content line starts. A scalar made by CreateScalar has none;
   and because libfyaml gives it the same 0:0 mark as input's very
   first byte, once CreateScalar has been called on a document a
   parsed scalar at 1:1 reports none either. *)
PROCEDURE (n: Node) Location*(VAR line, column: INTEGER): BOOLEAN;
BEGIN Live(n); RETURN ScalarLocation(n.doc, n.handle, line, column)
END Location;

PROCEDURE (n: Node) HasLocation*(): BOOLEAN;
  VAR line, column: INTEGER;
BEGIN RETURN n.Location(line, column)
END HasLocation;

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
  d.created := TRUE;
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
    END;
    err.path := file
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
  NEW(err); err.kind := DuplicateKey; err.file := path; err.line := 0; err.column := 0; err.path := path;
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
