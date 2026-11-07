// 屏幕墙：把收藏夹里的受控端铺成网格，已保存密码的设备直接拉流做低帧预览。
// 未保存密码的设备只显示卡片，点击后走正常连接流程。
//
// 宿主有两种：
//  1) 独立窗口（desktop_multi_window 子窗口，系统标题栏是隐藏的，必须自绘 + 自己拖动/关闭）；
//  2) 主窗口内 Navigator 压栈（独立窗口创建失败时的降级，带返回栏）。
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/desktop/pages/license_client.dart';
import 'package:flutter_hbb/desktop/pages/address_book_page.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';

/// 布局档位 = 一屏最多铺几路（同时也就是列数²）
const _kCapacities = [4, 9, 16, 32, 64];

/// 群控用：格子 id -> 内嵌的 RemotePage（RemotePage.ffi 可取到会话 FFI）
final Map<String, RemotePage> _wallPages = {};

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

  /// 被放大成整屏的那一格（空 = 正常网格）。
  /// 双击任意小窗进入，双击画面/点标题栏「还原」退出。
  String _zoomId = '';

  /// 每个格子的 GlobalKey：放大 / 还原时把同一个 Element 搬到新位置，
  /// 会话不会被销毁重建（否则每双击一次都要重新握手、重新出画面）。
  final Map<String, GlobalKey> _tileKeys = {};

  GlobalKey _tileKey(String id) => _tileKeys.putIfAbsent(id, () => GlobalKey());

  /// 主窗口侧（Rust 配置里）是否已经存过这台设备的密码。
  /// 屏幕墙进程读不到主窗口的收藏模型，但 `mainPeerHasPassword` 是本地同步查询，
  /// 主窗口能免密直连的设备，墙里同样能免密拉流。
  final Map<String, bool> _hasSavedPw = {};

  // ---- 群控（9 宫格）：键盘 + 鼠标点击广播 ----
  final Map<String, RemotePage> _pages = {};
  bool _groupOn = false;
  String _groupPrimary = '';

  /// 独立子窗口才有的 windowId；主窗口内压栈时为 null
  int? get _windowId => kWindowId;

  bool get _isChildWindow => _windowId != null;

  /// 收藏列表在本窗口加载不出来时的兜底占位（只有 id，够显示和点开）
  final List<Peer> _favStubs = [];
  List<String>? _favIdsSeen;
  Timer? _favTimer;

  @override
  void initState() {
    super.initState();
    bind.mainLoadFavPeers();
    WallFps.begin();
    // 子窗口默认拦了系统关闭信号，这里放开，任务栏 X 才能正常关掉墙。
    // 窗口刚创建时 method channel 可能还没就绪，首帧后再补一次。
    _releasePreventClose();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _releasePreventClose();
    });
    // 墙跑在独立子进程里，本地配置可能还是授权前的旧快照；进来先拉一次，
    // 刚在别的窗口兑换完附加包就能直接解锁档位。
    _pullLicense();
    // 收藏列表同理：主窗口「加入屏幕墙」只是写配置 + 在主窗口刷新模型，
    // 本窗口收不到那次推送，会一直显示「没有设备」。这里自己对齐。
    _syncFavPeers(force: true);
    _favTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _syncFavPeers();
    });
  }

  /// 按配置里的收藏 id 对齐本窗口的收藏列表。
  /// 先读 id（不依赖推送事件），变了就重新加载；事件没送到本引擎时，
  /// 退化成用「主窗口写下的快照」造 Peer（带别名/在线状态/密码），
  /// 快照也没有才用裸 id 兜底。
  Future<void> _syncFavPeers({bool force = false}) async {
    List<String> ids;
    try {
      ids = (await bind.mainGetFav()).toList();
    } catch (_) {
      return;
    }
    final changed = _favIdsSeen == null || !_sameIds(ids, _favIdsSeen!);
    if (changed || force) {
      _favIdsSeen = ids;
      try {
        bind.mainLoadFavPeers();
      } catch (_) {}
    }
    await _pullWallSnap();
    if (!mounted) return;
    setState(() => _rebuildFavStubs(ids));
    unawaited(_probeSavedPw());
    if (!changed) return;
    // 事件可能只送到主窗口的引擎，稍等再看一眼，仍没有就用快照/裸 id 兜底
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _rebuildFavStubs(ids));
  }

  void _rebuildFavStubs(List<String> ids) {
    final loaded = gFFI.favoritePeersModel.peers
        .map((p) => p.id.replaceAll(' ', ''))
        .toSet();
    _favStubs
      ..clear()
      ..addAll(ids
          .where((id) => !loaded.contains(id.replaceAll(' ', '')))
          .map((id) {
        final key = id.replaceAll(' ', '');
        final s = _snap[key];
        if (s == null) return Peer.fromJson({'id': key});
        final p = Peer.fromJson({
          'id': key,
          'alias': s.alias,
          'hostname': s.hostname,
        });
        p.online = s.online;
        return p;
      }));
  }

  // ---------------- 主窗口数据 ----------------

  /// 主窗口能免密直连的设备 = Rust 配置里已经存过密码。
  /// 墙这边拿不到那个密码明文（也不该拿），但可以问「存过没有」，
  /// 存过就直接开会话、让 Rust 自己用保存的密码登录 —— 这就是
  /// 「直接调用主窗口的访问密码数据」，用户不必在墙里再输一遍。
  Future<void> _probeSavedPw() async {
    var dirty = false;
    for (final p in _peers) {
      final id = p.id.replaceAll(' ', '');
      // 已经确认为 true 的不再重复问（密码只会从无到有）
      if (_hasSavedPw[id] == true) continue;
      bool has = false;
      try {
        has = await bind.mainPeerHasPassword(id: id);
      } catch (_) {}
      if (_hasSavedPw[id] != has) {
        _hasSavedPw[id] = has;
        dirty = true;
      }
    }
    if (dirty && mounted) setState(() {});
  }

  /// 这一格能不能直接出画面：本机有密码，或 Rust 里存过密码
  bool _canPreview(Peer p) =>
      _pwOf(p).isNotEmpty || _hasSavedPw[p.id.replaceAll(' ', '')] == true;

  Map<String, _WallSnapPeer> _snap = {};
  Map<String, String> _pwCache = {};

  /// 屏幕墙跑在独立进程里，收藏模型在本进程是空的（推送事件只送到主窗口），
  /// 别名/在线状态/密码都靠跨窗口 call 回主窗口问一嘴。
  Future<void> _pullWallSnap() async {
    if (!_isChildWindow) return; // 在主窗口里跑，模型本来就有
    try {
      final r = await rustDeskWinManager.call(
          WindowType.Main, 'wall_get_peers', '');
      final res = r.result;
      if (res is! String || res.isEmpty) return;
      final j = jsonDecode(res);
      final list = (j is Map) ? j['peers'] : null;
      if (list is! List) return;
      final next = <String, _WallSnapPeer>{};
      for (final raw in list) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final id = (m['id'] ?? '').toString().replaceAll(' ', '');
        if (id.isEmpty) continue;
        next[id] = _WallSnapPeer(
          id: id,
          alias: (m['alias'] ?? '').toString(),
          hostname: (m['hostname'] ?? '').toString(),
          online: m['online'] == true,
          password: (m['password'] ?? '').toString(),
        );
      }
      _snap = next;
    } catch (_) {}
  }

  /// 手输密码后存下来，下次进墙直接出画面
  Future<void> _askPassword(Peer p) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('输入设备密码',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「${p.alias.isEmpty ? formatAbId(p.id) : p.alias}」还没有保存密码，'
                '输入后在墙里直接预览。',
                style: const TextStyle(fontSize: 12.5, height: 1.6)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: '设备密码 / 临时密码',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确定')),
        ],
      ),
    );
    final pw = ctrl.text.trim();
    if (ok != true || pw.isEmpty) return;
    _pwCache[p.id.replaceAll(' ', '')] = pw;
    if (mounted) setState(() {});
  }

  bool _sameIds(List<String> a, List<String> b) =>
      a.length == b.length && a.every((x) => b.contains(x));

  Future<void> _pullLicense() async {
    try {
      await LicenseClient.instance.check();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  /// 从墙里移除一台设备（墙就是收藏夹，移除即取消收藏）
  Future<void> _removePeer(Peer peer) async {
    final name = peer.alias.isNotEmpty
        ? peer.alias
        : (peer.hostname.isNotEmpty ? peer.hostname : peer.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('从屏幕墙移除',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text('移除后「$name」不再显示在墙上（同时取消收藏，不影响已保存的密码）。',
            style: const TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消', style: TextStyle(color: Color(0xFF9AA3AF)))),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE23B3B), elevation: 0),
            child: const Text('移除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = await removePeersFromScreenWall([peer.id]);
    if (!mounted) return;
    if (n < 0) {
      showToast('移除失败，请重试');
      return;
    }
    _wallPages.remove(peer.id);
    await _syncFavPeers(force: true);
    if (mounted) setState(() {});
    showToast('已从屏幕墙移除');
  }

  void _releasePreventClose() {
    final id = _windowId;
    if (id == null) return;
    try {
      WindowController.fromWindowId(id).setPreventClose(false);
    } catch (_) {}
  }

  @override
  void dispose() {
    _favTimer?.cancel();
    WallFps.restore();
    _setGroupListeners(false);
    super.dispose();
  }

  // ---------------- 群控广播 ----------------

  void _setGroupListeners(bool on) {
    try {
      if (on) {
        RawKeyboard.instance.addListener(_onGroupRawKey);
      } else {
        RawKeyboard.instance.removeListener(_onGroupRawKey);
      }
    } catch (_) {}
  }

  /// 把键盘事件广播到除主控格以外的所有已连接会话。
  void _onGroupRawKey(RawKeyEvent e) {
    if (!_groupOn) return;
    for (final entry in _wallPages.entries) {
      if (entry.key == _groupPrimary) continue;
      try {
        entry.value.ffi.inputModel.handleRawKeyEvent(e);
      } catch (_) {}
    }
  }

  /// 群控时的点击：点击的格子成为主控；按下/抬起广播给其余会话
  /// （走 bind.sessionSendMouse 原始协议，不依赖 InputModel 的手势换算）
  void _groupPointer(String id, bool down) {
    if (!_groupOn) return;
    _groupPrimary = id;
    for (final entry in _wallPages.entries) {
      if (entry.key == id) continue;
      try {
        final sid = entry.value.ffi.sessionId;
        bind.sessionSendMouse(
            sessionId: sid,
            msg: json.encode({'type': down ? 'down' : 'up', 'buttons': 'left'}));
      } catch (_) {}
    }
  }

  int get _columns => math.sqrt(_capacity).round().clamp(1, 8);

  List<Peer> get _peers {
    final loaded = gFFI.favoritePeersModel.peers;
    // 模型里还没有的收藏，用占位补上（本窗口收不到推送事件时不至于空着）
    final all = <Peer>[
      ...loaded,
      ..._favStubs.where((s) => !loaded.any((p) => p.id == s.id)),
    ];
    if (all.length <= _capacity) return all;
    return all.sublist(0, _capacity);
  }

  /// 密码可能在三处：Peer 自带 / 主窗口快照 / 本进程最近连接，
  /// 最后还有用户在墙里手输的缓存。任何一处拿到就直接出画面。
  String _pwOf(Peer p) {
    if (p.password.isNotEmpty) return p.password;
    final key = p.id.replaceAll(' ', '');
    final snapPw = _snap[key]?.password ?? '';
    if (snapPw.isNotEmpty) return snapPw;
    try {
      for (final r in gFFI.recentPeersModel.peers) {
        if (r.id.replaceAll(' ', '') == key && r.password.isNotEmpty) {
          return r.password;
        }
      }
    } catch (_) {}
    return _pwCache[key] ?? '';
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
            // 放大单屏时把工具条也收起来：用户要看的是整块远端桌面
            if (_zoomId.isEmpty) _buildToolbar(),
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
            Text(_zoomId.isEmpty ? '屏幕墙' : '屏幕墙 · 放大',
                style: const TextStyle(fontSize: 12.5, color: _C.text)),
            const SizedBox(width: 8),
            if (_zoomId.isEmpty)
              AnimatedBuilder(
                animation: gFFI.favoritePeersModel,
                builder: (context, _) {
                  // 数量按「墙里实际铺出来的格子」算：收藏模型还没同步到本窗口时
                  // 会显示 0，但格子其实已经用占位排出来了，看起来就像坏了。
                  final n = _peers.length;
                  return Text('$n 台设备',
                      style: const TextStyle(fontSize: 11.5, color: _C.sub));
                },
              )
            else
              InkWell(
                onTap: _unzoom,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  height: 20,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F232A),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: _C.line),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.grid_view_rounded, size: 11, color: _C.sub),
                      SizedBox(width: 4),
                      Text('还原小窗',
                          style: TextStyle(fontSize: 11, color: _C.sub)),
                    ],
                  ),
                ),
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
          const SizedBox(width: 10),
          _groupChip(),
          const Spacer(),
          if (_groupOn) ...[
            const Icon(Icons.wifi_tethering,
                size: 13, color: Color(0xFF2FA45C)),
            const SizedBox(width: 5),
            const Text('群控中 · 键盘与鼠标点击广播到其余在线格子（点击某格设为主控）',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF2FA45C))),
            const SizedBox(width: 8),
          ],
          const Text('双击卡片进入控制',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          const SizedBox(width: 6),
          _iconButton(Icons.playlist_add_check, '添加设备到屏幕墙',
              _showAddPeersDialog),
          _iconButton(Icons.refresh, '刷新', () {
            _syncFavPeers(force: true);
          }),
        ],
      ),
    );
  }

  Widget _groupChip() {
    return InkWell(
      onTap: _toggleGroup,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _groupOn
              ? const Color(0xFF2FA45C)
              : const Color(0xFF1F232A),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_tethering,
                size: 12,
                color: _groupOn ? Colors.white : _C.sub),
            const SizedBox(width: 4),
            Text('群控',
                style: TextStyle(
                  fontSize: 11.5,
                  color: _groupOn ? Colors.white : _C.sub,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
      ),
    );
  }

  void _toggleGroup() {
    // 定价：4 屏（含）以下群控免费；4 屏以上按 20 元/月收费
    if (!_groupOn && _capacity > 4 && !licenseFeature('group')) {
      _showUpgradeDialog('群控（20 元/月）', 'paGroup');
      return;
    }
    setState(() {
      _groupOn = !_groupOn;
      if (!_groupOn) _groupPrimary = '';
    });
    _setGroupListeners(_groupOn);
  }

  /// 已经买过卡密的用户，不必绕到授权详情，就地兑换
  Future<void> _redeemCode({String? productId}) async {
    final ctrl = TextEditingController();
    final act = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('兑换附加包',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('输入屏幕墙档位或群控的授权码，开通后立即生效。',
                style: TextStyle(fontSize: 13, color: _C.sub, height: 1.6)),
            const SizedBox(height: 8),
            // 没买过的用户也要有明确出口，别只给一个输入框
            InkWell(
              onTap: () => Navigator.of(ctx).pop('buy'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('还没有授权码？',
                        style: TextStyle(fontSize: 12.5, color: _C.sub)),
                    Text('去商城购买 →',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF1B72D6),
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'XXXX-XXXX-XXXX-XXXX',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: Text('取消', style: TextStyle(color: _C.sub)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop('ok'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B72D6),
              elevation: 0,
            ),
            child: const Text('立即开通',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (act == 'buy') {
      if (!mounted) return;
      await gotoShop(context, productId: productId);
      return;
    }
    if (act != 'ok') return;
    final code = ctrl.text.trim();
    if (code.isEmpty) {
      // 以前这里是静默 return，用户以为按钮坏了
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('请先填写附加包授权码；还没有码可点弹窗里的「去商城购买」'),
          duration: Duration(seconds: 3)));
      return;
    }
    try {
      final r = await LicenseClient.instance.activate(code);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r.isAddon ? '已开通：${r.addonName}，请重新点击档位' : '授权已更新'),
          duration: const Duration(seconds: 3)));
    } on LicenseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.msg), duration: const Duration(seconds: 3)));
    }
  }

  /// 收费档位 / 功能 未授权时弹的引导框
  void _showUpgradeDialog(String what, String productId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('该功能需要升级授权',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text(
            '$what属于付费功能，当前授权不包含。\n\n购买拿到授权码后，在「授权详情 → 兑换附加包」里输入即可开通，立即生效，不需要重新激活主授权。附加包绑定当前授权码，换设备后重新激活同一授权码依然可用。',
            style: TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: _C.sub)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _redeemCode(productId: productId);
            },
            child: Text('已购买，兑换',
                style: TextStyle(
                    color: Color(0xFF2FA45C), fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              if (!mounted) return;
              // 统一走 gotoShop：浏览器唤不起时复制链接并弹窗，不会点了没反应
              await gotoShop(context, productId: productId);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFF1B72D6),
              elevation: 0,
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: Text('购买',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCapacity(int value) async {
    // 定价：9 屏以下免费；16 屏 4 元/月、32 屏 12 元/月、64 屏 20 元/月
    bool locked() =>
        (value == 16 && !licenseFeature('wall16')) ||
        (value == 32 && !licenseFeature('wall32')) ||
        (value == 64 && !licenseFeature('wall64'));
    if (locked()) {
      // 可能是刚在别的窗口兑换完、本进程配置还没刷新：先拉一次再判定，
      // 免得已付费的用户被收费弹窗再拦一次。
      try {
        await LicenseClient.instance.check();
      } catch (_) {}
      if (!mounted) return;
      if (locked()) {
        final price = value == 16 ? '4' : (value == 32 ? '12' : '20');
        _showUpgradeDialog('$value 屏布局（$price 元/月）', 'pa$value');
        return;
      }
      setState(() {});
    }
    // 切到 4 屏以上且没有群控授权时，自动关掉群控，避免白用
    if (_groupOn && value > 4 && !licenseFeature('group')) {
      setState(() {
        _groupOn = false;
        _groupPrimary = '';
      });
    }
    setState(() => _capacity = value);
  }

  Widget _capacityChip(int value) {
    final active = _capacity == value;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: () => _pickCapacity(value),
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

  // ---------------- 添加设备 ----------------

  /// 屏幕墙窗口内直接加设备：候选 = 最近连接 + 收藏 + 地址簿（按识别码去重），
  /// 勾选后批量写入收藏并刷新墙。
  Future<void> _showAddPeersDialog() async {
    try {
      bind.mainLoadRecentPeers();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 400));
    try {
      await AddressBookStore.instance.load();
    } catch (_) {}
    final Map<String, _AddCandidate> map = {};
    void put(String id, String alias, String note) {
      final key = id.replaceAll(' ', '');
      if (key.isEmpty) return;
      final existing = map[key];
      if (existing == null || (existing.alias.isEmpty && alias.isNotEmpty)) {
        map[key] = _AddCandidate(id: key, alias: alias, note: note);
      }
    }

    for (final p in gFFI.recentPeersModel.peers) {
      put(p.id, p.alias, p.hostname);
    }
    for (final p in gFFI.favoritePeersModel.peers) {
      put(p.id, p.alias, p.hostname);
    }
    for (final e in AddressBookStore.instance.entries) {
      put(e.id, e.alias, e.note);
    }
    List<String> favs = [];
    try {
      favs = (await bind.mainGetFav()).toList();
    } catch (_) {}
    final favSet = favs.map((s) => s.replaceAll(' ', '')).toSet();
    final candidates = map.values.toList()
      ..sort((a, b) => a.display.compareTo(b.display));
    if (!mounted) return;
    final sel = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _AddPeersDialog(candidates: candidates, favSet: favSet),
    );
    if (sel == null || sel.isEmpty) return;
    final n = await addPeersToScreenWall(sel.toList());
    if (!mounted) return;
    // 加完立刻按配置对齐一次，不用等 3 秒轮询
    await _syncFavPeers(force: true);
    if (!mounted) return;
    if (n < 0) {
      showToast('添加失败，请重试');
    } else if (n == 0) {
      showToast('所选设备都已在屏幕墙里');
    } else {
      showToast('已把 $n 台设备加入屏幕墙');
    }
  }

  // ---------------- 网格 / 放大 ----------------

  void _zoom(String id) {
    if (_zoomId == id) return;
    setState(() => _zoomId = id.replaceAll(' ', ''));
  }

  void _unzoom() {
    if (_zoomId.isEmpty) return;
    setState(() => _zoomId = '');
  }

  void _toggleZoom(String id) {
    final key = id.replaceAll(' ', '');
    if (_zoomId == key) {
      _unzoom();
    } else {
      _zoom(key);
    }
  }

  Widget _buildBody() {
    return AnimatedBuilder(
      animation: gFFI.favoritePeersModel,
      builder: (context, _) {
        final peers = _peers;
        if (peers.isEmpty) return _buildEmpty();
        if (_zoomId.isNotEmpty) {
          final hit = peers.where((p) => p.id.replaceAll(' ', '') == _zoomId);
          if (hit.isNotEmpty) return _buildZoomed(hit.first);
          // 设备被移出墙了，放大状态自动作废
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _zoomId.isNotEmpty) _unzoom();
          });
        }
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
            itemBuilder: (context, index) => _tile(peers[index], zoomed: false),
          ),
        );
      },
    );
  }

  /// 单屏放大：整块 body 只放这一路，上下各留 6px
  Widget _buildZoomed(Peer peer) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: _tile(peer, zoomed: true),
    );
  }

  Widget _tile(Peer peer, {required bool zoomed}) {
    final pw = _pwOf(peer);
    return _WallTile(
      // 同一个 GlobalKey：放大/还原时搬的是同一个 Element，会话不重建
      key: _tileKey(peer.id.replaceAll(' ', '')),
      peer: peer,
      password: pw,
      live: _live && _canPreview(peer),
      zoomed: zoomed,
      onOpen: () => connect(
        context,
        peer.id,
        password: pw.isEmpty ? null : pw,
      ),
      onToggleZoom: () => _toggleZoom(peer.id),
      onRemove: () => _removePeer(peer),
      onSetPassword: () => _askPassword(peer),
      onGroupPointer:
          _groupOn ? (id, down) => _groupPointer(id, down) : null,
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

  /// 该设备的保存密码（可能来自最近连接；空表示没存过）
  final String password;

  /// 是否开一路预览会话（墙里连上就出画面）
  final bool live;

  /// 是否处于「放大成整屏」状态
  final bool zoomed;

  /// 打开独立的控制窗口（有完整工具栏的那种）
  final VoidCallback onOpen;

  /// 双击画面：放大 / 还原
  final VoidCallback onToggleZoom;

  /// 从墙里移除这台设备
  final VoidCallback onRemove;

  /// 没存密码时，让用户手输一次
  final VoidCallback onSetPassword;

  /// 群控：down/up=按下/抬起；id 为本格识别码
  final void Function(String id, bool down)? onGroupPointer;

  const _WallTile({
    Key? key,
    required this.peer,
    required this.password,
    required this.live,
    required this.zoomed,
    required this.onOpen,
    required this.onToggleZoom,
    required this.onRemove,
    required this.onSetPassword,
    this.onGroupPointer,
  }) : super(key: key);

  @override
  State<_WallTile> createState() => _WallTileState();
}

class _WallTileState extends State<_WallTile> {
  ToolbarState? _toolbarState;

  /// 远端会话建立后把缩放方式强制成「自适应」：
  /// 原生默认可能就是 1:1（original），一格只有 200px 宽时只会露出
  /// 远端桌面的左上角一块，用户就看不到整个屏幕了。
  Timer? _fitTimer;
  int _fitTries = 0;

  /// 手写双击识别：RemotePage 内部有手势竞争，外层 GestureDetector.onDoubleTap
  /// 抢不到事件（这也是之前「双击没反应」的原因），所以用 Listener 自己数。
  DateTime _lastDownAt = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastDownPos = Offset.zero;

  bool _hover = false;

  @override
  void initState() {
    super.initState();
    if (widget.live) _ensureSession();
  }

  @override
  void didUpdateWidget(covariant _WallTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 密码是后来才拿到的（主窗口快照晚到、或 Rust 里本来就有保存密码）时，
    // 这里把会话补建出来，否则格子会一直停在占位画面上。
    if (widget.live && _toolbarState == null) {
      _ensureSession();
    }
  }

  void _ensureSession() {
    _toolbarState ??= ToolbarState();
    _toolbarState!.hide.value = true;
    // 注册进「墙预览」集合：这条会话的工具栏一律不渲染
    kWallToolbarStates.add(_toolbarState!);
    _startFitLoop();
  }

  void _startFitLoop() {
    _fitTimer?.cancel();
    _fitTries = 0;
    _fitTimer = Timer.periodic(const Duration(milliseconds: 700), (t) async {
      _fitTries++;
      final page = _wallPages[widget.peer.id];
      int sid = 0;
      try {
        sid = page?.ffi.sessionId ?? 0;
      } catch (_) {
        sid = 0;
      }
      if (sid != 0) {
        try {
          await bind.sessionSetViewStyle(
              sessionId: sid, value: kRemoteViewStyleAdaptive);
          try {
            page?.ffi.canvasModel.updateViewStyle();
          } catch (_) {}
        } catch (_) {}
        t.cancel();
        return;
      }
      if (_fitTries > 20) t.cancel();
    });
  }

  @override
  void dispose() {
    _fitTimer?.cancel();
    final ts = _toolbarState;
    if (ts != null) kWallToolbarStates.remove(ts);
    _wallPages.remove(widget.peer.id);
    super.dispose();
  }

  String get _name {
    final p = widget.peer;
    if (p.alias.isNotEmpty) return p.alias;
    if (p.hostname.isNotEmpty) return p.hostname;
    return formatAbId(p.id);
  }

  /// 双击判定：两次按下间隔 < 420ms 且落点相距 < 40px
  void _onDown(PointerDownEvent e) {
    final now = DateTime.now();
    final isDouble = now.difference(_lastDownAt).inMilliseconds < 420 &&
        (e.localPosition - _lastDownPos).distance < 40;
    _lastDownAt = isDouble ? DateTime.fromMillisecondsSinceEpoch(0) : now;
    _lastDownPos = e.localPosition;
    if (isDouble) widget.onToggleZoom();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _C.tile,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: widget.zoomed ? _C.accent.withOpacity(0.55) : Colors.white.withOpacity(0.06),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // 标题条在画面外面：画面区一整块都是远端桌面，不再被渐变遮住顶部
          MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: _buildTileBar(),
          ),
          Expanded(child: ColoredBox(color: Colors.black, child: _buildPreview())),
        ],
      ),
    );
  }

  Widget _buildTileBar() {
    final online = widget.peer.online;
    return Container(
      height: 22,
      color: _C.tileBar,
      padding: const EdgeInsets.only(left: 7, right: 2),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: online ? const Color(0xFF3DBE5B) : const Color(0xFFE23B3B),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              _name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (_hover)
            Text(
              widget.live ? '预览中' : (online ? '待连接' : '离线'),
              style: TextStyle(
                fontSize: 9.5,
                color: widget.live ? _C.green : Colors.white38,
              ),
            ),
          const SizedBox(width: 2),
          _barButton(
            widget.zoomed ? Icons.fullscreen_exit : Icons.fullscreen,
            widget.zoomed ? '还原小窗' : '放大这一屏',
            widget.onToggleZoom,
            // 放大按钮常驻：小窗里最常用的就是这个
            alwaysShow: true,
          ),
          _barButton(Icons.open_in_full, '打开控制窗口（带工具栏）', widget.onOpen),
          _barButton(Icons.close_rounded, '从屏幕墙移除', widget.onRemove),
        ],
      ),
    );
  }

  Widget _barButton(IconData icon, String tip, VoidCallback onTap,
      {bool alwaysShow = false}) {
    if (!_hover && !alwaysShow) return const SizedBox.shrink();
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 20,
          height: 22,
          child: Icon(icon, size: 13, color: Colors.white70),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (!widget.live || _toolbarState == null) {
      return _buildPlaceholder();
    }
    final page = RemotePage(
      key: ValueKey('page_${widget.peer.id}'),
      id: widget.peer.id,
      // 空密码就不传：让 Rust 用本机保存的密码登录（= 主窗口那份密码），
      // 主窗口能免密直连的设备，墙里也不会再问一遍。
      password: widget.password.isEmpty ? null : widget.password,
      toolbarState: _toolbarState!,
    );
    // 群控广播需要拿到每个会话的 FFI（RemotePage.ffi），注册进全局表
    _wallPages[widget.peer.id] = page;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _onDown(e);
        widget.onGroupPointer?.call(widget.peer.id, true);
      },
      onPointerUp: (_) => widget.onGroupPointer?.call(widget.peer.id, false),
      child: ClipRect(child: page),
    );
  }

  Widget _buildPlaceholder() {
    final p = widget.peer;
    final needPw = p.online && widget.password.isEmpty;
    final String hint;
    if (!p.online) {
      hint = '设备离线';
    } else if (needPw) {
      hint = '还没保存密码';
    } else {
      hint = '预览已暂停';
    }
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      child: InkWell(
        onTap: needPw ? widget.onSetPassword : widget.onToggleZoom,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(needPw ? Icons.key_outlined : Icons.desktop_windows_outlined,
                  size: widget.zoomed ? 42 : 28, color: Colors.white24),
              const SizedBox(height: 6),
              Text(hint,
                  style: const TextStyle(fontSize: 11, color: Colors.white38)),
              const SizedBox(height: 6),
              if (needPw)
                OutlinedButton(
                  onPressed: widget.onSetPassword,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withOpacity(0.35)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(fontSize: 11.5),
                  ),
                  child: const Text('输入密码'),
                )
              else
                Text(
                  '双击放大 / 还原',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10, color: Colors.white24),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「添加设备到屏幕墙」的可选项（识别码去重后的统一视图）
class _AddCandidate {
  final String id;
  final String alias;
  final String note;
  _AddCandidate({required this.id, required this.alias, required this.note});
  String get display => alias.isEmpty ? formatAbId(id) : alias;
}

/// 屏幕墙窗口内批量添加设备：搜索 + 复选框列表，已在墙里的设备置灰不可选
class _AddPeersDialog extends StatefulWidget {
  final List<_AddCandidate> candidates;
  final Set<String> favSet;

  const _AddPeersDialog({required this.candidates, required this.favSet});

  @override
  State<_AddPeersDialog> createState() => _AddPeersDialogState();
}

class _AddPeersDialogState extends State<_AddPeersDialog> {
  final Set<String> _sel = {};
  String _q = '';

  List<_AddCandidate> get _filtered {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return widget.candidates;
    return widget.candidates
        .where((c) =>
            c.id.contains(q) ||
            c.display.toLowerCase().contains(q) ||
            c.note.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加设备到屏幕墙',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      content: SizedBox(
        width: 430,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              onChanged: (v) => setState(() => _q = v),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon:
                    const Icon(Icons.search, size: 17, color: Colors.grey),
                hintText: '搜索名称 / 识别码 / 备注',
                hintStyle: const TextStyle(fontSize: 12.5, color: Colors.grey),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _filtered.isEmpty
                  ? const Center(
                      child: Text('没有找到设备',
                          style: TextStyle(fontSize: 13, color: Colors.grey)),
                    )
                  : ListView.builder(
                      itemCount: _filtered.length,
                      itemBuilder: (context, i) =>
                          _row(context, _filtered[i]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(fontSize: 13.5)),
        ),
        TextButton(
          onPressed: _sel.isEmpty
              ? null
              : () => Navigator.of(context).pop(_sel),
          child: Text(_sel.isEmpty ? '添加' : '添加（${_sel.length} 台）',
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1B72D6))),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, _AddCandidate c) {
    final inWall = widget.favSet.contains(c.id);
    final checked = _sel.contains(c.id);
    return InkWell(
      onTap: inWall
          ? null
          : () => setState(
              () => checked ? _sel.remove(c.id) : _sel.add(c.id)),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: inWall
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: Icon(Icons.check_circle,
                          size: 17, color: Color(0xFFB8C4D4)),
                    )
                  : Checkbox(
                      value: checked,
                      onChanged: (v) => setState(() => v == true
                          ? _sel.add(c.id)
                          : _sel.remove(c.id)),
                    ),
            ),
            const SizedBox(width: 6),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: abAvatarColor(c.display),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.desktop_windows_outlined,
                  size: 19, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: inWall
                            ? const Color(0xFF9AA4B2)
                            : const Color(0xFF333333)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.note.isEmpty ? formatAbId(c.id) : '${formatAbId(c.id)} · ${c.note}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF7A7A7A)),
                  ),
                ],
              ),
            ),
            if (inWall)
              const Text('已在屏幕墙',
                  style: TextStyle(
                      fontSize: 11.5, color: Color(0xFF9AA4B2))),
          ],
        ),
      ),
    );
  }
}

/// 主窗口落盘的收藏快照（屏幕墙进程读不到收藏模型，只能靠这份）
class _WallSnapPeer {
  final String id;
  final String alias;
  final String hostname;
  final bool online;
  final String password;
  const _WallSnapPeer({
    required this.id,
    this.alias = '',
    this.hostname = '',
    this.online = false,
    this.password = '',
  });
}
