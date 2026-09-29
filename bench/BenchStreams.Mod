MODULE BenchStreams; (* Many small documents from one stream *)

(* Counterpart of alibfyaml's bench_streams.adb, on the same generated
   input (gen_manydocs.py): read each document, take its id and name,
   and let it go. Stresses Document creation and destruction.

   Run: BenchStreams [file] [gc]. By default each document is Closed
   explicitly; with "gc" it is only dropped, so the GC finalizer frees
   it -- which, since the GC can't see libfyaml's C memory, lets C
   memory pile up between collections (see Fyaml's header). The
   "open at end" count shows how many were still unfreed. *)

IMPORT Modules, Out, Fyaml, FyamlStreams, Timing;

PROCEDURE Run;
  VAR path, mode: ARRAY 256 OF CHAR; s: FyamlStreams.Stream; d: Fyaml.Document;
    err: Fyaml.Error; root: Fyaml.Node; t0, sum, count: LONGINT; id: INTEGER;
    name: Fyaml.String; ok, close: BOOLEAN;
BEGIN
  path := "manydocs.yaml"; mode := "";
  IF Modules.ArgCount > 1 THEN Modules.GetArg(1, path) END;
  IF Modules.ArgCount > 2 THEN Modules.GetArg(2, mode) END;
  close := mode # "gc";
  t0 := Timing.Now();
  s := FyamlStreams.OpenFile(path, err);
  IF s = NIL THEN Out.String(err.msg^); RETURN END;
  sum := 0; count := 0; ok := TRUE;
  LOOP
    d := s.Next(err);
    IF d = NIL THEN EXIT END;
    root := d.Root();
    ok := ok & root.IntegerField("id", id, err) & root.StringFieldOr("name", "", name, err);
    INC(count); INC(sum, id + LEN(name^) - 1);
    IF close THEN d.Close END
  END;
  s.Close;
  t0 := Timing.Now() - t0;
  Out.String("bench_streams: docs= "); Out.Int(count, 0);
  Out.String(" checksum= "); Out.Int(sum, 0);
  IF ~ok OR (err # NIL) THEN Out.String(" (errors)") END;
  Out.String(" open at end= "); Out.Int(Fyaml.openDocuments, 0); Out.Ln;
  Timing.Report("bench_streams: ", t0)
END Run;

BEGIN Run
END BenchStreams.
