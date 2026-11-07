#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在远端会话工具栏上加一个「眼睛」按钮：只看画面 / 可以操作 一键切换。

用法: python patch_toolbar_eye.py <rustdesk 源码根目录>

做的两件事（纯文本插入，锚点找不到直接报错退出，宁可构建失败，
也不要悄悄出一个「工具栏上少个按钮」的包）：
1. _buildToolbar 里 _ControlMenu 之后插入 _ViewOnlyEyeButton；
2. 文件末尾追加 _ViewOnlyEyeButton 类。

按钮走的是 RustDesk 自带的 kOptionToggleViewOnly 会话选项（和「视图模式」菜单
同一套机制），所以切过去之后：只读时本地输入不发给对方，界面按原逻辑显示。
"""

import os
import sys

REL = os.path.join('flutter', 'lib', 'desktop', 'widgets', 'remote_toolbar.dart')

ANCHOR = """    toolbarItems
        .add(_ControlMenu(id: widget.id, ffi: widget.ffi, state: widget.state));"""

INSERT = """
    // 【HyDesk】眼睛按钮：只看画面 / 可以操作，一键切换
    toolbarItems.add(_ViewOnlyEyeButton(id: widget.id, ffi: widget.ffi));"""

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

    if '_ViewOnlyEyeButton' in src:
        print('  skip (already patched): view only eye button')
        return

    if src.count(ANCHOR) != 1:
        raise SystemExit('anchor not unique for toolbar items (found %d)'
                         % src.count(ANCHOR))
    src = src.replace(ANCHOR, ANCHOR + INSERT, 1)
    print('  patch: toolbar item _ViewOnlyEyeButton')

    src = src.rstrip('\n') + '\n' + WIDGET
    print('  patch: append _ViewOnlyEyeButton class')

    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)


if __name__ == '__main__':
    main()
