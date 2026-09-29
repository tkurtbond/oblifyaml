MODULE ExampleConfig; (* The README's example: read, check, change, emit *)

(* Reads config.yaml, takes typed values from it with gcc-style error
   reports, changes a setting, and prints the result. Built and run by
   `make test`, so the README's copy of it stays correct.

   Run: ExampleConfig [file]   (default config.yaml) *)

IMPORT Modules, Out, Fyaml;

PROCEDURE Run;
  VAR path: ARRAY 256 OF CHAR;
    d: Fyaml.Document; err: Fyaml.Error;
    root, server, origins, origin, patch: Fyaml.Node; it: Fyaml.ItemIter;
    host, text, yaml: Fyaml.String; port, timeout: INTEGER; ssl: BOOLEAN;
BEGIN
  path := "config.yaml";
  IF Modules.ArgCount > 1 THEN Modules.GetArg(1, path) END;

  d := Fyaml.ParseFile(path, err);
  IF d = NIL THEN Out.String(err.msg^); RETURN END;   (* gcc-style, one line per error *)

  root := d.Root();
  server := root.Value("server");                     (* NIL if absent *)
  IF (server = NIL)
     OR ~server.StringField("host", host, err)        (* required *)
     OR ~server.IntegerField("port", port, err)
     OR ~server.BooleanFieldOr("ssl", FALSE, ssl, err) (* optional, with a default *)
  THEN
    IF err # NIL THEN Out.String(err.msg^) ELSE Out.String("no server section"); Out.Ln END;
    d.Close; RETURN
  END;
  Out.String("server: "); Out.String(host^); Out.String(":"); Out.Int(port, 0);
  IF ssl THEN Out.String(" (ssl)") END; Out.Ln;

  origins := root.ByPath("/allowed_origins");
  origins.Items(it);
  WHILE it.Next(origin) DO text := origin.Scalar(); Out.String("origin: "); Out.String(text^); Out.Ln END;

  (* Merge {timeout: 45} into /server. InsertAt consumes patch and
     makes every Node taken from d before it invalid: look them up
     again afterwards. *)
  patch := d.CreateMapping();
  IF ~patch.AppendPair(d.CreateScalar("timeout"), d.CreateScalar("45"), err)
     OR ~d.InsertAt("/server", patch, err) THEN
    Out.String(err.msg^); d.Close; RETURN
  END;
  root := d.Root(); server := root.Value("server");
  IF server.IntegerField("timeout", timeout, err) THEN
    Out.String("timeout now "); Out.Int(timeout, 0); Out.Ln
  END;

  yaml := d.ToYAML(Fyaml.emitModeFlowOneline, err);
  IF yaml # NIL THEN Out.String(yaml^) END;
  d.Close
END Run;

BEGIN Run
END ExampleConfig.
