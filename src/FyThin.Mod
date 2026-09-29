MODULE FyThin; (* Thin libfyaml binding: direct calls, no ownership or error policy *)

(* Low-level access to libfyaml's core API. Handles are SYSTEM.ADDRESS
   values holding the C pointer; strings go in and out as an address
   plus an explicit length. Nothing here copies, frees, or checks:
   build the idiomatic API in Fyaml on top of this module rather than
   using it directly.

   Why every C call is an unexported code procedure wrapped by an
   ordinary exported one: voc emits a code procedure as a C macro, and
   an exported one is expanded in the *importing* module's .c file,
   which does not #include <libfyaml.h> -- gcc then fails with
   "implicit declaration of function fy_...". Confirmed in the Phase 0
   spike (PLAN.md). The wrappers cost one plain C call each.

   Because the code procedures are inline C compiled against the
   installed header, libfyaml's static inline helpers
   (fy_node_is_mapping and friends) and #define constants are usable
   directly, and C struct fields are read through code procedures
   rather than mirrored as Oberon records.

   Only the entry points Fyaml actually calls are bound here.

   Types: compiled with -OC (AGENTS.md), but boundary signatures use
   explicit sizes anyway -- SYSTEM.INT32 for C int, SYSTEM.ADDRESS for
   pointers and size_t -- so each one states the C type it carries. *)

IMPORT SYSTEM;

TYPE
  Document* = SYSTEM.ADDRESS;  (* struct fy_document* *)
  Node* = SYSTEM.ADDRESS;      (* struct fy_node* *)

PROCEDURE -AincludeFyaml '#include <libfyaml.h>';

PROCEDURE -documentBuildFromString(str, len: SYSTEM.ADDRESS): Document
  "(ADDRESS)fy_document_build_from_string(NULL, (const char*)str, (size_t)len)";
PROCEDURE -documentDestroy(fyd: Document)
  "fy_document_destroy((struct fy_document*)fyd)";
PROCEDURE -documentRoot(fyd: Document): Node
  "(ADDRESS)fy_document_root((struct fy_document*)fyd)";
PROCEDURE -nodeIsMapping(fyn: Node): BOOLEAN
  "(BOOLEAN)fy_node_is_mapping((struct fy_node*)fyn)";
PROCEDURE -nodeByPath(fyn, path, len: SYSTEM.ADDRESS): Node
  "(ADDRESS)fy_node_by_path((struct fy_node*)fyn, (const char*)path, (size_t)len, FYNWF_DONT_FOLLOW)";
PROCEDURE -nodeGetScalar(fyn: Node; lenp: SYSTEM.ADDRESS): SYSTEM.ADDRESS
  "(ADDRESS)fy_node_get_scalar((struct fy_node*)fyn, (size_t*)lenp)";

(* Builds a document from len bytes at str. libfyaml does NOT copy the
   input: scalars of the returned document are spans into it, so the
   memory at str must stay valid and unchanged until DocumentDestroy.
   Never pass the address of a value ARRAY OF CHAR parameter -- voc
   copies those into alloca memory that dies on return, and valgrind
   cannot see the resulting dangling spans (PLAN.md, "Buffer
   lifetime"). Returns 0 on parse failure. *)
PROCEDURE DocumentBuildFromString*(str, len: SYSTEM.ADDRESS): Document;
BEGIN RETURN documentBuildFromString(str, len)
END DocumentBuildFromString;

PROCEDURE DocumentDestroy*(fyd: Document);
BEGIN documentDestroy(fyd)
END DocumentDestroy;

PROCEDURE DocumentRoot*(fyd: Document): Node;
BEGIN RETURN documentRoot(fyd)
END DocumentRoot;

(* fy_node_is_mapping is a static inline in the header, not an exported
   symbol: callable here only because this is inline C. *)
PROCEDURE NodeIsMapping*(fyn: Node): BOOLEAN;
BEGIN RETURN nodeIsMapping(fyn)
END NodeIsMapping;

(* path/len: the path's bytes and length; libfyaml does not keep them
   after the call returns. Returns 0 if there is no such node. *)
PROCEDURE NodeByPath*(fyn: Node; path, len: SYSTEM.ADDRESS): Node;
BEGIN RETURN nodeByPath(fyn, path, len)
END NodeByPath;

(* Returns the address of the scalar's bytes and stores their count in
   len. The bytes are NOT 0X-terminated and may contain 0X: copy
   exactly len bytes. Returns 0 if fyn is not a scalar. *)
PROCEDURE NodeGetScalar*(fyn: Node; VAR len: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
BEGIN RETURN nodeGetScalar(fyn, SYSTEM.ADR(len))
END NodeGetScalar;

END FyThin.
