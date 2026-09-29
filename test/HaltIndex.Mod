MODULE HaltIndex; (* Expected to halt: Item past the end of a sequence *)

(* Run by `make test`, which requires exit status Fyaml.AssertIndex
   (63). Reaching the end means the check failed. *)

IMPORT Fyaml, Out;

VAR d: Fyaml.Document; err: Fyaml.Error; root, n: Fyaml.Node;

BEGIN
  d := Fyaml.ParseString("[a, b]", err);
  root := d.Root();
  n := root.Item(2);  (* must halt here: only items 0 and 1 *)
  Out.String("HaltIndex: did not halt"); Out.Ln
END HaltIndex.
