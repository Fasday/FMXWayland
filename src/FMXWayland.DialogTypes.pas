{ FMXWayland: public, replaceable dialog backend contract. MIT license. }
unit FMXWayland.DialogTypes;

interface

uses
  System.UITypes, FMX.Dialogs;

type
  TWaylandFileDialogKind = (OpenFile, SaveFile, SelectFolder);
  TWaylandFileFilter = record
    Name: string;
    Patterns: TArray<string>;
  end;
  TWaylandFileDialogRequest = record
    Kind: TWaylandFileDialogKind;
    Title, InitialFile, InitialFolder: string;
    Filters: TArray<TWaylandFileFilter>;
    FilterIndex: Integer; // One based, like TOpenDialog.FilterIndex.
    Multiple, ConfirmOverwrite: Boolean;
  end;

  IFMXWaylandDialogBackend = interface
    ['{EEC02518-487A-4E43-9D41-22D5E5FB00EA}']
    function FileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
      var FilterIndex: Integer): Boolean;
    function MessageDialog(const Message: string; DialogType: TMsgDlgType; Buttons: TMsgDlgButtons;
      DefaultButton: TMsgDlgBtn): TModalResult;
    function InputQuery(const Caption: string; const Prompts: TArray<string>; var Values: TArray<string>): Boolean;
  end;

implementation

end.
