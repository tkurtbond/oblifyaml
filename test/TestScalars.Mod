MODULE TestScalars; (* Typed scalar accessors and the mapping-field forms *)

(* Port of alibfyaml's test_scalars.adb on its scalars.yaml: per-node
   conversions and predicates, the required (...Field) and optional
   (...FieldOr) forms, and every failure mode -- MissingKey, and
   DataError for malformed text, out-of-range numbers and non-scalar
   values. Plus what the Ada test can't check here: exact error
   messages and locations, LONGINT/INTEGER edge values, the float
   forms Ada rejects (".5", "5."), and IsNullValue.

   LONGREAL literals need the D suffix (1234.56D0): an unsuffixed
   literal is a REAL, and strtod's result matches voc's D literals
   bit for bit (confirmed live). *)

IMPORT Fyaml, Check;

VAR err: Fyaml.Error;

PROCEDURE IsText(s: Fyaml.String; t: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF s = NIL THEN RETURN FALSE END;
  i := 0;
  WHILE (i < LEN(t)) & (t[i] # 0X) DO
    IF (i >= LEN(s^)) OR (s[i] # t[i]) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN (i < LEN(s^)) & (s[i] = 0X)
END IsText;

(* err.msg is exactly line plus a newline. *)
PROCEDURE MsgIs(line: ARRAY OF CHAR): BOOLEAN;
  VAR i, n: LONGINT;
BEGIN
  IF (err = NIL) OR (err.msg = NIL) THEN RETURN FALSE END;
  n := 0; WHILE (n < LEN(line)) & (line[n] # 0X) DO INC(n) END;
  IF LEN(err.msg^) < n + 2 THEN RETURN FALSE END;
  FOR i := 0 TO n - 1 DO IF err.msg[i] # line[i] THEN RETURN FALSE END END;
  RETURN (err.msg[n] = 0AX) & (err.msg[n + 1] = 0X)
END MsgIs;

PROCEDURE Failed(ok: BOOLEAN; kind: INTEGER; label: ARRAY OF CHAR);
BEGIN Check.Check(~ok & (err # NIL) & (err.kind = kind), label)
END Failed;

PROCEDURE FromFile;
  VAR d: Fyaml.Document; m, n: Fyaml.Node; ok, b: BOOLEAN; i: INTEGER; l: LONGINT;
    r, r2: REAL; x: LONGREAL; s: Fyaml.String;
BEGIN
  d := Fyaml.ParseFile("scalars.yaml", err);
  m := d.Root();

  (* Per-node accessors and predicates *)
  n := m.Value("int_dec");
  Check.Check(n.IsInteger() & n.IsReal() & ~n.IsBoolean(), "int_dec: IsInteger, IsReal, not IsBoolean");
  Check.Check(n.IntegerValue(i, err) & (i = 42) & (err = NIL), "IntegerValue(int_dec) = 42, err NIL");
  Check.Check(n.LongIntValue(l, err) & (l = 42), "LongIntValue(int_dec) = 42");
  Check.Check(n.RealValue(r, err) & (r = 42.0), "RealValue(int_dec) = 42.0");
  Check.Check(n.LongRealValue(x, err) & (x = 42.0D0), "LongRealValue(int_dec) = 42.0");
  n := m.Value("bool_true");
  Check.Check(n.IsBoolean() & ~n.IsInteger() & ~n.IsReal(), "bool_true: IsBoolean only");
  Check.Check(n.BooleanValue(b, err) & b, "BooleanValue(bool_true) = TRUE");
  n := m.Value("not_scalar");
  Check.Check(~n.IsInteger() & ~n.IsReal() & ~n.IsBoolean(), "predicates are FALSE for a mapping");

  (* Required and ...Field: happy path *)
  n := m.Required("name", err);
  Check.Check((n # NIL) & (err = NIL) & n.ScalarIs("widget"), "Required(name) = widget");
  Check.Check(m.IntegerField("int_dec", i, err) & (i = 42), "IntegerField(int_dec) = 42");
  Check.Check(m.IntegerField("int_neg", i, err) & (i = -7), "IntegerField(int_neg) = -7");
  Check.Check(m.IntegerField("int_hex", i, err) & (i = 26), "IntegerField(int_hex) = 26");
  Check.Check(m.IntegerField("int_oct", i, err) & (i = 15), "IntegerField(int_oct) = 15");
  Check.Check(m.IntegerField("int_zero", i, err) & (i = 0), "IntegerField(int_zero) = 0");
  Check.Check(m.IntegerField("int_bin", i, err) & (i = 10), "IntegerField(int_bin) = 10 (0b extension)");
  Check.Check(m.IntegerField("int_underscore", i, err) & (i = 1000000), "IntegerField(int_underscore) = 1000000 (_ extension)");
  Check.Check(m.IntegerField("int_hex_underscore", i, err) & (i = 65535), "IntegerField(int_hex_underscore) = 65535");
  Check.Check(m.IntegerField("int_hex_neg", i, err) & (i = -26), "IntegerField(int_hex_neg) = -26 (sign + 0x)");
  Check.Check(m.LongIntField("int_dec", l, err) & (l = 42), "LongIntField(int_dec) = 42");
  Check.Check(m.LongIntField("big_int", l, err) & (l = 5000000000), "LongIntField(big_int) = 5000000000");

  Check.Check(m.RealField("float_val", r, err) & (r = 3.5), "RealField(float_val) = 3.5");
  Check.Check(m.RealField("float_exp", r, err) & (r = 150.0), "RealField(float_exp) = 150.0");
  Check.Check(m.RealField("float_neg", r, err) & (r = -2.25), "RealField(float_neg) = -2.25");
  r2 := SHORT(1234.56D0);
  Check.Check(m.RealField("float_underscore", r, err) & (r = r2), "RealField(float_underscore) = 1234.56 (_ extension)");
  Check.Check(m.LongRealField("float_underscore", x, err) & (x = 1234.56D0), "LongRealField(float_underscore) = 1234.56, exactly");
  Check.Check(m.LongRealField("float_overflow", x, err) & (x = 1.0D40), "LongRealField(float_overflow) = 1.0e40");

  Check.Check(m.BooleanField("bool_true", b, err) & b, "BooleanField(bool_true)");
  Check.Check(m.BooleanField("bool_True", b, err) & b, "BooleanField(bool_True)");
  Check.Check(m.BooleanField("bool_TRUE", b, err) & b, "BooleanField(bool_TRUE)");
  Check.Check(m.BooleanField("bool_false", b, err) & ~b, "BooleanField(bool_false)");
  Check.Check(m.BooleanField("bool_False", b, err) & ~b, "BooleanField(bool_False)");
  Check.Check(m.BooleanField("bool_FALSE", b, err) & ~b, "BooleanField(bool_FALSE)");
  Check.Check(m.StringField("name", s, err) & IsText(s, "widget"), "StringField(name) = widget");

  (* MissingKey *)
  n := m.Required("does_not_exist", err);
  Check.Check((n = NIL) & (err # NIL) & (err.kind = Fyaml.MissingKey), "Required(does_not_exist): NIL + MissingKey");
  Check.Check(MsgIs('scalars.yaml: error: /: missing required key "does_not_exist"'), "MissingKey message");
  Check.Check(IsText(err.path, "/") & IsText(err.file, "scalars.yaml") & (err.line = 0), "MissingKey path is the mapping's; no location");
  i := 7;
  Failed(m.IntegerField("does_not_exist", i, err), Fyaml.MissingKey, "IntegerField(does_not_exist): MissingKey");
  Check.Check(i = 7, "v is unchanged on failure");

  (* DataError: malformed; StringField takes any text *)
  Failed(m.IntegerField("malformed", i, err), Fyaml.DataError, "IntegerField(malformed): DataError");
  Check.Check(MsgIs('scalars.yaml:50:12: error: /malformed: not a valid integer: "banana"'), "DataError message has file:line:column and path");
  Check.Check((err.line = 50) & (err.column = 12) & IsText(err.path, "/malformed"), "DataError line, column, path fields");
  Failed(m.LongIntField("malformed", l, err), Fyaml.DataError, "LongIntField(malformed): DataError");
  Failed(m.RealField("malformed", r, err), Fyaml.DataError, "RealField(malformed): DataError");
  Failed(m.LongRealField("malformed", x, err), Fyaml.DataError, "LongRealField(malformed): DataError");
  Failed(m.BooleanField("malformed", b, err), Fyaml.DataError, "BooleanField(malformed): DataError");
  Check.Check(MsgIs('scalars.yaml:50:12: error: /malformed: not a valid boolean: "banana"'), "not a valid boolean message");
  Check.Check(m.StringField("malformed", s, err) & IsText(s, "banana") & (err = NIL), "StringField(malformed) = banana, err NIL again");

  Failed(m.IntegerField("bad_underscore_leading", i, err), Fyaml.DataError, "IntegerField(_123): DataError");
  Failed(m.IntegerField("bad_underscore_trailing", i, err), Fyaml.DataError, "IntegerField(123_): DataError");
  Failed(m.IntegerField("bad_underscore_double", i, err), Fyaml.DataError, "IntegerField(1__2): DataError");
  Failed(m.IntegerField("bad_binary", i, err), Fyaml.DataError, "IntegerField(0b102): DataError");

  (* DataError: out of range *)
  Failed(m.IntegerField("big_int", i, err), Fyaml.DataError, "IntegerField(big_int): DataError (overflow)");
  Check.Check(MsgIs('scalars.yaml:23:10: error: /big_int: integer out of range: "5000000000"'), "out of range message");
  Failed(m.RealField("float_overflow", r, err), Fyaml.DataError, "RealField(float_overflow): DataError (overflow)");
  Failed(m.LongIntField("huge_int", l, err), Fyaml.DataError, "LongIntField(huge_int): DataError (overflow)");
  Failed(m.LongRealField("huge_float", x, err), Fyaml.DataError, "LongRealField(huge_float): DataError (overflow)");
  Check.Check(MsgIs('scalars.yaml:69:13: error: /huge_float: float out of range: "1.0e400"'), "float out of range message");

  (* DataError: not a scalar, even with a default *)
  n := m.Required("not_scalar", err);
  Check.Check((n # NIL) & n.IsMapping(), "Required(not_scalar) is a mapping");
  Failed(m.IntegerField("not_scalar", i, err), Fyaml.DataError, "IntegerField(not_scalar): DataError");
  Check.Check(MsgIs("scalars.yaml:46:1: error: /not_scalar: not a scalar value"), "not a scalar: located at its key");
  Failed(m.BooleanFieldOr("not_scalar", TRUE, b, err), Fyaml.DataError, "BooleanFieldOr(not_scalar, default): DataError anyway");
  Failed(m.StringFieldOr("not_scalar", "x", s, err), Fyaml.DataError, "StringFieldOr(not_scalar, default): DataError anyway");

  (* ...FieldOr: absent gives the default *)
  Check.Check(m.IntegerFieldOr("absent", 99, i, err) & (i = 99) & (err = NIL), "IntegerFieldOr(absent, 99) = 99, err NIL");
  Check.Check(m.LongIntFieldOr("absent", 99, l, err) & (l = 99), "LongIntFieldOr(absent, 99) = 99");
  Check.Check(m.RealFieldOr("absent", 9.5, r, err) & (r = 9.5), "RealFieldOr(absent, 9.5) = 9.5");
  Check.Check(m.LongRealFieldOr("absent", 9.5D0, x, err) & (x = 9.5D0), "LongRealFieldOr(absent, 9.5) = 9.5");
  Check.Check(m.BooleanFieldOr("absent", TRUE, b, err) & b, "BooleanFieldOr(absent, TRUE) = TRUE");
  Check.Check(m.StringFieldOr("absent", "fallback", s, err) & IsText(s, "fallback"), "StringFieldOr(absent) = fallback");

  (* ...FieldOr: present gives the value *)
  Check.Check(m.IntegerFieldOr("int_dec", 0, i, err) & (i = 42), "IntegerFieldOr(int_dec, 0) = 42");
  Check.Check(m.LongIntFieldOr("big_int", 0, l, err) & (l = 5000000000), "LongIntFieldOr(big_int, 0) = 5000000000");
  Check.Check(m.RealFieldOr("float_val", 0.0, r, err) & (r = 3.5), "RealFieldOr(float_val, 0) = 3.5");
  Check.Check(m.LongRealFieldOr("float_overflow", 0.0D0, x, err) & (x = 1.0D40), "LongRealFieldOr(float_overflow, 0) = 1.0e40");
  Check.Check(m.BooleanFieldOr("bool_true", FALSE, b, err) & b, "BooleanFieldOr(bool_true, FALSE) = TRUE");
  Check.Check(m.StringFieldOr("name", "x", s, err) & IsText(s, "widget"), "StringFieldOr(name, x) = widget");
  Failed(m.IntegerFieldOr("malformed", 0, i, err), Fyaml.DataError, "IntegerFieldOr(malformed, 0): DataError, not the default");

  d.Close
END FromFile;

(* Edge values and forms, from a string document *)
PROCEDURE Edges;
  VAR d: Fyaml.Document; m, n: Fyaml.Node; i: INTEGER; l: LONGINT; x: LONGREAL; ok: BOOLEAN;
BEGIN
  d := Fyaml.ParseString(
    "{lmin: -9223372036854775808, lmax: 9223372036854775807, lover: 9223372036854775808, lunder: -9223372036854775809, hmax: 0x7FFFFFFFFFFFFFFF, hmin: -0x8000000000000000, hover: 0x8000000000000000, imax: 2147483647, imin: -2147483648, iover: 2147483648, iunder: -2147483649, lead: .5, trail: 5., exp: 1.5E-2, bare: ., noexp: 1e, hex: 0x1A, inf: .inf, sep: 1_000.0, spaced: ' 42 ', prefix: 0x, plus: +7}",
    err);
  m := d.Root();
  Check.Check(m.LongIntField("lmin", l, err) & (l = MIN(LONGINT)), "MIN(LONGINT) parses");
  Check.Check(m.LongIntField("lmax", l, err) & (l = MAX(LONGINT)), "MAX(LONGINT) parses");
  Failed(m.LongIntField("lover", l, err), Fyaml.DataError, "MAX(LONGINT)+1 is out of range");
  Failed(m.LongIntField("lunder", l, err), Fyaml.DataError, "MIN(LONGINT)-1 is out of range");
  Check.Check(m.LongIntField("hmax", l, err) & (l = MAX(LONGINT)), "0x7FFFFFFFFFFFFFFF = MAX(LONGINT)");
  Check.Check(m.LongIntField("hmin", l, err) & (l = MIN(LONGINT)), "-0x8000000000000000 = MIN(LONGINT)");
  Failed(m.LongIntField("hover", l, err), Fyaml.DataError, "0x8000000000000000 is out of range");
  Check.Check(m.IntegerField("imax", i, err) & (i = MAX(INTEGER)), "MAX(INTEGER) parses");
  Check.Check(m.IntegerField("imin", i, err) & (i = MIN(INTEGER)), "MIN(INTEGER) parses");
  Failed(m.IntegerField("iover", i, err), Fyaml.DataError, "MAX(INTEGER)+1 is out of range for IntegerField");
  Failed(m.IntegerField("iunder", i, err), Fyaml.DataError, "MIN(INTEGER)-1 is out of range for IntegerField");
  Check.Check(m.LongIntField("iover", l, err) & (l = 2147483648), "...but fits LongIntField");
  Failed(m.IntegerField("prefix", i, err), Fyaml.DataError, "a bare 0x prefix is not an integer");
  Check.Check(m.IntegerField("plus", i, err) & (i = 7), "+7 = 7");

  Check.Check(m.LongRealField("lead", x, err) & (x = 0.5D0), ".5 = 0.5 (core schema; Ada rejects it)");
  Check.Check(m.LongRealField("trail", x, err) & (x = 5.0D0), "5. = 5.0 (core schema; Ada rejects it)");
  Check.Check(m.LongRealField("exp", x, err) & (x = 1.5D-2), "1.5E-2 = 0.015, exactly");
  Failed(m.LongRealField("bare", x, err), Fyaml.DataError, "a lone . is not a float");
  Failed(m.LongRealField("noexp", x, err), Fyaml.DataError, "1e (no exponent digits) is not a float");
  Failed(m.LongRealField("hex", x, err), Fyaml.DataError, "0x1A is not a float");
  Failed(m.LongRealField("inf", x, err), Fyaml.DataError, ".inf is not accepted (deferred)");
  Check.Check(m.LongRealField("sep", x, err) & (x = 1000.0D0), "1_000.0 = 1000.0");
  Check.Check(m.IntegerField("spaced", i, err) & (i = 42), "the text is trimmed: ' 42 ' = 42");

  Failed(m.IntegerField("bare", i, err), Fyaml.DataError, "IntegerField(.): DataError");
  Check.Check(MsgIs('(string-in-memory):1:312: error: /bare: not a valid integer: "."'),
              "  a string document's errors name (string-in-memory)");
  d.Close;

  (* Nulls *)
  d := Fyaml.ParseString("{e: , t: ~, n1: null, n2: Null, n3: NULL, q: '', qn: 'null', s: nothing, m: {}}", err);
  m := d.Root();
  n := m.Value("e"); ok := n.IsNullValue();
  n := m.Value("t"); ok := ok & n.IsNullValue();
  n := m.Value("n1"); ok := ok & n.IsNullValue();
  n := m.Value("n2"); ok := ok & n.IsNullValue();
  n := m.Value("n3"); ok := ok & n.IsNullValue();
  Check.Check(ok, "IsNullValue: empty, ~, null, Null, NULL");
  n := m.Value("q"); Check.Check(~n.IsNullValue(), "IsNullValue: a quoted '' is not null");
  n := m.Value("qn"); Check.Check(~n.IsNullValue(), "IsNullValue: a quoted 'null' is not null");
  n := m.Value("s"); Check.Check(~n.IsNullValue(), "IsNullValue: other text is not null");
  n := m.Value("m"); Check.Check(~n.IsNullValue(), "IsNullValue: a mapping is not null");
  d.Close;

  (* A built document has no file name, and created scalars no location *)
  d := Fyaml.NewDocument();
  m := d.CreateMapping(); d.SetRoot(m);
  ok := m.AppendPair(d.CreateScalar("n"), d.CreateScalar("zz"), err);
  Failed(m.IntegerField("n", i, err), Fyaml.DataError, "built document: DataError");
  Check.Check(MsgIs('/n: error: not a valid integer: "zz"') & (err.line = 0), "  named by path, with no location");
  d.Close
END Edges;

BEGIN
  FromFile;
  Edges;
  Check.Summary
END TestScalars.
