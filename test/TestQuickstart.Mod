MODULE TestQuickstart; (* Read side of libfyaml's examples/quick-start.c *)

(* Port of the read side of alibfyaml's test_quickstart.adb (itself a
   port of libfyaml's examples/quick-start.c), on the same
   config.yaml: parse a file, read nested values, print the current
   configuration. The mutate-and-emit half waits for Phase 2. *)

IMPORT Fyaml, Check, Out;

PROCEDURE Run;
  VAR d: Fyaml.Document; err: Fyaml.Error; root, server, host, port, origins, n: Fyaml.Node;
    s: Fyaml.String;
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

  d.Close
END Run;

BEGIN
  Run;
  Check.Summary
END TestQuickstart.
