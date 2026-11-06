; Jarvis for Windows — a per-user installer (no administrator rights, nothing outside your profile).
; Built by packaging/package.mjs:  makensis /DVERSION=… /DARCH=… /DSTAGE=<staged folder> /DOUTFILE=… jarvis.nsi
;
; Installs into %LOCALAPPDATA%\Programs\Jarvis, adds Start menu shortcuts and an "Apps & features"
; entry for this user, then (if you agree) runs `jarvis setup` and `jarvis install` in a console so
; you can see what happens. The uninstaller runs `jarvis uninstall` first, which removes the login
; entries; your settings and permissions are kept unless you delete them yourself.

Unicode true
!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef ARCH
  !define ARCH "x64"
!endif
Name "Jarvis ${VERSION}"
OutFile "${OUTFILE}"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\Jarvis"
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show

!include "LogicLib.nsh"

!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Jarvis"

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Function .onInit
  ; Jarvis runs on Node.js 20 or newer; it is not bundled.
  nsExec::ExecToStack 'node --version'
  Pop $0
  Pop $1
  ${If} $0 != 0
    MessageBox MB_ICONEXCLAMATION|MB_OK "Jarvis needs Node.js 20 or newer. Install it from https://nodejs.org, then run this installer again."
    Abort
  ${EndIf}
FunctionEnd

Section "Jarvis"
  SetOutPath "$INSTDIR"
  File /r "${STAGE}\*"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Jarvis"
  CreateShortcut "$SMPROGRAMS\Jarvis\Jarvis setup.lnk" "$SYSDIR\cmd.exe" '/k "$INSTDIR\jarvis.cmd" setup && "$INSTDIR\jarvis.cmd" install'
  CreateShortcut "$SMPROGRAMS\Jarvis\Jarvis status.lnk" "$SYSDIR\cmd.exe" '/k "$INSTDIR\jarvis.cmd" status'
  CreateShortcut "$SMPROGRAMS\Jarvis\Uninstall Jarvis.lnk" "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "Jarvis"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "JARVIS contributors"
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
  IfSilent done
  MessageBox MB_YESNO|MB_ICONQUESTION "Set Jarvis up now? This downloads the speech models (about 48 MB), checks your microphone and Claude sign-in, and starts Jarvis at login." IDNO done
  Exec '"$SYSDIR\cmd.exe" /k "$INSTDIR\jarvis.cmd" setup && "$INSTDIR\jarvis.cmd" install'
  done:
SectionEnd

Section "Uninstall"
  nsExec::ExecToLog '"$SYSDIR\cmd.exe" /c "$INSTDIR\jarvis.cmd" uninstall'
  RMDir /r "$SMPROGRAMS\Jarvis"
  DeleteRegKey HKCU "${UNINSTKEY}"
  RMDir /r "$INSTDIR"
SectionEnd
