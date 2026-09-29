MODULE TestThin; (* Phase 0 smoke test: FyThin parse, navigate, read a scalar *)

(* Checks actual scalar bytes, not just "non-empty": the voc buffer
   lifetime bug this guards against (PLAN.md, "Buffer lifetime")
   produces wrong text with no valgrind error. *)

IMPORT SYSTEM, FyThin, Check;

TYPE Buffer = POINTER TO ARRAY OF CHAR;

(* Copies text into a fresh GC-heap buffer that the caller keeps
   alive for the document's whole life: libfyaml spans into it. *)
PROCEDURE NewBuffer(text: ARRAY OF CHAR; VAR len: SYSTEM.ADDRESS): Buffer;
  VAR b: Buffer; i: SYSTEM.ADDRESS;
BEGIN
  len := 0; WHILE (len < LEN(text)) & (text[len] # 0X) DO INC(len) END;
  NEW(b, len + 1);
  FOR i := 0 TO len - 1 DO b[i] := text[i] END;
  b[len] := 0X;
  RETURN b
END NewBuffer;

(* TRUE if the scalar at path is exactly the len bytes of want. want
   is an explicit byte count so embedded 0X can be checked too. *)
PROCEDURE ScalarIs(root: FyThin.Node; path: ARRAY OF CHAR;
                   want: ARRAY OF CHAR; wantLen: SYSTEM.ADDRESS): BOOLEAN;
  VAR n: FyThin.Node; p, len, plen, i: SYSTEM.ADDRESS; c: CHAR; ok: BOOLEAN;
BEGIN
  plen := 0; WHILE (plen < LEN(path)) & (path[plen] # 0X) DO INC(plen) END;
  n := FyThin.NodeByPath(root, SYSTEM.ADR(path[0]), plen);
  IF n = 0 THEN RETURN FALSE END;
  p := FyThin.NodeGetScalar(n, len);
  IF (p = 0) OR (len # wantLen) THEN RETURN FALSE END;
  ok := TRUE; i := 0;
  WHILE ok & (i < len) DO
    SYSTEM.GET(p + i, c); ok := c = want[i]; INC(i)
  END;
  RETURN ok
END ScalarIs;

PROCEDURE Run;
  VAR buf: Buffer; len: SYSTEM.ADDRESS; doc: FyThin.Document; root: FyThin.Node;
    nul: ARRAY 4 OF CHAR;
BEGIN
  buf := NewBuffer('{a: {b: hello}, nul: "x\0y"}', len);
  doc := FyThin.DocumentBuildFromString(SYSTEM.ADR(buf[0]), len);
  Check.Check(doc # 0, "parse from heap buffer");
  IF doc # 0 THEN
    root := FyThin.DocumentRoot(doc);
    Check.Check(root # 0, "document has a root");
    Check.Check(FyThin.NodeIsMapping(root), "root is a mapping (static inline helper)");
    Check.Check(ScalarIs(root, "/a/b", "hello", 5), "scalar /a/b is exactly 'hello'");
    nul[0] := "x"; nul[1] := 0X; nul[2] := "y";
    Check.Check(ScalarIs(root, "/nul", nul, 3), "scalar with embedded 0X keeps all 3 bytes");
    Check.Check(~ScalarIs(root, "/missing", "", 0), "missing path finds nothing");
    FyThin.DocumentDestroy(doc)
  END
END Run;

BEGIN
  Run;
  Check.Summary
END TestThin.
