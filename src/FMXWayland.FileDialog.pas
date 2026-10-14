{ FMXWayland: file dialogs made with FMX and the Delphi RTL only.
  Written by Hemul GM. Copyright (c) 2026 Fasday and contributors. MIT license, see LICENSE. }

/// <summary>An FMX file dialog form (open, save, select a folder): navigation, hidden files, new folder, filters,
/// overwrite confirmation. FMXWayland's fallback when there is no portal.</summary>
unit FMXWayland.FileDialog;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, FMX.Types, FMX.Controls, FMX.Forms,
  FMX.Layouts, FMX.StdCtrls, FMX.Edit, FMX.ListBox, FMXWayland.DialogTypes;

type
  /// <summary>The file dialog form.</summary>
  TFMXWaylandFileDialog = class(TForm)
    Content: TLayout;
    NavigationRow: TLayout;
    UpButton: TButton;
    HomeButton: TButton;
    NewFolderButton: TButton;
    HiddenCheck: TCheckBox;
    LocationRow: TLayout;
    LocationLabel: TLabel;
    LocationEdit: TEdit;
    GoButton: TButton;
    FileList: TListBox;
    Footer: TLayout;
    NameRow: TLayout;
    NameLabel: TLabel;
    NameEdit: TEdit;
    FilterRow: TLayout;
    FilterLabel: TLabel;
    FilterCombo: TComboBox;
    StatusLabel: TLabel;
    ButtonRow: TLayout;
    AcceptButton: TButton;
    CancelButton: TButton;
    procedure UpClick(Sender: TObject);
    procedure HomeClick(Sender: TObject);
    procedure NewFolderClick(Sender: TObject);
    procedure GoClick(Sender: TObject);
    procedure ReloadClick(Sender: TObject);
    procedure ListChange(Sender: TObject);
    procedure ListDblClick(Sender: TObject);
    procedure NameChange(Sender: TObject);
    procedure AcceptClick(Sender: TObject);
    procedure LocationKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
    procedure DialogKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
  private
    FRequest: TWaylandFileDialogRequest;
    FFolder: string;
    FUpdating: Boolean;
    FPaths: TArray<string>;
    FDirectories: TArray<Boolean>;
    FFiles: TArray<string>;
    function ResolvePath(const Value: string): string;
    function MatchesFilter(const FileName: string): Boolean;
    function SelectedPaths(Directories: Boolean): TArray<string>;
    procedure Navigate(const Folder: string);
    procedure ShowError(const Message: string);
    function ConfirmOverwrite(const FileName: string): Boolean;
  public
    /// <summary>Sets the dialog up for Request (kind, title, filters, initial folder and name).</summary>
    procedure Configure(const Request: TWaylandFileDialogRequest);
    property CurrentFolder: string read FFolder;
  end;

/// <summary>Shows the FMX file dialog modally; True with the chosen Files, False when cancelled.</summary>
function ExecuteFMXFileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
  var FilterIndex: Integer): Boolean;

implementation

uses
  System.IOUtils, System.Math, System.Masks, System.Generics.Collections, System.Generics.Defaults,
  FMX.Dialogs, FMX.DialogHelper, FMX.Dialogs.Default;

{$R *.fmx}

resourcestring
  SOpenCaption = 'Open';
  SSaveCaption = 'Save As';
  SFolderCaption = 'Select Folder';
  SOpenButton = 'Open';
  SSaveButton = 'Save';
  SFolderButton = 'Select';
  SFolderNotFound = 'Folder not found: %s';
  SFileNotFound = 'File not found: %s';
  SCounts = 'Folders: %d   Files: %d';
  SNameMissing = 'Enter a file name.';
  SOneOnly = 'Select one file or one folder.';
  SUnsupportedName = 'The name contains characters that FMX''s file lists cannot hold (line breaks).';
  SNoSaveFolder = 'The folder to save into does not exist.';
  SOverwrite = '%s already exists.' + sLineBreak + 'Do you want to replace it?';
  SNewFolderCaption = 'New Folder';
  SNewFolderPrompt = 'Folder name';
  SNewFolderName = 'New folder';
  SBadFolderName = 'Enter a folder name without path separators.';
  SNameExists = 'That name exists already.';

function ExecuteFMXFileDialog(const Request: TWaylandFileDialogRequest; out Files: TArray<string>;
  var FilterIndex: Integer): Boolean;
var
  Dialog: TFMXWaylandFileDialog;
