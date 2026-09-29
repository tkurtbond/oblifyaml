MODULE TestStdinStream; (* FyamlStreams.OpenStdin, fed test/TestStdinStream.stdin *)

(* Three good documents, then a malformed one, then a good one that
   libfyaml can never reach. The documents come back one at a time,
   and outlive the stream (libfyaml copies what it reads from stdin
   into its own buffers). *)

IMPORT Heap, Fyaml, FyamlStreams, Check;

TYPE Junk = POINTER TO ARRAY OF CHAR;

VAR
  s: FyamlStreams.Stream; err: Fyaml.Error;
  d1, d2, d3, d4: Fyaml.Document;
  root, n: Fyaml.Node;

PROCEDURE Churn;
  VAR i: INTEGER; j: Junk;
BEGIN
  FOR i := 1 TO 200 DO NEW(j, 1000); j[0] := "x" END;
  Heap.GC(TRUE)
END Churn;

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

PROCEDURE NameIs(d: Fyaml.Document; name: ARRAY OF CHAR): BOOLEAN;
  VAR root, n: Fyaml.Node;
BEGIN
  IF d = NIL THEN RETURN FALSE END;
  root := d.Root(); n := root.Value("name");
  RETURN (n # NIL) & n.ScalarIs(name)
END NameIs;

BEGIN
  s := FyamlStreams.OpenStdin(err);
  Check.Check((s # NIL) & (err = NIL), "OpenStdin");
  Check.Check(s.HasNext(err) & (err = NIL), "HasNext before the first document");
  d1 := s.Next(err);
  d2 := s.Next(err);
  d3 := s.Next(err);
  Check.Check((err = NIL) & NameIs(d1, "one") & NameIs(d2, "two") & NameIs(d3, "three"),
              "three documents, in order");
  root := d3.Root(); n := root.Value("alias");
  Check.Check((n # NIL) & ~n.IsAlias() & n.ScalarIs("three"), "aliases resolved by default");

  d4 := s.Next(err);
  Check.Check((d4 = NIL) & (err # NIL) & (err.kind = Fyaml.ParseError), "the malformed fourth: ParseError");
  Check.Check((err # NIL) & HasPrefix(err.msg, "<stdin>:8:7: error: invalid multiline plain key"), "  located, and named <stdin>");
  Check.Check(~s.HasNext(err) & (err = NIL), "finished after the error");

  s.Close; s := NIL;
  Churn;
  Check.Check(FyamlStreams.openStreams = 0, "the stream is closed");
  Check.Check(NameIs(d1, "one") & NameIs(d3, "three"), "documents outlive the closed stream");
  d1.Close; d2.Close; d3.Close;
  Check.Summary
END TestStdinStream.
