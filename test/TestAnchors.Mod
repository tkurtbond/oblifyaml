MODULE TestAnchors; (* Anchors, aliases, merge keys, Resolve, tags, styles *)

(* Port of alibfyaml's test_anchors.adb on its anchors.yaml and
   anchors_cycle.yaml, plus Style, a cyclic reference found at parse
   time, and this binding's rule that Resolve kills earlier Nodes
   (libfyaml frees the merge-key pairs it replaces). In alibfyaml a
   Node taken before Resolve stays usable; here it must be taken
   again. alibfyaml saw a small leak inside libfyaml when resolving
   the cycle; with a collecting diag there is none (valgrind, Phase 4). *)

IMPORT Fyaml, Check;

VAR err: Fyaml.Error;

PROCEDURE MsgIs(line: ARRAY OF CHAR): BOOLEAN;
  VAR i, n: LONGINT;
BEGIN
  IF (err = NIL) OR (err.msg = NIL) THEN RETURN FALSE END;
  n := 0; WHILE (n < LEN(line)) & (line[n] # 0X) DO INC(n) END;
  IF LEN(err.msg^) < n + 2 THEN RETURN FALSE END;
  FOR i := 0 TO n - 1 DO IF err.msg[i] # line[i] THEN RETURN FALSE END END;
  RETURN (err.msg[n] = 0AX) & (err.msg[n + 1] = 0X)
END MsgIs;

PROCEDURE At(d: Fyaml.Document; path: ARRAY OF CHAR): Fyaml.Node;
  VAR root: Fyaml.Node;
BEGIN root := d.Root(); RETURN root.ByPath(path)
END At;

PROCEDURE Resolved;
  VAR d: Fyaml.Document; same, n, x, y: Fyaml.Node; s: Fyaml.String;
BEGIN
  d := Fyaml.ParseFile("anchors.yaml", err);
  same := At(d, "/same");
  Check.Check(~same.IsAlias() & same.IsMapping(), "default parse: the alias is resolved to a mapping");
  x := same.Value("x"); y := same.Value("y");
  Check.Check(x.ScalarIs("1") & y.ScalarIs("2"), "default parse: ...a copy of the anchored one");
  x := At(d, "/derived/x"); y := At(d, "/derived/y"); n := At(d, "/derived/z");
  Check.Check((x # NIL) & x.ScalarIs("1") & (y # NIL) & y.ScalarIs("2"), "default parse: merged pairs are reachable");
  Check.Check((n # NIL) & n.ScalarIs("3"), "default parse: the mapping's own pairs are kept");
  n := At(d, "/derived");
  Check.Check(~n.HasKey("<<"), "default parse: the << key is gone");
  n := At(d, "/tagged");
  s := n.Tag(); Check.Check(s^ = "!mytag", "Tag returns the explicit tag verbatim");
  n := At(d, "/untagged");
  s := n.Tag(); Check.Check(s^ = "", 'Tag returns "" when there is none');
  d.Close
END Resolved;

PROCEDURE Unresolved;
  VAR d: Fyaml.Document; same, n, derived: Fyaml.Node; ok: BOOLEAN;
BEGIN
  d := Fyaml.ParseFileWith("anchors.yaml", {Fyaml.NoResolve}, err);
  same := At(d, "/same");
  Check.Check(same.IsAlias() & (same.Style() = Fyaml.StyleAlias), "NoResolve: the alias is an alias");
  Check.Check(same.IsScalar() & same.ScalarIs("b"), "NoResolve: its text is the anchor's name");
  Check.Check(~same.IsNullValue(), "NoResolve: IsNullValue is FALSE on an alias");
  derived := At(d, "/derived");
  Check.Check((At(d, "/derived/x") = NIL) & derived.HasKey("<<"), "NoResolve: the merge key is still a << pair");

  ok := d.Resolve(err);
  Check.Check(ok & (err = NIL), "Resolve succeeds");
  Check.Check(~Fyaml.Valid(same) & ~Fyaml.Valid(derived), "Nodes taken before Resolve are dead");
  same := At(d, "/same");
  Check.Check(~same.IsAlias() & same.IsMapping() & same.HasKey("x"), "after Resolve: the alias is the anchored mapping");
  n := At(d, "/derived/x");
  Check.Check((n # NIL) & n.ScalarIs("1"), "after Resolve: merged pairs are reachable");
  d.Close
END Unresolved;

PROCEDURE Cycles;
  VAR d: Fyaml.Document; ok: BOOLEAN;
BEGIN
  d := Fyaml.ParseFileWith("anchors_cycle.yaml", {Fyaml.NoResolve}, err);
  Check.Check(d # NIL, "a merge-key cycle parses with NoResolve");
  ok := d.Resolve(err);
  Check.Check(~ok & (err # NIL) & (err.kind = Fyaml.ResolveError), "Resolve of a cycle: FALSE + ResolveError");
  Check.Check(MsgIs("anchors_cycle.yaml:2:8: error: cyclic reference detected"), "ResolveError message is located");
  Check.Check(d.IsOpen(), "the document stays open");
  d.Close;

  d := Fyaml.ParseFile("anchors_cycle.yaml", err);
  Check.Check((d = NIL) & (err.kind = Fyaml.ParseError), "with resolve on, a cycle is a ParseError");
  Check.Check(MsgIs("anchors_cycle.yaml:2:8: error: cyclic reference detected"), "ParseError message is located");

  d := Fyaml.ParseStringWith("a: &a {<<: *a}", {Fyaml.NoResolve}, err);
  ok := d.Resolve(err);
  Check.Check(~ok & MsgIs("(string-in-memory):1:13: error: cyclic reference detected"),
              "a string document's ResolveError names (string-in-memory)");
  d.Close;

  d := Fyaml.NewDocument();
  d.SetRoot(d.CreateScalar("x"));
  Check.Check(d.Resolve(err) & (err = NIL), "Resolve of a built document with no aliases succeeds");
  d.Close
END Cycles;

PROCEDURE Styles;
  VAR d: Fyaml.Document; n: Fyaml.Node;
BEGIN
  d := Fyaml.ParseFile("styles.yaml", err);
  n := d.Root(); Check.Check(n.Style() = Fyaml.StyleBlock, "Style: a block mapping");
  n := At(d, "/p"); Check.Check(n.Style() = Fyaml.StylePlain, "Style: plain");
  n := At(d, "/s"); Check.Check(n.Style() = Fyaml.StyleSingleQuoted, "Style: single-quoted");
  n := At(d, "/d"); Check.Check(n.Style() = Fyaml.StyleDoubleQuoted, "Style: double-quoted");
  n := At(d, "/l"); Check.Check(n.Style() = Fyaml.StyleLiteral, "Style: literal |");
  n := At(d, "/f"); Check.Check(n.Style() = Fyaml.StyleFolded, "Style: folded >");
  n := At(d, "/q"); Check.Check(n.Style() = Fyaml.StyleFlow, "Style: a flow sequence");
  d.Close
END Styles;

BEGIN
  Resolved;
  Unresolved;
  Cycles;
  Styles;
  Check.Summary
END TestAnchors.
