MODULE TestParseErrors; (* Parse failures come back as Error objects *)

(* Port of alibfyaml's test_parse_errors.adb, plus the Error fields
   this binding adds (kind, file, line, column) and a missing file. *)

IMPORT Fyaml, Check;

PROCEDURE HasPrefix(s: Fyaml.String; prefix: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i < LEN(prefix)) & (prefix[i] # 0X) DO
    IF (i >= LEN(s^)) OR (s[i] # prefix[i]) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END HasPrefix;

PROCEDURE Run;
  VAR d: Fyaml.Document; err, stale: Fyaml.Error; n: Fyaml.Node;
BEGIN
  (* malformed.yaml: "bad: [1, 2" on line 2, unclosed at end of input *)
  d := Fyaml.ParseFile("malformed.yaml", err);
  Check.Check(d = NIL, "ParseFile on malformed input returns NIL");
  Check.Check(err # NIL, "ParseFile on malformed input returns an Error");
  IF err # NIL THEN
    Check.Check(err.kind = Fyaml.ParseError, "ParseFile error kind is ParseError");
    Check.Check(HasPrefix(err.msg, "malformed.yaml:"),
                "ParseFile error message names the file, gcc style");
    Check.Check(err.file^ = "malformed.yaml", "ParseFile error file field");
    Check.Check((err.line > 0) & (err.column > 0), "ParseFile error has line and column");
    Check.Check(err.msg[LEN(err.msg^) - 1] = 0X, "error message is 0X-terminated");
  END;

  d := Fyaml.ParseString("bad: [1, 2", err);
  Check.Check((d = NIL) & (err # NIL), "ParseString on malformed input returns NIL and an Error");
  IF err # NIL THEN
    Check.Check(HasPrefix(err.msg, "(string-in-memory):"),
                "ParseString error reports (string-in-memory), not libfyaml's address label")
  END;

  (* A fresh diag per call: no state carries over between failures. *)
  stale := err;
  d := Fyaml.ParseString("[1, 2", err);
  Check.Check((d = NIL) & (err # NIL) & (err # stale),
              "a second, independent failure also returns its own Error");

  d := Fyaml.ParseFile("no-such-file.yaml", err);
  Check.Check((d = NIL) & (err # NIL), "missing file returns NIL and an Error");
  IF err # NIL THEN
    Check.Check(err.kind = Fyaml.FileError, "missing file error kind is FileError");
    Check.Check(HasPrefix(err.msg, "no-such-file.yaml: error: No such file or directory"),
                "missing file message gives the path and the OS reason")
  END;

  err := stale;  (* success must reset err to NIL *)
  d := Fyaml.ParseString("ok: 1", err);
  Check.Check((d # NIL) & (err = NIL), "valid input after failures parses, err = NIL");
  IF d # NIL THEN
    n := d.Root(); n := n.Value("ok");
    Check.Check(n.ScalarIs("1"), "and reads back correctly");
    d.Close
  END
END Run;

BEGIN
  Run;
  Check.Summary
END TestParseErrors.
