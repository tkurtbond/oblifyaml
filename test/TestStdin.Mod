MODULE TestStdin; (* Fyaml.ParseStdin, fed test/TestStdin.stdin by make test *)

(* Standard input can be read only once per process, so each stdin
   case is its own program: TestStdinError (a malformed document) and
   TestStdinStream (FyamlStreams.OpenStdin). *)

IMPORT Heap, Fyaml, Check;

TYPE Junk = POINTER TO ARRAY OF CHAR;

VAR
  d, again: Fyaml.Document; err: Fyaml.Error;
  root, item, n: Fyaml.Node;
  size: LONGINT; ok: BOOLEAN;

PROCEDURE Churn;
  VAR i: INTEGER; j: Junk;
BEGIN
  FOR i := 1 TO 200 DO NEW(j, 1000); j[0] := "x" END;
  Heap.GC(TRUE)
END Churn;

PROCEDURE Is(s: Fyaml.String; lit: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN (s # NIL) & (s^ = lit)
END Is;

(* s is exactly the one line lit, newline-terminated. *)
PROCEDURE IsLine(s: Fyaml.String; lit: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF s = NIL THEN RETURN FALSE END;
  i := 0;
  WHILE (i < LEN(lit)) & (lit[i] # 0X) DO
    IF (i >= LEN(s^)) OR (s[i] # lit[i]) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN (i + 1 < LEN(s^)) & (s[i] = 0AX) & (s[i + 1] = 0X)
END IsLine;

BEGIN
  d := Fyaml.ParseStdin(err);
  Check.Check((d # NIL) & (err = NIL), "ParseStdin parses standard input");
  Churn;  (* nothing libfyaml spans into may be collected *)
  root := d.Root();
  item := root.Value("item");
  n := item.Value("name");
  Check.Check((n # NIL) & n.ScalarIs("widget"), "merge key resolved by default");
  ok := item.LongIntField("size", size, err);
  Check.Check(ok & (size = 4), "the merged mapping's own size wins");
  n := root.Value("text");
  Check.Check((n # NIL) & n.ScalarIs("a scalar long enough to be well past the sixty-four byte text buffer"),
              "a long scalar reads back intact after a GC");
  n := root.Value("name");
  Check.Check(n = NIL, "only the first document is kept");
  d.Close;

  (* stdin is now at its end *)
  again := Fyaml.ParseStdin(err);
  Check.Check((again = NIL) & (err # NIL) & (err.kind = Fyaml.ParseError), "a second ParseStdin: ParseError");
  Check.Check((err # NIL) & Is(err.file, Fyaml.stdinName) & IsLine(err.msg, "<stdin>: error: document failed to parse"),
              "  naming <stdin>");
  Check.Summary
END TestStdin.
