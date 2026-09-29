MODULE TestBuild; (* Building documents from scratch, and emitting them *)

(* NewDocument, Create*, Append, AppendPair, SetRoot, ToYAML, ToFile.
   Expected emitter output was taken from libfyaml's actual output
   (Phase 2 probe), not written from expectation. Leaving nodes
   unattached on purpose checks, under `make valgrind`, that Close
   frees them: libfyaml's own destroy leaks them (confirmed live). *)

IMPORT Fyaml, Check;

CONST nl = 0AX;

VAR d: Fyaml.Document;

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

(* TRUE if s is exactly the lines given, each followed by a newline;
   lines are separated by "|" in spec. *)
PROCEDURE IsLines(s: Fyaml.String; spec: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: LONGINT; c: CHAR;
BEGIN
  IF s = NIL THEN RETURN FALSE END;
  i := 0; j := 0;
  LOOP
    IF (j < LEN(spec)) & (spec[j] # 0X) THEN
      c := spec[j]; IF c = "|" THEN c := nl END
    ELSE c := nl
    END;
    IF (i >= LEN(s^)) OR (s[i] # c) THEN RETURN FALSE END;
    INC(i);
    IF (j >= LEN(spec)) OR (spec[j] = 0X) THEN EXIT END;
    INC(j)
  END;
  RETURN (i < LEN(s^)) & (s[i] = 0X)
END IsLines;

(* {name: widget, items: [a, b], count: 2} *)
PROCEDURE BuildWidget(): Fyaml.Node;
  VAR m, k, v, seq: Fyaml.Node; err: Fyaml.Error; ok: BOOLEAN;
BEGIN
  m := d.CreateMapping();
  k := d.CreateScalar("name"); v := d.CreateScalar("widget");
  ok := m.AppendPair(k, v, err);
  seq := d.CreateSequence();
  v := d.CreateScalar("a"); seq.Append(v);
  v := d.CreateScalar("b"); seq.Append(v);
  k := d.CreateScalar("items"); ok := ok & m.AppendPair(k, seq, err);
  k := d.CreateScalar("count"); v := d.CreateScalar("2");
  ok := ok & m.AppendPair(k, v, err);
  Check.Check(ok, "AppendPair of three distinct keys succeeds");
  RETURN m
END BuildWidget;

PROCEDURE Run;
  VAR err: Fyaml.Error; root, m, k, v, n, old, orphan: Fyaml.Node; s: Fyaml.String;
    e: Fyaml.Document; ok: BOOLEAN; out: ARRAY 64 OF CHAR;
BEGIN
  d := Fyaml.NewDocument();
  Check.Check(d.IsOpen() & (d.Root() = NIL), "NewDocument is open and has no root");
  s := d.ToYAML(Fyaml.emitDefault, err);
  Check.Check((s = NIL) & (err # NIL) & (err.kind = Fyaml.EmitError),
              "ToYAML of an empty document gives an EmitError");
  Check.Check(~d.ToFile("unused.yaml", Fyaml.emitDefault, err) & (err.kind = Fyaml.EmitError),
              "ToFile of an empty document gives an EmitError");

  orphan := d.CreateScalar("never attached");  (* freed by Close *)
  m := BuildWidget();
  d.SetRoot(m);
  Check.Check(Fyaml.Valid(m) & Fyaml.Valid(orphan),
              "SetRoot on an empty document keeps earlier nodes valid");
  root := d.Root();
  n := root.ByPath("/items/1");
  Check.Check((n # NIL) & n.ScalarIs("b"), "built tree navigates: /items/1 = b");

  s := d.ToYAML(Fyaml.emitDefault, err);
  Check.Check((err = NIL) & IsLines(s, "name: widget|items:|- a|- b|count: 2"),
              "emitDefault: block style, document order");
  s := d.ToYAML(0, err);
  Check.Check(IsLines(s, "name: widget|items:|- a|- b|count: 2"), "flags 0 gives the same here");
  s := d.ToYAML(Fyaml.emitModeBlock + Fyaml.emitSortKeys, err);
  Check.Check(IsLines(s, "count: 2|items:|- a|- b|name: widget"), "emitModeBlock + emitSortKeys");
  s := d.ToYAML(Fyaml.emitModeFlowOneline, err);
  Check.Check(IsLines(s, "{name: widget, items: [a, b], count: 2}"), "emitModeFlowOneline");
  s := d.ToYAML(Fyaml.emitModeJson, err);
  Check.Check(IsLines(s, '{|  "name": "widget",|  "items": [|    "a",|    "b"|  ],|  "count": 2|}'),
              "emitModeJson");

  (* Round trip through text *)
  s := d.ToYAML(Fyaml.emitDefault, err);
  e := Fyaml.ParseString(s^, err);
  root := e.Root(); n := root.ByPath("/items/0");
  Check.Check((n # NIL) & n.ScalarIs("a") & (root.Length() = 3), "ParseString(ToYAML(d)) round-trips");
  e.Close;

  (* Duplicate key: refused, nothing attached, nodes stay usable *)
  k := d.CreateScalar("name"); v := d.CreateScalar("dup");
  ok := m.AppendPair(k, v, err);
  Check.Check(~ok & (err # NIL) & (err.kind = Fyaml.DuplicateKey), "AppendPair of an existing key gives DuplicateKey");
  IF err # NIL THEN
    Check.Check(IsLines(err.msg, '/: error: duplicate key "name"'), "DuplicateKey message names the mapping's path and key")
  END;
  Check.Check(Fyaml.Valid(k) & Fyaml.Valid(v) & (m.Length() = 3),
              "after DuplicateKey, key and value stay usable and the mapping is unchanged");

  (* ToFile: written twice, the file holds one copy ("wa" truncates) *)
  out := "../build/build-out.yaml";  (* tests run in test/ *)
  ok := d.ToFile(out, Fyaml.emitDefault, err) & d.ToFile(out, Fyaml.emitDefault, err);
  Check.Check(ok & (err = NIL), "ToFile succeeds");
  e := Fyaml.ParseFile(out, err);
  Check.Check(e # NIL, "the written file parses (one copy: two would repeat keys)");
  IF e # NIL THEN root := e.Root(); Check.Check(root.Length() = 3, "the written file has the 3 keys"); e.Close END;
  ok := d.ToFile("no-such-dir/x.yaml", Fyaml.emitDefault, err);
  Check.Check(~ok & (err.kind = Fyaml.FileError) & HasPrefix(err.msg, "no-such-dir/x.yaml: error: No such file or directory"),
              "ToFile into a missing directory gives a FileError with the OS reason");

  (* SetRoot replacing an existing root: old nodes die, the new root lives *)
  old := d.Root(); n := old.Value("name");
  v := d.CreateScalar("replacement");
  d.SetRoot(v);
  Check.Check(~Fyaml.Valid(old) & ~Fyaml.Valid(n), "SetRoot replacing a root kills nodes from the old tree");
  Check.Check(~Fyaml.Valid(orphan), "...and every other earlier node too");
  Check.Check(Fyaml.Valid(v) & v.ScalarIs("replacement"), "the new root stays usable");
  root := d.Root();
  Check.Check(root.ScalarIs("replacement"), "Root() returns the new root");

  d.Close
END Run;

BEGIN
  Run;
  Check.Summary
END TestBuild.
