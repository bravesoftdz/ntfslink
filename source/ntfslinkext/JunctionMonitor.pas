{-----------------------------------------------------------------------------
The contents of this file are subject to the GNU General Public License
Version 1.1 or later (the "License"); you may not use this file except in
compliance with the License. You may obtain a copy of the License at
http://www.gnu.org/copyleft/gpl.html

Software distributed under the License is distributed on an "AS IS" basis,
WITHOUT WARRANTY OF ANY KIND, either expressed or implied. See the License for
the specific language governing rights and limitations under the License.

The Initial Developer of the Original Code is Michael Elsd�rfer, with
contributions from Sebastian Schuberth.

You can find more information at http://elsdoerfer.name/ntfslink
-----------------------------------------------------------------------------}

unit JunctionMonitor;

interface

uses
  Windows, Classes, SysUtils;

// Returns the number of links to a given directory; this function also makes
// sure that any old, invalid or non-existant links are removed.
// The valid links are returned via the second var-Paramter.
function GetFolderLinkCount(Folder: string; var LinksAsString: string): Integer;

// Call this whenever a junction is created; it will store the neccessary
// tracking information in a stream, or the registry.
procedure TrackJunctionCreate(Junction, Target: string);

// If registry tracking is activated, with time coming and going, more and
// more unneccessary space will be wasted, so we call this function, which will
// delete all tracking entries related to not existing folders.
procedure CleanRegistryTrackingInformation;

implementation

uses
  JclNTFS, JclSysInfo, JclRegistry, Global, Constants, ShellObjExtended, ComObj;


function NtfsStreamsSupported(const Volume: string): Boolean;
begin
  Result := fsSupportsReparsePoints in GetVolumeFileSystemFlags(Volume);
end;

function GetFolderLinkCount(Folder: string; var LinksAsString: string): Integer;

  procedure RemoveInvalidTrackingEntries(Links: TStrings); overload;
  var
    i: integer;
  begin
    // Remove all links not existing
    for i := Links.Count - 1 downto 0 do
      if (not DirectoryExists(Links[i])) or
         (not NtfsIsFolderMountPoint(RemoveBackslash(Links[i]))) or
         (AnsiCompareFileName(RemoveBackslash(GetJPDestination(Links[i])),
                              RemoveBackslash(Folder)) <> 0) then
        Links.Delete(i);
  end;

  function ReadFromStream: Integer;
  var
    Handle: THandle;
    LinkList: TStringList;
    {BytesWritten: Cardinal;}
    StrToRead, StrToWrite: string;
  begin
    // Assume zero links
    Result := 0;

    // Open the stream
    Handle := CreateFileW(PWideChar(RemoveBackslash(Folder) + ':' + NTFSLINK_TRACKING_STREAM),
                         {FILE_READ_DATA, not defined in Windows.pas}$1,
                         0, nil, OPEN_EXISTING,
                         FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,
                         0);
    if Handle <> 0 then
      try
        // Read the whole content
        SetString(StrToRead, nil, GetFileSize(Handle, nil));
        FileRead(Handle, Pointer(StrToRead)^, Length(StrToRead));

        // Load everything into a TStringList object
        try
          LinkList := TStringList.Create;
          try
            // Call the overloaded function, which will do the actual work
            LinkList.Text := StrToRead;
            RemoveInvalidTrackingEntries(LinkList);

            // Add the found links to the var param used to return this info
            LinksAsString := LinksAsString + LinkList.Text;

            // Finally, write the up-to-date list back into the stream
            SetFilePointer(Handle, 0, nil, FILE_BEGIN);
            StrToWrite := LinkList.Text;
            {BytesWritten := }FileWrite(Handle, Pointer(StrToWrite)^, Length(StrToWrite));
            SetEndOfFile(Handle);

            // Return the number of links left
            Result := LinkList.Count;
          finally
            LinkList.Free;
          end;
        except
        end;
      finally
        CloseHandle(Handle);
      end;
  end;

  function ReadFromRegistry: Integer;
  var
    LinkList: TStringList;
    i: integer;
  begin
    // Assume zero links
    Result := 0;

    try
      LinkList := TStringList.Create;
      try
        // Read list of links from registry
        if RegGetValueNames(HKEY_LOCAL_MACHINE,
                            NTFSLINK_TRACKINGDATA_KEY + Folder, LinkList) then
        begin
          // Remove all the invalid items from the list
          RemoveInvalidTrackingEntries(LinkList);

          // Return the number of links found
          Result := LinkList.Count;
          // Add the found links to the var param used to return this info
          LinksAsString := LinksAsString + LinkList.Text;

          // Make sure only the existing junctions are stored - delete
          // everything, and than write the clean list
          RegDeleteKeyTree(HKEY_LOCAL_MACHINE, NTFSLINK_TRACKINGDATA_KEY + Folder);
          RegCreateKey(HKEY_LOCAL_MACHINE, NTFSLINK_TRACKINGDATA_KEY + Folder, '');
          for i := 0 to LinkList.Count - 1 do
            RegWriteString(HKEY_LOCAL_MACHINE, NTFSLINK_TRACKINGDATA_KEY + Folder, LinkList[i], '');
        end;
      finally
        LinkList.Free;
      end;
    except
    end;
  end;

