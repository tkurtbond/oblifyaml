MODULE BenchWide; (* One large document, every entity navigated *)

(* Counterpart of alibfyaml's bench_wide.adb, on the same generated
   input (gen_wide.py): a top-level sequence of small mappings
   {id, name, value, active}. Times three passes over one parsed
   document, each printing a checksum so a change in behaviour shows:

   - typed: alibfyaml's work (IntegerField, StringFieldOr, RealField,
     BooleanField per entity), for comparison across bindings. It
     includes the parse, as alibfyaml's does.
   - nav:   Value and ScalarLen of the 4 fields: a Node allocation per
     field and per item, and nothing else.
   - thin:  the same as nav through FyThin directly, with no Nodes.
   - parse: ParseFile and Close alone, to subtract from typed.

   nav minus thin is what allocating a Node per navigation step costs
   (PLAN.md, "Node as heap object versus record").

   Run: BenchWide [file] [pass], pass one of typed, nav, thin, parse
   (default all four). *)

IMPORT SYSTEM, Modules, Out, Fyaml, FyThin, Timing;

VAR path, pass: ARRAY 256 OF CHAR;

PROCEDURE Typed;
  VAR d: Fyaml.Document; err: Fyaml.Error; root, item: Fyaml.Node; it: Fyaml.ItemIter;
    t0, sum, count: LONGINT; id: INTEGER; name: Fyaml.String; v: REAL; active, ok: BOOLEAN;
BEGIN
  t0 := Timing.Now();
  d := Fyaml.ParseFile(path, err);
  IF d = NIL THEN Out.String(err.msg^); RETURN END;
  root := d.Root(); root.Items(it);
  sum := 0; count := 0; ok := TRUE;
  WHILE it.Next(item) DO
    ok := ok & item.IntegerField("id", id, err) & item.StringFieldOr("name", "", name, err)
      & item.RealField("value", v, err) & item.BooleanField("active", active, err);
    INC(count); INC(sum, id + LEN(name^) - 1);
    IF active THEN INC(sum, ENTIER(v)) END
  END;
  d.Close;
  t0 := Timing.Now() - t0;
  Out.String("bench_wide typed: items= "); Out.Int(count, 0);
  Out.String(" checksum= "); Out.Int(sum, 0); IF ~ok THEN Out.String(" (errors)") END; Out.Ln;
  Timing.Report("bench_wide typed: ", t0)
END Typed;

PROCEDURE Nav(d: Fyaml.Document);
  VAR root, item, n: Fyaml.Node; it: Fyaml.ItemIter; t0, sum, count: LONGINT;
BEGIN
  t0 := Timing.Now();
  root := d.Root(); root.Items(it);
  sum := 0; count := 0;
  WHILE it.Next(item) DO
    n := item.Value("id"); INC(sum, n.ScalarLen());
    n := item.Value("name"); INC(sum, n.ScalarLen());
    n := item.Value("value"); INC(sum, n.ScalarLen());
    n := item.Value("active"); INC(sum, n.ScalarLen());
    INC(count)
  END;
  t0 := Timing.Now() - t0;
  Out.String("bench_wide nav: items= "); Out.Int(count, 0);
  Out.String(" checksum= "); Out.Int(sum, 0); Out.Ln;
  Timing.Report("bench_wide nav: ", t0)
END Nav;

PROCEDURE Len(item: FyThin.Node; key: ARRAY OF CHAR): LONGINT;
  VAR n: FyThin.Node; len: SYSTEM.ADDRESS; p: SYSTEM.ADDRESS; k: LONGINT;
BEGIN
  k := 0; WHILE key[k] # 0X DO INC(k) END;
  n := FyThin.NodeMappingLookupValueByString(item, SYSTEM.ADR(key[0]), k);
  p := FyThin.NodeGetScalar(n, len);
  RETURN len
END Len;

PROCEDURE Thin(h: FyThin.Document);
  VAR root, item: FyThin.Node; prev: SYSTEM.ADDRESS; t0, sum, count: LONGINT;
BEGIN
  t0 := Timing.Now();
  root := FyThin.DocumentRoot(h); prev := 0;
  sum := 0; count := 0;
  LOOP
    item := FyThin.NodeSequenceIterate(root, prev);
    IF item = 0 THEN EXIT END;
    INC(sum, Len(item, "id") + Len(item, "name") + Len(item, "value") + Len(item, "active"));
    INC(count)
  END;
  t0 := Timing.Now() - t0;
  Out.String("bench_wide thin: items= "); Out.Int(count, 0);
  Out.String(" checksum= "); Out.Int(sum, 0); Out.Ln;
  Timing.Report("bench_wide thin: ", t0)
END Thin;

PROCEDURE Parse;
  VAR d: Fyaml.Document; err: Fyaml.Error; t0: LONGINT;
BEGIN
  t0 := Timing.Now();
  d := Fyaml.ParseFile(path, err);
  IF d = NIL THEN Out.String(err.msg^); RETURN END;
  d.Close;
  Timing.Report("bench_wide parse: ", Timing.Now() - t0)
END Parse;

PROCEDURE Run;
  VAR d: Fyaml.Document; err: Fyaml.Error; h: FyThin.Document; diag: FyThin.Diag;
BEGIN
  path := "wide.yaml"; pass := "";
  IF Modules.ArgCount > 1 THEN Modules.GetArg(1, path) END;
  IF Modules.ArgCount > 2 THEN Modules.GetArg(2, pass) END;
  IF (pass = "") OR (pass = "typed") THEN Typed END;
  IF (pass = "") OR (pass = "nav") THEN
    d := Fyaml.ParseFile(path, err);
    IF d = NIL THEN Out.String(err.msg^); RETURN END;
    Nav(d); d.Close
  END;
  IF (pass = "") OR (pass = "thin") THEN
    diag := FyThin.DiagCreate();
    h := FyThin.DocumentBuildFromFile(SYSTEM.ADR(path[0]), TRUE, diag);
    FyThin.DiagDestroy(diag);
    IF h = 0 THEN Out.String("thin: parse failed"); Out.Ln; RETURN END;
    Thin(h); FyThin.DocumentDestroy(h)
  END;
  IF (pass = "") OR (pass = "parse") THEN Parse END
END Run;

BEGIN Run
END BenchWide.
