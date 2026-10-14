{ FMXWayland: the public, replaceable dialog backend contract.
  Written by Hemul GM. Copyright (c) 2026 Fasday and contributors. MIT license, see LICENSE. }

/// <summary>The contract of FMXWayland's dialog backends (FMXWayland.Dialogs): the file dialog request and
/// IFMXWaylandDialogBackend.</summary>
unit FMXWayland.DialogTypes;

interface

uses
  System.UITypes, FMX.Dialogs;

type
  /// <summary>What a file dialog asks for.</summary>
  TWaylandFileDialogKind = (OpenFile, SaveFile, SelectFolder);

  /// <summary>A filter of a file dialog: its name and its glob patterns ('*.txt').</summary>
  TWaylandFileFilter = record
    Name: string;
    Patterns: TArray<string>;
  end;

  /// <summary>A file dialog request.</summary>
  TWaylandFileDialogRequest = record
    Kind: TWaylandFileDialogKind;
    Title, InitialFile, InitialFolder: string;
    Filters: TArray<TWaylandFileFilter>;
    /// <summary>One based, like TOpenDialog.FilterIndex.</summary>
    FilterIndex: Integer;
    Multiple, ConfirmOverwrite: Boolean;
  end;

  /// <summary>A dialog backend: file dialogs, message dialogs and input queries.</summary>
  IFMXWaylandDialogBackend = interface
    ['{EEC02518-487A-4E43-9D41-22D5E5FB00EA}']
    /// <summary>Shows a file dialog; True with the chosen Files, False when cancelled. FilterIndex (one based)
    /// returns the filter chosen.</summary>
    function FileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
      var FilterIndex: Integer): Boolean;
    /// <summary>Shows a message dialog; returns the modal result of the button.</summary>
    function MessageDialog(const Message: string; DialogType: TMsgDlgType; Buttons: TMsgDlgButtons;
      DefaultButton: TMsgDlgBtn): TModalResult;
    /// <summary>Asks for values; True when the user confirmed them.</summary>
    function InputQuery(const Caption: string; const Prompts: TArray<string>; var Values: TArray<string>): Boolean;
  end;

implementation

end.
