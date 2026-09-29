MODULE TestNavigate; (* Walking a nested tree: kinds, Value, Item, iteration, ByPath *)

(* Port of the regression checks in alibfyaml's test_navigate.adb, on
   the same navigate.yaml, plus checks of this binding's own API
   (iterators, Length, Kind, ScalarInto, missing keys). Typed values
   (version = 3 as an integer, etc.) wait for Phase 3; here they are
   compared as text. Indexes are 0-based: alibfyaml's Item (1) is
   Item(0) here. *)

IMPORT Fyaml, Check;

PROCEDURE Run;
  VAR d: Fyaml.Document; err: Fyaml.Error;
    root, n, tags, server, endpoints, teams, k, v, item: Fyaml.Node;
    it: Fyaml.ItemIter; pit: Fyaml.PairIter;
    count: LONGINT; s: Fyaml.String; short: ARRAY 4 OF CHAR; ok: BOOLEAN;
BEGIN
  d := Fyaml.ParseFile("navigate.yaml", err);
  Check.Check(d # NIL, "parse navigate.yaml");
  IF d = NIL THEN RETURN END;
  root := d.Root();

  Check.Check(root.Kind() = Fyaml.KindMapping, "root Kind is KindMapping");
  n := root.Value("name");
  Check.Check(n.ScalarIs("Sample Config"), "top-level name");
  n := root.Value("version");
  Check.Check((n.Kind() = Fyaml.KindScalar) & n.ScalarIs("3"), "top-level version (as text)");
  Check.Check(root.Value("no-such-key") = NIL, "missing key gives NIL");
  Check.Check(root.HasKey("pi") & ~root.HasKey("no-such-key"), "HasKey");

  tags := root.Value("tags");
  Check.Check(tags.Kind() = Fyaml.KindSequence, "tags Kind is KindSequence");
  Check.Check(tags.Length() = 3, "tags Length is 3");
  n := tags.Item(0);
  Check.Check(n.ScalarIs("alpha"), "tags sequence: first tag, Item(0)");
  n := tags.Item(2);
  Check.Check(n.ScalarIs("gamma"), "tags sequence: last tag, Item(2)");

  (* Items visits every element, in order. *)
  count := 0; ok := TRUE;
  tags.Items(it);
  WHILE it.Next(item) DO
    CASE count OF
      0: ok := ok & item.ScalarIs("alpha")
    | 1: ok := ok & item.ScalarIs("beta")
    | 2: ok := ok & item.ScalarIs("gamma")
    ELSE ok := FALSE
    END;
    INC(count)
  END;
  Check.Check(ok & (count = 3), "Items visits alpha, beta, gamma in order");
  Check.Check(~it.Next(item) & (item = NIL), "an exhausted ItemIter stays exhausted");

  server := root.Value("server");
  n := server.Value("port");
  Check.Check(n.ScalarIs("8080"), "nested mapping: server.port");
  Check.Check(server.Length() = 4, "server mapping Length is 4 pairs");

  (* Pairs visits keys in document order. *)
  count := 0; ok := TRUE;
  server.Pairs(pit);
  WHILE pit.Next(k, v) DO
    CASE count OF
      0: ok := ok & k.ScalarIs("host") & v.ScalarIs("localhost")
    | 1: ok := ok & k.ScalarIs("port") & v.ScalarIs("8080")
    | 2: ok := ok & k.ScalarIs("timeout") & v.ScalarIs("30.5")
    | 3: ok := ok & k.ScalarIs("ssl") & v.ScalarIs("true")
    ELSE ok := FALSE
    END;
    INC(count)
  END;
  Check.Check(ok & (count = 4), "Pairs visits server's keys and values in document order");
  Check.Check(~pit.Next(k, v) & (k = NIL) & (v = NIL), "an exhausted PairIter stays exhausted");

  endpoints := root.Value("endpoints");
  n := endpoints.Item(0); n := n.Value("name");
  Check.Check(n.ScalarIs("health"), "sequence of mappings: endpoints Item(0).name");

  (* 4 levels deep: chained steps (no call chaining in Oberon-2) = ByPath *)
  n := root.Value("company"); n := n.Value("departments"); n := n.Item(0);
  teams := n.Value("teams"); n := teams.Item(0); n := n.Value("lead");
  v := root.ByPath("/company/departments/0/teams/0/lead");
  Check.Check(v # NIL, "4 levels deep, ByPath finds the node");
  s := n.Scalar();
  Check.Check(v.ScalarIs(s^), "4 levels deep, step-by-step Value/Item = ByPath");
  Check.Check(v.ScalarIs("Ada Lovelace"), "4 levels deep, expected value");
  Check.Check(root.ByPath("/company/departments/9") = NIL, "ByPath past the end gives NIL");

  (* ScalarInto: exact fit, and truncation reported *)
  n := root.Value("name");
  Check.Check(~n.ScalarInto(short) & (short = "Sam"),
              "ScalarInto truncates to fit and returns FALSE");
  n := tags.Item(1);
  Check.Check(~n.ScalarInto(short) & (short = "bet"),
              "ScalarInto of 'beta' (4 bytes + 0X) into 4 chars is truncated");
  n := root.Value("version");
  Check.Check(n.ScalarInto(short) & (short = "3"), "ScalarInto of '3' fits and returns TRUE");
  Check.Check(n.ScalarLen() = 1, "ScalarLen of '3' is 1");

  d.Close
END Run;

BEGIN
  Run;
  Check.Summary
END TestNavigate.
