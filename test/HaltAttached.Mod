MODULE HaltAttached; (* Expected to halt: attaching a node twice *)

(* Run by `make test`, which requires exit status Fyaml.AssertAttach
   (64). *)

IMPORT Fyaml, Out;

VAR d: Fyaml.Document; seq, n: Fyaml.Node;

BEGIN
  d := Fyaml.NewDocument();
  seq := d.CreateSequence();
  n := d.CreateScalar("x");
  seq.Append(n);
  seq.Append(n);  (* must halt here: n is already in seq *)
  Out.String("HaltAttached: did not halt"); Out.Ln
END HaltAttached.
