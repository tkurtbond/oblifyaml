MODULE TestLiveness; (* Document/Node lifetime: buffers, GC, finalizers, Close *)

(* Counterpart of alibfyaml's test_liveness.adb, for a GC host. Every
   read checks the actual text: the voc buffer-lifetime bug this
   guards against gives wrong text with no valgrind error (PLAN.md,
   "Buffer lifetime"). The "halts after Close" cases are separate
   programs (HaltClosed etc.), run by `make test` expecting a halt. *)

IMPORT Heap, Fyaml, Check;

TYPE Junk = POINTER TO ARRAY OF CHAR;

(* Allocates and drops garbage, then collects, so the GC really runs
   and reuses freed memory. *)
PROCEDURE Churn;
  VAR i: INTEGER; j: Junk;
BEGIN
  FOR i := 1 TO 200 DO NEW(j, 1000); j[0] := "x" END;
  Heap.GC(TRUE)
END Churn;

(* text is a value parameter here, so voc copies it into this frame's
   alloca memory -- exactly the spike's failure case, if ParseString
   did not copy it into a buffer of its own. *)
PROCEDURE ParseValueParam(text: ARRAY OF CHAR): Fyaml.Document;
  VAR err: Fyaml.Error;
BEGIN RETURN Fyaml.ParseString(text, err)
END ParseValueParam;

(* Returns only a node: its Document is then referenced only by it. *)
PROCEDURE OnlyANode(): Fyaml.Node;
  VAR d: Fyaml.Document; err: Fyaml.Error; root: Fyaml.Node;
BEGIN
  d := Fyaml.ParseString("keep: {me: alive}", err);
  root := d.Root();
  RETURN root.ByPath("/keep/me")
END OnlyANode;

(* Parses a document and drops every reference to it. *)
PROCEDURE ParseAndDrop;
  VAR d: Fyaml.Document; err: Fyaml.Error;
BEGIN d := Fyaml.ParseString("dropped: 1", err)
END ParseAndDrop;

PROCEDURE Run;
  VAR d: Fyaml.Document; err: Fyaml.Error; root, n, m: Fyaml.Node;
    text: ARRAY 32 OF CHAR; before: LONGINT;
BEGIN
  (* ParseString copies its input *)
  text := "k: original";
  d := Fyaml.ParseString(text, err);
  text := "k: CHANGED!";
  root := d.Root(); n := root.Value("k");
  Check.Check(n.ScalarIs("original"), "changing the caller's text after ParseString doesn't change the document");
  d.Close;

  (* ...even from a value parameter whose frame is gone *)
  d := ParseValueParam("a: {b: hello}");
  Churn;
  n := d.Root(); n := n.ByPath("/a/b");
  Check.Check(n.ScalarIs("hello"), "document parsed from a dead value-parameter frame reads correctly");
  d.Close;

  (* A reachable Node keeps its Document (and its buffer) alive *)
  before := Fyaml.openDocuments;
  n := OnlyANode();
  Churn; Churn;
  Check.Check(Fyaml.Valid(n), "a Node alone keeps its Document open across GCs");
  Check.Check(n.ScalarIs("alive"), "and still reads correctly");
  Check.Check(Fyaml.openDocuments = before + 1, "and its Document was not finalized");
  n := NIL;

  (* An unreachable Document is finalized by the GC *)
  Churn;
  before := Fyaml.openDocuments;
  ParseAndDrop;
  Check.Check(Fyaml.openDocuments = before + 1, "(parsed one more document)");
  Churn;
  Check.Check(Fyaml.openDocuments = before, "an unreachable Document is finalized by the GC");

  (* Close: every Node from the document dies at once *)
  d := Fyaml.ParseString("x: {y: 1}", err);
  before := Fyaml.openDocuments;
  root := d.Root(); m := root.ByPath("/x/y");
  Check.Check(d.IsOpen() & Fyaml.Valid(root) & Fyaml.Valid(m), "while open: document and nodes valid");
  d.Close;
  Check.Check(~d.IsOpen(), "after Close: IsOpen is FALSE");
  Check.Check(~Fyaml.Valid(root) & ~Fyaml.Valid(m), "after Close: both nodes from it are invalid");
  d.Close;
  Check.Check(Fyaml.openDocuments = before - 1, "Close is idempotent: counted once");
  Check.Check(~Fyaml.Valid(NIL), "Valid(NIL) is FALSE")
END Run;

BEGIN
  Run;
  Check.Summary
END TestLiveness.
