MODULE HaltResolved; (* Expected to halt: a Node used after Resolve *)

(* Resolve frees merge-key pairs, so it kills every Node taken from
   the document before it. Run by `make test`, which requires exit
   status Fyaml.AssertInvalid (61). *)

IMPORT Fyaml, Out;

VAR d: Fyaml.Document; err: Fyaml.Error; root: Fyaml.Node; ok: BOOLEAN;

BEGIN
  d := Fyaml.ParseStringWith("a: 1", {Fyaml.NoResolve}, err);
  root := d.Root();
  ok := d.Resolve(err);
  ok := root.IsMapping();  (* must halt here *)
  Out.String("HaltResolved: did not halt"); Out.Ln
END HaltResolved.
