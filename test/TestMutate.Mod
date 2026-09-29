MODULE TestMutate; (* InsertAt: merge rules, consumption, and stale nodes *)

(* Port of alibfyaml's test_mutate.adb, plus this binding's rule that
   InsertAt kills every Node taken from the document before it
   (libfyaml frees the nodes it replaces; see Fyaml's header). *)

IMPORT Fyaml, Check;

CONST nl = 0AX;

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

PROCEDURE Run;
  VAR d: Fyaml.Document; err: Fyaml.Error; root, n, patch, k, v, before, seq, alias: Fyaml.Node;
    ok: BOOLEAN;
BEGIN
  (* Replacing a scalar *)
  d := Fyaml.ParseString("greeting: old", err);
  root := d.Root(); before := root.Value("greeting");
  n := d.CreateScalar("hello"); alias := n;
  ok := d.InsertAt("/greeting", n, err);
  Check.Check(ok & (err = NIL), "InsertAt replacing a scalar succeeds");
  Check.Check((n = NIL) & ~Fyaml.Valid(alias), "InsertAt consumes the node: n is NIL, and other copies are dead");
  Check.Check(~Fyaml.Valid(before) & ~Fyaml.Valid(root), "nodes taken before InsertAt are dead");
  root := d.Root(); n := root.ByPath("/greeting");
  Check.Check(n.ScalarIs("hello"), "the new value is reachable by path");
  d.Close;

  (* Merging a mapping into a mapping *)
  d := Fyaml.ParseString("server: {host: localhost}", err);
  patch := d.CreateMapping();
  k := d.CreateScalar("port"); v := d.CreateScalar("8080");
  ok := patch.AppendPair(k, v, err);
  ok := d.InsertAt("/server", patch, err);
  Check.Check(ok & (patch = NIL), "InsertAt merging into a mapping succeeds and consumes the patch");
  root := d.Root();
  n := root.ByPath("/server/port"); v := root.ByPath("/server/host");
  Check.Check(n.ScalarIs("8080") & v.ScalarIs("localhost"), "merged: the new key is added, the old one kept");
  d.Close;

  (* Merging a sequence into a sequence appends *)
  d := Fyaml.ParseString("tags: [a, b]", err);
  seq := d.CreateSequence(); v := d.CreateScalar("c"); seq.Append(v);
  ok := d.InsertAt("/tags", seq, err);
  root := d.Root(); n := root.Value("tags");
  Check.Check(ok & (n.Length() = 3), "InsertAt merging into a sequence appends its items");
  n := n.Item(2);
  Check.Check(n.ScalarIs("c"), "the appended item is last");
  d.Close;

  (* A path with no node: FALSE, PathError, and the node is still consumed *)
  d := Fyaml.ParseString("{}", err);
  n := d.CreateScalar("orphan");
  ok := d.InsertAt("/no/such/path", n, err);
  Check.Check(~ok & (err # NIL) & (err.kind = Fyaml.PathError), "InsertAt at a missing path gives a PathError");
  Check.Check(n = NIL, "InsertAt at a missing path still consumes the node");
  IF err # NIL THEN
    Check.Check(IsLines(err.msg, "/no/such/path: error: no node at this path"), "PathError message names the path")
  END;
  d.Close
END Run;

BEGIN
  Run;
  Check.Summary
END TestMutate.