begin
  MessageDialogCheckInUIThread;
  Files := nil;
  Dialog := TFMXWaylandFileDialog.Create(nil);
  try
    Dialog.Configure(Request);
    Result := Dialog.ShowModal = mrOK;
    if Result then
    begin
      Files := Copy(Dialog.FFiles);
      if Length(Request.Filters) > 0 then
        FilterIndex := Dialog.FilterCombo.ItemIndex + 1;
    end;
  finally
    Dialog.Free;
  end;
end;

procedure TFMXWaylandFileDialog.Configure(const Request: TWaylandFileDialogRequest);
var
  Filter: TWaylandFileFilter;
  Folder: string;
begin
  FRequest := Request;
  case Request.Kind of
    TWaylandFileDialogKind.OpenFile:
      begin
        Caption := SOpenCaption;
        AcceptButton.Text := SOpenButton;
      end;
    TWaylandFileDialogKind.SaveFile:
      begin
        Caption := SSaveCaption;
        AcceptButton.Text := SSaveButton;
      end;
    TWaylandFileDialogKind.SelectFolder:
      begin
        Caption := SFolderCaption;
        AcceptButton.Text := SFolderButton;
      end;
  end;
  if Request.Title <> '' then
    Caption := Request.Title;
  NameRow.Visible := Request.Kind <> TWaylandFileDialogKind.SelectFolder;
  FilterRow.Visible := NameRow.Visible and (Length(Request.Filters) > 0);
  Footer.Height := 72 + IfThen(NameRow.Visible, 34, 0) + IfThen(FilterRow.Visible, 34, 0);
  if Request.Multiple and (Request.Kind <> TWaylandFileDialogKind.SaveFile) then
    FileList.MultiSelectStyle := TMultiSelectStyle.Extended;
  FUpdating := True;
  try
    for Filter in Request.Filters do
      FilterCombo.Items.Add(Filter.Name);
    if FilterCombo.Items.Count > 0 then
      FilterCombo.ItemIndex := EnsureRange(Request.FilterIndex - 1, 0, FilterCombo.Items.Count - 1);
    if Request.Kind <> TWaylandFileDialogKind.SelectFolder then
      NameEdit.Text := TPath.GetFileName(Request.InitialFile);
  finally
    FUpdating := False;
  end;
  Folder := Request.InitialFolder;
  if (Folder = '') and TPath.IsPathRooted(Request.InitialFile) then
  begin
    if (Request.Kind = TWaylandFileDialogKind.SelectFolder) and DirectoryExists(Request.InitialFile) then
      Folder := Request.InitialFile
    else
      Folder := TPath.GetDirectoryName(Request.InitialFile);
  end;
  if Folder = '' then
    Folder := GetCurrentDir;
  if not DirectoryExists(ExpandFileName(Folder)) then
    Folder := GetEnvironmentVariable('HOME');
  if not DirectoryExists(Folder) then
    Folder := '/';
  Navigate(Folder);
  // The keyboard starts where a name is typed (saving) or a file chosen.
  if Request.Kind = TWaylandFileDialogKind.SaveFile then
    ActiveControl := NameEdit
  else
    ActiveControl := FileList;
end;

function TFMXWaylandFileDialog.ResolvePath(const Value: string): string;
var
  Path: string;
begin
  Path := Value;
  if Path = '~' then
    Path := GetEnvironmentVariable('HOME')
  else if Path.StartsWith('~/') then
    Path := TPath.Combine(GetEnvironmentVariable('HOME'), Copy(Path, 3, MaxInt));
  if not TPath.IsPathRooted(Path) then
    Path := TPath.Combine(FFolder, Path);
  Result := ExpandFileName(Path);
end;

function TFMXWaylandFileDialog.MatchesFilter(const FileName: string): Boolean;
var
  Pattern: string;
begin
  if (FilterCombo.ItemIndex < 0) or (FilterCombo.ItemIndex >= Length(FRequest.Filters)) then
    Exit(True);
  for Pattern in FRequest.Filters[FilterCombo.ItemIndex].Patterns do
  begin
    if Pattern.Trim = '*.*' then
      Exit(True);
    // Not case-sensitive, as on Windows and in GTK 4's file chooser.
    if (Pattern.Trim <> '') and MatchesMask(FileName, Pattern.Trim, False) then
      Exit(True);
  end;
  Result := False;
end;

procedure TFMXWaylandFileDialog.ShowError(const Message: string);
begin
  StatusLabel.Text := Message;
  StatusLabel.TextSettings.FontColor := TAlphaColorRec.Firebrick;
end;

procedure TFMXWaylandFileDialog.Navigate(const Folder: string);
var
  Target, Path, Name: string;
  Entries, Paths: TArray<string>;
  Directories, Names: TList<string>;
  Item: TListBoxItem;
  I: Integer;
