MODULE HaltKind; (* Expected to halt: Item on a mapping *)

(* Run by `make test`, which requires exit status Fyaml.AssertKind
   (62). Reaching the end means the check failed. *)

IMPORT Fyaml, Out;

VAR d: Fyaml.Document; err: Fyaml.Error; root, n: Fyaml.Node;

BEGIN
  d := Fyaml.ParseString("a: 1", err);
  root := d.Root();
  n := root.Item(0);  (* must halt here: root is a mapping *)
  Out.String("HaltKind: did not halt"); Out.Ln
END HaltKind.
