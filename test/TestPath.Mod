MODULE TestPath; (* Node.Path: the inverse of ByPath *)

(* Port of alibfyaml's test_path.adb, on the same navigate.yaml. *)

IMPORT Fyaml, Check;

VAR root: Fyaml.Node;

PROCEDURE CheckPath(label: ARRAY OF CHAR; n: Fyaml.Node; expected: ARRAY OF CHAR);
  VAR p: Fyaml.String;
BEGIN
  IF n = NIL THEN Check.Check(FALSE, label)
  ELSE p := n.Path(); Check.Check(p^ = expected, label)
  END
END CheckPath;

PROCEDURE Run;
  VAR d: Fyaml.Document; err: Fyaml.Error; n, lead, again: Fyaml.Node; p, s: Fyaml.String;
BEGIN
  d := Fyaml.ParseFile("navigate.yaml", err);
  Check.Check(d # NIL, "parse navigate.yaml");
  IF d = NIL THEN RETURN END;
  root := d.Root();

  (* "/", not "" or NIL -- confirmed by alibfyaml, despite the header *)
  CheckPath("root: Path = /", root, "/");
  CheckPath("top-level scalar: /name", root.ByPath("/name"), "/name");
  CheckPath("sequence element: /tags/0", root.ByPath("/tags/0"), "/tags/0");

  n := root.ByPath("/server");
  Check.Check(n.IsMapping(), "server: IsMapping");
  CheckPath("mapping node (no scalar token, still has a path): /server", n, "/server");

  CheckPath("4 levels deep: /company/departments/0/teams/1",
            root.ByPath("/company/departments/0/teams/1"), "/company/departments/0/teams/1");
  CheckPath("field in a sequence of mappings: /endpoints/1/name",
            root.ByPath("/endpoints/1/name"), "/endpoints/1/name");

  (* Round trip: ByPath(Path(N)) finds N, for a node reached step by step *)
  n := root.Value("company"); n := n.Value("departments"); n := n.Item(1);
  n := n.Value("teams"); n := n.Item(0); lead := n.Value("lead");
  p := lead.Path();
  again := root.ByPath(p^);
  s := lead.Scalar();
  Check.Check((again # NIL) & again.ScalarIs(s^) & again.ScalarIs("Margaret Hamilton"),
              "round trip: ByPath(Path(N)) = N");

  d.Close
END Run;

BEGIN
  Run;
  Check.Summary
END TestPath.
