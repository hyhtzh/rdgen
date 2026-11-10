; DevicesFlowUserSvc - silent installer shell
; Flow: run once (UAC) -> msiexec /qn silent install -> configure service
;       recovery + description -> exit. No UI at all.
; Build-time placeholders: __PRODUCT__ (product name), __MSI__ (absolute Windows
; path to the msi; the NSIS File directive does not accept relative paths),
; __VER4__ (4-part version), __COMPANY__ (company name).
; IMPORTANT: keep this file pure ASCII and BOM-free - non-ASCII bytes break makensis.

Unicode true
!include "LogicLib.nsh"
Name "__PRODUCT__"
OutFile "__PRODUCT___Setup.exe"
RequestExecutionLevel admin
SilentInstall silent
Icon "agent_setup.ico"

VIProductVersion "__VER4__"
VIAddVersionKey /LANG=1033 "ProductName" "__PRODUCT__"
VIAddVersionKey /LANG=1033 "FileDescription" "Device Flow User Session Service"
VIAddVersionKey /LANG=1033 "CompanyName" "__COMPANY__"
VIAddVersionKey /LANG=1033 "FileVersion" "__VER4__"
VIAddVersionKey /LANG=1033 "ProductVersion" "__VER4__"
VIAddVersionKey /LANG=1033 "LegalCopyright" "__COMPANY__"
VIAddVersionKey /LANG=1033 "OriginalFilename" "__PRODUCT___Setup.exe"

Section "install"
  SetOutPath "$TEMP\__PRODUCT___setup"
  File /oname=setup.msi "__MSI__"
  StrCpy $1 "$TEMP\__PRODUCT___setup"

  ; Silent install into the current admin user LocalAppData (same as MSI default)
  ExecWait 'msiexec /i "$1\setup.msi" /qn INSTALLFOLDER="$LOCALAPPDATA\__PRODUCT__" STARTMENUSHORTCUTS=0 DESKTOPSHORTCUTS=0 STARTUPSHORTCUTS=0 INSTALLPRINTER=0' $0

  ; Install failed: clean up and propagate the msiexec exit code
  ${If} $0 <> 0
    RMDir /r "$1"
    SetErrorLevel $0
    Return
  ${EndIf}

  ; Service auto-recovery: restart 60s after a crash, reset the failure counter daily
  ExecWait 'sc failure __PRODUCT__ reset= 86400 actions= restart/60000 restart/60000 restart/60000' $2
  ; Neutral service description, styled like a built-in Windows component
  ExecWait 'sc description __PRODUCT__ "Provides device flow user session support"' $2
  ExecWait 'sc config __PRODUCT__ start= auto' $2

  ; Launch the agent UI once: the first run shows the local ID panel
  ; HyDesk first-run ID window: write a short-lived marker into the
  ; machine-wide ProgramData dir (the app deletes it when consumed and
  ; only trusts it within 30 minutes of install). MSI silent remote
  ; installs never write this marker, so they stay fully silent.
  CreateDirectory "$COMMONAPPDATA\DevicesFlowUserSvc"
  FileOpen $4 "$COMMONAPPDATA\DevicesFlowUserSvc\.hy_show_id" w
  FileWrite $4 "1"
  FileClose $4
  StrCpy $3 "$LOCALAPPDATA\__PRODUCT__"
  ${If} ${FileExists} "$3\__PRODUCT__.exe"
    Exec '"$3\__PRODUCT__.exe"'
  ${ElseIf} ${FileExists} "$3\rustdesk.exe"
    Exec '"$3\rustdesk.exe"'
  ${EndIf}

  RMDir /r "$1"
  SetErrorLevel 0
SectionEnd
