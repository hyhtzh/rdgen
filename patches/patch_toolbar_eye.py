#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在远端会话工具栏上加一个「眼睛」按钮：只看画面 / 可以操作 一键切换；
并给屏幕墙的小窗预览加一个「整条工具栏不渲染」的开关。

用法: python patch_toolbar_eye.py <rustdesk 源码根目录>

做的四件事（纯文本插入，锚点找不到直接报错退出，宁可构建失败，
也不要悄悄出一个「工具栏上少个按钮」的包）：
1. _buildToolbar 里 _ControlMenu 之后插入 _ViewOnlyEyeButton；
2. 文件末尾追加 _ViewOnlyEyeButton 类；
3. 工具栏 build 开头加「墙预览状态直接返回 SizedBox.shrink()」；
4. 文件末尾追加 kWallToolbarStates 集合（屏幕墙把自己的 ToolbarState 放进去）；
5. 隐藏原生「会话录像」按钮（_RecordMenu）：录像/截图统一走屏幕墙的
   自动录屏（收费附加包 record），避免两套录像入口打架（2026-11-09）。

为什么用集合而不是全局 bool：同一个进程里可能同时有墙预览和正常远控窗口，
用 ToolbarState 身份判断，只有墙自己的那几路会话不显示工具栏。

眼睛按钮走的是 RustDesk 自带的 kOptionToggleViewOnly 会话选项（和「视图模式」菜单
同一套机制），所以切过去之后：只读时本地输入不发给对方，界面按原逻辑显示。
"""

import os
import sys

REL = os.path.join('flutter', 'lib', 'desktop', 'widgets', 'remote_toolbar.dart')

# 【HyDesk】隐藏原生会话录像按钮：上游 _RecordMenu 的挂载点。
RECORD_ANCHOR = "    if (!isWeb) toolbarItems.add(_RecordMenu());"
RECORD_NEW = ("    // 【HyDesk】隐藏原生会话录像按钮：录像/截图统一走屏幕墙自动录屏\n"
             "    // （收费附加包 record），不再提供两套录像入口。\n"
             "    // if (!isWeb) toolbarItems.add(_RecordMenu());")

ANCHOR = """    toolbarItems
        .add(_ControlMenu(id: widget.id, ffi: widget.ffi, state: widget.state));"""

INSERT = """
    // 【HyDesk】眼睛按钮：只看画面 / 可以操作，一键切换
    toolbarItems.add(_ViewOnlyEyeButton(id: widget.id, ffi: widget.ffi));"""

# 工具栏整条隐藏：锚点带上下面两行，保证只命中 _RemoteToolbarState.build
BUILD_ANCHOR = """  Widget build(BuildContext context) {
    return Obx(() {
      // Wait for initialization to complete to prevent flickering
      if (!widget.state.initialized.value ||
          !_dockingOptionsInitialized.value) {
"""

BUILD_REPLACE = """  Widget build(BuildContext context) {
    // 【HyDesk】屏幕墙小窗预览：整条工具栏不渲染，画面区全部留给远端桌面
    if (kWallToolbarStates.contains(widget.state)) {
      return const SizedBox.shrink();
    }
    return Obx(() {
      // Wait for initialization to complete to prevent flickering
      if (!widget.state.initialized.value ||
          !_dockingOptionsInitialized.value) {
"""

WALL_SET = r"""

/// 【HyDesk】屏幕墙小窗预览的会话状态集合：属于这些状态的远端工具栏一律不渲染。
/// 屏幕墙每开一路预览就 add 一次，格子销毁时 remove。
final Set<ToolbarState> kWallToolbarStates = <ToolbarState>{};
"""

WIDGET = r"""

// ---------------------------------------------------------------------------
// 【HyDesk】远端工具栏「眼睛」按钮
// 点一次切换「只看画面（只读）」和「可以操作（控制）」。
// 用的是 RustDesk 自带会话选项 kOptionToggleViewOnly，与「视图模式」菜单同源，
// 区别只是把它提到工具栏上，不用翻菜单。
class _ViewOnlyEyeButton extends StatelessWidget {
  final String id;
  final FFI ffi;
  const _ViewOnlyEyeButton({Key? key, required this.id, required this.ffi})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    // 订阅 FfiModel，别人从菜单改了只读状态，这个按钮也跟着变
    final ffiModel = Provider.of<FfiModel>(context);
    if (versionCmp(ffiModel.pi.version, '1.2.0') < 0) {
      return const Offstage();
    }
    final viewOnly = ffiModel.viewOnly;
    return _IconMenuButton(
      icon: Icon(
        viewOnly ? Icons.visibility_off_rounded : Icons.visibility_rounded,
        color: Colors.white,
        size: _ToolbarTheme.buttonSize,
      ),
      tooltip: viewOnly ? '切换为可以操作' : '切换为只看画面',
      onPressed: () async {
        await bind.sessionToggleOption(
            sessionId: ffi.sessionId, value: kOptionToggleViewOnly);
        final v = await bind.sessionGetToggleOption(
            sessionId: ffi.sessionId, arg: kOptionToggleViewOnly);
        ffi.ffiModel.setViewOnly(id, v ?? !viewOnly);
      },
      color: viewOnly ? _ToolbarTheme.redColor : _ToolbarTheme.blueColor,
      hoverColor:
          viewOnly ? _ToolbarTheme.hoverRedColor : _ToolbarTheme.hoverBlueColor,
    );
  }
}
"""


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    path = os.path.join(root, REL)
    if not os.path.isfile(path):
        raise SystemExit('remote_toolbar.dart not found: %s' % path)
    with open(path, encoding='utf-8') as f:
        src = f.read()

    # 5) 隐藏原生录像按钮（独立于眼按钮，幂等）
    if '隐藏原生会话录像按钮' in src:
        print('  skip (already patched): record menu hidden')
    elif src.count(RECORD_ANCHOR) == 1:
        src = src.replace(RECORD_ANCHOR, RECORD_NEW, 1)
        print('  patch: hide native record menu button')
    else:
        raise SystemExit('anchor not unique for record menu (found %d)'
                         % src.count(RECORD_ANCHOR))

    if '_ViewOnlyEyeButton' in src:
        print('  skip (already patched): view only eye button')
        return

    if src.count(ANCHOR) != 1:
        raise SystemExit('anchor not unique for toolbar items (found %d)'
                         % src.count(ANCHOR))
    src = src.replace(ANCHOR, ANCHOR + INSERT, 1)
    print('  patch: toolbar item _ViewOnlyEyeButton')

    if src.count(BUILD_ANCHOR) != 1:
        raise SystemExit('anchor not unique for toolbar build (found %d)'
                         % src.count(BUILD_ANCHOR))
    src = src.replace(BUILD_ANCHOR, BUILD_REPLACE, 1)
    print('  patch: hide toolbar in screen wall preview')

    src = src.rstrip('\n') + '\n' + WIDGET + WALL_SET
    print('  patch: append _ViewOnlyEyeButton class + kWallToolbarStates')

    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)


if __name__ == '__main__':
    main()
