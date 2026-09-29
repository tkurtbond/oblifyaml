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
   rather than mirrored as Oberon records -- struct fy_parse_cfg is
   built as a C compound literal inside the call, and struct
   fy_diag_error's fields are read one accessor at a time, so gcc
   computes every layout from the installed header.

   Only the entry points Fyaml actually calls are bound here.

   Types: compiled with -OC (AGENTS.md), but boundary signatures use
   explicit sizes anyway -- SYSTEM.INT32 for C int, SYSTEM.ADDRESS for
   pointers and size_t -- so each one states the C type it carries. *)

IMPORT SYSTEM;

TYPE
  Document* = SYSTEM.ADDRESS;  (* struct fy_document* *)
  Node* = SYSTEM.ADDRESS;      (* struct fy_node* *)
  NodePair* = SYSTEM.ADDRESS;  (* struct fy_node_pair* *)
  Diag* = SYSTEM.ADDRESS;      (* struct fy_diag* *)
  DiagError* = SYSTEM.ADDRESS; (* struct fy_diag_error* *)

PROCEDURE -AincludeFyaml '#include <libfyaml.h>';
PROCEDURE -AincludeStdlib '#include <stdlib.h>';
PROCEDURE -AincludeString '#include <string.h>';

(* ---- Documents ---- *)

(* The parse config: diag receives the errors; resolve sets
   FYPCF_RESOLVE_DOCUMENT (anchors, aliases, merge keys). *)
PROCEDURE -documentBuildFromString(str, len: SYSTEM.ADDRESS; resolve: BOOLEAN; diag: Diag): Document
  "(ADDRESS)fy_document_build_from_string(&(struct fy_parse_cfg){ .flags = (resolve) ? FYPCF_RESOLVE_DOCUMENT : 0, .diag = (struct fy_diag*)diag }, (const char*)str, (size_t)len)";
PROCEDURE -documentBuildFromFile(file: SYSTEM.ADDRESS; resolve: BOOLEAN; diag: Diag): Document
  "(ADDRESS)fy_document_build_from_file(&(struct fy_parse_cfg){ .flags = (resolve) ? FYPCF_RESOLVE_DOCUMENT : 0, .diag = (struct fy_diag*)diag }, (const char*)file)";
PROCEDURE -documentDestroy(fyd: Document)
  "fy_document_destroy((struct fy_document*)fyd)";
PROCEDURE -documentRoot(fyd: Document): Node
  "(ADDRESS)fy_document_root((struct fy_document*)fyd)";

