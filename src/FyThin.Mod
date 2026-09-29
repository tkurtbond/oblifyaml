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
PROCEDURE -AincludeStdio '#include <stdio.h>';
PROCEDURE -AincludeErrno '#include <errno.h>';

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

(* ---- Building and mutating ---- *)

PROCEDURE -documentCreate(): Document "(ADDRESS)fy_document_create(NULL)";
PROCEDURE -documentSetRoot(fyd: Document; fyn: Node): SYSTEM.INT32
  "(INT32)fy_document_set_root((struct fy_document*)fyd, (struct fy_node*)fyn)";
PROCEDURE -documentInsertAt(fyd: Document; path, len: SYSTEM.ADDRESS; fyn: Node): SYSTEM.INT32
  "(INT32)fy_document_insert_at((struct fy_document*)fyd, (const char*)path, (size_t)len, (struct fy_node*)fyn)";
PROCEDURE -nodeCreateScalarCopy(fyd: Document; data, size: SYSTEM.ADDRESS): Node
  "(ADDRESS)fy_node_create_scalar_copy((struct fy_document*)fyd, (const char*)data, (size_t)size)";
PROCEDURE -nodeCreateSequence(fyd: Document): Node
  "(ADDRESS)fy_node_create_sequence((struct fy_document*)fyd)";
PROCEDURE -nodeCreateMapping(fyd: Document): Node
  "(ADDRESS)fy_node_create_mapping((struct fy_document*)fyd)";
PROCEDURE -nodeIsAttached(fyn: Node): BOOLEAN
  "(BOOLEAN)fy_node_is_attached((struct fy_node*)fyn)";
PROCEDURE -nodeSequenceAppend(seq, fyn: Node): SYSTEM.INT32
  "(INT32)fy_node_sequence_append((struct fy_node*)seq, (struct fy_node*)fyn)";
PROCEDURE -nodeMappingAppend(map, key, value: Node): SYSTEM.INT32
  "(INT32)fy_node_mapping_append((struct fy_node*)map, (struct fy_node*)key, (struct fy_node*)value)";

PROCEDURE -nodeFree(fyn: Node): SYSTEM.INT32 "(INT32)fy_node_free((struct fy_node*)fyn)";

(* Frees an unattached node and, recursively, everything attached to
   it. Refuses (-1) an attached node. fy_document_destroy frees only
   the tree, so a node created and never attached must be freed this
   way or it leaks (confirmed live with valgrind). *)
PROCEDURE NodeFree*(fyn: Node): SYSTEM.INT32;
BEGIN RETURN nodeFree(fyn)
END NodeFree;

(* An empty document (no root), default config. 0 on failure. *)
PROCEDURE DocumentCreate*(): Document;
BEGIN RETURN documentCreate()
END DocumentCreate;

(* Makes fyn (unattached) the root. 0 on success, -1 if fyn is already
   attached. FREES THE PREVIOUS ROOT TREE, if any (fy-doc.c:
   fy_node_detach_and_free(fyd->root)). *)
PROCEDURE DocumentSetRoot*(fyd: Document; fyn: Node): SYSTEM.INT32;
BEGIN RETURN documentSetRoot(fyd, fyn)
END DocumentSetRoot;

(* Merges fyn into the node at path (fy_node_insert rules: a scalar,
   or a node of a different kind, replaces the target and FREES it; a
   mapping/sequence into the same kind merges, replacing and freeing
   the values of duplicate keys). Then frees fyn -- unconditionally,
   on success and failure (fy-doc.c calls fy_node_free(fyn), which
   refuses only if fyn is attached). 0 on success, -1 on failure,
   e.g. no node at path. *)
PROCEDURE DocumentInsertAt*(fyd: Document; path, len: SYSTEM.ADDRESS; fyn: Node): SYSTEM.INT32;
BEGIN RETURN documentInsertAt(fyd, path, len, fyn)
END DocumentInsertAt;

(* A new unattached scalar holding a copy of size bytes at data. *)
PROCEDURE NodeCreateScalarCopy*(fyd: Document; data, size: SYSTEM.ADDRESS): Node;
BEGIN RETURN nodeCreateScalarCopy(fyd, data, size)
END NodeCreateScalarCopy;

PROCEDURE NodeCreateSequence*(fyd: Document): Node;
BEGIN RETURN nodeCreateSequence(fyd)
END NodeCreateSequence;

PROCEDURE NodeCreateMapping*(fyd: Document): Node;
BEGIN RETURN nodeCreateMapping(fyd)
END NodeCreateMapping;

