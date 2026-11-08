#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""让远端画布按「控件自己的尺寸」算缩放，屏幕墙的小窗才能真正自适应。

用法: python patch_wall_canvas.py <rustdesk 源码根目录>

为什么必须改：`CanvasModel.getSize()` 读的是 `MediaQueryData.fromView(ui.window).size`，
也就是**整个窗口**的尺寸。远端窗口独占一个窗口时这没问题；但屏幕墙是把好几路
RemotePage 塞进同一个窗口的格子里的，于是「窗口大小对应的缩放」被塞进 200px 的
格子 —— 自适应算出来接近 1:1，看起来就是「原始尺寸，只看得到左上角」。

改法（锚点找不到直接报错，宁可构建失败也不要悄悄出一个没效果的包）：
1. model.dart 的 CanvasModel 增加 useLayoutSize / layoutSize，getSize() 优先用 layoutSize；
2. remote_page.dart 的 _ViewStyleUpdater 在布局时把真实尺寸写进 layoutSize；
3. CanvasModel.updateViewStyle() 结尾：useLayoutSize 时无条件按格子自适应
   （不看会话里存的 view-style，避免「明明设了 adaptive 还是 1:1」）；
4. CanvasModel.reset() 同理，避免还原画布时把缩放打回 1:1。

只有屏幕墙的格子会打开 useLayoutSize，普通远控窗口的行为完全不变。
"""

import io
import os
import sys

MODEL_REL = os.path.join('flutter', 'lib', 'models', 'model.dart')
PAGE_REL = os.path.join('flutter', 'lib', 'desktop', 'pages', 'remote_page.dart')
INPUT_REL = os.path.join('flutter', 'lib', 'models', 'input_model.dart')

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

# updateViewStyle() 里这段是「按 view-style 算完缩放、准备摆放画布」的位置。
# 放在它前面插：仍然走原逻辑，最后再把缩放强行改成「整屏塞进格子」。
SCALE_ANCHOR = "    _resetCanvasOffset(displayWidth, displayHeight);"
SCALE_ADD = """    // 【HyDesk】屏幕墙小窗：不管会话里存的 view-style 是什么，一律按格
    // 子尺寸整屏适配。会话是连上之后才认这个设置的，墙里等不到那一刻，
    // 所以这里直接在算缩放这一步兜住。
    if (useLayoutSize && displayWidth > 0 && displayHeight > 0) {
      final _sw = size.width, _sh = size.height;
      if (_sw > 0 && _sh > 0) {
        final _s1 = _sw / displayWidth, _s2 = _sh / displayHeight;
        _scale = _s1 < _s2 ? _s1 : _s2;
      }
    }
    _resetCanvasOffset(displayWidth, displayHeight);"""

# 墙里的小窗没有标签栏/窗口边框，但 CanvasModel.topToEdge 仍会按 28px 的标签栏
# 高度去修正鼠标坐标 —— 于是「点的位置」和「远端落点」差 28 个逻辑像素。
# 墙窗口里把这两个边距置零，坐标就和画面完全对齐了。
LEFT_ANCHOR = """  static double get leftToEdge =>
      isDesktop ? windowBorderWidth + kDragToResizeAreaPadding.left : 0;"""
LEFT_ADD = """  static double get leftToEdge => !isDesktop || wallNoEdge
      ? 0
      : windowBorderWidth + kDragToResizeAreaPadding.left;"""

TOP_ANCHOR = """  static double get topToEdge => isDesktop
      ? tabBarHeight + windowBorderWidth + kDragToResizeAreaPadding.top
      : 0;"""
TOP_ADD = """  static double get topToEdge => !isDesktop || wallNoEdge
      ? 0
      : tabBarHeight + windowBorderWidth + kDragToResizeAreaPadding.top;"""

FLAG_ANCHOR = """  /// 最近一次布局尺寸，由 RemotePage 的 _ViewStyleUpdater 写入。
  Size? layoutSize;"""
FLAG_ADD = """  /// 最近一次布局尺寸，由 RemotePage 的 _ViewStyleUpdater 写入。
  Size? layoutSize;

  /// 【HyDesk】屏幕墙窗口里置 true：墙里的小窗没有标签栏/边框，
  /// 不能再按顶层窗口的边距去修正鼠标坐标。
  static bool wallNoEdge = false;

  /// 【HyDesk】本画布的画面区左上角在**窗口**里的坐标。
  ///
  /// 墙是「一个窗口里并着好几格」，鼠标事件给的是窗口全局坐标，而
  /// canvas.x/y 只是画面在**本格内部**的偏移。以前统一减 topToEdge/
  /// leftToEdge（= 顶层窗口的标签栏+边框），在墙里就只减掉了标题栏，
  /// 每格自己的偏移一点没减 → 点第二格，远端光标跳到很远的地方。
  /// 现在由墙里每格在布局完成后写进来，换算时按这个原点减。
  Offset globalOrigin = Offset.zero;"""

# input_model.dart：鼠标事件是「窗口全局坐标」，墙里必须减掉本格画面区的原点。
INPUT_ANCHOR = """    y -= CanvasModel.topToEdge;
    x -= CanvasModel.leftToEdge;"""
INPUT_ADD = """    // 【HyDesk】屏幕墙小窗：同一窗口里并着好几格，每格画面区左上角都不同，
    // 固定减顶层窗口的 topToEdge/leftToEdge 只减掉了标题栏，格子自己的偏移
    // 还在 → 落点会被算到很远的地方。墙里改用画布自己上报的窗口原点。
    if (CanvasModel.wallNoEdge) {
      final _wallOrigin =
          parent.target?.canvasModel.globalOrigin ?? Offset.zero;
      x -= _wallOrigin.dx;
      y -= _wallOrigin.dy;
    } else {
      y -= CanvasModel.topToEdge;
      x -= CanvasModel.leftToEdge;
    }"""

# 键盘 grab：屏幕墙里最要命的一条。
#
# 鼠标进入某一格 → InputModel.enterOrLeave(true) → Rust 的
# session_enter_or_leave(true) → keyboard::client::change_grab_status(Run)
# → KEYBOARD_HOOKED=true + 装 rdev 全局键盘钩子，**把整台机器的键盘交给远端**。
# 墙里 9 格并排，鼠标一划过就在几个 session 之间来回抢 owner（日志里
# `[grab] Run/Wait ... releasing grab` 每秒刷好几条），本机输入法根本拿不到键，
# 用户看到的就是「开启屏幕墙后整个电脑无法使用输入法」。
#
# 网格态只做预览/鼠标，不抢键盘；放大成单屏（控制台）才允许抢。
GRAB_FIELD_ANCHOR = """  void enterOrLeave(bool enter) {
    toReleaseKeys.release(handleKeyEvent);"""
GRAB_FIELD_ADD = """  /// 【HyDesk】屏幕墙网格里的预览会话置 true：不去 grab 本机键盘。
  bool wallNoGrab = false;

  void enterOrLeave(bool enter) {
    toReleaseKeys.release(handleKeyEvent);"""

GRAB_CALL_ANCHOR = """    if (!isInputSourceFlutter) {
      bind.sessionEnterOrLeave(sessionId: sessionId, enter: enter);
    }"""
GRAB_CALL_ADD = """    // 【HyDesk】墙里网格态不抢本机键盘（否则输入法整机失效）；
    // 释放（enter=false）照常发，保证放大收回后一定把 grab 放掉。
    if (!isInputSourceFlutter && !(wallNoGrab && enter)) {
      bind.sessionEnterOrLeave(sessionId: sessionId, enter: enter);
    }"""

RESET_ANCHOR = """  reset() {
    _scale = _lastViewStyle.scale;"""
RESET_ADD = """  reset() {
    _scale = _lastViewStyle.scale;
    // 【HyDesk】屏幕墙小窗：还原画布也保持整屏自适应
    if (useLayoutSize) {
      final _sz = getSize();
      final _dw = getDisplayWidth(), _dh = getDisplayHeight();
      if (_dw > 0 && _dh > 0 && _sz.width > 0 && _sz.height > 0) {
        final _s1 = _sz.width / _dw, _s2 = _sz.height / _dh;
        _scale = _s1 < _s2 ? _s1 : _s2;
      }
    }"""

# 「尺寸/样式都没变就直接 return」这一段是「必须反复开关窗口才恢复自适应」的根源：
# 会话第一次算缩放时画布尺寸可能还是整窗（1:1），之后尺寸再没变过，早退就把错的
# 缩放一直留着。墙内改成「先补一次强制自适应，值本来就对才返回」。
EARLY_ANCHOR = """    if (_lastViewStyle == viewStyle &&
        _devicePixelRatio == ui.window.devicePixelRatio &&
        style != kRemoteViewStyleCustom) {
      return;
    }"""
EARLY_ADD = """    if (_lastViewStyle == viewStyle &&
        _devicePixelRatio == ui.window.devicePixelRatio &&
        style != kRemoteViewStyleCustom) {
      // 【HyDesk】屏幕墙小窗：到这里说明会话认为「什么都没变」，
      // 但缩放可能还是第一次按整窗尺寸算出来的那个。先补一次强制自适应，
      // 值一致就直接返回（不产生多余重绘）。
      if (!useLayoutSize) {
        return;
      }
      final _dw0 = getDisplayWidth(), _dh0 = getDisplayHeight();
      final _sz0 = getSize();
      if (_dw0 <= 0 || _dh0 <= 0 || _sz0.width <= 0 || _sz0.height <= 0) {
        return;
      }
      final _f1 = _sz0.width / _dw0, _f2 = _sz0.height / _dh0;
      final _fs = _f1 < _f2 ? _f1 : _f2;
      final _fx = (_sz0.width - _dw0 * _fs) / 2;
      final _fy = (_sz0.height - _dh0 * _fs) / 2;
      if ((_scale - _fs).abs() < 0.0005 &&
          (_x - _fx).abs() < 0.5 &&
          (_y - _fy).abs() < 0.5) {
        return;
      }
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
    input_model = os.path.join(root, INPUT_REL)
    patch(model, FIELD_ANCHOR, FIELD_ADD, 'CanvasModel.useLayoutSize')
    patch(model, FLAG_ANCHOR, FLAG_ADD, 'CanvasModel.wallNoEdge')
    patch(model, LEFT_ANCHOR, LEFT_ADD, 'CanvasModel.leftToEdge')
    patch(model, TOP_ANCHOR, TOP_ADD, 'CanvasModel.topToEdge')
    patch(model, GETSIZE_ANCHOR, GETSIZE_ADD, 'CanvasModel.getSize')
    patch(page, UPDATER_ANCHOR, UPDATER_ADD, '_ViewStyleUpdater.layoutSize')
    patch(model, EARLY_ANCHOR, EARLY_ADD, 'CanvasModel.updateViewStyle.early')
    patch(model, SCALE_ANCHOR, SCALE_ADD, 'CanvasModel.updateViewStyle.fit')
    patch(model, RESET_ANCHOR, RESET_ADD, 'CanvasModel.reset.fit')
    # 鼠标坐标：墙里必须按「本格画面区原点」修正，否则点第二格会跳到很远
    if os.path.isfile(input_model):
        patch(input_model, INPUT_ANCHOR, INPUT_ADD, 'InputModel.wallOrigin')
        patch(input_model, GRAB_FIELD_ANCHOR, GRAB_FIELD_ADD,
              'InputModel.wallNoGrab')
        patch(input_model, GRAB_CALL_ANCHOR, GRAB_CALL_ADD,
              'InputModel.wallNoGrab.call')
    else:
        raise SystemExit('missing file: %s' % input_model)


if __name__ == '__main__':
    main()
