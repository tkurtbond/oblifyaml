MODULE ExampleMissingField; (* Reporting a missing required key *)

(* A missing key has no node, so no location of its own: the
   MissingKey error names the file and the path of the mapping it is
   missing from,

     missing_field.yaml: error: /1: missing required key "count"

   which is exact about WHERE in the structure. To also give a line to
   jump to, this example borrows a sibling's location ("name", which
   every entry has) -- labelled "near", since it is the sibling's
   position, not the missing key's. Location is FALSE for a node with
   none (e.g. one built with CreateScalar), and then it is left out.

   Run: ExampleMissingField [file]   (default missing_field.yaml, two
   entries: "alpha" with a count, "beta" without one)
   Exit status 1 if any entry lacks a count. *)

IMPORT Modules, Out, Platform, Fyaml;

PROCEDURE Run(): BOOLEAN;
  VAR path: ARRAY 256 OF CHAR; d: Fyaml.Document; err: Fyaml.Error; root, item, name: Fyaml.Node;
    it: Fyaml.ItemIter; count, line, column: INTEGER; ok: BOOLEAN;
BEGIN
  path := "missing_field.yaml";
  IF Modules.ArgCount > 1 THEN Modules.GetArg(1, path) END;
  d := Fyaml.ParseFile(path, err);
  IF d = NIL THEN Out.String(err.msg^); RETURN FALSE END;
  ok := TRUE;
  root := d.Root(); root.Items(it);
  WHILE it.Next(item) DO
    IF item.IntegerField("count", count, err) THEN
      (* use count *)
    ELSIF err.kind = Fyaml.MissingKey THEN
      Out.String(err.msg^);
      name := item.Value("name");
      IF (name # NIL) & name.Location(line, column) THEN
        Out.String("  near "); Out.String(path); Out.String(":"); Out.Int(line, 0);
        Out.String(":"); Out.Int(column, 0); Out.Ln
      END;
      ok := FALSE
    ELSE  (* present but malformed: a DataError, already located *)
      Out.String(err.msg^); ok := FALSE
    END
  END;
  d.Close;
  RETURN ok
END Run;

BEGIN
  IF ~Run() THEN Out.Flush; Platform.Exit(1) END  (* Out buffers until Ln *)
END ExampleMissingField.
