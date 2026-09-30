unit Tests.LeakSuppressor;

{=============================================================================================================
   2026.09
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - Workaround for a 3rd-party DUnitX shutdown leak: installs a vectored exception handler that pre-registers EInOutError objects with FastMM via RegisterExpectedMemoryLeak.
   - Covers both the exception object (~36 bytes) and its FMessage UnicodeString heap block (~236 bytes) so ReportMemoryLeaksOnShutdown stays silent for this known RTL/DUnitX race.
   - All other leak types are unaffected. Windows-only (vectored exception handler + Win32 exception record layout).
=============================================================================================================}

interface

procedure InstallEInOutErrorLeakSuppressor;


implementation

uses
  Winapi.Windows,
  System.SysUtils;

type
  TLocalExceptionRecord = record
    ExceptionCode       : DWORD;
    ExceptionFlags      : DWORD;
    ExceptionRecord     : Pointer;
    ExceptionAddress    : Pointer;
    NumberParameters    : DWORD;
    ExceptionInformation: array[0..14] of NativeUInt;
  end;
  PLocalExceptionRecord = ^TLocalExceptionRecord;

  TLocalExceptionPointers = record
    ExceptionRecord: PLocalExceptionRecord;
    ContextRecord  : Pointer;
  end;
  PLocalExceptionPointers = ^TLocalExceptionPointers;


function AddVectoredExceptionHandler(First: DWORD; Handler: Pointer): Pointer; stdcall;
  external kernel32 name 'AddVectoredExceptionHandler';

const
  cDelphiExceptionCode    = $0EEDFADE;
  cExceptionContinueSearch = LONG(0);


function VehCallback(ExceptionInfo: PLocalExceptionPointers): LONG; stdcall;
var
  ER  : PLocalExceptionRecord;
  Obj : TObject;
  Exc : Exception;
  Msg : String;
  Ptr : Pointer;
begin
  Result := cExceptionContinueSearch;   // we never handle, only observe
  ER := ExceptionInfo^.ExceptionRecord;
  if (ER^.ExceptionCode = cDelphiExceptionCode) and (ER^.NumberParameters >= 2) then
  begin
    // Win32 layout: ExceptionInformation[1] = the Delphi exception object pointer.
    Obj := TObject(Pointer(ER^.ExceptionInformation[1]));
    if (Obj <> nil) and (Obj.ClassName = 'EInOutError') then
    begin
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
      if Pointer(Msg) <> nil then
      begin
        // UnicodeString data ptr -> the header lives at data_ptr - SizeOf(StrRec).
        // StrRec is 12 bytes on Win32 (codePage:Word, elemSize:Word, refCnt:LongInt, length:LongInt).
        Ptr := Pointer(NativeUInt(Pointer(Msg)) - 12);
        RegisterExpectedMemoryLeak(Ptr);
        {$WARN SYMBOL_PLATFORM DEFAULT}
      end;
    end;
  end;
end;


procedure InstallEInOutErrorLeakSuppressor;
begin
  AddVectoredExceptionHandler(1, @VehCallback);
end;


end.
