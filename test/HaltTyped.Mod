MODULE HaltTyped; (* Expected to halt: a typed accessor on a mapping node *)

(* The per-node typed accessors take a scalar; a sequence or mapping is
   a programmer error (the ...Field forms report it as a DataError
   instead). Run by `make test`, which requires exit status
   Fyaml.AssertKind (62). *)

IMPORT Fyaml, Out;

VAR d: Fyaml.Document; err: Fyaml.Error; root: Fyaml.Node; v: LONGINT; ok: BOOLEAN;

BEGIN
  d := Fyaml.ParseString("a: 1", err);
  root := d.Root();
  ok := root.LongIntValue(v, err);  (* must halt here *)
  Out.String("HaltTyped: did not halt"); Out.Ln
END HaltTyped.
