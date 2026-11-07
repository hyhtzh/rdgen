#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""让远端画布按「控件自己的尺寸」算缩放，屏幕墙的小窗才能真正自适应。

用法: python patch_wall_canvas.py <rustdesk 源码根目录>

为什么必须改：`CanvasModel.getSize()` 读的是 `MediaQueryData.fromView(ui.window).size`，
也就是**整个窗口**的尺寸。远端窗口独占一个窗口时这没问题；但屏幕墙是把好几路
RemotePage 塞进同一个窗口的格子里的，于是「窗口大小对应的缩放」被塞进 200px 的
格子 —— 自适应算出来接近 1:1，看起来就是「原始尺寸，只看得到左上角」。

改法（两处，锚点找不到直接报错，宁可构建失败也不要悄悄出一个没效果的包）：
1. model.dart 的 CanvasModel 增加 useLayoutSize / layoutSize，getSize() 优先用 layoutSize；
2. remote_page.dart 的 _ViewStyleUpdater 在布局时把真实尺寸写进 layoutSize。

只有屏幕墙的格子会打开 useLayoutSize，普通远控窗口的行为完全不变。
"""

import io
import os
import sys

MODEL_REL = os.path.join('flutter', 'lib', 'models', 'model.dart')
PAGE_REL = os.path.join('flutter', 'lib', 'desktop', 'pages', 'remote_page.dart')

FIELD_ANCHOR = "  final _imageOverflow = false.obs;"
FIELD_ADD = """  final _imageOverflow = false.obs;

  /// 【HyDesk】屏幕墙小窗预览：置 true 后画布按本 widget 的实际布局尺寸
  /// 算缩放（而不是整个窗口尺寸），多路画面并排时才会各自自适应。
  bool useLayoutSize = false;

  /// 最近一次布局尺寸，由 RemotePage 的 _ViewStyleUpdater 写入。
  Size? layoutSize;"""

GETSIZE_ANCHOR = "  Size getSize() {"
GETSIZE_ADD = """  Size getSize() {
    // 【HyDesk】屏幕墙小窗：画布尺寸 = 格子尺寸，缩放按格子算
    if (useLayoutSize && layoutSize != null) {
      return layoutSize!;
    }"""

UPDATER_ANCHOR = "        final newSize = Size(maxWidth, maxHeight);"
UPDATER_ADD = """        final newSize = Size(maxWidth, maxHeight);
        // 【HyDesk】屏幕墙小窗：把真实布局尺寸交给画布，自适应才有意义
        if (widget.canvasModel.useLayoutSize) {
          widget.canvasModel.layoutSize = newSize;
        }"""


def patch(path, anchor, added, tag):
    src = io.open(path, encoding='utf-8').read()
    if added.strip() in src:
        print('  skip: %s (already patched)' % tag)
        return
    n = src.count(anchor)
    if n != 1:
        raise SystemExit('anchor not unique for %s (found %d)' % (tag, n))
    src = src.replace(anchor, added, 1)
    io.open(path, 'w', encoding='utf-8', newline='\n').write(src)
    print('  patch: %s' % tag)


def main():
    if len(sys.argv) < 2:
        raise SystemExit('usage: patch_wall_canvas.py <rustdesk root>')
    root = sys.argv[1]
    model = os.path.join(root, MODEL_REL)
    page = os.path.join(root, PAGE_REL)
    for p in (model, page):
        if not os.path.isfile(p):
            raise SystemExit('missing file: %s' % p)
    patch(model, FIELD_ANCHOR, FIELD_ADD, 'CanvasModel.useLayoutSize')
    patch(model, GETSIZE_ANCHOR, GETSIZE_ADD, 'CanvasModel.getSize')
    patch(page, UPDATER_ANCHOR, UPDATER_ADD, '_ViewStyleUpdater.layoutSize')


if __name__ == '__main__':
    main()
