MODULE TestQuickstart; (* libfyaml's examples/quick-start.c *)

(* Port of alibfyaml's test_quickstart.adb (itself a port of
   libfyaml's examples/quick-start.c), on the same config.yaml: parse
   a file, read nested values, print the current configuration, merge
   a {timeout: 45} patch into /server, and emit the result. *)

IMPORT Fyaml, Check, Out;

PROCEDURE Run;
  VAR d: Fyaml.Document; err: Fyaml.Error; root, server, host, port, origins, n, patch, k, v: Fyaml.Node;
    s: Fyaml.String; ok: BOOLEAN;
BEGIN
  d := Fyaml.ParseFile("config.yaml", err);
  IF d = NIL THEN
    Out.String("Failed to parse config.yaml:"); Out.Ln; Out.String(err.msg^);
    Check.Check(FALSE, "parse config.yaml");
    RETURN
  END;
  root := d.Root();
  server := root.ByPath("/server");
  Check.Check(server # NIL, "/server section present");
  IF server = NIL THEN RETURN END;

  host := server.Value("host"); port := server.Value("port");
  Out.String("Current configuration: ");
  s := host.Scalar(); Out.String(s^); Out.String(":");
  s := port.Scalar(); Out.String(s^); Out.Ln;
  Check.Check(host.ScalarIs("localhost") & port.ScalarIs("8080"), "server host:port");

  n := root.ByPath("/database/name");
  Check.Check(n.ScalarIs("production_db"), "/database/name");
  origins := root.Value("allowed_origins");
  Check.Check(origins.IsSequence() & (origins.Length() = 3), "allowed_origins has 3 entries");
  n := origins.Item(1);
  Check.Check(n.ScalarIs("https://www.example.com"), "allowed_origins Item(1)");
  n := root.Value("logging"); n := n.Value("max_size");
  Check.Check(n.ScalarIs("100M"), "logging.max_size stays text");

  (* Merge {timeout: 45} into /server (fy_node_insert rules: keys are
     added or replaced, others kept). This kills root, server, etc. *)
  patch := d.CreateMapping();
  k := d.CreateScalar("timeout"); v := d.CreateScalar("45");
  ok := patch.AppendPair(k, v, err) & d.InsertAt("/server", patch, err);
  Check.Check(ok, "InsertAt of the timeout patch");
  Out.String("Updated timeout setting"); Out.Ln;
  root := d.Root();
  n := root.ByPath("/server/timeout");
  Check.Check((n # NIL) & n.ScalarIs("45"), "/server/timeout = 45");
  n := root.ByPath("/server/host");
  Check.Check(n.ScalarIs("localhost"), "/server/host kept by the merge");

  s := d.ToYAML(Fyaml.emitSortKeys, err);
  Check.Check((s # NIL) & (err = NIL), "ToYAML with emitSortKeys");
  IF s # NIL THEN Out.String("Updated configuration:"); Out.Ln; Out.String(s^) END;

  d.Close
END Run;

BEGIN
  Run;
  Check.Summary
END TestQuickstart.