begin
  try
    LinksAsString := '';
    // Number is the sum of the entries found in data stream + from registry
    Result := ReadFromStream + ReadFromRegistry;
    // Remove the line break at the end, if existing
    LinksAsString := Trim(LinksAsString);
  except
    Result := 0;
  end;
end;

procedure TrackJunctionCreate(Junction, Target: string);
var
  Handle: THandle;
  {BytesWritten: Cardinal;}
  StrToWrite: string;
  TrackingMode: Integer;
begin
  // Check if this the target path is prefixed with "\??\", if yes, remove it
  if Copy(Target, 1, 4) = '\??\' then
    Delete(Target, 1, 4);

  // Try to extract the tracking mode setting from registry
  TrackingMode := RegReadIntegerDef(HKEY_LOCAL_MACHINE, NTFSLINK_CONFIGURATION,
                                    'JunctionTrackingMode', 0);
  // If Mode = 3 = Deactivated, then exit right here
  if TrackingMode = 3 then exit;

  // If the target file system supports streams, store information there
  if (NtfsStreamsSupported(ExtractFileDrive(Target) + '\')) and
     ((TrackingMode = 0(*Prefer Streams*)) or (TrackingMode = 2(*Always Streams*))) then
  begin
    // Open the file, append the new junction path, close
    Handle := CreateFileW(PWideChar(RemoveBackslash(Target) + ':' + NTFSLINK_TRACKING_STREAM),
                         {FILE_WRITE_DATA, not defined in Windows.pas}$2,
                         0, nil, OPEN_ALWAYS,
                         FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT,
                         0);
    if Handle <> 0 then
      try
        SetFilePointer(Handle, 0, nil, FILE_END);
        StrToWrite := Junction + #13#10;
        {BytesWritten := }FileWrite(Handle, Pointer(StrToWrite)^, Length(StrToWrite));
      finally
        CloseHandle(Handle);
      end;
  end

  // If streams are not supported, use the registry
  else begin
    RegCreateKey(HKEY_LOCAL_MACHINE, NTFSLINK_TRACKINGDATA_KEY + Target, '');
    RegWriteString(HKEY_LOCAL_MACHINE, NTFSLINK_TRACKINGDATA_KEY + Target, Junction, '');
  end;
end;

procedure CleanRegistryTrackingInformation;

  function CleanUp(AKey: string): boolean;
  var
    KeyList: TStringList;
    i: Integer;
    DirNotExisting: boolean;
  begin
    // Default result is "true"
    Result := True;

    // Make sure the passed key has a backslash at the end
    AKey := CheckBackslash(AKey);

    // Check if the directory we are currently testing is still existing;
    // We will delete the key only if it is not.
    DirNotExisting := not
      DirectoryExists(Copy(AKey, Length(NTFSLINK_TRACKINGDATA_KEY) + 1, MaxInt));

    try
      KeyList := TStringList.Create;
      try
        // Try to get the subkeys
        RegGetKeyNames(HKEY_LOCAL_MACHINE, AKey, KeyList);

        // Try to delete each of the subkeys
        for i := 0 to KeyList.Count - 1 do
          if not CleanUp(CheckBackslash(AKey + KeyList[i])) then
            Result := False;

        // If Result <> False ==> all subkeys were deleted; now, if the dir
        // reflected by tge current key is not existing, delete the key too.
        // Otherwise return false, to indicate that nothing happend.
        if (Result) and (DirNotExisting) then
          RegDeleteKeyTree(HKEY_LOCAL_MACHINE, AKey)
        else
          Result := False;
      finally
        KeyList.Free;
      end;
    except
      // If anything went wrong, do not delete the key and return false
      Result := False;
    end;
  end;

begin
  CleanUp(NTFSLINK_TRACKINGDATA_KEY);
end;

end.

