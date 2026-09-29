MODULE HaltAttach; (* Expected to halt: attaching a node from another document *)

(* Run by `make test`, which requires exit status Fyaml.AssertAttach
   (64). *)

IMPORT Fyaml, Out;

VAR d, e: Fyaml.Document; seq, n: Fyaml.Node;

BEGIN
  d := Fyaml.NewDocument(); e := Fyaml.NewDocument();
  seq := d.CreateSequence();
  n := e.CreateScalar("x");
  seq.Append(n);  (* must halt here *)
  Out.String("HaltAttach: did not halt"); Out.Ln
END HaltAttach.
