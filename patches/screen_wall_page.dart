// 屏幕墙：把收藏夹里的受控端铺成网格，已保存密码的设备直接拉流做低帧预览。
// 未保存密码的设备只显示卡片，点击后走正常连接流程。
//
// 宿主有两种：
//  1) 独立窗口（desktop_multi_window 子窗口，系统标题栏是隐藏的，必须自绘 + 自己拖动/关闭）；
//  2) 主窗口内 Navigator 压栈（独立窗口创建失败时的降级，带返回栏）。
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, exit, Directory, File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/desktop/pages/license_client.dart';
import 'package:flutter_hbb/desktop/pages/address_book_page.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:uuid/uuid.dart';

// ---------------------------------------------------------------------------
// 【HyDesk】自动录屏 / 截图（管理端执行）
//
// 录屏（2026-11-09 重做）：**原生视频文件**，不再是 PNG 帧序列
// （用户报障「只能截图，没有录像视频」）。每一路墙会话调上游
// sessionRecordScreen，由 Rust 侧 Recorder 把会话视频流编码成
// .webm/.mp4（VP8/VP9 → webm，H264/H265 → mp4），Windows 自带播放器直接放。
// · 落盘目录通过本地选项 video-save-directory 对齐到墙自定义根目录；
// · 停止/格子销毁时归档：<根>\<设备名>\录像\<设备名>_时间.webm
//   （文件名以重命名后的设备名为主，不暴露识别码）；
// · 录像期间该路临时提到 20fps/balanced（墙平时 5fps/low 录出来没法看），
//   停录恢复 5fps/low。
// 自动截图：与录屏独立开关，画面有变化才栅格化一张 PNG
// （远端屏幕原始分辨率），最短间隔 3 秒，静止不截图。
// 目录：<根目录>\<设备名>\截图\yyyyMMdd_HHmmssfff.png
// 收费：4 路免费；墙里设备超过 4 路需要 record 附加包，
// 与屏幕墙档位/群控同一套体系（licenseFeature），客户端不显示金额。
// ---------------------------------------------------------------------------
class WallRecorder {
  static bool on = false;
  /// 【HyDesk】自动截图模式：与录屏独立开关。画面有变化才落一张 PNG，
  /// 最短间隔 3 秒（拖动/播放时不刷屏），静止不截图。
  /// **按远端屏幕原始分辨率落盘**（不是格子的缩略图），放大查看不糊。
  /// 目录：<根目录>\<设备名>\截图\yyyyMMdd_HHmmssfff.png
  static bool snapOn = false;
  static String root = r'D:\录屏';
  static Timer? _tick;
  static final Map<String, bool Function()> _lanes = {};
  /// 【HyDesk】原生视频录制：每格注册自己的启停回调。
  /// key = 设备 id，value = ctl(true/false) 启/停该路的 sessionRecordScreen。
  static final Map<String, Future<void> Function(bool)> _vids = {};

  static void register(String id, bool Function() alive) => _lanes[id] = alive;
  static void unregister(String id) => _lanes.remove(id);
  static void registerVideo(String id, Future<void> Function(bool) ctl) =>
      _vids[id] = ctl;
  static void unregisterVideo(String id) => _vids.remove(id);

  static void start() {
    on = true;
    _prepareThenStart();
  }

  /// 先把原生录像的落盘目录对齐到墙根目录（Rust 侧 Recorder::new 时读取），
  /// 再逐路启动，避免目录还没写入就开始录。
  static void _prepareThenStart() async {
    try {
      await bind.mainSetLocalOption(
          key: 'video-save-directory', value: root);
    } catch (_) {}
    for (final ctl in _vids.values.toList()) {
      unawaited(ctl(true));
    }
    _ensureTick();
  }

  static void stop() {
    on = false;
    for (final ctl in _vids.values.toList()) {
      unawaited(ctl(false));
    }
    if (!snapOn) {
      _tick?.cancel();
      _tick = null;
    }
    _lanes.clear();
  }

  /// 截图/录像共用的存活巡检（销毁的格子自动清注册，防泄漏）。
  static void _ensureTick() {
    _tick ??= Timer.periodic(const Duration(seconds: 2), (_) {
      _lanes.removeWhere((_, f) => !f());
    });
  }

  /// 【HyDesk】修复：只开「自动截图」不开录像时，周期器也要跑
  /// （旧实现 tick 只在录像 start() 里启动，导致截图开关单独开无效）。
  static void startSnap() {
    snapOn = true;
    _ensureTick();
  }

  static void stopSnap() {
    snapOn = false;
    if (!on) {
      _tick?.cancel();
      _tick = null;
    }
  }

  static String loadRoot() {
    try {
      final v = bind.mainGetOptionSync(key: 'wall-rec-root');
      if (v != null && v.isNotEmpty) root = v;
    } catch (_) {}
    return root;
  }

  static Future<void> saveRoot(String v) async {
    root = v;
    try {
      await bind.mainSetOption(key: 'wall-rec-root', value: v);
    } catch (_) {}
  }
}

String _sanitizeName(String s) => s
    .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
    .trim()
    .replaceAll(RegExp(r'\s+'), '_');

/// 布局档位 = 一屏最多铺几路（同时也就是列数²）。
/// 手机端只给 4/9 两档：屏幕本来小，16 格以上每格小到看不见。
const _kCapacitiesDesktop = [4, 9, 16, 32, 64];
final List<int> _kCapacities =
    Platform.isAndroid || Platform.isIOS ? const [4, 9] : _kCapacitiesDesktop;

/// 同时保持多少路预览会话。
///
/// 每路会话在本机都有一份解码线程 + 一路视频流，铺太多会把整机 CPU 吃满，
/// 表现是进程消息循环饿死 → 输入法候选框弹不出来、键盘像失灵
/// （用户报过「开启屏幕墙后整个电脑无法使用输入法」）。
/// 9 路已经够看一个 3×3 墙；16/32 档超出的格子只显示卡片，点开再连。
/// 手机端同样给 9 路（用户 2026-11-09 要求「切到 9 屏自动开启全部连接」）：
/// 墙里全程压 5 帧 + low 画质，手机可以承受；4 屏档位下天然只有 4 路。
final int _kMaxLive = 9;

/// 取某一格的 FFI（会话、画布、输入模型都在里面）。
///
/// **不能用** `RemotePage.ffi`：那个 getter 读的是 widget 实例自己的
/// `_lastState`，而墙里每次 build 都会新建一个 RemotePage widget（State 复用、
/// `_lastState` 却是空的）→ 取一次抛一次异常，被 try/catch 吞掉，
/// 表现就是「自适应永远不生效、群控拿不到会话、鼠标换算全是 0」。
///
/// RemotePage 在 initState 里做了 `Get.put<FFI>(_ffi, tag: 设备id)`，
/// 按 id 从 GetX 里取到的才是这一格自己的会话。
FFI? wallFfi(String id) {
  for (final tag in {id, id.replaceAll(' ', '')}) {
    try {
      // common.dart 里的官方辅助：Get.find<FFI>(tag: 设备id)，
      // RemotePage 在 initState 里就是用它注册这一路会话的。
      return ffi(tag);
    } catch (_) {}
  }
  return null;
}

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

/// 屏幕墙只需要低帧画面，进墙时把全局 custom-fps 压到合法下限再恢复。
///
/// **值必须 ≥ 5**：RustDesk 的 io_loop 里有
/// `if custom_fps < 5 || custom_fps > 120 { custom_fps = 30 }` 的兜底，
/// 以前这里写的是 '2'，会被判非法直接回落成 **30 帧** —— 等于墙里
/// 9~16 路一直在全速解码，整机被拖到输入法都弹不出来。这是本次的真凶。
///
/// 墙是独立进程，被任务栏 X 直接关掉时 dispose 不会执行，所以额外存一份
/// 备份 + dirty 标记，主窗口下次启动时兜底恢复（否则以后所有远程都变成 5 帧）。
class WallFps {
  static const _kFps = 'custom-fps';
  static const _kBackup = 'wall-fps-backup';
  static const _kDirty = 'wall-fps-dirty';

  // 画质同理：墙里每格只有几百像素宽，却按 balanced/best 拉整屏原图，
  // 解码量白白放大好几倍。网格态降到 low，放大成单屏再恢复。
  static const _kQual = 'image_quality';
  static const _kQualBackup = 'wall-qual-backup';
  static const _kQualDirty = 'wall-qual-dirty';

  /// RustDesk 允许的最小帧率；低于它会被当成非法值回落 30
  static const _kLow = '5';
  static const _kQualLow = 'low';

  static void begin() {
    try {
      // 上次墙是任务栏 X / 崩溃退出的，dirty 会留在配置里。
      // 先把值恢复回去，再重新备份当前值 —— 否则用户在这期间改过的设置
      // 会被旧备份覆盖。
      final dirtyFps = bind.mainGetUserDefaultOption(key: _kDirty) == 'Y';
      final cur = bind.mainGetUserDefaultOption(key: _kFps);
      if (dirtyFps) {
        restore();
      } else {
        // 历史版本写坏的 '2' 不能备份（它本身是非法值，读回来会变成 30）
        final keep = (cur.isEmpty || cur == '2') ? '30' : cur;
        bind.mainSetUserDefaultOption(key: _kBackup, value: keep);
        bind.mainSetUserDefaultOption(key: _kDirty, value: 'Y');
      }

      if (bind.mainGetUserDefaultOption(key: _kQualDirty) == 'Y') {
        _restoreQuality();
      } else {
        final q = bind.mainGetUserDefaultOption(key: _kQual);
        bind.mainSetUserDefaultOption(
            key: _kQualBackup, value: q.isEmpty ? 'balanced' : q);
        bind.mainSetUserDefaultOption(key: _kQualDirty, value: 'Y');
      }

      bind.mainSetUserDefaultOption(key: _kFps, value: _kLow);
      bind.mainSetUserDefaultOption(key: _kQual, value: _kQualLow);
    } catch (_) {}
  }

  static void _restoreQuality() {
    try {
      if (bind.mainGetUserDefaultOption(key: _kQualDirty) != 'Y') return;
      final b = bind.mainGetUserDefaultOption(key: _kQualBackup);
      bind.mainSetUserDefaultOption(
          key: _kQual, value: b.isNotEmpty ? b : 'balanced');
      bind.mainSetUserDefaultOption(key: _kQualDirty, value: 'N');
    } catch (_) {}
  }

  /// 恢复并清标记；主窗口启动时也调用它做兜底
  static void restore() {
    try {
      if (bind.mainGetUserDefaultOption(key: _kDirty) == 'Y') {
        final backup = bind.mainGetUserDefaultOption(key: _kBackup);
        bind.mainSetUserDefaultOption(
            key: _kFps, value: backup.isNotEmpty ? backup : '30');
        bind.mainSetUserDefaultOption(key: _kDirty, value: 'N');
      }
      _restoreQuality();
    } catch (_) {}
  }
}

class ScreenWallPage extends StatefulWidget {
  const ScreenWallPage({Key? key}) : super(key: key);

