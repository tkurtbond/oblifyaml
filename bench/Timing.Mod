MODULE Timing; (* Wall-clock timing and output for the benchmarks *)

IMPORT Platform, Out;

(* Microseconds since the epoch. *)
PROCEDURE Now*(): LONGINT;
  VAR sec, usec: LONGINT;
BEGIN Platform.GetTimeOfDay(sec, usec); RETURN sec * 1000000 + usec
END Now;

(* Prints "<prefix>elapsed_seconds= S.UUUUUU", the line run_stats.sh
   reads (the same format as alibfyaml's benchmarks). *)
PROCEDURE Report*(prefix: ARRAY OF CHAR; usec: LONGINT);
  VAR frac: LONGINT; i: INTEGER; d: ARRAY 7 OF CHAR;
BEGIN
  Out.String(prefix); Out.String("elapsed_seconds= ");
  Out.Int(usec DIV 1000000, 0); Out.Char(".");
  frac := usec MOD 1000000;
  FOR i := 5 TO 0 BY -1 DO d[i] := CHR(ORD("0") + frac MOD 10); frac := frac DIV 10 END;
  d[6] := 0X; Out.String(d); Out.Ln
END Report;

END Timing.
