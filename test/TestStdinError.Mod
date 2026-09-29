MODULE TestStdinError; (* Fyaml.ParseStdin on a malformed document, fed test/TestStdinError.stdin *)

(* libfyaml labels a stdin document's errors "<stream>"; Fyaml reports
   gcc's "<stdin>" instead (confirmed live). *)

IMPORT Fyaml, Check;

VAR d: Fyaml.Document; err: Fyaml.Error;

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

BEGIN
  d := Fyaml.ParseStdinWith({Fyaml.NoResolve}, err);
  Check.Check((d = NIL) & (err # NIL) & (err.kind = Fyaml.ParseError), "malformed stdin: ParseError");
  IF err # NIL THEN
    Check.Check((err.file # NIL) & (err.file^ = Fyaml.stdinName), "  err.file is <stdin>");
    Check.Check((err.line = 3) & (err.column = 1), "  at 3:1");
    Check.Check(HasPrefix(err.msg, "<stdin>:3:1: error: flow sequence without a closing bracket"),
                "  gcc-format message naming <stdin>")
  END;
  Check.Summary
END TestStdinError.
