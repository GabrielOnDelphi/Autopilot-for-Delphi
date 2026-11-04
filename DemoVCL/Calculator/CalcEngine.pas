UNIT CalcEngine;

(*=====================================================
   2026.09.22
   GabrielMoraru.com/autopilot

   Pure arithmetic for the Mini Calc demo. No VCL, no state -- trivially
   unit-testable. The three functions below are correct; if a result on screen
   looks wrong, the fault is in how a button is wired, not in the math here.
=====================================================*)

INTERFACE

FUNCTION Add     (A, B: Integer): Integer;
FUNCTION Subtract(A, B: Integer): Integer;
FUNCTION Multiply(A, B: Integer): Integer;

IMPLEMENTATION

FUNCTION Add(A, B: Integer): Integer;
BEGIN
  Result := A + B;
END;


FUNCTION Subtract(A, B: Integer): Integer;
BEGIN
  Result := A - B;
END;


FUNCTION Multiply(A, B: Integer): Integer;
BEGIN
  Result := A * B;
END;


END.
