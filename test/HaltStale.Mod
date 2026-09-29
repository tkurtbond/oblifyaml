MODULE HaltStale; (* Expected to halt: a Node used after InsertAt *)

(* InsertAt may free nodes libfyaml replaces, so it kills every Node
   taken from the document before it. Run by `make test`, which
   requires exit status Fyaml.AssertInvalid (61). *)

IMPORT Fyaml, Out;

VAR d: Fyaml.Document; err: Fyaml.Error; root, old, n: Fyaml.Node; s: Fyaml.String; ok: BOOLEAN;

BEGIN
  d := Fyaml.ParseString("a: 1", err);
  root := d.Root(); old := root.Value("a");
  n := d.CreateScalar("2");
  ok := d.InsertAt("/a", n, err);
  s := old.Scalar();  (* must halt here: the scalar it named is freed *)
  Out.String("HaltStale: did not halt"); Out.Ln
END HaltStale.
