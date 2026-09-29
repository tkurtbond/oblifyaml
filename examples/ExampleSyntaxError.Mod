MODULE ExampleSyntaxError; (* Reporting a YAML syntax error *)

(* A document that doesn't parse gives NIL and an Error whose msg is
   already in gcc's diagnostic format, one "file:line:column: error:
   text" line per error -- so reporting it is printing it. Parsed from
   a file, the file is its path; from a string, "(string-in-memory)".

   Run: ExampleSyntaxError [file]   (default malformed.yaml)
   Exit status 1 if anything failed to parse. *)

IMPORT Modules, Out, Platform, Fyaml;

VAR failed: BOOLEAN;

(* spec with each "|" turned into a newline. *)
PROCEDURE Lines(spec: ARRAY OF CHAR; VAR text: ARRAY OF CHAR);
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE spec[i] # 0X DO
    IF spec[i] = "|" THEN text[i] := 0AX ELSE text[i] := spec[i] END;
    INC(i)
  END;
  text[i] := 0X
END Lines;

PROCEDURE Report(d: Fyaml.Document; err: Fyaml.Error);
BEGIN
  IF d = NIL THEN Out.String(err.msg^); failed := TRUE
  ELSE Out.String("no errors"); Out.Ln; d.Close
  END
END Report;

PROCEDURE Run;
  VAR path, text: ARRAY 256 OF CHAR; d: Fyaml.Document; err: Fyaml.Error;
BEGIN
  path := "malformed.yaml";
  IF Modules.ArgCount > 1 THEN Modules.GetArg(1, path) END;

  Out.String("=== Parsing from a file ==="); Out.Ln;
  d := Fyaml.ParseFile(path, err); Report(d, err);

  Out.Ln; Out.String("=== Parsing the same text from a string ==="); Out.Ln;
  Lines("name: widget|bad: [1, 2|", text);  (* malformed.yaml's content *)
  d := Fyaml.ParseString(text, err); Report(d, err)
END Run;

BEGIN
  failed := FALSE;
  Run;
  Out.Flush;  (* Out buffers until Ln; Platform.Exit would drop the rest *)
  IF failed THEN Platform.Exit(1) END
END ExampleSyntaxError.