(* TRUE once fyn is part of a tree (root, item, key, or value). *)
PROCEDURE NodeIsAttached*(fyn: Node): BOOLEAN;
BEGIN RETURN nodeIsAttached(fyn)
END NodeIsAttached;

(* Attaches fyn (unattached, same document) at the end of seq. 0 on
   success; -1 if seq is not a sequence, fyn is attached, or from
   another document. Never frees fyn. *)
PROCEDURE NodeSequenceAppend*(seq, fyn: Node): SYSTEM.INT32;
BEGIN RETURN nodeSequenceAppend(seq, fyn)
END NodeSequenceAppend;

(* Attaches key and value (unattached, same document) as a new last
   pair of map. 0 on success; -1 if map is not a mapping, either node
   is attached or from another document, or key duplicates an
   existing key (fy_node_mapping_pair_insert_prepare). Never frees
   them. *)
PROCEDURE NodeMappingAppend*(map, key, value: Node): SYSTEM.INT32;
BEGIN RETURN nodeMappingAppend(map, key, value)
END NodeMappingAppend;

(* ---- Emitting ---- *)

PROCEDURE -emitDocumentToString(fyd: Document; flags: SYSTEM.INT32): SYSTEM.ADDRESS
  "(ADDRESS)fy_emit_document_to_string((struct fy_document*)fyd, (enum fy_emitter_cfg_flags)flags)";
PROCEDURE -emitDocumentToFile(fyd: Document; flags: SYSTEM.INT32; file: SYSTEM.ADDRESS): SYSTEM.INT32
  "({ errno = 0; int r_ = fy_emit_document_to_file((struct fy_document*)fyd, (enum fy_emitter_cfg_flags)flags, (const char*)file); (INT32)(r_ == 0 ? 0 : (errno ? errno : -1)); })";
PROCEDURE -flagSortKeys(): SYSTEM.INT32 "(INT32)FYECF_SORT_KEYS";
PROCEDURE -flagDefault(): SYSTEM.INT32 "(INT32)FYECF_DEFAULT";
PROCEDURE -flagModeOriginal(): SYSTEM.INT32 "(INT32)FYECF_MODE_ORIGINAL";
PROCEDURE -flagModeBlock(): SYSTEM.INT32 "(INT32)FYECF_MODE_BLOCK";
PROCEDURE -flagModeFlow(): SYSTEM.INT32 "(INT32)FYECF_MODE_FLOW";
PROCEDURE -flagModeFlowOneline(): SYSTEM.INT32 "(INT32)FYECF_MODE_FLOW_ONELINE";
PROCEDURE -flagModeJson(): SYSTEM.INT32 "(INT32)FYECF_MODE_JSON";

(* A malloc'd, 0X-terminated emission of fyd (free it with Free), or 0
   on failure. *)
PROCEDURE EmitDocumentToString*(fyd: Document; flags: SYSTEM.INT32): SYSTEM.ADDRESS;
BEGIN RETURN emitDocumentToString(fyd, flags)
END EmitDocumentToString;

(* Writes fyd to the file named by file (0X-terminated), created or
   truncated. 0 on success, else the errno (e.g. from fopen), or -1
   for a failure that set none. *)
PROCEDURE EmitDocumentToFile*(fyd: Document; flags: SYSTEM.INT32; file: SYSTEM.ADDRESS): SYSTEM.INT32;
BEGIN RETURN emitDocumentToFile(fyd, flags, file)
END EmitDocumentToFile;

(* enum fy_emitter_cfg_flags values, read from the header rather than
   retyped. The mode values form a multi-bit field: combine at most
   one mode with FlagSortKeys. *)
PROCEDURE FlagSortKeys*(): SYSTEM.INT32; BEGIN RETURN flagSortKeys() END FlagSortKeys;
PROCEDURE FlagDefault*(): SYSTEM.INT32; BEGIN RETURN flagDefault() END FlagDefault;
PROCEDURE FlagModeOriginal*(): SYSTEM.INT32; BEGIN RETURN flagModeOriginal() END FlagModeOriginal;
PROCEDURE FlagModeBlock*(): SYSTEM.INT32; BEGIN RETURN flagModeBlock() END FlagModeBlock;
PROCEDURE FlagModeFlow*(): SYSTEM.INT32; BEGIN RETURN flagModeFlow() END FlagModeFlow;
PROCEDURE FlagModeFlowOneline*(): SYSTEM.INT32; BEGIN RETURN flagModeFlowOneline() END FlagModeFlowOneline;
PROCEDURE FlagModeJson*(): SYSTEM.INT32; BEGIN RETURN flagModeJson() END FlagModeJson;

(* ---- libc ---- *)

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
