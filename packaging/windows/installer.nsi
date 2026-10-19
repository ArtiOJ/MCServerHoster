; Server Manager installer for Windows 10/11 (per-user: no administrator rights needed).
; Built by packaging/build.sh: makensis -DVERSION=x.y.z -DSOURCE=<dir with ServerManager.exe> -DOUTFILE=<setup.exe>

Unicode true
!include "MUI2.nsh"

Name "Server Manager"
OutFile "${OUTFILE}"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\Server Manager"
InstallDirRegKey HKCU "Software\Server Manager" "InstallDir"
SetCompressor /SOLID lzma

!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\ServerManager"
!define MUI_ICON "${SOURCE}\server-manager.ico"
!define MUI_UNICON "${SOURCE}\server-manager.ico"
!define MUI_FINISHPAGE_RUN "$INSTDIR\ServerManager.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Start Server Manager"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${SOURCE}\LICENSE.txt"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "Server Manager"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "Server Manager installer"
VIAddVersionKey "LegalCopyright" "Copyright (c) 2026 Artifabrian"

Section "Server Manager" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "${SOURCE}\ServerManager.exe"
  File "${SOURCE}\server-manager.ico"
  File "${SOURCE}\LICENSE.txt"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateShortcut "$SMPROGRAMS\Server Manager.lnk" "$INSTDIR\ServerManager.exe" "" "$INSTDIR\server-manager.ico"
  WriteRegStr HKCU "Software\Server Manager" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "Server Manager"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "Artifabrian"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\server-manager.ico"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "Desktop shortcut" SecDesktop
  CreateShortcut "$DESKTOP\Server Manager.lnk" "$INSTDIR\ServerManager.exe" "" "$INSTDIR\server-manager.ico"
SectionEnd

Section "Uninstall"
  ; Settings and servers (in your user folder) are left alone.
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Server Manager"
  nsExec::Exec 'schtasks /Delete /TN "Server Manager wake-up" /F'
  Delete "$SMPROGRAMS\Server Manager.lnk"
  Delete "$DESKTOP\Server Manager.lnk"
  Delete "$INSTDIR\ServerManager.exe"
  Delete "$INSTDIR\server-manager.ico"
  Delete "$INSTDIR\LICENSE.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegKey HKCU "Software\Server Manager"
SectionEnd
