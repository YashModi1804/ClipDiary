Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "WinVer.nsh"
!include "x64.nsh"

!ifndef APP_VERSION
  !error "Build through windows/scripts/package.py to supply the release inputs."
!endif
Name "ClipDiary"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\ClipDiary"
InstallDirRegKey HKCU "Software\ClipDiary" "InstallDir"
BrandingText "ClipDiary · local and open source"
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName" "ClipDiary"
VIAddVersionKey /LANG=1033 "FileDescription" "ClipDiary Windows Setup"
VIAddVersionKey /LANG=1033 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright 2026 Yash Modi"
Icon "${REPOSITORY}\windows\ClipDiary.Windows\Assets\ClipDiary.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\ClipDiary.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open ClipDiary"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${REPOSITORY}\LICENSE"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  SetShellVarContext current
  ${IfNot} ${AtLeastBuild} 19045
    MessageBox MB_OK|MB_ICONSTOP "ClipDiary requires Windows 10 version 22H2 or newer. Windows 11 is recommended."
    Abort
  ${EndIf}
  !if "${APP_RID}" == "win-arm64"
    ${IfNot} ${IsNativeARM64}
      MessageBox MB_OK|MB_ICONSTOP "This installer is for Windows on ARM64. Use the win-x64 download for Intel or AMD PCs."
      Abort
    ${EndIf}
  !else
    ${IfNot} ${RunningX64}
      MessageBox MB_OK|MB_ICONSTOP "This installer requires 64-bit Windows."
      Abort
    ${EndIf}
  !endif
FunctionEnd

Section "ClipDiary"
  ; The new helper can also close an instance running from an old portable folder.
  InitPluginsDir
  SetOutPath "$PLUGINSDIR\ClipDiaryUpdate"
  File /oname=ClipDiary.exe "${PUBLISH_DIR}\ClipDiary.exe"
  ExecWait '"$PLUGINSDIR\ClipDiaryUpdate\ClipDiary.exe" --quit' $0
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONSTOP "Close ClipDiary and run Setup again. Your saved data is kept."
    Abort
  ${EndIf}
  SetOutPath "$INSTDIR"
  File /r "${PUBLISH_DIR}\*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\ClipDiary" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipDiary" "DisplayName" "ClipDiary"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipDiary" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipDiary" "Publisher" "Yash Modi"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipDiary" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipDiary" "DisplayIcon" "$INSTDIR\ClipDiary.exe"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipDiary" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipDiary" "NoRepair" 1
  CreateDirectory "$SMPROGRAMS\ClipDiary"
  CreateShortcut "$SMPROGRAMS\ClipDiary\ClipDiary.lnk" "$INSTDIR\ClipDiary.exe"
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  IfFileExists "$INSTDIR\ClipDiary.exe" 0 stopped
    ExecWait '"$INSTDIR\ClipDiary.exe" --quit' $0
    ${If} $0 != 0
      MessageBox MB_OK|MB_ICONSTOP "Close ClipDiary and try uninstalling again."
      Abort
    ${EndIf}
  stopped:
  !include "${UNINSTALL_MANIFEST}"
  Delete "$INSTDIR\Uninstall.exe"
  Delete "$SMPROGRAMS\ClipDiary\ClipDiary.lnk"
  RMDir "$SMPROGRAMS\ClipDiary"
  RMDir "$INSTDIR"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "ClipDiary"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClipDiary"
  DeleteRegValue HKCU "Software\ClipDiary" "InstallDir"
  DeleteRegKey /ifempty HKCU "Software\ClipDiary"
  ; History/snippets live in LocalAppData\ClipDiary and are deliberately retained.
SectionEnd
