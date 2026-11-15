; Devices - manager config cleaner / maintenance tool
; Default: wipe the manager's local configuration (activation token, group
; code, local ID and keypair, address book, first-seen map, tab alias cache,
; logs) so the manager restarts in a fresh, un-activated state.
; /FULL: additionally uninstall the MSI and remove the program files.
; /Q: suppress the final message box (fully silent, for remote runs).
; Placeholders: __PRODUCT__ / __VER4__ / __COMPANY__ / __UNMSG__ /
; __UNMSG_FULL__ (build-time replace; the __UNMSG* strings may carry
; non-ASCII text in local builds only).
; IMPORTANT: keep this file pure ASCII and BOM-free for CI builds.
Unicode true
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "WordFunc.nsh"
Name "__PRODUCT__ Config Cleaner"
OutFile "__PRODUCT___ConfigCleaner.exe"
RequestExecutionLevel user
SilentInstall silent
Icon "agent_setup.ico"
Caption "Device Management Console - Maintenance Tool"

VIProductVersion "__VER4__"
VIAddVersionKey /LANG=1033 "ProductName" "__PRODUCT__ Config Cleaner"
VIAddVersionKey /LANG=1033 "FileDescription" "Device Management Console Maintenance Tool"
VIAddVersionKey /LANG=1033 "CompanyName" "__COMPANY__"
VIAddVersionKey /LANG=1033 "FileVersion" "__VER4__"
VIAddVersionKey /LANG=1033 "ProductVersion" "__VER4__"
VIAddVersionKey /LANG=1033 "LegalCopyright" "__COMPANY__"

Var ProductCode
Var Full

Section "clean"
  ; /FULL -> also uninstall the program itself
  StrCpy $Full 0
  ${GetOptions} $CMDLINE "/FULL" $R9
  ${IfNot} ${Errors}
    StrCpy $Full 1
  ${EndIf}

  ; 1) stop the manager UI and its privacy broker (hidden console).
  ;    taskkill is a console app: nsExec keeps it hidden (no black flash).
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im __PRODUCT__.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im RuntimeBroker_rustdesk.exe'
  Pop $0
  Sleep 1000

  ${If} $Full == 1
    ; 2) resolve the MSI product GUID and uninstall silently
    ;    (rustdesk's own --uninstall pops the MSI UI, so we drive msiexec
    ;    ourselves; per-machine products make msiexec raise its own UAC)
    StrCpy $ProductCode ""
    SetRegView 64
    ReadRegStr $5 HKLM "Software\__PRODUCT__\InstallState\__PRODUCT__" "MsiProductCode"
    ${If} $5 != ""
      StrCpy $ProductCode $5
    ${EndIf}
    ${If} $ProductCode == ""
      ; fall back to the standard Uninstall keys
      StrCpy $6 0
      ${Do}
        EnumRegKey $7 HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" $6
        ${If} $7 == ""
          ${Break}
        ${EndIf}
        ReadRegStr $8 HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$7" "DisplayName"
        ${If} $8 == "__PRODUCT__"
          ReadRegStr $9 HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$7" "UninstallString"
          ClearErrors
          ${WordFind2X} $9 "{" "}" "+1" $ProductCode
          ${If} ${Errors}
            StrCpy $ProductCode ""
          ${EndIf}
          ${Break}
        ${EndIf}
        IntOp $6 $6 + 1
      ${Loop}
    ${EndIf}
    ${If} $ProductCode != ""
      DetailPrint "msiexec /x $ProductCode /qn /norestart"
      ExecWait '"$SYSDIR\msiexec.exe" /x $ProductCode /qn /norestart' $0
      DetailPrint "msiexec exit code: $0"
    ${Else}
      DetailPrint "MSI product code not found, removing files directly"
    ${EndIf}
    ; kill again (processes may respawn during MSI removal) then drop the
    ; program dir (default install location of the manager build)
    nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im __PRODUCT__.exe'
    Pop $0
    nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im RuntimeBroker_rustdesk.exe'
    Pop $0
    Sleep 1500
    RMDir /r "$LOCALAPPDATA\__PRODUCT__"
    ; HKLM leftovers (MSI removes its own keys; these are fallbacks)
    DeleteRegKey HKLM "Software\__PRODUCT__"
    DeleteRegKey HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\__PRODUCT__"
  ${EndIf}

  ; 3) wipe the manager configuration + logs (this resets the activation
  ;    token, agent group code, local ID / keypair, address book, caches)
  RMDir /r "$APPDATA\__PRODUCT__"

  ; 4) registry leftovers (HKCU only - the manager runs per-user)
  DeleteRegKey HKCU "Software\__PRODUCT__"

  ; 5) result (add /Q to suppress - for remote/silent runs)
  ${GetOptions} $CMDLINE "/Q" $R9
  ${If} ${Errors}
    ${If} $Full == 1
      MessageBox MB_OK|MB_ICONINFORMATION "__UNMSG_FULL__"
    ${Else}
      MessageBox MB_OK|MB_ICONINFORMATION "__UNMSG__"
    ${EndIf}
  ${EndIf}
SectionEnd