  @override
  State<ScreenWallPage> createState() => _ScreenWallPageState();
}

class _ScreenWallPageState extends State<ScreenWallPage> {
  /// 默认开 4 格（2×2）。
  ///
  /// 以前默认 16：一进墙就把收藏里 16 台全部建会话、同时拉 16 路视频，
  /// 机器当场被拖满 —— 用户看到的是「打开屏幕墙后整个电脑输入法都不能用」。
  /// 现在默认只连 4 路，用户切到 9/16 档才连更多，而且选择会记住。
  int _capacity = 4;
  bool _live = true;
  bool _fullscreen = false;

  /// 已经「在独立窗口里打开」的设备：双击小窗后开独立远控窗口，
  /// 同时把这一格的预览会话关掉（和原生小窗→大窗口的行为一致），
  /// 免得同一台设备在本机并着两路会话。
  final Set<String> _bigIds = {};

  /// 墙内放大的那一格（铺满整墙，null = 正常网格）。
  ///
  /// 「放大」以前是开独立窗口，收回来要跨窗口关窗 + 轮询子窗口列表，
  /// 这条链上任何一环不灵（窗口 id 对不上、列表拿不到、子进程没注册
  /// controller），用户就只能把整个墙关掉重开 —— 就是他说的
  /// 「屏幕放大后无法退回小窗口，只能关闭」。
  /// 现在放大就在墙里做：同一棵树上换尺寸/层级，收放都是本地 setState，
  /// 不跨窗口、不重连会话。
  String? _maxId;

  /// 已开的大窗口：设备 id -> 子窗口 id（用来判断那个窗口是不是被关掉了）
  final Map<String, int> _bigWinIds = {};
  final Map<String, DateTime> _bigBorn = {};
  Timer? _bigWatch;

  /// 每格的「重建代次」：点重连、从大窗口收回时 +1，
  /// 格子会用新的 key 重建会话（旧会话彻底释放，避免半死连接）。
  final Map<String, int> _retryGen = {};


  // ---- 群控（9 宫格）：键盘 + 鼠标点击广播 ----
  bool _groupOn = false;
  String _groupPrimary = '';