(* Builds a document from len bytes at str. libfyaml does NOT copy the
   input: scalars of the returned document are spans into it, so the
   memory at str must stay valid and unchanged until DocumentDestroy.
   Never pass the address of a value ARRAY OF CHAR parameter -- voc
   copies those into alloca memory that dies on return, and valgrind
   cannot see the resulting dangling spans (PLAN.md, "Buffer
   lifetime"). Returns 0 on parse failure, with the errors collected
   in diag (see DiagCreate). *)
PROCEDURE DocumentBuildFromString*(str, len: SYSTEM.ADDRESS; resolve: BOOLEAN; diag: Diag): Document;
BEGIN RETURN documentBuildFromString(str, len, resolve, diag)
END DocumentBuildFromString;

(* file: address of a 0X-terminated path. Returns 0 on failure. *)
PROCEDURE DocumentBuildFromFile*(file: SYSTEM.ADDRESS; resolve: BOOLEAN; diag: Diag): Document;
BEGIN RETURN documentBuildFromFile(file, resolve, diag)
END DocumentBuildFromFile;

PROCEDURE DocumentDestroy*(fyd: Document);
BEGIN documentDestroy(fyd)
END DocumentDestroy;

(* 0 for an empty document. *)
PROCEDURE DocumentRoot*(fyd: Document): Node;
BEGIN RETURN documentRoot(fyd)
END DocumentRoot;

(* ---- Diagnostics ---- *)

PROCEDURE -diagCreate(): Diag "(ADDRESS)fy_diag_create(NULL)";
PROCEDURE -diagDestroy(diag: Diag) "fy_diag_destroy((struct fy_diag*)diag)";
PROCEDURE -diagSetCollectErrors(diag: Diag; collect: BOOLEAN)
  "fy_diag_set_collect_errors((struct fy_diag*)diag, (bool)(collect))";
PROCEDURE -diagErrorsIterate(diag: Diag; prevp: SYSTEM.ADDRESS): DiagError
  "(ADDRESS)fy_diag_errors_iterate((struct fy_diag*)diag, (void**)prevp)";
PROCEDURE -errorMsg(e: DiagError): SYSTEM.ADDRESS "(ADDRESS)((struct fy_diag_error*)e)->msg";
PROCEDURE -errorFile(e: DiagError): SYSTEM.ADDRESS "(ADDRESS)((struct fy_diag_error*)e)->file";
PROCEDURE -errorLine(e: DiagError): SYSTEM.INT32 "(INT32)((struct fy_diag_error*)e)->line";
PROCEDURE -errorColumn(e: DiagError): SYSTEM.INT32 "(INT32)((struct fy_diag_error*)e)->column";

(* A diag with default config. Pass to a parse call, then destroy it
   exactly once with DiagDestroy. *)
PROCEDURE DiagCreate*(): Diag;
BEGIN RETURN diagCreate()
END DiagCreate;

PROCEDURE DiagDestroy*(diag: Diag);
BEGIN diagDestroy(diag)
END DiagDestroy;

(* With collect = TRUE, errors are kept for DiagErrorsIterate. *)
PROCEDURE DiagSetCollectErrors*(diag: Diag; collect: BOOLEAN);
BEGIN diagSetCollectErrors(diag, collect)
END DiagSetCollectErrors;

(* Iterates the collected errors: start with prev = 0; returns 0 when
   done. Each error lives as long as diag. *)
PROCEDURE DiagErrorsIterate*(diag: Diag; VAR prev: SYSTEM.ADDRESS): DiagError;
BEGIN RETURN diagErrorsIterate(diag, SYSTEM.ADR(prev))
END DiagErrorsIterate;

(* Fields of a collected error. Msg and File are 0X-terminated C
   strings, or 0. Line and Column are 1-based (alibfyaml confirmed
   this; fy_mark's are 0-based). *)
PROCEDURE ErrorMsg*(e: DiagError): SYSTEM.ADDRESS;
BEGIN RETURN errorMsg(e)
END ErrorMsg;

PROCEDURE ErrorFile*(e: DiagError): SYSTEM.ADDRESS;
BEGIN RETURN errorFile(e)
END ErrorFile;

PROCEDURE ErrorLine*(e: DiagError): SYSTEM.INT32;
BEGIN RETURN errorLine(e)
END ErrorLine;

PROCEDURE ErrorColumn*(e: DiagError): SYSTEM.INT32;
BEGIN RETURN errorColumn(e)
END ErrorColumn;

(* ---- Node kinds ---- *)

(* fy_node_is_scalar/_sequence/_mapping are static inlines in the
   header, not exported symbols: callable here only because this is
   inline C. An alias node counts as a scalar (fy_node_is_alias
   further checks the style); with resolve on there are none. *)
PROCEDURE -nodeIsScalar(fyn: Node): BOOLEAN "(BOOLEAN)fy_node_is_scalar((struct fy_node*)fyn)";
PROCEDURE -nodeIsSequence(fyn: Node): BOOLEAN "(BOOLEAN)fy_node_is_sequence((struct fy_node*)fyn)";
PROCEDURE -nodeIsMapping(fyn: Node): BOOLEAN "(BOOLEAN)fy_node_is_mapping((struct fy_node*)fyn)";

PROCEDURE NodeIsScalar*(fyn: Node): BOOLEAN;
BEGIN RETURN nodeIsScalar(fyn)
END NodeIsScalar;

PROCEDURE NodeIsSequence*(fyn: Node): BOOLEAN;
BEGIN RETURN nodeIsSequence(fyn)
END NodeIsSequence;

PROCEDURE NodeIsMapping*(fyn: Node): BOOLEAN;
BEGIN RETURN nodeIsMapping(fyn)
END NodeIsMapping;

(* ---- Scalars ---- *)

PROCEDURE -nodeGetScalar(fyn: Node; lenp: SYSTEM.ADDRESS): SYSTEM.ADDRESS
  "(ADDRESS)fy_node_get_scalar((struct fy_node*)fyn, (size_t*)lenp)";

(* Returns the address of the scalar's bytes and stores their count in
   len. The bytes are NOT 0X-terminated and may contain 0X: copy
   exactly len bytes. Returns 0 if fyn is not a scalar. *)
PROCEDURE NodeGetScalar*(fyn: Node; VAR len: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
BEGIN RETURN nodeGetScalar(fyn, SYSTEM.ADR(len))
END NodeGetScalar;

(* ---- Sequences ---- *)

PROCEDURE -nodeSequenceItemCount(fyn: Node): SYSTEM.INT32
  "(INT32)fy_node_sequence_item_count((struct fy_node*)fyn)";
PROCEDURE -nodeSequenceGetByIndex(fyn: Node; index: SYSTEM.INT32): Node
  "(ADDRESS)fy_node_sequence_get_by_index((struct fy_node*)fyn, (int)index)";
PROCEDURE -nodeSequenceIterate(fyn: Node; prevp: SYSTEM.ADDRESS): Node
  "(ADDRESS)fy_node_sequence_iterate((struct fy_node*)fyn, (void**)prevp)";

PROCEDURE NodeSequenceItemCount*(fyn: Node): SYSTEM.INT32;
BEGIN RETURN nodeSequenceItemCount(fyn)
END NodeSequenceItemCount;

(* 0-based; 0 if out of range. *)
PROCEDURE NodeSequenceGetByIndex*(fyn: Node; index: SYSTEM.INT32): Node;
BEGIN RETURN nodeSequenceGetByIndex(fyn, index)
END NodeSequenceGetByIndex;

(* Start with prev = 0; returns 0 when done. *)
PROCEDURE NodeSequenceIterate*(fyn: Node; VAR prev: SYSTEM.ADDRESS): Node;
BEGIN RETURN nodeSequenceIterate(fyn, SYSTEM.ADR(prev))
END NodeSequenceIterate;

(* ---- Mappings ---- *)

PROCEDURE -nodeMappingItemCount(fyn: Node): SYSTEM.INT32
  "(INT32)fy_node_mapping_item_count((struct fy_node*)fyn)";
PROCEDURE -nodeMappingLookupValueByString(fyn: Node; key, len: SYSTEM.ADDRESS): Node
  "(ADDRESS)fy_node_mapping_lookup_value_by_string((struct fy_node*)fyn, (const char*)key, (size_t)len)";
PROCEDURE -nodeMappingIterate(fyn: Node; prevp: SYSTEM.ADDRESS): NodePair
  "(ADDRESS)fy_node_mapping_iterate((struct fy_node*)fyn, (void**)prevp)";
PROCEDURE -nodePairKey(p: NodePair): Node "(ADDRESS)fy_node_pair_key((struct fy_node_pair*)p)";
PROCEDURE -nodePairValue(p: NodePair): Node "(ADDRESS)fy_node_pair_value((struct fy_node_pair*)p)";

PROCEDURE NodeMappingItemCount*(fyn: Node): SYSTEM.INT32;
BEGIN RETURN nodeMappingItemCount(fyn)
END NodeMappingItemCount;

(* key/len: the key's bytes and length, not kept after the call.
   Returns 0 if there is no such key. *)
PROCEDURE NodeMappingLookupValueByString*(fyn: Node; key, len: SYSTEM.ADDRESS): Node;
BEGIN RETURN nodeMappingLookupValueByString(fyn, key, len)
END NodeMappingLookupValueByString;

(* Start with prev = 0; returns 0 when done. *)
PROCEDURE NodeMappingIterate*(fyn: Node; VAR prev: SYSTEM.ADDRESS): NodePair;
BEGIN RETURN nodeMappingIterate(fyn, SYSTEM.ADR(prev))
END NodeMappingIterate;

PROCEDURE NodePairKey*(p: NodePair): Node;
BEGIN RETURN nodePairKey(p)
END NodePairKey;

PROCEDURE NodePairValue*(p: NodePair): Node;
BEGIN RETURN nodePairValue(p)
END NodePairValue;

(* ---- Paths ---- *)

PROCEDURE -nodeByPath(fyn, path, len: SYSTEM.ADDRESS): Node
  "(ADDRESS)fy_node_by_path((struct fy_node*)fyn, (const char*)path, (size_t)len, FYNWF_DONT_FOLLOW)";
PROCEDURE -nodeGetPath(fyn: Node): SYSTEM.ADDRESS
  "(ADDRESS)fy_node_get_path((struct fy_node*)fyn)";

(* path/len: the path's bytes and length, not kept after the call.
   Returns 0 if there is no such node. *)
PROCEDURE NodeByPath*(fyn: Node; path, len: SYSTEM.ADDRESS): Node;
BEGIN RETURN nodeByPath(fyn, path, len)
END NodeByPath;

(* A malloc'd, 0X-terminated path: the caller frees it with Free.
   alibfyaml confirmed the root gives "/" (not NULL, as the header
   claims); 0 is still possible in principle. *)
PROCEDURE NodeGetPath*(fyn: Node): SYSTEM.ADDRESS;
BEGIN RETURN nodeGetPath(fyn)
END NodeGetPath;

(* ---- libc ---- *)

PROCEDURE -AincludeStdio '#include <stdio.h>';
PROCEDURE -AincludeErrno '#include <errno.h>';

PROCEDURE -free(p: SYSTEM.ADDRESS) "free((void*)p)";
PROCEDURE -strlen(p: SYSTEM.ADDRESS): SYSTEM.ADDRESS "(ADDRESS)strlen((const char*)p)";
PROCEDURE -openErrno(path: SYSTEM.ADDRESS): SYSTEM.INT32
  '({ FILE *f_ = fopen((const char*)path, "r"); int e_ = f_ ? 0 : errno; if (f_) fclose(f_); (INT32)e_; })';
PROCEDURE -strerror(e: SYSTEM.INT32): SYSTEM.ADDRESS "(ADDRESS)strerror((int)e)";

(* 0 if the file at path (0X-terminated) opens for reading, else the
   errno from fopen. libfyaml reports an unopenable file only on
   stderr ("[ERR]: failed to open ...") and collects nothing, so the
   caller checks first. *)
PROCEDURE OpenErrno*(path: SYSTEM.ADDRESS): SYSTEM.INT32;
BEGIN RETURN openErrno(path)
END OpenErrno;

(* A static C string describing errno e. *)
PROCEDURE Strerror*(e: SYSTEM.INT32): SYSTEM.ADDRESS;
BEGIN RETURN strerror(e)
END Strerror;

PROCEDURE Free*(p: SYSTEM.ADDRESS);
BEGIN free(p)
END Free;

PROCEDURE Strlen*(p: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
BEGIN RETURN strlen(p)
END Strlen;

END FyThin.
