MODULE HaltStream; (* Expected to halt: a Stream used after Close *)

(* Run by `make test`, which requires exit status Fyaml.AssertInvalid
   (61). *)

IMPORT Fyaml, FyamlStreams, Out;

VAR s: FyamlStreams.Stream; err: Fyaml.Error; d: Fyaml.Document;

BEGIN
  s := FyamlStreams.OpenString("a: 1", err);
  s.Close;
  d := s.Next(err);  (* must halt here *)
  Out.String("HaltStream: did not halt"); Out.Ln
END HaltStream.