  /// 已经收到 down、还没收到 up 的设备 id。抬起的坐标不一定和按下时同格，
  /// 但保证「按下的每台都会收到对应的抬起」，不会出现按键卡住。
  final Set<String> _groupDown = {};

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
    // 上次用的档位（默认 4）。存在用户配置里，重启后不用每次重新切。
    try {
      final saved =
          int.tryParse(bind.mainGetUserDefaultOption(key: 'wall-capacity'));
      if (saved != null && _kCapacities.contains(saved)) _capacity = saved;
    } catch (_) {}
    // 墙窗口里的小窗没有标签栏/窗口边框：把画布的边距置零，
    // 否则原生会按 28px 标签栏修正鼠标坐标 → 点哪里都差 28 像素。
    CanvasModel.wallNoEdge = true;
    WallFps.begin();
    // Esc 收回墙内放大（只在放大态拦截，平时完全透传）
    try {
      HardwareKeyboard.instance.addHandler(_onKeyEvent);
    } catch (_) {}
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
    // 3 秒一轮的轮询不能让整墙每轮都重建：9 路 RemotePage 一起 build
    // 很容易卡一下。内容没变就什么都不做。
    final sig = _wallSig(ids);
    if (sig != _lastSig) {
      _lastSig = sig;
      setState(() => _rebuildFavStubs(ids));
    }
    unawaited(_probeSavedPw());
    if (!changed) return;
    // 事件可能只送到主窗口的引擎，稍等再看一眼，仍没有就用快照/裸 id 兜底
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _rebuildFavStubs(ids));
  }

  String _lastSig = '';

  /// 墙上要显示的内容指纹（id + 别名 + 在线态 + 密码是否已知）。
  /// 用来避免「什么都没变也整墙重建」。
  String _wallSig(List<String> ids) {
    final b = StringBuffer();
    for (final id in ids) {
      final key = id.replaceAll(' ', '');
      final s = _snap[key];
      b.write(key);
      b.write(s?.alias ?? '');
      b.write(s?.online == true ? '1' : '0');
      b.write(_savedPw.contains(key) ? '1' : '0');
      b.write((_pwCache[key]?.isNotEmpty ?? false) ? '1' : '0');
      b.write('|');
    }
    return b.toString();
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

  /// 本机 Rust 配置里「存过密码」的设备 id 集合。
  ///
  /// 只取「有没有」这个结果，**绝不**把 peer 配置里的 `password` 字段当成
  /// 密码传下去：那串是密文（`Vec<u8>`），传给 `sessionAdd(password: ...)`
  /// 会被对端判成「密码错误」，而且会盖掉本机已经存好的那一份，于是
  /// 每次进墙/开大窗口都要重新输一遍。什么都不传，Rust 才会自己拿存好的
  /// 密码去登录 —— 这才是主窗口「免密直连」走的那条路。
  final Set<String> _savedPw = {};

  /// 每台设备探测一次：本机是否存过密码（只要结果，不要内容）
  final Set<String> _pwProbed = {};

  Future<void> _probeSavedPw() async {
    var changed = false;
    for (final p in _peers) {
      final id = p.id.replaceAll(' ', '');
      if (_savedPw.contains(id) || _pwProbed.contains(id)) continue;
      bool has = false;
      try {
        has = await bind.mainPeerHasPassword(id: id);
        _pwProbed.add(id); // 只有问到了才记住，异常的下轮还能再问
      } catch (_) {}
      if (!has) continue;
      _savedPw.add(id);
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  /// 这一格能不能直接出画面：
  /// - 有明文密码（地址簿共享密码 / 主窗口快照 / 最近连接）→ 直接传给会话；
  /// - 或者本机存过密码 → 不传密码，让 Rust 自动登录。
  bool _canPreview(Peer p) =>
      _pwOf(p).isNotEmpty || _savedPw.contains(p.id.replaceAll(' ', ''));

  Map<String, _WallSnapPeer> _snap = {};

  /// 用户在墙里手输过的明文密码（只在本进程有效；长期保存靠 Rust 的
  /// 「记住密码」，也就是 peer 配置里那份加密后的数据）
  Map<String, String> _pwCache = {};

  /// 屏幕墙跑在独立进程里，收藏模型在本进程是空的（推送事件只送到主窗口），
  /// 别名/在线状态/密码都靠跨窗口 call 回主窗口问一嘴。
  bool _snapBusy = false;

  Future<void> _pullWallSnap() async {
    if (!_isChildWindow) return; // 在主窗口里跑，模型本来就有
    if (_snapBusy) return; // 上一次还没回来就别再压一层（会越堆越卡）
    _snapBusy = true;
    try {
      // 主窗口卡住时这个跨窗口调用可能一直不返回，加超时兜底
      final r = await rustDeskWinManager
          .call(WindowType.Main, 'wall_get_peers', '')
          .timeout(const Duration(seconds: 4));
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
    } catch (_) {
    } finally {
      _snapBusy = false;
    }
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
    _bigIds.remove(peer.id.replaceAll(' ', ''));
    _retryGen.remove(peer.id.replaceAll(' ', ''));
    // 移除的正好是放大那一格：退回网格，否则画面停在一个已删掉的设备上
    if (_maxId == peer.id.replaceAll(' ', '')) _setMaxId(null);
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
    CanvasModel.wallNoEdge = false;
    try {
      HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    } catch (_) {}
    if (_groupOn) _releaseGroupButtons();
    _bigWatch?.cancel();
    WallFps.restore();
    _setGroupListeners(false);
    super.dispose();
  }

  // ---------------- 群控广播 ----------------

  /// 退出群控 / 页面销毁时，给所有被控端补一个「抬起」：
  /// 否则对端会一直以为左键按着，鼠标就"卡"住了。
  void _releaseGroupButtons() {
    if (_groupDown.isEmpty) return;
    final pending = _groupDown.toList();
    _groupDown.clear();
    for (final id in pending) {
      final sess = wallFfi(id);
      if (sess == null) continue;
      try {
        bind.sessionSendMouse(
            sessionId: sess.sessionId,
            msg: json.encode({
              'type': 'up',
              'buttons': 'left',
              'x': '0',
              'y': '0',
            }));
      } catch (_) {}
    }
  }

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
    for (final p in _peers) {
      final id = p.id;
      if (id == _groupPrimary) continue;
      final sess = wallFfi(id);
      if (sess == null) continue;
      try {
        sess.inputModel.handleRawKeyEvent(e);
      } catch (_) {}
    }
  }

  /// 群控时的点击：点到的格子成为主控，按下/抬起连同「远端坐标」一起
  /// 广播给其余会话。
  ///
  /// 坐标怎么来的很关键：用**主控格自己的画布**把落点换成远端像素
  /// （`(落点 - 画布偏移) / 缩放`），再按各端分辨率比例换算、加上对端
  /// 显示原点。这样不管格子被缩放到多大，落点都和原生点击一致。
  void _groupPointer(String id, Offset local, bool down) {
    if (!_groupOn) return;
    if (down) _groupPrimary = id;

    double rx = 0, ry = 0;
    int pw = 0, ph = 0;
    final src = wallFfi(id);
    if (src != null) {
      try {
        final c = src.canvasModel;
        final scale = c.scale;
        if (scale > 0) {
          rx = (local.dx - c.x) / scale;
          ry = (local.dy - c.y) / scale;
        }
        pw = c.getDisplayWidth();
        ph = c.getDisplayHeight();
      } catch (_) {}
    }
    if (pw <= 0 || ph <= 0) return;

    for (final p in _peers) {
      if (p.id == id) continue;
      // 抬起：只补给真正按下过的那几台
      if (!down && !_groupDown.contains(p.id)) continue;
      final sess = wallFfi(p.id);
      if (sess == null) continue;
      try {
        final c = sess.canvasModel;
        final dw = c.getDisplayWidth();
        final dh = c.getDisplayHeight();
        if (dw <= 0 || dh <= 0) continue;
        // 各机器分辨率不同：先按比例换成对端的相对像素，再加上对端的显示原点
        var x = rx * dw / pw;
        var y = ry * dh / ph;
        final rect = sess.ffiModel.rect;
        if (rect != null) {
          x += rect.left;
          y += rect.top;
        }
        final int xi = x.round();
        final int yi = y.round();
        final sid = sess.sessionId;
        if (down) {
          _groupDown.add(p.id);
          // 先移动再按下：远端光标先到位，点击才落在主控点的那一处
          bind.sessionSendMouse(
              sessionId: sid,
              msg: json.encode({
                'type': 'move',
                'buttons': 'left',
                'x': '$xi',
                'y': '$yi',
              }));
          bind.sessionSendMouse(
              sessionId: sid,
              msg: json.encode({
                'type': 'down',
                'buttons': 'left',
                'x': '$xi',
                'y': '$yi',
              }));
        } else {
          _groupDown.remove(p.id);
          bind.sessionSendMouse(
              sessionId: sid,
              msg: json.encode({
                'type': 'up',
                'buttons': 'left',
                'x': '$xi',
                'y': '$yi',
              }));
        }
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
    // 不再按档位截断：超出当前档位的格子由布局层 Offstage 藏起来，
    // 这样换到小档位时那几路会话不会被销毁（否则就是「切分屏必掉线」）。
    return all;
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

  /// 墙窗口当前是否由我们最大化。
  ///
  /// 不能只信 native 的 `isMaximized()`：自绘边框的子窗口在 Windows 上
  /// 常常恒返回 false，于是「点一次最大化，之后再点还是最大化」——
  /// 用户看到的就是「屏幕放大后无法缩小，只能关闭」。
  /// 这里自己记状态，native 只当第一次的线索。
  bool _maxed = false;

  Future<void> _toggleMaximize() async {
    final id = _windowId;
    if (id == null) return;
    final wc = WindowController.fromWindowId(id);
    var isMax = _maxed;
    if (!isMax) {
      try {
        isMax = await wc.isMaximized();
      } catch (_) {}
    }
    try {
      if (isMax) {
        await wc.unmaximize();
        _maxed = false;
      } else {
        await wc.maximize();
        _maxed = true;
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  /// 正在优雅关闭：格子先摘下树，再关窗口。期间 build 直接给空壳，
  /// 防止轮询/重建把 RemotePage 又拉回树上。
  bool _shutting = false;

  Future<void> _closeWindow() async {
    if (_shutting) return;
    final id = _windowId;
    if (id == null) {
      // 主窗口压栈的降级形态：正常 pop，路由销毁时整棵树连同
      // RemotePage 一起 dispose，会话本来就是优雅关闭的。
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
    _shutting = true;
    if (mounted) setState(() {});
    // 1) 先把所有格子从树上摘掉：RemotePage 走完整 dispose
    //    （释放 grab、销毁纹理、向对端发 sessionClose）。
    //    之前是窗口一关整个进程直接死，4~9 路会话不发关闭消息，
    //    对端/中继留着一堆半开连接 —— 用户接着单独连同一台设备时
    //    握手困难，过一会儿还容易崩（就是这次要修的问题）。
    await Future.delayed(const Duration(milliseconds: 150));
    // 2) 兜底：树上没摘干净的（挂起、Offstage 里的）直接关 FFI。
    //    已关过的再关一次是无害的（sessionClose 对已关会话是空操作）。
    for (final p in _peers) {
      final sess = wallFfi(p.id);
      if (sess == null) continue;
      try {
        await sess.close(closeSession: true);
      } catch (_) {}
    }
    // 3) 恢复全局帧率/画质（子进程销毁时 dispose 不会跑，这里手动恢复，
    //    磁盘上的配置立刻回到墙外该有的值）
    WallFps.restore();
    // 4) 给 sessionClose / 输入释放一点冲刷时间再销毁窗口
    await Future.delayed(const Duration(milliseconds: 400));
    try {
      final wc = WindowController.fromWindowId(id);
      await wc.setPreventClose(false);
      await wc.close();
    } catch (_) {}
    // 5) 进程兜底：窗口销毁后引擎偶尔被 Rust 会话线程拽住不退，
    //    留一个看不见的进程继续占着几路连接（表现同「关了墙还连不上」）。
    //    1.5 秒后强退；主窗口压栈形态不走这里（_windowId == null）。
    //    安卓上没有子窗口形态，但万一误入此分支也绝不能 exit——
    //    手机端 exit(0) 会杀掉整个 App（墙只是 App 里的一个页面）。
    if (!Platform.isAndroid && !Platform.isIOS) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        try {
          exit(0);
        } catch (_) {}
      });
    }
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
    // 关闭中：只剩空壳。不摘干净的话，周期同步会把 RemotePage 又 build 回来。
    if (_shutting) {
      return const Scaffold(backgroundColor: _C.bg, body: SizedBox.expand());
    }
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

  /// 切换「墙内放大」，同时同步帧率。
  ///
  /// 网格态 9~16 路都在跑，必须压到低帧（5 帧，RustDesk 允许的下限）；
  /// 放大成单屏就是控制台，5 帧没法操作，要恢复用户自己的帧率。
  void _setMaxId(String? id) {
    if (_maxId == id) return;
    final prev = _maxId;
    _maxId = id;
    _applyFpsForMode();
    // 已在跑的会话不会自动跟随全局选项（那套只影响“将要建”的会话），
    // 放大/收回必须当场热推给受影响的那一路，切换才有即时反应。
    unawaited(_pushFpsHot(prev, id));
  }

  /// 会话级帧率/画质热推送：改的是**正在拉流**的那一路会话，
  /// 改完 refresh_video 让对端按新参数重新出图。
  ///
  /// 以前只写全局默认值：放大后画面仍按 5 帧 low 拉，要等很久才“看起来
  /// 清晰了”，观感就是「切换没反应、卡」。
  Future<void> _pushFpsHot(String? prev, String? cur) async {
    final maxed = cur;
    final restored = prev;
    for (final entry in {
      maxed: true, // 放大：恢复用户自己的帧率/画质
      restored: false, // 刚收回的这路：压回墙的省流参数
    }.entries) {
      final key = entry.key;
      if (key == null) continue;
      final sess = wallFfi(key);
      if (sess == null) continue;
      try {
        final sid = sess.sessionId;
        final tag = '$sid';
        if (tag == '0' ||
            tag == '00000000-0000-0000-0000-000000000000') {
          continue;
        }
        if (entry.value) {
          final backFps = bind.mainGetUserDefaultOption(key: 'wall-fps-backup');
          final backQual =
              bind.mainGetUserDefaultOption(key: 'wall-qual-backup');
          await bind.sessionSetCustomFps(
              sessionId: sid, fps: int.tryParse(backFps) ?? 30);
          await bind.sessionSetImageQuality(
              sessionId: sid,
              value: backQual.isNotEmpty ? backQual : 'balanced');
        } else {
          await bind.sessionSetCustomFps(sessionId: sid, fps: 5);
          await bind.sessionSetImageQuality(sessionId: sid, value: 'low');
        }
        // refresh 用会话当前显示器（多屏对端 display 0 未必在放）
        var disp = 0;
        try {
          disp = sess.ffiModel.pi.currentDisplay;
        } catch (_) {}
        await bind.sessionRefresh(sessionId: sid, display: disp);
      } catch (_) {}
    }
  }

  /// 网格态压帧/降画质，放大态恢复。
  ///
  /// `custom-fps` 的合法范围是 5~120，写更小的值会被 RustDesk 判非法、
  /// 回落成 30（这就是以前「压了帧率还卡」的根因）。
  void _applyFpsForMode() {
    try {
      final backFps = bind.mainGetUserDefaultOption(key: 'wall-fps-backup');
      final backQual = bind.mainGetUserDefaultOption(key: 'wall-qual-backup');
      if (_maxId != null) {
        bind.mainSetUserDefaultOption(
            key: 'custom-fps', value: backFps.isNotEmpty ? backFps : '30');
        bind.mainSetUserDefaultOption(
            key: 'image_quality',
            value: backQual.isNotEmpty ? backQual : 'balanced');
      } else {
        bind.mainSetUserDefaultOption(key: 'custom-fps', value: '5');
        bind.mainSetUserDefaultOption(key: 'image_quality', value: 'low');
      }
    } catch (_) {}
  }

  /// Esc = 收回墙内放大。
  ///
  /// 放大后整墙都被画面盖住，必须有一个「不用找按钮」的退出方式，
  /// 否则用户只能关窗口。用全局键盘钩子而不是 Focus：RemotePage 内部
  /// 会抢焦点，Focus.onKeyEvent 收不到。这里只在放大态吞掉 Esc，
  /// 平时完全透传（不干扰远端键盘、也不碰本机输入法）。
  bool _onKeyEvent(KeyEvent e) {
    if (_maxId == null) return false;
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _setMaxId(null));
      return true;
    }
    return false;
  }

  // ---------------- 自绘标题栏 ----------------

  Widget _buildTitleBar() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => _startDrag(),
      onDoubleTap: _toggleMaximize,
      child: Container(
        // 手机端标题栏加高：系统字体放大时按钮文字容易被压扁（用户报「按钮变形」）
        height: (Platform.isAndroid || Platform.isIOS) ? 44 : 32,
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
                // 数量按「墙里实际铺出来的格子」算：收藏模型还没同步到本窗口时
                // 会显示 0，但格子其实已经用占位排出来了，看起来就像坏了。
                final n = _peers.length;
                return Text('$n 台设备',
                    style: const TextStyle(fontSize: 11.5, color: _C.sub));
              },
            ),
            const Spacer(),
            // 手机端：没有系统标题栏也没有窗口按钮，左上角的小灰箭头太不
            // 显眼，用户报「屏幕墙没有退出按钮」。右侧给一个明确的红色
            // 退出按钮（2026-11-09）。
            if (Platform.isAndroid || Platform.isIOS)
              _mobileExitButton()
            else if (_isChildWindow) ...[
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
              _winButton(
                  _maxed ? Icons.filter_none : Icons.crop_square,
                  _toggleMaximize,
                  tooltip: _maxed ? '还原窗口' : '最大化'),
              _winButton(Icons.close, _closeWindow, tooltip: '关闭'),
            ],
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  /// 手机端标题栏右侧的「退出屏幕墙」按钮。
  ///
  /// 2026-11-09 重做：原来是 height:24 + horizontal padding 的方角按钮，
  /// 系统字体放大时文字撑破容器、圆角被压成异形（用户报「按钮变形」）。
  /// 现在改成固定 32 高的胶囊（StadiumBorder）+ 文字缩放锁定，任何
  /// 字体倍率下形状和字号都不变。
  Widget _mobileExitButton() {
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: 1.0,
      maxScaleFactor: 1.0,
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox(
          height: 32,
          child: Material(
            color: const Color(0xFFE03A3A),
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _closeWindow,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: const [
                    Icon(Icons.logout_rounded, size: 15, color: Colors.white),
                    SizedBox(width: 6),
                    Text('退出屏幕墙',
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.0,
                            letterSpacing: 0.2,
                            color: Colors.white,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
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
    final mobile = Platform.isAndroid || Platform.isIOS;
    // 手机竖屏放不下这一整排（用户截图里「群控 / 双击卡片放…」被切掉），
    // 移动端改成横向可滚动，并去掉只对桌面有意义的提示文案。
    final leading = <Widget>[
      const Text('实时预览', style: TextStyle(fontSize: 12.5, color: _C.sub)),
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
      const SizedBox(width: 10),
      _recordChip(),
      const SizedBox(width: 10),
      _snapChip(),
      const SizedBox(width: 10),
      _recRootChip(),
      const SizedBox(width: 10),
    ];
    final trailing = <Widget>[
      // 放大后最显眼的出口：墙上格子里的按钮可能被画面盖住/看不清，
      // 顶栏这个一直在。
      if (_maxId != null) ...[
        _restoreFromMaxChip(),
        const SizedBox(width: 8),
      ],
      if (_groupOn) ...[
        const Icon(Icons.wifi_tethering, size: 13, color: Color(0xFF2FA45C)),
        const SizedBox(width: 5),
        const Text('群控中 · 键盘与鼠标点击广播到其余在线格子（点击某格设为主控）',
            style: TextStyle(fontSize: 11.5, color: Color(0xFF2FA45C))),
        const SizedBox(width: 8),
      ],
      if (!mobile) ...[
        const Text('双击卡片放大/收回',
            style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
        const SizedBox(width: 6),
      ],
      _iconButton(Icons.playlist_add_check, '添加设备到屏幕墙', _showAddPeersDialog),
      _iconButton(Icons.refresh, '刷新', () {
        _syncFavPeers(force: true);
      }),
    ];
    return Container(
      height: mobile ? 44 : 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _C.line)),
      ),
      child: mobile
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [...leading, ...trailing]),
            )
          : Row(
              children: [...leading, const Spacer(), ...trailing],
            ),
    );
  }

  /// 顶栏的「收回」提示条：放大后用它在任何情况下都能退回网格
  Widget _restoreFromMaxChip() {
    var name = '';
    for (final p in _peers) {
      if (p.id.replaceAll(' ', '') == _maxId) {
        name = p.alias.isNotEmpty ? p.alias : p.hostname;
        break;
      }
    }
    return InkWell(
      onTap: () => setState(() => _setMaxId(null)),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1B72D6),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.close_fullscreen, size: 12, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              '收回${name.isEmpty ? '' : '「$name」'}（Esc）',
              style: const TextStyle(
                  fontSize: 11.5,
                  color: Colors.white,
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
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
    // 收费：4 屏（含）以下群控免费；4 屏以上需要 group 附加包（价格在套餐里配置）
    if (!_groupOn && _capacity > 4 && !licenseFeature('group')) {
      _showUpgradeDialog('群控', 'paGroup');
      return;
    }
    final wasOn = _groupOn;
    setState(() {
      _groupOn = !_groupOn;
      if (!_groupOn) _groupPrimary = '';
    });
    _setGroupListeners(_groupOn);
    if (wasOn && !_groupOn) _releaseGroupButtons();
    // 群控开 = 要操作这么多台，把各路从「只看」切成可操作；
    // 群控关 = 回到只看，避免退出群控后随手一点就落到别人机器上。
    if (wasOn != _groupOn) _applyViewOnlyToAll(!_groupOn);
  }

  /// 把墙里所有会话的「只看」状态刷成目标值（群控开关联动）。
  ///
  /// 目标值一样就跳过：翻转会话选项同时会写设备配置并推给对端，
  /// 不必要地翻来翻去会让对端的键盘/剪贴板开关反复跳。
  Future<void> _applyViewOnlyToAll(bool viewOnly) async {
    for (final p in _peers) {
      final sess = wallFfi(p.id);
      if (sess == null) continue;
      try {
        final sid = sess.sessionId;
        final cur = await bind.sessionGetToggleOption(
            sessionId: sid, arg: kOptionToggleViewOnly);
        // 读不到（会话还没起来）就不动 Flutter 侧的状态，免得两边说法不一致
        if (cur == null || cur == viewOnly) continue;
        await bind.sessionToggleOption(
            sessionId: sid, value: kOptionToggleViewOnly);
        sess.ffiModel.setViewOnly(p.id, viewOnly);
      } catch (_) {}
    }
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

  /// 自定义录屏存储位置：每路设备在根目录下按设备名单独建文件夹
  Future<void> _showRecRootDialog() async {
    final ctrl = TextEditingController(text: WallRecorder.loadRoot());
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('录屏存储位置',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: ctrl, decoration: const InputDecoration(suffixText: '')),
            const SizedBox(height: 8),
            const Text('每路设备在该目录下按设备名单独建文件夹（录像/截图）；\n录像为视频文件（webm/mp4），停止后自动归档。',
                style: TextStyle(fontSize: 12, color: _C.sub)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _C.accent),
              onPressed: () {
                final p = ctrl.text.trim();
                if (p.isEmpty) return;
                Navigator.of(ctx).pop(p);
              },
              child: const Text('保存')),
        ],
      ),
    ).then((v) async {
      if (v is String && v.isNotEmpty) {
        await WallRecorder.saveRoot(v);
        showToast('已保存，之后的录屏存到：$v');
      }
    });
  }

  /// 自动录屏/截图开关（4 路免费，超过 4 路需 record 附加包，与档位同一套体系）
  Widget _recordChip() {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _toggleRecord(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: WallRecorder.on
              ? const Color(0xFFFDECEC)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: WallRecorder.on
                  ? const Color(0xFFE5484D)
                  : _C.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              WallRecorder.on ? Icons.fiber_manual_record : Icons.videocam_outlined,
              size: 12,
              color: WallRecorder.on
                  ? const Color(0xFFE5484D)
                  : _C.sub,
            ),
            const SizedBox(width: 4),
            Text(
              WallRecorder.on ? '录像中' : '自动录像',
              style: TextStyle(
                  fontSize: 11.5,
                  color: WallRecorder.on
                      ? const Color(0xFFE5484D)
                      : _C.sub),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleRecord() async {
    if (WallRecorder.on) {
      setState(() => WallRecorder.stop());
      showToast('已停止自动录像，视频已按设备名归档');
      return;
    }
    // 4 路免费；墙里设备超过 4 路时需要 record 附加包
    if (_peers.length > 4 && !licenseFeature('record')) {
      try {
        await LicenseClient.instance.check();
      } catch (_) {}
      if (!licenseFeature('record')) {
        _showUpgradeDialog('自动录屏/截图（4 路以上）', 'paRecord');
        return;
      }
    }
    final root = WallRecorder.loadRoot();
    try {
      Directory(root).createSync(recursive: true);
    } catch (_) {}
    setState(() => WallRecorder.start());
    showToast('自动录像已开启：生成视频文件（webm/mp4），保存在 $root');
  }

  /// 自动截图独立开关（与录屏分开启停；同一收费规则：4 路免费，超出 record 附加包）
  Widget _snapChip() {
    final on = WallRecorder.snapOn;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _toggleSnap(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFE8F0FE) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: on ? const Color(0xFF1B72D6) : _C.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.camera_alt : Icons.camera_alt_outlined,
              size: 12,
              color: on ? const Color(0xFF1B72D6) : _C.sub,
            ),
            const SizedBox(width: 4),
            Text(
              on ? '截图中' : '自动截图',
              style: TextStyle(
                  fontSize: 11.5,
                  color: on ? const Color(0xFF1B72D6) : _C.sub),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleSnap() async {
    if (WallRecorder.snapOn) {
      setState(() => WallRecorder.stopSnap());
      showToast('已停止自动截图');
      return;
    }
    // 4 路免费；墙里设备超过 4 路时需要 record 附加包（与录屏同一附加包）
    if (_peers.length > 4 && !licenseFeature('record')) {
      try {
        await LicenseClient.instance.check();
      } catch (_) {}
      if (!licenseFeature('record')) {
        _showUpgradeDialog('自动截图（4 路以上）', 'paRecord');
        return;
      }
    }
    final root = WallRecorder.loadRoot();
    try {
      Directory(root).createSync(recursive: true);
    } catch (_) {}
    setState(() => WallRecorder.startSnap());
    showToast('自动截图已开启：画面有操作才截图，静止不截图');
  }

  /// 录屏/截图存储位置胶囊：路径常驻可见，点击改路径。
  Widget _recRootChip() {
    final root = WallRecorder.loadRoot();
    final short = root.length > 22 ? '…${root.substring(root.length - 21)}' : root;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _showRecRootDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _C.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_outlined, size: 12, color: _C.sub),
            const SizedBox(width: 4),
            Text('存储：$short',
                style: const TextStyle(fontSize: 11.5, color: _C.sub)),
          ],
        ),
      ),
    );
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
    // 收费：9 屏以下免费；16/32/64 屏需要附加包（价格只在套餐里配置，
    // 客户端不显示金额 —— 2026-11-09 用户明确要求）。
    // 档位向下包含（2026-11-09 用户要求）：买了 64 屏，16/32 一起解锁，
    // 无需重复购买；买了 32 屏，16 屏也免费。
    bool locked() {
      final has16 = licenseFeature('wall16');
      final has32 = licenseFeature('wall32');
      final has64 = licenseFeature('wall64');
      if (value == 16) return !(has16 || has32 || has64);
      if (value == 32) return !(has32 || has64);
      if (value == 64) return !has64;
      return false;
    }
    if (locked()) {
      // 可能是刚在别的窗口兑换完、本进程配置还没刷新：先拉一次再判定，
      // 免得已付费的用户被收费弹窗再拦一次。
      try {
        await LicenseClient.instance.check();
      } catch (_) {}
      if (!mounted) return;
      if (locked()) {
        _showUpgradeDialog('$value 屏布局', 'pa$value');
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
    try {
      bind.mainSetUserDefaultOption(
          key: 'wall-capacity', value: '$value');
    } catch (_) {}
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

  /// 双击（或点标题条上的放大按钮）= 把这一路放大成大窗口：
  /// 打开独立的远控窗口，同时关掉这一格的小窗预览。
  void _openBig(Peer peer) {
    final key = peer.id.replaceAll(' ', '');
    final pw = _pwOf(peer);
    // 安卓：没有多窗口能力，newRemoteDesktop 必失败；别先等 260ms 再试它，
    // 直接走全屏连接流程，点了立刻有反应。
    if (Platform.isAndroid || Platform.isIOS) {
      setState(() => _bigIds.add(key));
      connect(context, peer.id, password: pw.isEmpty ? null : pw);
      return;
    }
    // 先让这一格的小窗关掉（live=false → 预览会话 dispose），
    // 再开大窗口：同一台设备在本机不会并着两路会话。
    setState(() {
      if (_maxId == key) _setMaxId(null); // 墙内放大与独立窗口不叠加
      _bigIds.add(key);
    });
    Future.delayed(const Duration(milliseconds: 260), () async {
      if (!mounted) return;
      int wid = 0;
      try {
        final r = await rustDeskWinManager.newRemoteDesktop(
          peer.id,
          password: pw.isEmpty ? null : pw,
        );
        wid = r.windowId;
      } catch (_) {
        // 走原生新窗口失败时退回到普通连接流程（主窗口里开标签页/窗口）
        if (!mounted) return;
        setState(() => _bigIds.remove(key));
        connect(context, peer.id, password: pw.isEmpty ? null : pw);
        return;
      }
      if (!mounted) return;
      if (wid > 0) {
        _bigWinIds[key] = wid;
        _bigBorn[key] = DateTime.now();
        _startBigWatch();
      }
    });
  }

  /// 「收回屏幕墙」：关掉这一路的大窗口，并把小窗预览接回来。
  ///
  /// 以前只把 `_bigIds` 里的记录删掉，靠轮询子窗口列表来兜底；
  /// 可一旦 `getAllSubWindowIds()` 拿不到（或窗口 id 对不上），那一格就永远
  /// 停在「已放大成大窗口显示」，用户怎么点都回不到墙上。
  /// 现在改成主动关窗 + 重建会话，不依赖轮询能不能用。
  void _restorePreview(Peer peer) {
    final key = peer.id.replaceAll(' ', '');
    unawaited(_closeBigWindow(key));
    _bigWinIds.remove(key);
    _bigBorn.remove(key);
    if (!mounted) return;
    setState(() {
      _bigIds.remove(key);
      // +1 让格子用新的 key 重建会话：旧的那路已经跟着大窗口结束了，
      // 直接复用会出现「连不上/黑屏」，这也是「收不回来」的原因之一。
      _retryGen[key] = (_retryGen[key] ?? 0) + 1;
    });
  }

  Future<void> _closeBigWindow(String key) async {
    final wid = _bigWinIds[key];
    if (wid == null || wid <= 0) return;
    try {
      await WindowController.fromWindowId(wid).close();
    } catch (_) {}
  }

  /// 盯住这些大窗口：子窗口列表中消失了，就认为它被关掉了，
  /// 顺手把对应的小窗预览恢复回来（用户提的「关闭大窗口后小窗要自动连上」）。
  void _startBigWatch() {
    var listFails = 0;
    _bigWatch ??= Timer.periodic(const Duration(milliseconds: 1200), (_) async {
      if (_bigWinIds.isEmpty) {
        _bigWatch?.cancel();
        _bigWatch = null;
        return;
      }
      List<int> alive;
      try {
        alive = await rustDeskWinManager.getAllSubWindowIds();
        listFails = 0;
      } catch (_) {
        // 窗口列表拿不到时不能一直等：等太久这一格就「回不来」了
        if (++listFails >= 12) {
          listFails = 0;
          final keys = _bigWinIds.keys.toList();
          _bigWinIds.clear();
          _bigBorn.clear();
          if (mounted) {
            setState(() {
              for (final k in keys) {
                _bigIds.remove(k);
                _retryGen[k] = (_retryGen[k] ?? 0) + 1;
              }
            });
          }
        }
        return;
      }
      final now = DateTime.now();
      final gone = <String>[];
      _bigWinIds.forEach((k, wid) {
        // 刚开出来的窗口可能还没进列表，给 6 秒宽限
        final born = _bigBorn[k];
        if (born != null && now.difference(born).inSeconds < 6) return;
        if (!alive.contains(wid)) gone.add(k);
      });
      if (gone.isEmpty) return;
      for (final k in gone) {
        _bigWinIds.remove(k);
        _bigBorn.remove(k);
      }
      if (!mounted) return;
      setState(() {
        for (final k in gone) {
          _bigIds.remove(k);
          // 大窗口关了 → 小窗换一路新会话（旧会话随大窗口一起结束了）
          _retryGen[k] = (_retryGen[k] ?? 0) + 1;
        }
      });
    });
  }

  Widget _buildBody() {
    return AnimatedBuilder(
      animation: gFFI.favoritePeersModel,
      builder: (context, _) {
        final peers = _peers;
        if (peers.isEmpty) return _buildEmpty();
        return LayoutBuilder(
          builder: (context, c) {
            const gap = 8.0;
            const pad = 8.0;
            final cols = _columns;
            final rows = (_capacity / cols).ceil();
            final tw = (c.maxWidth - pad * 2 - gap * (cols - 1)) / cols;
            final th = (c.maxHeight - pad * 2 - gap * (rows - 1)) / rows;
            final fitW = tw.isFinite && tw > 4;
            final fitH = th.isFinite && th > 4;
            final slots = cols * rows;

            // 关键：用 Stack + Positioned 摆格子，而不是 Column/Row + Expanded。
            // 后者在「换档位」时会把整棵树换成不同的嵌套结构，Flutter 只能把
            // 所有格子 dispose 再重建 → 每一路都断开重连（用户看到的就是
            // 「切分屏就掉线、还经常连不回来」）。Stack 只改位置和显隐，
            // 格子的 State 和会话都保得住，切档位不断线。
            //
            // 墙内放大（_maxId）：被放大的那格改成铺满整个 body 并放到最后一层，
            // 其它格原地不动（只是被完全盖住）——会话一路都不动，
            // 收回是瞬间的，不用重连。
            final maxKey = _maxId;
            final children = <Widget>[];
            Widget? maxChild;
            for (var i = 0; i < peers.length; i++) {
              final r = i ~/ cols;
              final k = i % cols;
              final key = peers[i].id.replaceAll(' ', '');
              final isMax = maxKey != null && key == maxKey;
              // 放大那格无论当前档位能不能放下都要显示（用户是在这一格上点的放大）
              final fits = (fitW && fitH && i < slots) || isMax;
              final cell = Positioned(
                key: ValueKey('cell_${peers[i].id}'),
                left: isMax ? 0 : (fits ? pad + k * (tw + gap) : 0),
                top: isMax ? 0 : (fits ? pad + r * (th + gap) : 0),
                width: isMax ? c.maxWidth : (fits ? tw : 8),
                height: isMax ? c.maxHeight : (fits ? th : 8),
                child: Offstage(
                  offstage: !fits,
                  child: _tile(peers[i],
                      visible: fits, order: i, maximized: isMax),
                ),
              );
              if (isMax) {
                maxChild = cell;
              } else {
                children.add(cell);
              }
            }
            // 放大格必须最后画：Stack 里后加的在上层，否则会被旁边的格子盖住
            if (maxChild != null) children.add(maxChild);
            return Stack(children: children);
          },
        );
      },
    );
  }

  Widget _tile(Peer peer,
      {required bool visible,
      required int order,
      bool maximized = false}) {
    final key = peer.id.replaceAll(' ', '');
    final pw = _pwOf(peer);
    final opened = _bigIds.contains(key);
    // 同时预览有上限：超出的格子只显示卡片，不再开第 17 路会话。
    final over = order >= _kMaxLive;
    return _WallTile(
      key: ValueKey('wall_$key'),
      peer: peer,
      password: pw,
      visible: visible,
      order: order,
      over: over,
      retry: _retryGen[key] ?? 0,
      // 放大那一格要一定有画面：即使它排在第 17 位（超出同时预览上限），
      // 放大以后就是「单独看这一台」，必须给它一路会话。
      live: _live && !opened && (!over || maximized) && _canPreview(peer),
      opened: opened,
      maximized: maximized,
      onToggleMax: () => setState(() {
        _setMaxId(maximized ? null : key);
      }),
      onOpen: () => _openBig(peer),
      onRestorePreview: () => _restorePreview(peer),
      onRetry: () {
        if (!mounted) return;
        setState(() {
          // 「开始预览」/「重连」要连全局开关一起打开，
          // 否则格子还是拿不到 live，点了没反应。
          _live = true;
          _retryGen[key] = (_retryGen[key] ?? 0) + 1;
        });
      },
      onRemove: () => _removePeer(peer),
      onSetPassword: () => _askPassword(peer),
      onGroupPointer: _groupOn
          ? (id, local, down) => _groupPointer(id, local, down)
          : null,
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

  /// 这一格现在是否在墙上可见（换到更小的档位时会被藏起来）
  final bool visible;

  /// 在整墙里的序号：用来错开建会话的时间，避免几十路同时握手。
  final int order;

  /// 超出同时预览上限（只显示卡片，不开会话）
  final bool over;

  /// 重建代次：变了就用新的 key 重开一路会话
  final int retry;

  /// 这一格已经放大成大窗口了（小窗预览已关）
  final bool opened;

  /// 这一格正在墙内放大（铺满整墙）
  final bool maximized;

  /// 墙内放大 / 收回
  final VoidCallback onToggleMax;

  /// 双击 / 点放大按钮：切换到大窗口显示（小窗关闭）
  final VoidCallback onOpen;

  /// 大窗口关掉后再点开小窗预览（同时把大窗口收回）
  final VoidCallback onRestorePreview;

  /// 手动重连这一格
  final VoidCallback onRetry;

  /// 从墙里移除这台设备
  final VoidCallback onRemove;

  /// 没存密码时，让用户手输一次
  final VoidCallback onSetPassword;

  /// 群控：id=本格识别码；local=落点（相对本格）；down=按下/抬起
  final void Function(String id, Offset local, bool down)? onGroupPointer;

  const _WallTile({
    Key? key,
    required this.peer,
    required this.password,
    required this.live,
    required this.visible,
    required this.order,
    required this.over,
    required this.retry,
    required this.opened,
    required this.maximized,
    required this.onToggleMax,
    required this.onOpen,
    required this.onRestorePreview,
    required this.onRetry,
    required this.onRemove,
    required this.onSetPassword,
    this.onGroupPointer,
  }) : super(key: key);

  @override
  State<_WallTile> createState() => _WallTileState();
}

class _WallTileState extends State<_WallTile> {
  ToolbarState? _toolbarState;

  /// 本格会话的独立 sessionId —— **手机端多会话的关键修复**。
  ///
  /// 上游 FFI 构造在移动端不生成新 id，而是用全局常量 `_constSessionId`
  /// （原生手机 App 就是「单会话复用 gFFI」的设计）。墙里几路并发共用
  /// 同一个 sessionId，Rust 会话表里互相顶掉 —— 表现就是只有第一格
  /// 能连上、其余永远停在「Connecting...」（2026-11-09 用户报障）。
  /// 桌面端 FFI 自己就会生成 UUID，不受影响；这里只给手机端显式传一份。
  SessionID? _wallSid;

  SessionID get _sid => _wallSid ??= Uuid().v4obj();

  /// 拟合定时器：会话什么时候连上不确定，一次性打几轮赶不上，
  /// 所以每 400ms 校一次（内部会先比尺寸，稳定后基本是空转）。
  Timer? _fitTimer;
  int _fitTicks = 0;
  bool _styleDone = false;

  /// 拟合已经稳定（稳定后把体检频率从 400ms 放到 3s，省 CPU）
  bool _settled = false;

  /// 长时间不在墙上（被更小的档位挤下去）就把这一路的会话放掉，
  /// 免得十几路没人看的画面一直在解码拖慢本机；
  /// 切回来会立刻重新拉起（有 60 秒宽限，来回切档位不会真的断线）。
  bool _sleeping = false;
  Timer? _sleepTimer;

  /// 拟合失败提示（正常情况永远 false，出现说明画布没按格子尺寸算）
  bool _fitBad = false;

  /// 会话迟迟没有画面（连不上/被拒），用来显示「重连」
  bool _noSignal = false;
  DateTime? _began;

  /// 手写双击识别：RemotePage 内部有手势竞争，外层 GestureDetector.onDoubleTap
  /// 抢不到事件（这也是之前「双击没反应」的原因），所以用 Listener 自己数。
  DateTime _lastDownAt = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastDownPos = Offset.zero;

  /// 这一格画面区的实际尺寸，交给画布算缩放用
  Size _tileSize = Size.zero;

  /// 上一次应用过的「是否允许抢本机键盘」，避免每轮校准都重复调 enterOrLeave
  bool? _grabApplied;

  /// 画面区的 key：用来算它在窗口里的位置（鼠标坐标换算的基准）
  final GlobalKey _imgKey = GlobalKey();

  // ---- 自动录屏 / 截图（【HyDesk】，详见 WallRecorder 注释）----
  final GlobalKey _recKey = GlobalKey();
  DateTime? _snapLastAt; // 上次截图时间（节流 ≥ 3 秒一张）
  Uint8List? _snapLastPng; // 上一张截图（同分辨率才能比，静止不刷文件）

  // ---- 【HyDesk】原生视频录制（2026-11-09 重做：录像 = 视频文件）----
  bool _vidOn = false; // 墙录像开关开着（本路应录）
  bool _vidLive = false; // Rust 录制器当前在录（静止暂停时为 false）
  DateTime? _vidStartAt; // 本段录像起点（归档时按 mtime 匹配文件）
  bool _vidBusy = false;
  DateTime _vidLastActive = DateTime.now(); // 画面最后变化时间
  Uint8List? _actLastPng; // 上一张低清快照（静止检测用）
  Timer? _vidWatch;

  /// 这一格在墙里显示的设备名：地址簿别名 > peer 别名 > ID
  /// （截图目录、录像归档共用；名字跟随重命名，文件名不暴露识别码）。
  String _wallDevName() {
    var n = widget.peer.alias;
    try {
      final nid = widget.peer.id.replaceAll(' ', '').trim();
      for (final e in AddressBookStore.instance.entries) {
        if (e.id.replaceAll(' ', '').trim() == nid &&
            e.alias.trim().isNotEmpty) {
          n = e.alias.trim();
          break;
        }
      }
    } catch (_) {}
    return _sanitizeName(n.isEmpty ? widget.peer.id : n);
  }

  /// 原生录像启停（墙级开关）：录像期间临时提帧率/画质（墙平时 5fps/low
  /// 录出来没法看），停录恢复。**静止不录**（2026-11-09 用户要求）：画面静止
  /// 60 秒自动暂停（文件封存归档），有操作自动开新文件续录。
  Future<void> _vidCtl(bool start) async {
    if (_vidBusy) return;
    if (start == _vidOn) return;
    final sess = wallFfi(widget.peer.id);
    if (sess == null) return;
    _vidBusy = true;
    try {
      if (start) {
        try {
          await bind.sessionSetCustomFps(sessionId: sess.sessionId, fps: 20);
          await bind.sessionSetImageQuality(
              sessionId: sess.sessionId, value: 'balanced');
        } catch (_) {}
        _vidOn = true;
        _vidLastActive = DateTime.now();
        unawaited(_vidResume());
        _vidWatch?.cancel();
        _vidWatch = Timer.periodic(const Duration(seconds: 3), (_) {
          unawaited(_vidWatchTick());
        });
      } else {
        _vidOn = false;
        _vidWatch?.cancel();
        _vidWatch = null;
        if (_vidLive) await _vidPause();
        try {
          await bind.sessionSetCustomFps(sessionId: sess.sessionId, fps: 5);
          await bind.sessionSetImageQuality(
              sessionId: sess.sessionId, value: 'low');
        } catch (_) {}
      }
    } catch (_) {
    } finally {
      _vidBusy = false;
    }
  }

  /// 开始/恢复一段录像（每次恢复都是新文件，时间戳独立）。
  Future<void> _vidResume() async {
    final sess = wallFfi(widget.peer.id);
    if (sess == null) return;
    try {
      try {
        sessionRefreshVideo(sess.sessionId, sess.ffiModel.pi);
      } catch (_) {}
      await bind.sessionRecordScreen(sessionId: sess.sessionId, start: true);
      _vidLive = true;
      _vidStartAt = DateTime.now().subtract(const Duration(seconds: 2));
      _vidLastActive = DateTime.now();
    } catch (_) {}
  }

  /// 结束当前一段（停止录制器，文件封存归档）。
  Future<void> _vidPause() async {
    _vidLive = false;
    final sess = wallFfi(widget.peer.id);
    if (sess != null) {
      try {
        await bind.sessionRecordScreen(sessionId: sess.sessionId, start: false);
      } catch (_) {}
    }
    unawaited(_vidArchive());
  }

  /// 静止检测：3 秒一次，96px 低清快照对比（CPU 可忽略）。
  /// 有变化 → 续录；静止超 60 秒 → 暂停封存。
  Future<void> _vidWatchTick() async {
    if (!mounted || !_vidOn) return;
    try {
      final ctx = _recKey.currentContext;
      final dynamic rb = ctx?.findRenderObject();
      if (rb == null) return;
      final bytes = await _rasterPng(rb, capW: 96);
      if (bytes == null) return;
      final changed = _actLastPng == null || !_sameAs(_actLastPng!, bytes);
      _actLastPng = bytes;
      if (changed) {
        _vidLastActive = DateTime.now();
        if (!_vidLive) unawaited(_vidResume());
      } else if (_vidLive &&
          DateTime.now().difference(_vidLastActive) >
              const Duration(seconds: 60)) {
        unawaited(_vidPause());
      }
    } catch (_) {}
  }

  /// 停录归档：Rust 侧落盘的是 outgoing_<id>_时间_display0_vp9.webm，
  /// 挪到 <根>\<设备名>\录像\ 下并改名为 <设备名>_时间.webm——
  /// 文件名以重命名后的设备名为主（2026-11-09 用户要求，不暴露识别码）。
  Future<void> _vidArchive() async {
    final start = _vidStartAt;
    _vidStartAt = null;
    if (start == null) return;
    try {
      final dev = _wallDevName();
      final dir = '${WallRecorder.root}\\$dev\\录像';
      Directory(dir).createSync(recursive: true);
      final pid = widget.peer.id.replaceAll(' ', '');
      final prefix = 'outgoing_$pid';
      final root = Directory(WallRecorder.root);
      if (!root.existsSync()) return;
      final ms = start.millisecondsSinceEpoch ~/ 1000 - 1;
      for (final ent in root.listSync().whereType<File>().toList()) {
        final base = ent.path.split('\\').last;
        if (!base.startsWith(prefix)) continue;
        final st = ent.statSync();
        if (st.modified.millisecondsSinceEpoch ~/ 1000 < ms) continue;
        // 原文件名里内嵌的启动时间（yyyyMMddHHmmssfff）
        var ts = '';
        final m = RegExp(r'_(\d{17})_display').firstMatch(base);
        if (m != null) {
          final d = m.group(1)!;
          ts = '${d.substring(0, 8)}_${d.substring(8, 14)}';
        } else {
          final t = st.modified;
          ts = '${t.year}${t.month.toString().padLeft(2, '0')}'
              '${t.day.toString().padLeft(2, '0')}'
              '_${t.hour.toString().padLeft(2, '0')}'
              '${t.minute.toString().padLeft(2, '0')}';
        }
        final ext = base.toLowerCase().endsWith('.mp4') ? '.mp4' : '.webm';
        var dst = File('$dir\\${dev}_$ts$ext');
        var i = 1;
        while (dst.existsSync()) {
          dst = File('$dir\\${dev}_${ts}_$i$ext');
          i++;
        }
        try {
          ent.renameSync(dst.path);
        } catch (_) {
          // 跨卷/被占用：复制后删
          try {
            dst.writeAsBytesSync(ent.readAsBytesSync(), flush: true);
            ent.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  bool _recTick() {
    if (!mounted) return false;
    if (!WallRecorder.snapOn || !widget.live || _sleeping || _noSignal) {
      return true;
    }
    final ctx = _recKey.currentContext;
    if (ctx == null) return true;
    final dynamic rb = ctx.findRenderObject();
    if (rb == null) return true;
    unawaited(_snapTick(rb));
    return true;
  }

  /// 截图：**远端屏幕原始分辨率**落盘，放大看不再糊。
  ///
  /// 原来的做法是 `pixelRatio: 1.0` 栅格化格子 —— PNG 只有格子的逻辑
  /// 像素那么大（九宫格时 ~600px 宽），一放大就是马赛克（用户 2026-11-09
  /// 报障「截图的图片太小，放大很模糊」）。现在按「远端屏幕像素 ÷ 格子宽」
  /// 算采样倍率，RepaintBoundary 栅格化会把视频纹理按该倍率重采样，
  /// 等于直接取到原始分辨率。时间节流放在栅格化**之前**（先判 3 秒再
  /// 花几百万像素的栅格+PNG 编码，静止时不再白烧 CPU）。
  Future<void> _snapTick(dynamic rb) async {
    final now = DateTime.now();
    if (_snapLastAt != null &&
        now.difference(_snapLastAt!) < const Duration(seconds: 3)) {
      return;
    }
    _snapLastAt = now;
    final bytes = await _rasterPng(rb, capW: 2560);
    if (bytes == null) return;
    // 和上一张一模一样（同分辨率才可比）：静止屏幕不再刷文件
    final last = _snapLastPng;
    if (last != null && _sameAs(last, bytes)) return;
    _snapLastPng = bytes;
    try {
      final name = _wallDevName();
      final dir = '${WallRecorder.root}\\$name\\截图';
      Directory(dir).createSync(recursive: true);
      final t = now;
      final ms = t.millisecond.toString().padLeft(3, '0');
      final f = File('$dir'
          '\\${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
          '_${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}'
          '${t.second.toString().padLeft(2, '0')}_$ms.png');
      f.writeAsBytesSync(bytes, flush: true);
    } catch (_) {}
  }

  /// 把格子这一层按「远端屏幕分辨率」栅格化成 PNG。
  /// capW 是输出宽度上限（内存/磁盘护栏），达不到远端分辨率时至少 1.0。
  Future<Uint8List?> _rasterPng(dynamic rb, {required int capW}) async {
    final img = await rb.toImage(pixelRatio: _recRatio(rb, capW));
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return data.buffer.asUint8List().sublist(0, data.lengthInBytes);
  }

  double _recRatio(dynamic rb, int capW) {
    try {
      final s = rb.size as Size;
      if (s.width < 2) return 1.0;
      final sess = wallFfi(widget.peer.id);
      if (sess == null) return 1.0;
      final c = sess.canvasModel;
      final pw = c.getDisplayWidth();
      if (pw <= 0) return 1.0;
      var r = pw / s.width;
      if (r < 1.0) r = 1.0;
      if (s.width * r > capW) r = capW / s.width;
      return r;
    } catch (_) {}
    return 1.0;
  }

  bool _sameAs(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    // PNG 头 60 字节是固定的，跳过；抽样比较足够判断「画面是否变化」。
    // 大图步长 997，小图（静止检测的 96px 快照）自适应加密到 ~200 个采样点。
    final n = a.length;
    final step = n > 120000 ? 997 : (n ~/ 200 > 0 ? n ~/ 200 : 1);
    for (int i = 60; i < n; i += step) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 把「画面区左上角在窗口里的坐标」写给画布。
  ///
  /// 鼠标事件（`PointerEvent.position`）给的是**窗口全局坐标**，而画布的
  /// x/y 只是画面在本格内部的偏移。原生换算是「(全局 - x) / scale」，
  /// 墙里不减掉本格原点，落点就会整体偏出一整格 —— 用户看到的就是
  /// 「在小窗口点这里，远端光标跑到很远的地方」。
  void _syncOrigin() {
    if (!mounted) return;
    final ro = _imgKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return;
    final sess = wallFfi(widget.peer.id);
    if (sess == null) return;
    try {
      sess.canvasModel.globalOrigin = ro.localToGlobal(Offset.zero);
    } catch (_) {}
  }

  bool _hover = false;

  /// 这一格是否上过墙。上过就一直保持这一路会话：
  /// 换到更小的档位只是把它藏起来（Offstage），不断线、不重连。
  bool _want = false;

  @override
  void initState() {
    super.initState();
    _want = widget.visible;
    if (_want && widget.live) _scheduleSession();
  }

  @override
  void didUpdateWidget(covariant _WallTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 第一次出现在墙上：建会话
    if (widget.visible && !_want) {
      _want = true;
      if (widget.live) _scheduleSession();
    }
    // 被更小的档位挤下去：先留 60 秒（来回切档位不断线），之后挂起省资源
    if (!widget.visible && oldWidget.visible) {
      _sleepTimer?.cancel();
      _sleepTimer = Timer(const Duration(seconds: 60), () {
        if (!mounted || widget.visible) return;
        setState(() => _sleeping = true);
        _fitTimer?.cancel();
        _fitTimer = null;
      });
    }
    // 重新回到墙上：唤醒
    if (widget.visible && !oldWidget.visible) {
      _sleepTimer?.cancel();
      _sleepTimer = null;
      if (_sleeping) {
        _sleeping = false;
        _styleDone = false;
        _began = null;
        _fitTicks = 0;
        _settled = false;
        // 挂起期间 RemotePage 已 dispose，唤醒要重建：换新 sessionId，
        // 旧 id 在 Rust 侧可能还没清干净，复用会握手冲突。
        _wallSid = null;
        if (widget.live) _startFitLoop();
      }
    }
    // 密码是后来才拿到的（主窗口快照晚到、或 Rust 里本来就存着密码），
    // 或者从大窗口收回（live 由 false 变 true）时补建会话。
    if (widget.live && (!oldWidget.live || _toolbarState == null)) {
      _scheduleSession();
    }
    // 手动重连 / 从大窗口收回：换了代次就用新 key 开一路干净的会话
    if (widget.retry != oldWidget.retry) {
      _noSignal = false;
      _began = null;
      _fitBad = false;
      _fitTicks = 0;
      _styleDone = false;
      _fitTimer?.cancel();
      _fitTimer = null;
      // 新代次 = 全新会话：连 sessionId 一起换，避免和旧会话撞车
      _wallSid = null;
      if (widget.live) _scheduleSession();
    }
    if (!widget.live && oldWidget.live) {
      _fitTimer?.cancel();
      _fitTimer = null;
    }
    // 放大 / 收回：放大后这一格就是控制台，工具栏要出来（切视图模式、
    // 发 Ctrl+Alt+Del 都要用它）；收回网格再藏起来。
    if (widget.maximized != oldWidget.maximized) {
      _applyToolbarMode();
    }
  }

  /// 墙体网格里工具栏一律不渲染（画面全留给远端桌面）；
  /// 放大成单屏控制台时再放出来。
  void _applyToolbarMode() {
    final ts = _toolbarState;
    if (ts == null) return;
    final show = widget.maximized;
    try {
      if (show) {
        kWallToolbarStates.remove(ts);
      } else {
        kWallToolbarStates.add(ts);
      }
      ts.hide.value = !show;
    } catch (_) {}
    _applyGrabMode();
  }

  /// 网格态禁止这一格 grab 本机键盘，放大成单屏才允许；只看态一律不抢。
  ///
  /// Rust 侧 `session_enter_or_leave(true)` 会把 `KEYBOARD_HOOKED` 置 true、
  /// 装全局键盘钩子，把**整台电脑**的键盘交给远端。墙里 9 格并排，鼠标
  /// 一划过就在几个会话之间来回抢，本机输入法彻底拿不到键。
  ///
  /// 1.5.23 起所有会话默认是「只看画面」：只看的会话被 Rust 拦掉了输入，
  /// 再 grab 本机键盘纯属白占着钩子，所以这里与 view-only 取交集。
  void _applyGrabMode() {
    final sess = wallFfi(widget.peer.id);
    if (sess == null) return;
    try {
      // 群控开着的时候，主控格自己的点击走正常输入通道，会被「只看」吃掉，
      // 所以这一路必须切成可操作（群控关掉时由墙统一切回只看）。
      if (widget.onGroupPointer != null) _forceControlForGroup(sess);
      var viewOnly = false;
      try {
        viewOnly = sess.ffiModel.viewOnly;
      } catch (_) {}
      final allow = widget.maximized && !viewOnly;
      if (_grabApplied == allow) return;
      _grabApplied = allow;
      final im = sess.inputModel;
      im.wallNoGrab = !allow;
      // 从放大收回时主动释放：别指望 MouseRegion 的 onExit 一定触发，
      // 释放不掉的 grab 会让本机键盘一直被远端占着。
      if (!allow) im.enterOrLeave(false);
    } catch (_) {}
  }

  /// 群控进行中：把这一路从「只看」切回「可操作」。
  ///
  /// 用「读当前值 → 确实是只看才翻」的方式，反复调用不会把状态翻乱；
  /// 每轮体检都会调一次，所以群控中途才连上的格子也会自己纠过来。
  bool _groupControlFixing = false;
  void _forceControlForGroup(FFI sess) {
    if (_groupControlFixing) return;
    try {
      if (!sess.ffiModel.viewOnly) return;
    } catch (_) {
      return;
    }
    _groupControlFixing = true;
    () async {
      try {
        final sid = sess.sessionId;
        final cur = await bind.sessionGetToggleOption(
            sessionId: sid, arg: kOptionToggleViewOnly);
        if (cur == null) return;
        if (cur == true) {
          await bind.sessionToggleOption(
              sessionId: sid, value: kOptionToggleViewOnly);
        }
        sess.ffiModel.setViewOnly(widget.peer.id, false);
      } catch (_) {} finally {
        _groupControlFixing = false;
      }
    }();
  }

  /// 错开建会话的时间：十几路一起握手会把本机和对端都打满，
  /// 表现就是「进墙很慢、半天才出画面」，严重时整机发卡。
  /// 前 4 格快速铺开（用户第一眼要看的就是这几格），其余每 450ms 补一路。
  void _scheduleSession() {
    // 放大态这一格就是「单独看这一台」，必须立刻连——
    // 以前超限格子（order >= 4）即使被放大也要先空等 1.2 秒错峰，
    // 用户点卡片后看着黑屏干等，观感就是「切换慢」。
    if (widget.maximized) {
      _ensureSession();
      return;
    }
    final o = widget.order.clamp(0, 15);
    // 手机端第一波覆盖全部 9 路（每路 180ms 错峰握手）；
    // 桌面端保持「前 4 格快速铺开 + 其余 450ms 递进」。
    final bool mobile = Platform.isAndroid || Platform.isIOS;
    final ms = mobile
        ? (o < 9 ? o * 180 : 1200 + (o - 9) * 450)
        : (o < 4 ? o * 150 : 1200 + (o - 4) * 450);
    final delay = Duration(milliseconds: ms);
    if (delay == Duration.zero) {
      _ensureSession();
      return;
    }
    Future.delayed(delay, () {
      if (mounted && widget.live) _ensureSession();
    });
  }

  void _ensureSession() {
    if (_sleeping) return;
    _toolbarState ??= ToolbarState();
    // 网格里工具栏不渲染；放大成控制台时 _applyToolbarMode 会放出来
    _applyToolbarMode();
    _began ??= DateTime.now();
    _startFitLoop();
    // 会话是延迟建起来的（错开握手），建好后要让这一格重建一次，
    // 否则画面会一直停在占位卡片上。
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) {
          _applyGrabMode();
          setState(() {});
        }
      });
    }
  }

  /// 会话在跑、且没被挂起
  bool get _active => widget.live && !_sleeping;

  void _startFitLoop() {
    _fitTimer?.cancel();
    _fitTicks = 0;
    _settled = false;
    unawaited(_applyFit());
    _armFit(400);
  }

  void _armFit(int ms) {
    _fitTimer?.cancel();
    _fitTimer = Timer(Duration(milliseconds: ms), _onFitTick);
  }

  Future<void> _onFitTick() async {
    if (!mounted || !_active) return;
    _fitTicks++;
    await _applyFit();
    if (!mounted || !_active) return;
    // 稳定后放慢：9 路 × 400ms 的空转没必要，3 秒够用了。
    // 放大成单屏时例外 —— 一轮只盯一路，保持 400ms，眼睛按钮切「可操作」
    // 之后要立刻把本机键盘 grab 回来，不能让用户等 3 秒。
    _armFit((_settled && !widget.maximized) ? 3000 : 400);
  }

  /// 把这一格的画布钉在「整屏塞进格子」的状态。
  ///
  /// 只做两件事：把格子尺寸交给画布（`useLayoutSize/layoutSize`，
  /// 原生补丁让 `getSize()` 用它），以及把会话的 view-style 定成自适应。
  /// **不再自己算缩放往画布里写** —— 手写的那套和原生画出来/换算鼠标的
  /// 那一套只要有一处单位不一致，鼠标点位就会错位。
  Future<void> _applyFit() async {
    final sess = wallFfi(widget.peer.id);
    if (sess == null) return;
    final CanvasModel c;
    try {
      c = sess.canvasModel;
    } catch (_) {
      return;
    }

    // 会话还没起来时 sessionId 是 nil uuid
    dynamic sid;
    try {
      sid = sess.sessionId;
    } catch (_) {}
    final tag = '$sid';
    final ready =
        tag != '0' && tag != '00000000-0000-0000-0000-000000000000';

    // 0) 画面区在窗口里的原点：每次校准都顺手刷一遍（工具栏折叠、窗口
    // 移动、放大/收回都会改变它，而鼠标换算全靠这个值）。
    _syncOrigin();

    // 1) 画布尺寸 = 格子尺寸。尺寸一变就必须重算一次。
    if (_tileSize.width > 8 && _tileSize.height > 8) {
      final changed = !c.useLayoutSize || c.layoutSize != _tileSize;
      if (changed) {
        c.useLayoutSize = true;
        c.layoutSize = _tileSize;
        unawaited(c.updateViewStyle());
      }
    }

    // 2) 会话就绪后把 view-style 定成自适应（只设一次，别反复骚扰对端）
    if (ready && !_styleDone) {
      _styleDone = true;
      try {
        await bind.sessionSetViewStyle(
            sessionId: sid, value: kRemoteViewStyleAdaptive);
      } catch (_) {}
      try {
        unawaited(c.updateViewStyle());
      } catch (_) {}
    }

    // 3) 只做体检，不写画布（写画布的权力留给原生，鼠标才不会错位）
    final ok = _fitIsOk(c);

    // 稳定判定：连续几轮都对就把频率降下来
    _settled = ok && _fitTicks > 5;

    // 有画面但缩放不对 → 标题条红字；没画面太久 → 「重连」
    final bad = _fitTicks > 8 && !ok;
    if (bad != _fitBad && mounted) setState(() => _fitBad = bad);

    var noSignal = _noSignal;
    if (ok) {
      noSignal = false;
    } else {
      final began = _began;
      if (began != null && DateTime.now().difference(began).inSeconds > 12) {
        var hasImage = false;
        try {
          hasImage = c.getDisplayWidth() > 0 && c.getDisplayHeight() > 0;
        } catch (_) {}
        noSignal = !hasImage;
      }
    }
    if (noSignal != _noSignal && mounted) setState(() => _noSignal = noSignal);

    // 会话卡住时上游的「Connecting...」loading 弹窗不会自己消失
    // （peer_info 永远不来，dismissAll 没机会跑）。12 秒无画面就把它撤掉，
    // 让用户看到本格自己的「重连」入口，而不是永远的转圈。
    if (noSignal && !_noSignal) {
      try {
        sess.dialogManager.dismissAll();
      } catch (_) {}
    }

    // 会话建好之后才能拿到 InputModel：在这里补一次「网格态不许 grab」，
    // 否则从窗口打开到会话起来这段时间，鼠标一进格子就会把本机键盘抢走。
    _applyGrabMode();
  }

  /// 体检：缩放和居中偏移是否都在容差内（只读，不改画布）
  bool _fitIsOk(CanvasModel c) {
    final w = _tileSize.width;
    final h = _tileSize.height;
    if (w < 8 || h < 8) return false;
    try {
      final dw = c.getDisplayWidth();
      final dh = c.getDisplayHeight();
      if (dw <= 0 || dh <= 0) return false;
      final s1 = w / dw;
      final s2 = h / dh;
      final s = s1 < s2 ? s1 : s2;
      if ((c.scale - s).abs() > 0.01) return false;
      final x = (w - dw * s) / 2;
      final y = (h - dh * s) / 2;
      return (c.x - x).abs() < 1.2 && (c.y - y).abs() < 1.2;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _fitTimer?.cancel();
    _sleepTimer?.cancel();
    _vidWatch?.cancel();
    _vidWatch = null;
    final ts = _toolbarState;
    if (ts != null) kWallToolbarStates.remove(ts);
    // 这一格被销毁时也要把本机键盘放回去（grab 没释放会让整机输入法失效）
    try {
      wallFfi(widget.peer.id)?.inputModel.enterOrLeave(false);
    } catch (_) {}
    // 录像中的格子被销毁/移出墙：停录并归档（视频文件按设备名落位）
    if (_vidOn) {
      unawaited(_vidCtl(false));
    }
    WallRecorder.unregisterVideo(widget.peer.id);
    WallRecorder.unregister(widget.peer.id);
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
    if (!isDouble) return;
    // 群控开着时，双击就是「往所有被控端各点两下」，
    // 不能再顺带把这一格放大（否则群控时双击必开大窗口）。
    if (widget.onGroupPointer != null) return;
    // 已经放大了：双击留给远端（放大后就是控制台，双击 = 打开文件/程序），
    // 收回一律走标题条按钮或 Esc —— 否则想收回时反而给远端点了两下。
    if (widget.maximized) return;
    // 双击 = 墙内放大（铺满整墙）。不再开独立窗口：那条路要跨窗口关窗 +
    // 轮询窗口列表才能收回，用户遇到的就是「放大了回不去，只能关掉」。
    widget.onToggleMax();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _C.tile,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
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
          if (_fitBad && widget.live)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Text('非自适应',
                  style: TextStyle(fontSize: 9, color: Color(0xFFE23B3B))),
            ),
          if (_hover)
            Text(
              widget.opened
                  ? '大窗口'
                  : (widget.maximized
                      ? '已放大'
                      : (widget.live
                          ? '预览中'
                          : (online ? '待连接' : '离线'))),
              style: TextStyle(
                fontSize: 9.5,
                color: widget.live ? _C.green : Colors.white38,
              ),
            ),
          // 放大 / 收回：小窗里最常用的就是这个。放大走墙内（本地 setState），
          // 收回直接点这里或按 Esc，不依赖跨窗口关窗。
          _barButton(
            widget.maximized ? Icons.close_fullscreen : Icons.open_in_full,
            widget.maximized ? '收回（Esc）' : '放大（铺满屏幕墙）',
            widget.onToggleMax,
            alwaysShow: true,
          ),
          // 独立大窗口：偶尔要拖到第二块屏看，留一个入口（不是默认行为）
          if (widget.opened)
            _barButton(
              Icons.close_fullscreen,
              '收回屏幕墙（关闭独立窗口，恢复小窗预览）',
              widget.onRestorePreview,
              alwaysShow: true,
            )
          else
            _barButton(
              Icons.open_in_new,
              '在独立窗口打开（关闭小窗预览）',
              widget.onOpen,
            ),
          if (_noSignal && widget.live)
            _barButton(Icons.refresh, '重新连接这一台', widget.onRetry,
                alwaysShow: true),
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
    if (!widget.live || _sleeping || _toolbarState == null) {
      return _buildPlaceholder();
    }
    final page = RemotePage(
      // retry 进 key：重连 / 从大窗口收回时换一路全新的会话，
      // 复用旧 State 会出现「连不上、黑屏、怎么点都没反应」。
      key: ValueKey('page_${widget.peer.id}_${widget.retry}'),
      id: widget.peer.id,
      // 手机端传独立 sessionId（见 _wallSid 注释）——否则多格共用上游的
      // _constSessionId，Rust 会话表互相顶掉，只有第一格能连上。
      // 桌面端 FFI 自己生成 UUID，保持 null 不改变既有行为。
      sessionId: Platform.isAndroid || Platform.isIOS ? _sid : null,
      // 空密码就不传：让 Rust 用本机保存的密码登录（= 主窗口那份密码），
      // 主窗口能免密直连的设备，墙里也不会再问一遍。
      password: widget.password.isEmpty ? null : widget.password,
      toolbarState: _toolbarState!,
    );
    // 录屏 lane 注册：build 会反复调，幂等；销毁的格子由定时器自动清
    WallRecorder.register(widget.peer.id, _recTick);
    // 原生视频录制：注册启停回调；墙已经在录的话，迟到的格子自动补录
    WallRecorder.registerVideo(widget.peer.id, _vidCtl);
    if (WallRecorder.on && !_vidOn && widget.live) {
      unawaited(_vidCtl(true));
    }
    return LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth;
      final h = cons.maxHeight;
      if (w.isFinite && h.isFinite && w > 2 && h > 2) {
        final changed = _tileSize.width != w || _tileSize.height != h;
        _tileSize = Size(w, h);
        // 画面区在窗口里的左上角：鼠标事件给的是窗口全局坐标，原生换算时
        // 必须减掉它（每格都不一样）。尺寸变了位置也会变，所以跟着刷。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncOrigin();
        });
        if (changed) {
          // 尺寸一确定就立刻拟合一次，别等定时器（那就是「自适应慢」）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_applyFit());
          });
        }
      }
      final child = Listener(
        key: _imgKey,
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          _onDown(e);
          widget.onGroupPointer?.call(widget.peer.id, e.localPosition, true);
        },
        onPointerUp: (e) =>
            widget.onGroupPointer?.call(widget.peer.id, e.localPosition, false),
        onPointerCancel: (e) => widget.onGroupPointer
            ?.call(widget.peer.id, e.localPosition, false),
        child: RepaintBoundary(
          // 【HyDesk】录屏采样点：截图从这一层取，不影响渲染
          key: _recKey,
          child: ClipRect(child: page),
        ),
      );
      if (!_noSignal) return child;
      return Stack(children: [
        Positioned.fill(child: child),
        Positioned(
          left: 0,
          right: 0,
          bottom: 6,
          child: Center(child: _reconnectChip()),
        ),
      ]);
    });
  }

  /// 连不上时的浮层：明确给一个「重新连接」，不用再靠反复开关窗口碰运气
  Widget _reconnectChip() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onRetry,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white24),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh, size: 12, color: Colors.white),
              SizedBox(width: 4),
              Text('连接失败，点此重连',
                  style: TextStyle(fontSize: 10.5, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    final p = widget.peer;
    final needPw = p.online && widget.password.isEmpty && !widget.opened;
    final bool paused = !widget.live && !widget.opened && !widget.over;
    final String hint;
    if (widget.opened) {
      hint = '已放大成大窗口显示';
    } else if (_sleeping) {
      hint = '已挂起（切回来自动恢复）';
    } else if (widget.over) {
      hint = '超出同时预览上限（$_kMaxLive 路）';
    } else if (!p.online) {
      hint = '设备离线';
    } else if (needPw) {
      hint = '还没保存密码';
    } else {
      hint = '预览已暂停';
    }
    VoidCallback? action;
    String? actionText;
    IconData icon = Icons.desktop_windows_outlined;
    if (widget.opened) {
      action = widget.onRestorePreview;
      actionText = '收回屏幕墙';
      icon = Icons.close_fullscreen;
    } else if (needPw) {
      action = widget.onSetPassword;
      actionText = '输入密码';
      icon = Icons.key_outlined;
    } else if (_sleeping) {
      action = () {
        setState(() => _sleeping = false);
        _styleDone = false;
        _began = null;
        _fitTicks = 0;
        _settled = false;
        if (widget.live) _startFitLoop();
      };
      actionText = '立即恢复';
      icon = Icons.play_circle_outline;
    } else if (paused) {
      action = widget.onRetry;
      actionText = '开始预览';
      icon = Icons.play_circle_outline;
    }
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _onDown(e);
        widget.onGroupPointer?.call(widget.peer.id, e.localPosition, true);
      },
      onPointerUp: (e) =>
          widget.onGroupPointer?.call(widget.peer.id, e.localPosition, false),
      onPointerCancel: (e) =>
          widget.onGroupPointer?.call(widget.peer.id, e.localPosition, false),
      child: InkWell(
        onTap: action ?? widget.onToggleMax,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 26, color: Colors.white24),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(hint,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(fontSize: 11, color: Colors.white38)),
              ),
              const SizedBox(height: 6),
              if (action != null && actionText != null)
                OutlinedButton(
                  onPressed: action,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withOpacity(0.35)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(fontSize: 11.5),
                  ),
                  child: Text(actionText),
                )
              else if (widget.over || !p.online)
                const SizedBox.shrink()
              else
                Text(
                  '双击放大（铺满屏幕墙）',
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
