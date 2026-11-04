unit Tests.RaiseCounter;

{=============================================================================================================
   2026.10.07
   www.GabrielMoraru.com
--------------------------------------------------------------------------------------------------------------
   - TRaiseCounter counts the raises of one exception class (descendants included) in the whole process,
     caught ones too: a vectored exception handler sees every raise before any except block runs.
   - Used by the tests that pin "the bridge raises nothing here" (GitHub issue 2): even a swallowed raise halts a
     debugger that stops on language exceptions, and with it the whole app.
   - Win32 only (Delphi exception record layout), like Tests.LeakSuppressor. One counter at a time: the handler is
     a plain stdcall routine, so its state lives in class variables.
=============================================================================================================}

interface

uses
  System.SysUtils;

type
  TRaiseCounter = class
  strict private
    class var FCount : Integer;
    class var FClass : ExceptClass;
    class var FHandle: Pointer;
    class function VehCallback(ExceptionInfo: System.PExceptionPointers): Integer; stdcall; static;
  public
    class procedure Install(AClass: ExceptClass);
    class procedure Uninstall;
    class procedure Reset;
    class function Count: Integer;
  end;


implementation

uses
  Winapi.Windows,
  System.SyncObjs;


function AddVectoredExceptionHandler(First: ULONG; Handler: Pointer): Pointer; stdcall;
  external kernel32 name 'AddVectoredExceptionHandler';
function RemoveVectoredExceptionHandler(Handle: Pointer): ULONG; stdcall;
  external kernel32 name 'RemoveVectoredExceptionHandler';

const
  DelphiExceptionCode     = $0EEDFADE;   // System.pas cDelphiException (declared in its implementation section)
  ExceptionContinueSearch = 0;


// Win32: a Delphi raise passes ExceptAddr and ExceptObject as the first two parameters (System.TExceptionRecord;
// Winapi.Windows redeclares TExceptionRecord without them, hence the System. prefix).
class function TRaiseCounter.VehCallback(ExceptionInfo: System.PExceptionPointers): Integer;
var
  ER: System.PExceptionRecord;
begin
  Result := ExceptionContinueSearch;   // observe only
  ER := ExceptionInfo^.ExceptionRecord;
  if (ER^.ExceptionCode = DelphiExceptionCode) and (ER^.NumberParameters >= 2)
  and (ER^.ExceptObject <> NIL) and (TObject(ER^.ExceptObject) is FClass) then
    TInterlocked.Increment(FCount);
end;


class procedure TRaiseCounter.Install(AClass: ExceptClass);
begin
  Assert(FHandle = NIL, 'TRaiseCounter.Install: a counter is already installed');
  Assert(AClass <> NIL, 'TRaiseCounter.Install: no exception class');
  FClass := AClass;
  FCount := 0;
  FHandle := AddVectoredExceptionHandler(1, @VehCallback);
  if FHandle = NIL then
    RaiseLastOSError;
end;


class procedure TRaiseCounter.Uninstall;
begin
  if FHandle = NIL then exit;
  RemoveVectoredExceptionHandler(FHandle);
  FHandle := NIL;
end;


class procedure TRaiseCounter.Reset;
begin
  TInterlocked.Exchange(FCount, 0);
end;


class function TRaiseCounter.Count: Integer;
begin
  Result := TInterlocked.CompareExchange(FCount, 0, 0);
end;


end.
