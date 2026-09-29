MODULE FyamlStreams; (* Several YAML documents from one input *)

(* Fyaml.ParseString/ParseFile read only the first of several
   "---"-separated documents. A Stream reads them all, one at a time,
   with libfyaml's streaming parser:

     s := FyamlStreams.OpenFile("many.yaml", err);
     IF s # NIL THEN
       WHILE s.HasNext(err) DO d := s.Next(err); ...; d.Close END;
       IF err # NIL THEN (* a malformed document *) END;
       s.Close
     END

   or, with Next alone: LOOP d := s.Next(err); IF d = NIL THEN EXIT
   END; ... END -- NIL with err = NIL is the end, NIL with err # NIL a
   parse error.

   Each document is an ordinary Fyaml.Document, independent of the
   stream: close it when done, and it stays usable after the stream is
   closed (a string stream's text is shared with its documents, and
   the GC keeps it for as long as any of them lives).

   After a parse error the stream is finished: libfyaml can't resync
   to the documents after a malformed one (confirmed live), so
   HasNext is FALSE and Next NIL from then on, with err NIL.

   Ownership as for Fyaml.Document: Close is idempotent, and a GC
   finalizer closes a stream that becomes unreachable without it. *)

IMPORT SYSTEM, Heap, FyThin, Fyaml;

