MODULE ExampleValueError; (* Reporting a malformed value *)

(* The document parses, but a typed field doesn't fit its type. The
   DataError's msg is already a gcc diagnostic with the value's line
   and column and its path, so, again, reporting it is printing it:

     value_error.yaml:2:8: error: /count: not a valid integer: "banana"

   err.line, err.column and err.path hold the same facts separately,
   for a program that wants to format them its own way. alibfyaml's
   version of this example has to look the node up first and ask it
   for its Location, because its Data_Error carries only the text.

   Run: ExampleValueError [file]   (default value_error.yaml)
   Exit status 1 if the value was missing or malformed. *)

IMPORT Modules, Out, Platform, Fyaml;

VAR failed: BOOLEAN;

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

PROCEDURE CheckCount(d: Fyaml.Document; err: Fyaml.Error);
  VAR root: Fyaml.Node; count: INTEGER;
BEGIN
  IF d = NIL THEN Out.String(err.msg^); failed := TRUE; RETURN END;
  root := d.Root();
  IF root.IntegerField("count", count, err) THEN
    Out.String("count = "); Out.Int(count, 0); Out.Ln
  ELSE
    Out.String(err.msg^);
    Out.String("  (line "); Out.Int(err.line, 0); Out.String(", column "); Out.Int(err.column, 0);
    Out.String(", path "); Out.String(err.path^); Out.String(")"); Out.Ln;
    failed := TRUE
  END;
  d.Close
END CheckCount;

PROCEDURE Run;
  VAR path, text: ARRAY 256 OF CHAR; d: Fyaml.Document; err: Fyaml.Error;
BEGIN
  path := "value_error.yaml";
  IF Modules.ArgCount > 1 THEN Modules.GetArg(1, path) END;

  Out.String("=== Parsing from a file ==="); Out.Ln;
  d := Fyaml.ParseFile(path, err); CheckCount(d, err);

  Out.Ln; Out.String("=== Parsing the same text from a string ==="); Out.Ln;
  Lines("name: widget|count: banana|", text);  (* value_error.yaml's content *)
  d := Fyaml.ParseString(text, err); CheckCount(d, err)
END Run;

BEGIN
  failed := FALSE;
  Run;
  Out.Flush;  (* Out buffers until Ln; Platform.Exit would drop the rest *)
  IF failed THEN Platform.Exit(1) END
END ExampleValueError.
