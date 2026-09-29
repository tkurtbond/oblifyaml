MODULE HaltClosed; (* Expected to halt: a Node used after its Document's Close *)

(* Run by `make test`, which requires exit status Fyaml.AssertInvalid
   (61). Reaching the end means the check failed. *)

IMPORT Fyaml, Out;

VAR d: Fyaml.Document; err: Fyaml.Error; root, n: Fyaml.Node; s: Fyaml.String;

BEGIN
  d := Fyaml.ParseString("a: 1", err);
  root := d.Root(); n := root.Value("a");
  d.Close;
  s := n.Scalar();  (* must halt here *)
  Out.String("HaltClosed: did not halt"); Out.Ln
END HaltClosed.