TYPE
  Stream* = POINTER TO StreamDesc;
  StreamDesc* = RECORD
    parser: FyThin.Parser;      (* 0 once closed *)
    diag: FyThin.Diag;          (* the parser's: tells an error from the end *)
    buffer: Fyaml.String;       (* OpenString text: the parser and documents span into it *)
    path: Fyaml.String;         (* OpenFile path: libfyaml opens the file lazily *)
    name: Fyaml.String;         (* labels documents' errors *)
    pending: FyThin.Document;   (* read ahead by HasNext, not yet taken *)
    peeked: BOOLEAN;            (* pending is valid (0 = the end or an error) *)
    finished: BOOLEAN           (* the end, or an error, was reached *)
  END;

VAR
  openStreams-: LONGINT;  (* streams made and not yet closed or finalized *)

PROCEDURE Length(VAR s: ARRAY OF CHAR): LONGINT;
  VAR n: LONGINT;
BEGIN n := 0; WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END; RETURN n
END Length;

PROCEDURE Copy(a: ARRAY OF CHAR): Fyaml.String;
  VAR s: Fyaml.String; n, i: LONGINT;
BEGIN
  n := Length(a); NEW(s, n + 1);
  FOR i := 0 TO n - 1 DO s[i] := a[i] END;
  s[n] := 0X;
  RETURN s
END Copy;

PROCEDURE CloseHandle(s: Stream);
  VAR p: FyThin.Parser;
BEGIN
  IF s.parser # 0 THEN
    p := s.parser; s.parser := 0;  (* dead before freed: no second free *)
    IF s.peeked & (s.pending # 0) THEN FyThin.DocumentDestroy(s.pending) END;
    s.pending := 0; s.peeked := FALSE; s.finished := TRUE;
    FyThin.ParserDestroy(p);
    FyThin.DiagDestroy(s.diag); s.diag := 0;
    DEC(openStreams)
  END
END CloseHandle;

(* GC finalizer; see Fyaml.FinalizeDocument. *)
PROCEDURE FinalizeStream(obj: SYSTEM.PTR);
BEGIN CloseHandle(SYSTEM.VAL(Stream, obj))
END FinalizeStream;

(* A stream on a new parser, with no input yet; NIL if libfyaml fails
   to allocate one. *)
PROCEDURE New(options: SET): Stream;
  VAR s: Stream; diag: FyThin.Diag; p: FyThin.Parser;
BEGIN
  diag := FyThin.DiagCreate();
  ASSERT(diag # 0);  (* allocation failure *)
  FyThin.DiagSetCollectErrors(diag, TRUE);
  p := FyThin.ParserCreate(~(Fyaml.NoResolve IN options), diag);
  ASSERT(p # 0);
  NEW(s); s.parser := p; s.diag := diag; s.buffer := NIL; s.path := NIL; s.name := NIL;
  s.pending := 0; s.peeked := FALSE; s.finished := FALSE;
  INC(openStreams);
  Heap.RegisterFinalizer(s, FinalizeStream);
  RETURN s
END New;

(* A stream over text (up to its first 0X), with options as for
   Fyaml.ParseStringWith. text is copied, since libfyaml doesn't copy
   it. err is always NIL: errors surface from HasNext/Next. *)
PROCEDURE OpenStringWith*(text: ARRAY OF CHAR; options: SET; VAR err: Fyaml.Error): Stream;
  VAR s: Stream; len: LONGINT;
BEGIN
  err := NIL;
  s := New(options);
  s.buffer := Copy(text); s.name := Copy(Fyaml.stringName);
  len := LEN(s.buffer^) - 1;
  ASSERT(FyThin.ParserSetString(s.parser, SYSTEM.ADR(s.buffer[0]), len) = 0);
  RETURN s
END OpenStringWith;

PROCEDURE OpenString*(text: ARRAY OF CHAR; VAR err: Fyaml.Error): Stream;
BEGIN RETURN OpenStringWith(text, {}, err)
END OpenString;

(* A stream over the file at path. NIL and a FileError if it can't be
   opened for reading. *)
PROCEDURE OpenFileWith*(path: ARRAY OF CHAR; options: SET; VAR err: Fyaml.Error): Stream;
  VAR s: Stream; p: Fyaml.String;
BEGIN
  p := Copy(path);
  err := Fyaml.Unreadable(p);
  IF err # NIL THEN RETURN NIL END;
  s := New(options);
  s.path := p; s.name := p;
  ASSERT(FyThin.ParserSetInputFile(s.parser, SYSTEM.ADR(s.path[0])) = 0);
  RETURN s
END OpenFileWith;

PROCEDURE OpenFile*(path: ARRAY OF CHAR; VAR err: Fyaml.Error): Stream;
BEGIN RETURN OpenFileWith(path, {}, err)
END OpenFile;

(* Loads the next document into s.pending (0 at the end or on an
   error, with err set for an error). Nothing is loaded once finished:
   libfyaml has nothing more to give after an error. *)
PROCEDURE Fetch(s: Stream; VAR err: Fyaml.Error);
BEGIN
  err := NIL;
  ASSERT(s.parser # 0, Fyaml.AssertInvalid);
  s.peeked := TRUE; s.pending := 0;
  IF s.finished THEN RETURN END;
  s.pending := FyThin.ParseLoadDocument(s.parser);
  IF s.pending = 0 THEN
    s.finished := TRUE;
    IF FyThin.DiagGotError(s.diag) THEN
      err := Fyaml.DiagErrors(s.diag, s.buffer # NIL, s.name)
    END
  END
END Fetch;

(* TRUE if there is another document. It reads that document ahead,
   so a malformed one is reported here: FALSE and a ParseError. FALSE
   with err NIL is the end. *)
PROCEDURE (s: Stream) HasNext*(VAR err: Fyaml.Error): BOOLEAN;
BEGIN
  err := NIL;
  ASSERT(s.parser # 0, Fyaml.AssertInvalid);
  IF ~s.peeked THEN Fetch(s, err) END;
  RETURN s.pending # 0
END HasNext;

(* The next document, or NIL: at the end with err NIL, or with a
   ParseError for a malformed document. *)
PROCEDURE (s: Stream) Next*(VAR err: Fyaml.Error): Fyaml.Document;
  VAR h: FyThin.Document;
BEGIN
  err := NIL;
  ASSERT(s.parser # 0, Fyaml.AssertInvalid);
  IF ~s.peeked THEN Fetch(s, err) END;
  h := s.pending; s.pending := 0; s.peeked := FALSE;
  IF h = 0 THEN RETURN NIL END;
  RETURN Fyaml.Adopt(h, s.buffer, s.name)
END Next;

(* Frees the parser, and any document read ahead but not taken.
   Idempotent. Documents already taken are unaffected. *)
PROCEDURE (s: Stream) Close*;
BEGIN CloseHandle(s)
END Close;

PROCEDURE (s: Stream) IsOpen*(): BOOLEAN;
BEGIN RETURN s.parser # 0
END IsOpen;

BEGIN
  openStreams := 0
END FyamlStreams.
