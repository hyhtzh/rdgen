#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""每路远控会话建好后，自动切到「只看画面」（只读），用户点工具栏的眼睛按钮才可操作。

用法: python patch_default_view_only.py <rustdesk 源码根目录>

为什么改 remote_page.dart 而不是 Rust：会话选项（kOptionToggleViewOnly）本来就是
Flutter 侧调的，打开后 Rust 会把 disable_keyboard / disable_clipboard 一起推给对端
（见 src/client.rs 的 "view-only" 分支），Flutter 侧 input_model 也会早退，
所以「只看」是两端都成立的，不需要动 Rust。

三个插入点都做唯一性校验，锚点变了直接报错退出，宁可构建失败也不要出个
「连上就能操作」的静默回退。
"""

import os
import sys

REL = os.path.join('flutter', 'lib', 'desktop', 'pages', 'remote_page.dart')

# 1) 字段：紧跟在 _ffi 声明之后
FIELD_ANCHOR = """  late FFI _ffi;
  Worker? _waylandKeyboardModeWorker;"""

FIELD_ADD = """  late FFI _ffi;
  Worker? _waylandKeyboardModeWorker;

  /// 【HyDesk】「默认只看」是否已经对这一路生效（每路会话只做一次）
  bool _hyViewOnlyApplied = false;"""

# 2) 触发点：第一帧画面到达 = 握手完成、会话选项可读写
CALL_ANCHOR = """    _ffi.imageModel.addCallbackOnFirstImage((String peerId) {
      _ffi.canvasModel.activateLocalCursor();"""

CALL_ADD = """    _ffi.imageModel.addCallbackOnFirstImage((String peerId) {
      _ffi.canvasModel.activateLocalCursor();
      // 【HyDesk】默认只看：连上就先给「只看画面」，要操作得自己点眼睛按钮
      unawaited(_hyApplyDefaultViewOnly());"""

# 3) 方法：塞在 _RemotePageState 的最后一个成员之后
CLASS_END_ANCHOR = """  @override
  bool get wantKeepAlive => true;
}"""

METHOD_ADD = """  @override
  bool get wantKeepAlive => true;

  /// 【HyDesk】默认只看：会话就绪后强制回到「只看画面」。
  ///
  /// 为什么不能只靠 peer config：`view-only` 会被 save_config 写进该设备的
  /// 配置，用户上次点过「可以操作」，下次连同一台就沿用可操作。产品要求是
  /// **每次连上都先只看**，所以这里不看历史值，只读当前实际状态，需要才翻。
  ///
  /// 放在「第一帧画面到达」的回调里：会话选项要到 peer info 之后才可读写，
  /// 而这个时机正好在握手完成之后、用户开始操作之前。
  Future<void> _hyApplyDefaultViewOnly() async {
    if (_hyViewOnlyApplied) return;
    _hyViewOnlyApplied = true;
    try {
      final cur = await bind.sessionGetToggleOption(
          sessionId: sessionId, arg: kOptionToggleViewOnly);
      if (cur != true) {
        await bind.sessionToggleOption(
            sessionId: sessionId, value: kOptionToggleViewOnly);
      }
      if (!mounted) return;
      _ffi.ffiModel.setViewOnly(widget.id, true);
      if (!_hyViewOnlyHintShown) {
        _hyViewOnlyHintShown = true;
        showToast('已进入只看画面，点上方「眼睛」按钮可切换为操作');
      }
    } catch (e) {
      debugPrint('HyDesk default view-only failed: $e');
    }
  }
}"""

# 4) 全局提示位：整个进程只提示一次，不是每台设备都弹
GLOBAL_ANCHOR = """final Map<String, bool> closeSessionOnDispose = {};"""

GLOBAL_ADD = """final Map<String, bool> closeSessionOnDispose = {};

/// 【HyDesk】「默认只看」的提示只在本次运行里弹一次，免得每连一台都弹。
bool _hyViewOnlyHintShown = false;"""


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    path = os.path.join(root, REL)
    if not os.path.isfile(path):
        raise SystemExit('remote_page.dart not found: %s' % path)
    with open(path, encoding='utf-8') as f:
        src = f.read()

    if '_hyApplyDefaultViewOnly' in src:
        print('  skip (already patched): default view only')
        return

    for name, anchor, add in (
        ('field', FIELD_ANCHOR, FIELD_ADD),
        ('first-image hook', CALL_ANCHOR, CALL_ADD),
        ('class end', CLASS_END_ANCHOR, METHOD_ADD),
        ('global flag', GLOBAL_ANCHOR, GLOBAL_ADD),
    ):
        n = src.count(anchor)
        if n != 1:
            raise SystemExit('anchor not unique for %s (found %d)' % (name, n))
        src = src.replace(anchor, add, 1)
        print('  patch: %s' % name)

    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('  done: default view only')


if __name__ == '__main__':
    main()
