MODULE TestLocation; (* Where a scalar starts in the input *)

(* Port of alibfyaml's test_location.adb on its location.yaml and
   anchors.yaml, plus block scalars and a string document. One
   difference: alibfyaml reports a created scalar at (1, 1), libfyaml's
   synthetic 0:0 mark; here it has no location (see Fyaml.Location). *)

IMPORT Fyaml, Check;

VAR err: Fyaml.Error;

PROCEDURE At(d: Fyaml.Document; path: ARRAY OF CHAR): Fyaml.Node;
  VAR root: Fyaml.Node;
BEGIN root := d.Root(); RETURN root.ByPath(path)
END At;

PROCEDURE Loc(d: Fyaml.Document; path: ARRAY OF CHAR; line, column: INTEGER; label: ARRAY OF CHAR);
  VAR n: Fyaml.Node; l, c: INTEGER;
BEGIN
  n := At(d, path);
  Check.Check(n.Location(l, c) & (l = line) & (c = column) & n.HasLocation(), label)
END Loc;

PROCEDURE Run;
  VAR d: Fyaml.Document; n, root, key, created: Fyaml.Node; l, c: INTEGER; it: Fyaml.PairIter;
    ok: BOOLEAN;
BEGIN
  d := Fyaml.ParseFile("location.yaml", err);
  Loc(d, "/name", 1, 7, "name: 1:7");
  Loc(d, "/count", 2, 8, "count: 2:8");
  Loc(d, "/empty", 3, 6, "an empty scalar still has a location: 3:6");
  n := d.Root();
  Check.Check(~n.Location(l, c) & ~n.HasLocation(), "a mapping has no location");
  d.Close;

  d := Fyaml.ParseFileWith("anchors.yaml", {Fyaml.NoResolve}, err);
  n := At(d, "/same");
  Check.Check(n.IsAlias(), "the alias is an alias");
  Loc(d, "/same", 7, 8, "an alias is located at its name, after the *: 7:8");
  d.Close;

  d := Fyaml.ParseFile("styles.yaml", err);
  Loc(d, "/s", 3, 5, "a quoted scalar starts after its quote: 3:5");
  Loc(d, "/l", 6, 1, "a literal block scalar starts at its content line: 6:1");
  n := At(d, "/q");
  Check.Check(~n.HasLocation(), "a flow sequence has no location");
  d.Close;

  (* A key at the very start of the input, before and after
     CreateScalar: the documented cost of hiding created scalars'
     synthetic 0:0 mark. *)
  d := Fyaml.ParseString("first: 1", err);
  Loc(d, "/first", 1, 8, "a string document: 1:8");
  root := d.Root(); root.Pairs(it); ok := it.Next(key, n);
  Check.Check(key.Location(l, c) & (l = 1) & (c = 1), "a key at the start of the input: 1:1");
  created := d.CreateScalar("x");
  Check.Check(~created.HasLocation(), "a created scalar has no location");
  Check.Check(~key.HasLocation(), "...and once one exists, 1:1 reads as none");
  Loc(d, "/first", 1, 8, "...while other locations are unaffected");
  d.Close
END Run;

BEGIN
  Run;
  Check.Summary
END TestLocation.