begin
  try
    Target := ResolvePath(Folder);
    if not DirectoryExists(Target) then
    begin
      ShowError(Format(SFolderNotFound, [Target]));
      Exit;
    end;
    // Read first, so a permission error keeps the previous folder and its contents usable.
    Entries := TDirectory.GetFileSystemEntries(Target);
    Directories := TList<string>.Create;
    Names := TList<string>.Create;
    try
      for Path in Entries do
      begin
        Name := TPath.GetFileName(Path);
        if (not HiddenCheck.IsChecked) and Name.StartsWith('.') then
          Continue;
        if DirectoryExists(Path) then
          Directories.Add(Path)
        else if (FRequest.Kind <> TWaylandFileDialogKind.SelectFolder) and MatchesFilter(Name) then
          Names.Add(Path);
      end;
      Directories.Sort(TIStringComparer.Ordinal);
      Names.Sort(TIStringComparer.Ordinal);
      Paths := Directories.ToArray + Names.ToArray;
      FUpdating := True;
      FileList.BeginUpdate;
      try
        FileList.Clear;
        FPaths := Paths;
        SetLength(FDirectories, Length(Paths));
        for I := 0 to High(Paths) do
        begin
          FDirectories[I] := I < Directories.Count;
          Item := TListBoxItem.Create(FileList);
          Item.Text := TPath.GetFileName(Paths[I]);
          if FDirectories[I] then
            Item.Text := Item.Text + '/';
          Item.Height := 28;
          FileList.AddObject(Item);
        end;
        FFolder := Target;
        LocationEdit.Text := FFolder;
        UpButton.Enabled := FFolder <> '/';
        StatusLabel.TextSettings.FontColor := TAlphaColorRec.Gray;
        StatusLabel.Text := Format(SCounts, [Directories.Count, Names.Count]);
      finally
        FileList.EndUpdate;
        FUpdating := False;
      end;
    finally
      Directories.Free;
      Names.Free;
    end;
  except
    on E: Exception do
      ShowError(E.Message);
  end;
end;

function TFMXWaylandFileDialog.SelectedPaths(Directories: Boolean): TArray<string>;
var
  I, Count: Integer;
begin
  SetLength(Result, Length(FPaths));
  Count := 0;
  for I := 0 to FileList.Count - 1 do
    if FileList.ListItems[I].IsSelected and (FDirectories[I] = Directories) then
    begin
      Result[Count] := FPaths[I];
      Inc(Count);
    end;
  SetLength(Result, Count);
end;

procedure TFMXWaylandFileDialog.UpClick(Sender: TObject);
begin
  Navigate(TPath.GetDirectoryName(ExcludeTrailingPathDelimiter(FFolder)));
end;

procedure TFMXWaylandFileDialog.HomeClick(Sender: TObject);
begin
  Navigate(GetEnvironmentVariable('HOME'));
end;

procedure TFMXWaylandFileDialog.GoClick(Sender: TObject);
begin
  Navigate(LocationEdit.Text);
end;

procedure TFMXWaylandFileDialog.ReloadClick(Sender: TObject);
begin
  if not FUpdating then
    Navigate(FFolder);
end;

procedure TFMXWaylandFileDialog.ListChange(Sender: TObject);
var
  Paths: TArray<string>;
begin
  if FUpdating or (FRequest.Kind = TWaylandFileDialogKind.SelectFolder) then
    Exit;
  Paths := SelectedPaths(False);
  FUpdating := True;
  try
    if Length(Paths) = 1 then
      NameEdit.Text := TPath.GetFileName(Paths[0])
    else if Length(Paths) > 1 then
      NameEdit.Text := '';
  finally
    FUpdating := False;
  end;
end;

procedure TFMXWaylandFileDialog.NameChange(Sender: TObject);
var
  I: Integer;
begin
  if FUpdating then
    Exit;
  FUpdating := True;
  try
    for I := 0 to FileList.Count - 1 do
      FileList.ListItems[I].IsSelected := False;
  finally
    FUpdating := False;
  end;
end;

procedure TFMXWaylandFileDialog.ListDblClick(Sender: TObject);
var
  I: Integer;
begin
  I := FileList.ItemIndex;
  if (I < 0) or (I >= Length(FPaths)) then
    Exit;
  if FDirectories[I] then
    Navigate(FPaths[I])
  else
    AcceptClick(Sender);
end;

function TFMXWaylandFileDialog.ConfirmOverwrite(const FileName: string): Boolean;
var
  R: TModalResult;
