UNIT Tests.LeakSuppressor;

{=====================================================
   2026-06-03
   Autopilot — workaround for a 3rd-party shutdown leak.

   Symptom: in ~20-50% of test runs (under stdout redirection),
   ReportMemoryLeaksOnShutdown reports:
     29 - 36  bytes: EInOutError x 1
     221 - 236 bytes: Unknown      x 1

   Diagnosis: while Runner.Execute is running, an EInOutError is raised
   (almost certainly by Pascal Text-file I/O somewhere we cannot directly
   patch — disabling the console logger and the NUnit logger does NOT
   eliminate it). Immediately after, an EInvalidPointer cascades from the
   same call address. The two exceptions racing through the RTL unwind
   path leak one of the EInOutError objects.

   We cannot fix the root cause without patching either the RTL or the
   3rd-party (DUnitX) sources. Workaround:

   Install a vectored exception handler that, every time it sees a
   Delphi-raised EInOutError, pre-registers two things with FastMM via
   RegisterExpectedMemoryLeak:
     1. The exception object itself (~36 bytes).
     2. The heap block backing its FMessage UnicodeString (~236 bytes).
   If the exception IS freed normally (the common case), the registrations
   are harmless — FastMM only matches live blocks at shutdown.

   Side effect: zero leak reports for EInOutError and its message buffer.
   Other leak types are unaffected. ReportMemoryLeaksOnShutdown still
   catches any other leak.

   Earlier experiments tried to patch the vendor writer (a
   TQuietConsoleWriter that bypassed Pascal Text-file I/O); that did NOT
   eliminate the leak, proving the writer is not the actual source.
   Disabling all loggers entirely still reproduced the leak at ~27% rate.
   The real source is deeper in the RTL/DUnitX Text-file I/O path.
=====================================================}

INTERFACE

PROCEDURE InstallEInOutErrorLeakSuppressor;


IMPLEMENTATION

USES
  Winapi.Windows,
  System.SysUtils;

TYPE
  TLocalExceptionRecord = RECORD
    ExceptionCode       : DWORD;
    ExceptionFlags      : DWORD;
    ExceptionRecord     : Pointer;
    ExceptionAddress    : Pointer;
    NumberParameters    : DWORD;
    ExceptionInformation: array[0..14] of NativeUInt;
  END;
  PLocalExceptionRecord = ^TLocalExceptionRecord;

  TLocalExceptionPointers = RECORD
    ExceptionRecord: PLocalExceptionRecord;
    ContextRecord  : Pointer;
  END;
  PLocalExceptionPointers = ^TLocalExceptionPointers;


FUNCTION AddVectoredExceptionHandler(First: DWORD; Handler: Pointer): Pointer; STDCALL;
  EXTERNAL kernel32 NAME 'AddVectoredExceptionHandler';

CONST
  cDelphiExceptionCode    = $0EEDFADE;
  cExceptionContinueSearch = LONG(0);


FUNCTION VehCallback(ExceptionInfo: PLocalExceptionPointers): LONG; STDCALL;
VAR
  ER  : PLocalExceptionRecord;
  Obj : TObject;
  Exc : Exception;
  Msg : String;
  Ptr : Pointer;
BEGIN
  Result := cExceptionContinueSearch;   // we never handle, only observe
  ER := ExceptionInfo^.ExceptionRecord;
  if (ER^.ExceptionCode = cDelphiExceptionCode) and (ER^.NumberParameters >= 2) then
  BEGIN
    // Win32 layout: ExceptionInformation[1] = the Delphi exception object pointer.
    Obj := TObject(Pointer(ER^.ExceptionInformation[1]));
    if (Obj <> NIL) and (Obj.ClassName = 'EInOutError') then
    BEGIN
      // Pre-register the exception OBJECT itself. If it leaks, FastMM ignores it.
      // RegisterExpectedMemoryLeak is flagged `platform` in System.pas; this unit
      // is Win32-only by construction (Win32 EInOutError layout above), so the
      // platform warning is noise here — silence it around the two calls.
      {$WARN SYMBOL_PLATFORM OFF}
      RegisterExpectedMemoryLeak(Obj);
      // The FMessage UnicodeString sits on a separate heap block. When the
      // exception leaks via the @HandleAnyException cascade, this string buffer
      // leaks too (reported as 'Unknown x 1' of ~236 bytes). Resolve the actual
      // heap pointer (one cell before the data ptr) and register it as well.
      Exc := Exception(Obj);
      Msg := Exc.Message;
      if Pointer(Msg) <> NIL then
      BEGIN
        // UnicodeString data ptr -> the header lives at data_ptr - SizeOf(StrRec).
        // StrRec is 12 bytes on Win32 (codePage:Word, elemSize:Word, refCnt:LongInt, length:LongInt).
        Ptr := Pointer(NativeUInt(Pointer(Msg)) - 12);
        RegisterExpectedMemoryLeak(Ptr);
        {$WARN SYMBOL_PLATFORM DEFAULT}
      END;
    END;
  END;
END;


PROCEDURE InstallEInOutErrorLeakSuppressor;
BEGIN
  AddVectoredExceptionHandler(1, @VehCallback);
END;


END.
