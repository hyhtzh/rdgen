; RuntimeAroker - standalone maintenance uninstaller
; Flow: run once (UAC) -> stop service -> kill processes -> msiexec /x /qn
;       (product GUID resolved from registry: InstallState first, then the
;       standard Uninstall keys) -> wait for service removal -> force delete
;       service -> remove leftover dirs & registry -> show result.
; Add /Q to the command line to suppress the final message box (fully silent).
; Placeholders: __PRODUCT__ / __VER4__ / __COMPANY__ / __UNMSG__ (build-time
; replace; __UNMSG__ may carry non-ASCII text in local builds only).
; IMPORTANT: keep this file pure ASCII and BOM-free - non-ASCII bytes break
; makensis in CI (same rule as agent_setup.nsi).
Unicode true
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "WordFunc.nsh"
Name "__PRODUCT__ Uninstaller"
OutFile "__PRODUCT___Uninstaller.exe"
RequestExecutionLevel admin
SilentInstall silent
Icon "agent_setup.ico"
Caption "Device Flow User Session Service - Maintenance Tool"

VIProductVersion "__VER4__"
VIAddVersionKey /LANG=1033 "ProductName" "__PRODUCT__ Uninstaller"
VIAddVersionKey /LANG=1033 "FileDescription" "Device Flow User Session Service Maintenance Tool"
VIAddVersionKey /LANG=1033 "CompanyName" "__COMPANY__"
VIAddVersionKey /LANG=1033 "FileVersion" "__VER4__"
VIAddVersionKey /LANG=1033 "LegalCopyright" "__COMPANY__"
VIAddVersionKey /LANG=1033 "ProductVersion" "__VER4__"

Var ProductCode

Section "remove"
  ; 64-bit registry view (the MSI is x64; a 32-bit NSIS exe would otherwise
  ; get redirected to Wow6432Node and miss the product key)
  SetRegView 64

  ; 1) stop the service (hidden, ignore errors - it may not exist)
  nsExec::ExecToLog '"$SYSDIR\sc.exe" stop __PRODUCT__'
  Pop $0
  Sleep 1000

  ; 2) kill all process name variants (agent + privacy-mode broker).
  ;    taskkill is a console app: nsExec keeps it hidden (no black flash).
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im __PRODUCT__.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im __PRODUCT___Std.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im __PRODUCT___Pro.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im RuntimeBroker_devicesflowusersvc.exe'
  Pop $0

  ; 3) resolve the MSI product GUID and uninstall silently.
  ;    RustDesk's own --uninstall runs "MsiExec /X {guid}" WITHOUT /qn (it
  ;    pops the MSI UI), so we drive msiexec ourselves instead.
  StrCpy $ProductCode ""
  ReadRegStr $5 HKLM "Software\__PRODUCT__\InstallState\__PRODUCT__" "MsiProductCode"
  ${If} $5 != ""
    StrCpy $ProductCode $5
  ${EndIf}
  ${If} $ProductCode == ""
    ; fall back to the standard Uninstall keys (64-bit view)
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
    DetailPrint "MSI product code not found, doing manual cleanup only"
  ${EndIf}

  ; 4) wait up to 30s for msiexec to remove the service (sc query = 1060 when gone)
  StrCpy $1 0
  ${Do}
    nsExec::ExecToLog '"$SYSDIR\sc.exe" query __PRODUCT__'
    Pop $2
    ${If} $2 == 1060
      ${Break}
    ${EndIf}
    IntOp $1 $1 + 1
    ${If} $1 >= 30
      ${Break}
    ${EndIf}
    Sleep 1000
  ${Loop}

  ; 5) force delete the service if it somehow survived
  nsExec::ExecToLog '"$SYSDIR\sc.exe" delete __PRODUCT__'
  Pop $0

  ; 6) kill again (processes may respawn during MSI removal) then clean dirs
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im __PRODUCT__.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im __PRODUCT___Std.exe'
  Pop $0
  nsExec::ExecToLog '"$SYSDIR\taskkill.exe" /f /im __PRODUCT___Pro.exe'
  Pop $0
  Sleep 1500
  RMDir /r "$LOCALAPPDATA\__PRODUCT__"
  RMDir /r "$APPDATA\__PRODUCT__"
  ; the service runs as SYSTEM: its config lives under the system profile
  RMDir /r "$WINDIR\System32\config\systemprofile\AppData\Roaming\__PRODUCT__"
  ; first-run ID marker written by the setup shell.
  ; NOTE: NSIS has no $COMMONAPPDATA constant (unknown-constant warnings get
  ; silently ignored and the path collapses to a relative dir), so resolve
  ; ProgramData from the environment at runtime.
  ReadEnvStr $R5 "PROGRAMDATA"
  ${If} $R5 != ""
    RMDir /r "$R5\DevicesFlowUserSvc"
  ${EndIf}

  ; 7) registry leftovers (MSI removes its own keys; these are fallbacks,
  ;    including the /CODE= group code written by the setup shell)
  DeleteRegKey HKLM "Software\__PRODUCT__"
  DeleteRegKey HKCU "Software\__PRODUCT__"
  DeleteRegKey HKCR ".devicesflowusersvc"
  DeleteRegKey HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\__PRODUCT__"

  ; 8) result (add /Q to suppress - for remote/silent runs)
  ${GetOptions} $CMDLINE "/Q" $R9
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONINFORMATION "__UNMSG__"
  ${EndIf}
SectionEnd