begin
  R := mrNone;
  TDialogHelper.MessageDialog(Format(SOverwrite, [FileName]),
    TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], TMsgDlgBtn.mbNo, 0,
    procedure(const Value: TModalResult)
    begin
      R := Value;
    end, True);
  Result := R = mrYes;
end;

procedure TFMXWaylandFileDialog.AcceptClick(Sender: TObject);
var
  Paths, Folders: TArray<string>;
  Path: string;
begin
  try
    Folders := SelectedPaths(True);
    if FRequest.Kind = TWaylandFileDialogKind.SelectFolder then
    begin
      Paths := Folders;
      if Length(Paths) = 0 then
        Paths := [FFolder];
    end
    else
    begin
      Paths := SelectedPaths(False);
      if (Length(Paths) = 0) and (Length(Folders) = 1) and (FRequest.Kind = TWaylandFileDialogKind.OpenFile) then
      begin
        Navigate(Folders[0]);
        Exit;
      end;
      if (FRequest.Kind = TWaylandFileDialogKind.SaveFile) or (Length(Paths) = 0) then
      begin
        if NameEdit.Text = '' then
        begin
          ShowError(SNameMissing);
          NameEdit.SetFocus;
          Exit;
        end;
        Paths := [ResolvePath(NameEdit.Text)];
      end;
      if (Length(Paths) = 1) and DirectoryExists(Paths[0]) then
      begin
        Navigate(Paths[0]);
        Exit;
      end;
    end;
    if not FRequest.Multiple and (Length(Paths) > 1) then
    begin
      ShowError(SOneOnly);
      Exit;
    end;
    for Path in Paths do
    begin
      if Path.Contains(#0) or Path.Contains(#10) or Path.Contains(#13) then
      begin
        ShowError(SUnsupportedName);
        Exit;
      end;
      if (FRequest.Kind = TWaylandFileDialogKind.SelectFolder) and not DirectoryExists(Path) then
      begin
        ShowError(Format(SFolderNotFound, [Path]));
        Exit;
      end;
      if (FRequest.Kind = TWaylandFileDialogKind.OpenFile) and not FileExists(Path) then
      begin
        ShowError(Format(SFileNotFound, [Path]));
        Exit;
      end;
      if FRequest.Kind = TWaylandFileDialogKind.SaveFile then
      begin
        if not DirectoryExists(TPath.GetDirectoryName(Path)) then
        begin
          ShowError(SNoSaveFolder);
          Exit;
        end;
        if FRequest.ConfirmOverwrite and FileExists(Path) and not ConfirmOverwrite(Path) then
          Exit;
      end;
    end;
    FFiles := Paths;
    ModalResult := mrOK;
  except
    on E: Exception do
      ShowError(E.Message);
  end;
end;

procedure TFMXWaylandFileDialog.NewFolderClick(Sender: TObject);
var
  Values: TArray<string>;
  Path: string;
begin
  Values := [SNewFolderName];
  if not DefaultInputQuery(SNewFolderCaption, [SNewFolderPrompt], Values, nil) then
    Exit;
  if (Values[0] = '') or (Values[0] = '.') or (Values[0] = '..') or Values[0].Contains('/') or
    Values[0].Contains(#0) then
  begin
    ShowError(SBadFolderName);
    Exit;
  end;
  Path := TPath.Combine(FFolder, Values[0]);
  try
    if DirectoryExists(Path) or FileExists(Path) then
    begin
      ShowError(SNameExists);
      Exit;
    end;
    TDirectory.CreateDirectory(Path);
    Navigate(Path);
  except
    on E: Exception do
      ShowError(E.Message);
  end;
end;

procedure TFMXWaylandFileDialog.LocationKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar;
  Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    GoClick(Sender);
    Key := 0;
    KeyChar := #0;
  end;
end;

procedure TFMXWaylandFileDialog.DialogKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar;
  Shift: TShiftState);
begin
  if Key = vkEscape then
  begin
    ModalResult := mrCancel;
    Key := 0;
    KeyChar := #0;
  end
  else if (Key = vkL) and (ssCtrl in Shift) then
  begin
    LocationEdit.SetFocus;
    LocationEdit.SelectAll;
    Key := 0;
    KeyChar := #0;
  end
  else if Key = vkF5 then
  begin
    ReloadClick(Sender);
    Key := 0;
    KeyChar := #0;
  end
  else if (Key = vkUp) and (ssAlt in Shift) then
  begin
    UpClick(Sender);
    Key := 0;
    KeyChar := #0;
  end
  else if (Key = vkReturn) and ((ActiveControl = NameEdit) or (ActiveControl = FileList)) then
  begin
    AcceptClick(Sender);
    Key := 0;
    KeyChar := #0;
  end;
end;

end.
