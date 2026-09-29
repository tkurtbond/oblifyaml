MODULE TestStreams; (* FyamlStreams: several documents from one input *)

(* Port of alibfyaml's test_streams.adb on its streams.yaml, plus what
   a GC host adds: a stream finalized by the GC, documents that
   outlive a closed and collected stream (string and file), the
   read-ahead document freed by Close (checked under make valgrind),
   the Next-only loop, NoResolve, and exact error text. *)

IMPORT Heap, Fyaml, FyamlStreams, Check;

TYPE Junk = POINTER TO ARRAY OF CHAR;

VAR err: Fyaml.Error;

PROCEDURE Churn;
  VAR i: INTEGER; j: Junk;
BEGIN
  FOR i := 1 TO 200 DO NEW(j, 1000); j[0] := "x" END;
  Heap.GC(TRUE)
END Churn;

(* spec with each "|" turned into a newline, into buf. *)
PROCEDURE Lines(spec: ARRAY OF CHAR; VAR buf: ARRAY OF CHAR);
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i < LEN(spec)) & (spec[i] # 0X) DO
    IF spec[i] = "|" THEN buf[i] := 0AX ELSE buf[i] := spec[i] END;
    INC(i)
  END;
  buf[i] := 0X
END Lines;

PROCEDURE HasPrefix(s: Fyaml.String; prefix: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF s = NIL THEN RETURN FALSE END;
  i := 0;
  WHILE (i < LEN(prefix)) & (prefix[i] # 0X) DO
    IF (i >= LEN(s^)) OR (s[i] # prefix[i]) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END HasPrefix;

(* d's /name is exactly name. *)
PROCEDURE NameIs(d: Fyaml.Document; name: ARRAY OF CHAR): BOOLEAN;
  VAR root, n: Fyaml.Node;
BEGIN
  IF d = NIL THEN RETURN FALSE END;
  root := d.Root(); n := root.Value("name");
  RETURN (n # NIL) & n.ScalarIs(name)
END NameIs;

(* A document from a string stream that is closed and dropped here. *)
PROCEDURE FromDroppedStringStream(): Fyaml.Document;
  VAR s: FyamlStreams.Stream; d: Fyaml.Document; e: Fyaml.Error;
BEGIN
  s := FyamlStreams.OpenString("name: widget", e);
  d := s.Next(e);
  s.Close;
  RETURN d
END FromDroppedStringStream;

PROCEDURE FromDroppedFileStream(): Fyaml.Document;
  VAR s: FyamlStreams.Stream; d: Fyaml.Document; e: Fyaml.Error;
BEGIN
  s := FyamlStreams.OpenFile("streams.yaml", e);
  d := s.Next(e);
  s.Close;
  RETURN d
END FromDroppedFileStream;

PROCEDURE OpenAndDrop;
  VAR s: FyamlStreams.Stream; e: Fyaml.Error;
BEGIN s := FyamlStreams.OpenString("a: 1", e)
END OpenAndDrop;

PROCEDURE Run;
  VAR s: FyamlStreams.Stream; d: Fyaml.Document; root: Fyaml.Node; count: INTEGER; v: INTEGER;
    ok: BOOLEAN; text: ARRAY 128 OF CHAR; before: LONGINT;
BEGIN
  d := Fyaml.ParseFile("streams.yaml", err);
  Check.Check(NameIs(d, "first"), "ParseFile sees only the first document");
  d.Close;

  (* All three, in order *)
  s := FyamlStreams.OpenFile("streams.yaml", err);
  Check.Check((s # NIL) & (err = NIL) & s.IsOpen(), "OpenFile");
  count := 0; ok := TRUE;
  WHILE s.HasNext(err) DO
    INC(count);
    d := s.Next(err);
    root := d.Root();
    ok := ok & root.IntegerField("value", v, err) & (v = count);
    IF count = 1 THEN ok := ok & NameIs(d, "first")
    ELSIF count = 2 THEN ok := ok & NameIs(d, "second")
    ELSE ok := ok & NameIs(d, "third")
    END;
    d.Close
  END;
  Check.Check(ok & (count = 3), "OpenFile yields the 3 documents in order");
  Check.Check(err = NIL, "the end is not an error");
  Check.Check(~s.HasNext(err) & (err = NIL), "HasNext stays FALSE once exhausted");
  d := s.Next(err);
  Check.Check((d = NIL) & (err = NIL), "Next at the end: NIL, err NIL");
  s.Close; s.Close;
  Check.Check(~s.IsOpen(), "Close is idempotent");

  (* A document's errors name its stream's input *)
  s := FyamlStreams.OpenFile("streams.yaml", err);
  d := s.Next(err); root := d.Root();
  ok := root.IntegerField("name", v, err);
  Check.Check(~ok & HasPrefix(err.msg, 'streams.yaml:2:7: error: /name: not a valid integer: "first"'),
              "a stream document's DataError names the file");
  d.Close; s.Close;

  (* OpenString, and the Next-only loop *)
  Lines("---|name: a|---|name: b|", text);
  s := FyamlStreams.OpenString(text, err);
  count := 0; ok := TRUE;
  LOOP
    d := s.Next(err);
    IF d = NIL THEN EXIT END;
    INC(count);
    IF count = 1 THEN ok := ok & NameIs(d, "a") ELSE ok := ok & NameIs(d, "b") END;
    d.Close
  END;
  Check.Check(ok & (count = 2) & (err = NIL), "OpenString, Next alone: 2 documents, then NIL with err NIL");
  s.Close;

  s := FyamlStreams.OpenString("", err);
  Check.Check(~s.HasNext(err) & (err = NIL), "an empty stream has no documents, and no error");
  s.Close;

  Lines("---|name: only|", text);
  s := FyamlStreams.OpenString(text, err);
  d := s.Next(err);
  Check.Check(NameIs(d, "only"), "a one-document stream: the document");
  d.Close;
  Check.Check(~s.HasNext(err) & (err = NIL), "  ...then the end");
  s.Close;

  (* A malformed document mid-stream is an error, then the stream is finished *)
  Lines("---|name: ok|---|[unterminated flow sequence|---|name: third|", text);
  s := FyamlStreams.OpenString(text, err);
  d := s.Next(err);
  Check.Check(NameIs(d, "ok"), "bad stream: the first document is fine");
  d.Close;
  Check.Check(~s.HasNext(err) & (err # NIL) & (err.kind = Fyaml.ParseError), "the malformed one: HasNext FALSE + ParseError");
  Check.Check(HasPrefix(err.msg, "(string-in-memory):5:1: error: "), "  located, and named (string-in-memory)");
  Check.Check(~s.HasNext(err) & (err = NIL), "HasNext again: FALSE, and not the same error again");
  d := s.Next(err);
  Check.Check((d = NIL) & (err = NIL), "the third document is unreachable: Next is NIL, err NIL");
  s.Close;

  s := FyamlStreams.OpenString(text, err);
  d := s.Next(err); d.Close;
  d := s.Next(err);
  Check.Check((d = NIL) & (err # NIL) & (err.kind = Fyaml.ParseError), "Next alone reports the malformed document too");
  s.Close;

  (* Files *)
  s := FyamlStreams.OpenFile("no-such-file.yaml", err);
  Check.Check((s = NIL) & (err.kind = Fyaml.FileError)
              & HasPrefix(err.msg, "no-such-file.yaml: error: No such file or directory"),
              "OpenFile of a missing file: NIL + FileError");

  (* Options *)
  Lines("a: &x 1|b: *x|", text);
  s := FyamlStreams.OpenString(text, err);
  d := s.Next(err); root := d.Root(); root := root.Value("b");
  Check.Check(~root.IsAlias() & root.ScalarIs("1"), "by default a stream resolves aliases");
  d.Close; s.Close;
  s := FyamlStreams.OpenStringWith(text, {Fyaml.NoResolve}, err);
  d := s.Next(err); root := d.Root(); root := root.Value("b");
  Check.Check(root.IsAlias(), "with NoResolve it leaves them");
  d.Close; s.Close;

  (* Lifetimes *)
  d := FromDroppedStringStream();
  Churn; Churn;
  Check.Check(NameIs(d, "widget"), "a document outlives its closed, collected string stream");
  d.Close;
  d := FromDroppedFileStream();
  Churn; Churn;
  Check.Check(NameIs(d, "first"), "a document outlives its closed, collected file stream");
  d.Close;

  before := Fyaml.openDocuments;
  s := FyamlStreams.OpenFile("streams.yaml", err);
  Check.Check(s.HasNext(err), "(read one document ahead)");
  s.Close;
  Check.Check(Fyaml.openDocuments = before, "a read-ahead document is not counted (make valgrind checks Close frees it)");

  Churn;
  before := FyamlStreams.openStreams;
  OpenAndDrop;
  Check.Check(FyamlStreams.openStreams = before + 1, "(opened one more stream)");
  Churn;
  Check.Check(FyamlStreams.openStreams = before, "an unreachable Stream is finalized by the GC")
END Run;

BEGIN
  Run;
  Check.Summary
END TestStreams.
