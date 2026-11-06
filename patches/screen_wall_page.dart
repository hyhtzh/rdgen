// 屏幕墙：把收藏夹里的受控端铺成网格，已保存密码的设备直接拉流做低帧预览。
// 未保存密码的设备只显示卡片，点击后走正常连接流程。
//
// 宿主有两种：
//  1) 独立窗口（desktop_multi_window 子窗口，系统标题栏是隐藏的，必须自绘 + 自己拖动/关闭）；
//  2) 主窗口内 Navigator 压栈（独立窗口创建失败时的降级，带返回栏）。
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';

/// 布局档位 = 一屏最多铺几路（同时也就是列数²）
const _kCapacities = [4, 9, 16, 32, 64];

class _C {
  static const bg = Color(0xFF0F1115);
  static const bar = Color(0xFF16181C);
  static const tile = Color(0xFF16181C);
  static const tileBar = Color(0xFF1E2126);
  static const line = Color(0xFF262A31);
  static const text = Color(0xFFEEF1F5);
  static const sub = Color(0xFF9AA3AF);
  static const accent = Color(0xFF1B72D6);
  static const green = Color(0xFF34C759);
}

/// 屏幕墙只需要低帧画面，把全局 custom-fps 压到 2 再恢复。
/// 墙现在是独立进程，被任务栏 X 直接关掉时 dispose 不会执行，所以额外存一份
/// 备份 + dirty 标记，主窗口下次启动时兜底恢复（否则以后所有远程都变成 2 帧）。
class WallFps {
  static const _kFps = 'custom-fps';
  static const _kBackup = 'wall-fps-backup';
  static const _kDirty = 'wall-fps-dirty';

  static void begin() {
    try {
      final dirty = bind.mainGetUserDefaultOption(key: _kDirty) == 'Y';
      final cur = bind.mainGetUserDefaultOption(key: _kFps);
      if (!dirty && cur.isNotEmpty && cur != '2') {
        bind.mainSetUserDefaultOption(key: _kBackup, value: cur);
        bind.mainSetUserDefaultOption(key: _kDirty, value: 'Y');
      }
      bind.mainSetUserDefaultOption(key: _kFps, value: '2');
    } catch (_) {}
  }

  /// 恢复并清标记；主窗口启动时也调用它做兜底
  static void restore() {
    try {
      if (bind.mainGetUserDefaultOption(key: _kDirty) != 'Y') return;
      final backup = bind.mainGetUserDefaultOption(key: _kBackup);
      if (backup.isNotEmpty) {
        bind.mainSetUserDefaultOption(key: _kFps, value: backup);
      }
      bind.mainSetUserDefaultOption(key: _kDirty, value: 'N');
    } catch (_) {}
  }
}

class ScreenWallPage extends StatefulWidget {
  const ScreenWallPage({Key? key}) : super(key: key);

  @override
  State<ScreenWallPage> createState() => _ScreenWallPageState();
}

class _ScreenWallPageState extends State<ScreenWallPage> {
  int _capacity = 16;
  bool _live = true;
  bool _fullscreen = false;

  /// 独立子窗口才有的 windowId；主窗口内压栈时为 null
  int? get _windowId => kWindowId;

  bool get _isChildWindow => _windowId != null;

