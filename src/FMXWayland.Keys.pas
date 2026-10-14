{ FMXWayland: native Wayland platform for Delphi FireMonkey on Linux.
  Copyright (c) 2026 Fasday. MIT license, see LICENSE. }

/// <summary>Keyboard mapping: XKB keysyms and Linux evdev key codes to FMX virtual keys (System.UITypes vk*).
/// </summary>
unit FMXWayland.Keys;

interface

/// <summary>The FMX virtual key of a key: non-character keys (editing, navigation, function, keypad, modifier keys)
/// by their keysym; character keys by their position (evdev code, as on a US keyboard, so shortcuts such as Ctrl+C
/// work with any layout - Windows does the same with its virtual keys); 0 if there is none.</summary>
function KeyToVirtualKey(const AKeysym, AEvdevCode: UInt32): Word;

implementation

uses
  System.UITypes;

type
  TKeyMap = record
    Code: UInt32;
    Vk: Word;
  end;

const
  CKeysymMap: array[0..92] of TKeyMap = (
    (Code: $FF08; Vk: vkBack), (Code: $FF09; Vk: vkTab), (Code: $FE20; Vk: vkTab), (Code: $FF0B; Vk: vkClear),
    (Code: $FF0D; Vk: vkReturn), (Code: $FF13; Vk: vkPause), (Code: $FF14; Vk: vkScroll),
    (Code: $FF15; Vk: vkSnapshot), (Code: $FF1B; Vk: vkEscape), (Code: $FFFF; Vk: vkDelete),
    (Code: $FF50; Vk: vkHome), (Code: $FF51; Vk: vkLeft), (Code: $FF52; Vk: vkUp), (Code: $FF53; Vk: vkRight),
    (Code: $FF54; Vk: vkDown), (Code: $FF55; Vk: vkPrior), (Code: $FF56; Vk: vkNext), (Code: $FF57; Vk: vkEnd),
    (Code: $FF58; Vk: vkClear), (Code: $FF60; Vk: vkSelect), (Code: $FF61; Vk: vkSnapshot),
    (Code: $FF62; Vk: vkExecute), (Code: $FF63; Vk: vkInsert), (Code: $FF67; Vk: vkApps), (Code: $FF6A; Vk: vkHelp),
    (Code: $FF6B; Vk: vkPause), (Code: $FF7F; Vk: vkNumLock),
    // keypad
    (Code: $FF80; Vk: vkSpace), (Code: $FF89; Vk: vkTab), (Code: $FF8D; Vk: vkReturn), (Code: $FF95; Vk: vkHome),
    (Code: $FF96; Vk: vkLeft), (Code: $FF97; Vk: vkUp), (Code: $FF98; Vk: vkRight), (Code: $FF99; Vk: vkDown),
    (Code: $FF9A; Vk: vkPrior), (Code: $FF9B; Vk: vkNext), (Code: $FF9C; Vk: vkEnd), (Code: $FF9D; Vk: vkClear),
    (Code: $FF9E; Vk: vkInsert), (Code: $FF9F; Vk: vkDelete), (Code: $FFAA; Vk: vkMultiply), (Code: $FFAB; Vk: vkAdd),
    (Code: $FFAC; Vk: vkSeparator), (Code: $FFAD; Vk: vkSubtract), (Code: $FFAE; Vk: vkDecimal),
    (Code: $FFAF; Vk: vkDivide), (Code: $FFB0; Vk: vkNumpad0), (Code: $FFB1; Vk: vkNumpad1),
    (Code: $FFB2; Vk: vkNumpad2), (Code: $FFB3; Vk: vkNumpad3), (Code: $FFB4; Vk: vkNumpad4),
    (Code: $FFB5; Vk: vkNumpad5), (Code: $FFB6; Vk: vkNumpad6), (Code: $FFB7; Vk: vkNumpad7),
    (Code: $FFB8; Vk: vkNumpad8), (Code: $FFB9; Vk: vkNumpad9), (Code: $FFBD; Vk: vkEqual),
    // modifiers
    (Code: $FFE1; Vk: vkShift), (Code: $FFE2; Vk: vkShift), (Code: $FFE3; Vk: vkControl),
    (Code: $FFE4; Vk: vkControl), (Code: $FFE5; Vk: vkCapital), (Code: $FFE6; Vk: vkCapital),
    (Code: $FFE7; Vk: vkMenu), (Code: $FFE8; Vk: vkMenu), (Code: $FFE9; Vk: vkMenu), (Code: $FFEA; Vk: vkMenu),
    (Code: $FE03; Vk: vkRMenu), (Code: $FFEB; Vk: vkLWin), (Code: $FFEC; Vk: vkRWin), (Code: $FFED; Vk: vkLWin),
    (Code: $FFEE; Vk: vkRWin),
    // XF86 multimedia and browser keys
    (Code: $1008FF11; Vk: vkVolumeDown), (Code: $1008FF12; Vk: vkVolumeMute), (Code: $1008FF13; Vk: vkVolumeUp),
    (Code: $1008FF14; Vk: vkMediaPlayPause), (Code: $1008FF15; Vk: vkMediaStop),
    (Code: $1008FF16; Vk: vkMediaPrevTrack), (Code: $1008FF17; Vk: vkMediaNextTrack),
    (Code: $1008FF26; Vk: vkBrowserBack), (Code: $1008FF27; Vk: vkBrowserForward),
    (Code: $1008FF29; Vk: vkBrowserRefresh), (Code: $1008FF28; Vk: vkBrowserStop),
    (Code: $1008FF1B; Vk: vkBrowserSearch), (Code: $1008FF30; Vk: vkBrowserFavorites),
    (Code: $1008FF18; Vk: vkBrowserHome), (Code: $1008FF19; Vk: vkLaunchMail), (Code: $1008FF2F; Vk: vkSleep),
    (Code: $1008FF1D; Vk: vkLaunchApp2), (Code: $1008FF5D; Vk: vkLaunchApp1), (Code: $1008FF32; Vk: vkLaunchMediaSelect),
    (Code: $FF6C; Vk: vkCancel));

  // evdev codes (linux/input-event-codes.h) of the character keys -> virtual key at that place on a US keyboard.
  CEvdevMap: array[0..48] of TKeyMap = (
    (Code: 2; Vk: vk1), (Code: 3; Vk: vk2), (Code: 4; Vk: vk3), (Code: 5; Vk: vk4), (Code: 6; Vk: vk5),
    (Code: 7; Vk: vk6), (Code: 8; Vk: vk7), (Code: 9; Vk: vk8), (Code: 10; Vk: vk9), (Code: 11; Vk: vk0),
    (Code: 12; Vk: vkMinus), (Code: 13; Vk: vkEqual), (Code: 16; Vk: vkQ), (Code: 17; Vk: vkW), (Code: 18; Vk: vkE),
    (Code: 19; Vk: vkR), (Code: 20; Vk: vkT), (Code: 21; Vk: vkY), (Code: 22; Vk: vkU), (Code: 23; Vk: vkI),
    (Code: 24; Vk: vkO), (Code: 25; Vk: vkP), (Code: 26; Vk: vkLeftBracket), (Code: 27; Vk: vkRightBracket),
    (Code: 30; Vk: vkA), (Code: 31; Vk: vkS), (Code: 32; Vk: vkD), (Code: 33; Vk: vkF), (Code: 34; Vk: vkG),
    (Code: 35; Vk: vkH), (Code: 36; Vk: vkJ), (Code: 37; Vk: vkK), (Code: 38; Vk: vkL), (Code: 39; Vk: vkSemicolon),
    (Code: 40; Vk: vkQuote), (Code: 41; Vk: vkTilde), (Code: 43; Vk: vkBackslash), (Code: 44; Vk: vkZ),
    (Code: 45; Vk: vkX), (Code: 46; Vk: vkC), (Code: 47; Vk: vkV), (Code: 48; Vk: vkB), (Code: 49; Vk: vkN),
    (Code: 50; Vk: vkM), (Code: 51; Vk: vkComma), (Code: 52; Vk: vkPeriod), (Code: 53; Vk: vkSlash),
    (Code: 57; Vk: vkSpace), (Code: 86; Vk: vkOem102));

function KeyToVirtualKey(const AKeysym, AEvdevCode: UInt32): Word;
var
  I: Integer;
begin
  // Function keys F1..F24.
  if (AKeysym >= $FFBE) and (AKeysym <= $FFD5) then
    Exit(vkF1 + Word(AKeysym - $FFBE));
  for I := Low(CKeysymMap) to High(CKeysymMap) do
    if CKeysymMap[I].Code = AKeysym then
      Exit(CKeysymMap[I].Vk);
  for I := Low(CEvdevMap) to High(CEvdevMap) do
    if CEvdevMap[I].Code = AEvdevCode then
      Exit(CEvdevMap[I].Vk);
  // Other keys that produce Latin letters or digits.
  case AKeysym of
    Ord('a')..Ord('z'):
      Result := vkA + Word(AKeysym - Ord('a'));
    Ord('A')..Ord('Z'):
      Result := vkA + Word(AKeysym - Ord('A'));
    Ord('0')..Ord('9'):
      Result := vk0 + Word(AKeysym - Ord('0'));
  else
    Result := 0;
  end;
end;

end.
