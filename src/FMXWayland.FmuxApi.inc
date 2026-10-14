{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE.

  Implementations of the helper routines that the interface of FMUX.Api declares. Included by the FMUX.Api.pas that
  tools\gen-fmux-api.ps1 generates (its implementation section). }

type
  TFmuxStateBit = record
    Bit: Integer;
    Shift: TShiftState;
  end;

const
  // FMUX_STATE_* bit <-> member of TShiftState.
  CFmuxStateBits: array[0..7] of TFmuxStateBit = (
    (Bit: FMUX_STATE_Shift; Shift: [ssShift]),
    (Bit: FMUX_STATE_Alt; Shift: [ssAlt]),
    (Bit: FMUX_STATE_CTRL; Shift: [ssCtrl]),
    (Bit: FMUX_STATE_SUPER; Shift: [ssCommand]),
    (Bit: FMUX_STATE_LEFT; Shift: [ssLeft]),
    (Bit: FMUX_STATE_RIGHT; Shift: [ssRight]),
    (Bit: FMUX_STATE_MIDDLE; Shift: [ssMiddle]),
    (Bit: FMUX_STATE_DOUBLE; Shift: [ssDouble]));

  CMsgDlgBtnBits: array[TMsgDlgBtn] of Integer = (FMUX_BTN_Yes, FMUX_BTN_No, FMUX_BTN_OK, FMUX_BTN_Cancel,
    FMUX_BTN_Abort, FMUX_BTN_Retry, FMUX_BTN_Ignore, FMUX_BTN_All, FMUX_BTN_NoToAll, FMUX_BTN_YesToAll,
    FMUX_BTN_Help, FMUX_BTN_Close);

  CPrintOptionBits: array[TPrintDialogOption] of Integer = (FMUX_poPrintToFile, FMUX_poPageNums, FMUX_poSelection,
    FMUX_poWarning, FMUX_poHelp, FMUX_poDisablePrintToFile);

function FmuxStateToShiftState(State: Integer): TShiftState;
var
  I: Integer;
begin
  Result := [];
  for I := Low(CFmuxStateBits) to High(CFmuxStateBits) do
    if State and CFmuxStateBits[I].Bit <> 0 then
      Result := Result + CFmuxStateBits[I].Shift;
end;

function FmuxShiftStateToState(State: TShiftState): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := Low(CFmuxStateBits) to High(CFmuxStateBits) do
    if CFmuxStateBits[I].Shift <= State then
      Result := Result or CFmuxStateBits[I].Bit;
end;

function FmuxStateToButton(State: Integer): TMouseButton;
begin
  // The button of a press/release event: the state carries the bit of that button; right and middle win over left
  // (a release of the right button while the left one is held is a right-button release).
  Result := TMouseButton.mbLeft;
  if State and FMUX_STATE_RIGHT <> 0 then
    Result := TMouseButton.mbRight
  else if State and FMUX_STATE_MIDDLE <> 0 then
    Result := TMouseButton.mbMiddle;
end;

function FmuxButtonToState(Button: TMouseButton): Integer;
const
  CButtonBits: array[TMouseButton] of Integer = (FMUX_STATE_LEFT, FMUX_STATE_RIGHT, FMUX_STATE_MIDDLE);
begin
  Result := CButtonBits[Button];
end;

function MsgDlgButtonsToButtons(Btns: TMsgDlgButtons): Integer;
var
  B: TMsgDlgBtn;
begin
  Result := 0;
  for B in Btns do
    Result := Result or CMsgDlgBtnBits[B];
end;

function PrinterOptionToInt(AOptions: TPrintDialogOptions): Integer;
var
  O: TPrintDialogOption;
begin
  Result := 0;
  for O in AOptions do
    Result := Result or CPrintOptionBits[O];
end;