  @override
  void initState() {
    super.initState();
    bind.mainLoadFavPeers();
    WallFps.begin();
    // 子窗口默认拦了系统关闭信号，这里放开，任务栏 X 才能正常关掉墙
    final id = _windowId;
    if (id != null) {
      try {
        WindowController.fromWindowId(id).setPreventClose(false);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    WallFps.restore();
    super.dispose();
  }

  int get _columns => math.sqrt(_capacity).round().clamp(1, 8);

  List<Peer> get _peers {
    final all = gFFI.favoritePeersModel.peers;
    if (all.length <= _capacity) return all;
    return all.sublist(0, _capacity);
  }

  // ---------------- 窗口动作 ----------------

  Future<void> _toggleFullscreen() async {
    final id = _windowId;
    if (id == null) return;
    try {
      final wc = WindowController.fromWindowId(id);
      final next = !_fullscreen;
      await wc.setFullscreen(next);
      if (mounted) setState(() => _fullscreen = next);
    } catch (_) {}
  }

  Future<void> _toggleMaximize() async {
    final id = _windowId;
    if (id == null) return;
    try {
      final wc = WindowController.fromWindowId(id);
      if (await wc.isMaximized()) {
        await wc.unmaximize();
      } else {
        await wc.maximize();
      }
    } catch (_) {}
  }

  Future<void> _closeWindow() async {
    final id = _windowId;
    if (id == null) {
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    try {
      final wc = WindowController.fromWindowId(id);
      await wc.setPreventClose(false);
      await wc.close();
    } catch (_) {}
  }

  Future<void> _startDrag() async {
    final id = _windowId;
    if (id == null) return;
    try {
      await WindowController.fromWindowId(id).startDragging();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      style: const TextStyle(decoration: TextDecoration.none),
      child: Scaffold(
        backgroundColor: _C.bg,
        body: Column(
          children: [
            _buildTitleBar(),
            _buildToolbar(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  // ---------------- 自绘标题栏 ----------------

  Widget _buildTitleBar() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => _startDrag(),
      onDoubleTap: _toggleMaximize,
      child: Container(
        height: 32,
        color: _C.bar,
        child: Row(
          children: [
            const SizedBox(width: 10),
            if (!_isChildWindow)
              InkWell(
                onTap: () => Navigator.of(context).maybePop(),
                borderRadius: BorderRadius.circular(5),
                child: const SizedBox(
                  width: 26,
                  height: 24,
                  child: Icon(Icons.arrow_back, size: 16, color: _C.sub),
                ),
              ),
            const SizedBox(width: 4),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: _C.accent,
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Icon(Icons.grid_view_rounded,
                  size: 10, color: Colors.white),
            ),
            const SizedBox(width: 8),
            const Text('屏幕墙',
                style: TextStyle(fontSize: 12.5, color: _C.text)),
            const SizedBox(width: 8),
            AnimatedBuilder(
              animation: gFFI.favoritePeersModel,
              builder: (context, _) {
                final n = gFFI.favoritePeersModel.peers.length;
                return Text('$n 台设备',
                    style: const TextStyle(fontSize: 11.5, color: _C.sub));
              },
            ),
            const Spacer(),
            if (_isChildWindow) ...[
              _winButton(
                _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                _toggleFullscreen,
                tooltip: _fullscreen ? '退出全屏' : '全屏',
              ),
              _winButton(Icons.remove, () async {
                final id = _windowId;
                if (id == null) return;
                try {
                  await WindowController.fromWindowId(id).minimize();
                } catch (_) {}
              }, tooltip: '最小化'),
              _winButton(Icons.crop_square, _toggleMaximize, tooltip: '最大化 / 还原'),
              _winButton(Icons.close, _closeWindow, tooltip: '关闭'),
            ],
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _winButton(IconData icon, VoidCallback onTap, {String? tooltip}) {
    final btn = SizedBox(
      width: 34,
      height: 26,
      child: InkWell(
        onTap: onTap,
        child: Icon(icon, size: 14, color: _C.sub),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: btn,
    );
  }

  // ---------------- 工具条 ----------------

  Widget _buildToolbar() {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _C.line)),
      ),
      child: Row(
        children: [
          const Text('实时预览',
              style: TextStyle(fontSize: 12.5, color: _C.sub)),
          const SizedBox(width: 2),
          Transform.scale(
            scale: 0.8,
            child: Switch(
              value: _live,
              activeColor: _C.accent,
              onChanged: (v) => setState(() => _live = v),
            ),
          ),
          const SizedBox(width: 10),
          Container(width: 1, height: 16, color: _C.line),
          const SizedBox(width: 10),
          const Text('布局', style: TextStyle(fontSize: 12.5, color: _C.sub)),
          const SizedBox(width: 8),
          ..._kCapacities.map(_capacityChip),
          const Spacer(),
          const Text('双击卡片进入控制',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          const SizedBox(width: 6),
          _iconButton(Icons.refresh, '刷新', () {
            bind.mainLoadFavPeers();
            setState(() {});
          }),
        ],
      ),
    );
  }

  Widget _capacityChip(int value) {
    final active = _capacity == value;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: () => setState(() => _capacity = value),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 30,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? _C.accent : const Color(0xFF1F232A),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '$value',
            style: TextStyle(
              fontSize: 11.5,
              color: active ? Colors.white : _C.sub,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: SizedBox(
        width: 32,
        height: 30,
        child: InkWell(
          onTap: onTap,
          child: Icon(icon, size: 17, color: _C.sub),
        ),
      ),
    );
  }

  // ---------------- 网格 ----------------

  Widget _buildBody() {
    return AnimatedBuilder(
      animation: gFFI.favoritePeersModel,
      builder: (context, _) {
        final peers = _peers;
        if (peers.isEmpty) return _buildEmpty();
        return Padding(
          padding: const EdgeInsets.all(12),
          child: GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _columns,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 16 / 10.4,
            ),
            itemCount: peers.length,
            itemBuilder: (context, index) {
              final peer = peers[index];
              return _WallTile(
                key: ValueKey('wall_${peer.id}'),
                peer: peer,
                live: _live && peer.password.isNotEmpty,
                onOpen: () => connect(
                  context,
                  peer.id,
                  password: peer.password.isEmpty ? null : peer.password,
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.grid_view_rounded, size: 44, color: Color(0xFF2E3440)),
          SizedBox(height: 12),
          Text('收藏夹里还没有设备',
              style: TextStyle(fontSize: 14, color: _C.sub)),
          SizedBox(height: 6),
          Text('在首页连接一台设备后点「收藏」，它就会出现在屏幕墙上',
              style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        ],
      ),
    );
  }
}

class _WallTile extends StatefulWidget {
  final Peer peer;
  final bool live;
  final VoidCallback onOpen;

  const _WallTile({
    Key? key,
    required this.peer,
    required this.live,
    required this.onOpen,
  }) : super(key: key);

  @override
  State<_WallTile> createState() => _WallTileState();
}

class _WallTileState extends State<_WallTile> {
  ToolbarState? _toolbarState;

  @override
  void initState() {
    super.initState();
    if (widget.live) {
      _toolbarState = ToolbarState();
      _toolbarState!.hide.value = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final name = peer.alias.isNotEmpty
        ? peer.alias
        : (peer.hostname.isNotEmpty ? peer.hostname : peer.id);
    return Container(
      decoration: BoxDecoration(
        color: _C.tile,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildPreview(),
                // 顶部状态条
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.55),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: peer.online ? _C.green : Colors.grey,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: widget.onOpen,
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.open_in_full,
                                size: 14, color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            color: _C.tileBar,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    peer.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white54,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                Text(
                  widget.live ? '预览中' : (peer.password.isEmpty ? '未存密码' : '已暂停'),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: widget.live ? _C.green : Colors.white38,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (!widget.live || _toolbarState == null) {
      return InkWell(
        onTap: widget.onOpen,
        child: const Center(
          child: Icon(Icons.desktop_windows_outlined,
              size: 32, color: Colors.white24),
        ),
      );
    }
    return GestureDetector(
      onDoubleTap: widget.onOpen,
      child: ClipRect(
        child: RemotePage(
          key: ValueKey('page_${widget.peer.id}'),
          id: widget.peer.id,
          password: widget.peer.password,
          toolbarState: _toolbarState!,
        ),
      ),
    );
  }
}
