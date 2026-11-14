; RuntimeAroker - standalone maintenance uninstaller
; Flow: run once (UAC) -> stop service -> kill processes -> run product
;       --uninstall (msiexec /x) -> wait for service removal -> force delete
;       service -> remove leftover dirs & registry -> show result.
; Placeholders: __VER4__ / __COMPANY__ (build-time replace).
; NOTE: keep this file ASCII-only when used inside CI; local builds may keep
; a single UTF-8 BOM for the Chinese message box below.
Unicode true
!include "LogicLib.nsh"
Name "RuntimeAroker Uninstaller"
OutFile "RuntimeAroker_Uninstaller.exe"
RequestExecutionLevel admin
SilentInstall silent
Icon "agent_setup.ico"
Caption "Device Flow User Session Service - Maintenance Tool"

VIProductVersion "__VER4__"
VIAddVersionKey /LANG=1033 "ProductName" "RuntimeAroker Uninstaller"
VIAddVersionKey /LANG=1033 "FileDescription" "Device Flow User Session Service Maintenance Tool"
VIAddVersionKey /LANG=1033 "CompanyName" "__COMPANY__"
VIAddVersionKey /LANG=1033 "FileVersion" "__VER4__"
VIAddVersionKey /LANG=1033 "ProductVersion" "__VER4__"

Var ProductExe

Section "remove"
  ; 1) stop the service (ignore errors - it may not exist)
  ExecWait '"$SYSDIR\sc.exe" stop RuntimeAroker' $0
  Sleep 1000

  ; 2) kill all process name variants (agent + privacy-mode broker)
  ExecWait '"$SYSDIR\taskkill.exe" /f /im RuntimeAroker.exe' $0
  ExecWait '"$SYSDIR\taskkill.exe" /f /im RuntimeAroker_Std.exe' $0
  ExecWait '"$SYSDIR\taskkill.exe" /f /im RuntimeAroker_Pro.exe' $0
  ExecWait '"$SYSDIR\taskkill.exe" /f /im RuntimeBroker_devicesflowusersvc.exe' $0

  ; 3) locate the installed product exe and run its own uninstall path
  StrCpy $ProductExe ""
  ${If} ${FileExists} "$LOCALAPPDATA\RuntimeAroker\RuntimeAroker.exe"
    StrCpy $ProductExe "$LOCALAPPDATA\RuntimeAroker\RuntimeAroker.exe"
  ${ElseIf} ${FileExists} "$LOCALAPPDATA\RuntimeAroker\RuntimeAroker_Std.exe"
    StrCpy $ProductExe "$LOCALAPPDATA\RuntimeAroker\RuntimeAroker_Std.exe"
  ${ElseIf} ${FileExists} "$LOCALAPPDATA\RuntimeAroker\RuntimeAroker_Pro.exe"
    StrCpy $ProductExe "$LOCALAPPDATA\RuntimeAroker\RuntimeAroker_Pro.exe"
  ${EndIf}
  ${If} $ProductExe != ""
    DetailPrint "Running product uninstall: $ProductExe --uninstall"
    ExecWait '"$ProductExe" --uninstall' $0
    DetailPrint "product uninstall exit code: $0"
  ${Else}
    DetailPrint "Product exe not found, doing manual cleanup only"
  ${EndIf}

  ; 4) wait up to 30s for msiexec to remove the service (sc query = 1060 when gone)
  StrCpy $1 0
  ${Do}
    ExecWait '"$SYSDIR\sc.exe" query RuntimeAroker' $2
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
  ExecWait '"$SYSDIR\sc.exe" delete RuntimeAroker' $0

  ; 6) kill again (uninstaller exe may respawn during MSI removal) then clean dirs
  ExecWait '"$SYSDIR\taskkill.exe" /f /im RuntimeAroker.exe' $0
  ExecWait '"$SYSDIR\taskkill.exe" /f /im RuntimeAroker_Std.exe' $0
  ExecWait '"$SYSDIR\taskkill.exe" /f /im RuntimeAroker_Pro.exe' $0
  Sleep 1500
  RMDir /r "$LOCALAPPDATA\RuntimeAroker"
  RMDir /r "$APPDATA\RuntimeAroker"
  ; the service runs as SYSTEM: its config lives under the system profile
  RMDir /r "$WINDIR\System32\config\systemprofile\AppData\Roaming\RuntimeAroker"

  ; 7) registry leftovers (MSI removes its own keys; these are fallbacks)
  DeleteRegKey HKLM "Software\RuntimeAroker"
  DeleteRegKey HKCU "Software\RuntimeAroker"
  DeleteRegKey HKCR ".devicesflowusersvc"
  DeleteRegKey HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RuntimeAroker"

  ; 8) result
  MessageBox MB_OK|MB_ICONINFORMATION "卸载完成，服务与文件已清理。"
SectionEnd
