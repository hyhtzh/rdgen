// 管理端（控制端）主页：按设计稿重做。
// 顶部：本机识别码 / 验证码 / IP 直连 + 右侧「控制远程桌面」连接区（5 个实色按钮）
// 中部：工具条 + 搜索 + 设备列表（最近 / 收藏），底部状态条。
// 由 patch_client_ui.py 注入到 flutter/lib/desktop/pages/ 下。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/desktop/pages/address_book_page.dart';
import 'package:flutter_hbb/desktop/pages/file_transfer_page.dart';
import 'package:flutter_hbb/desktop/pages/license_client.dart';
import 'package:flutter_hbb/desktop/pages/settings_page.dart';
import 'package:flutter_hbb/desktop/pages/screen_wall_page.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';

const _kBrandUrl = 'https://ww.hydesk.cn';

/// Windows / macOS 上的中文字体回退链。
/// 不显式给 fallback 时，Flutter 会用 Roboto 的度量去排中文，
/// 小字号下笔画容易发虚；直接落到系统的雅黑/苹方，边缘更干脆。
const _cnFonts = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'Noto Sans CJK SC',
];

/// 设计稿取色
class _C {
  static const blue = Color(0xFF1B72D6);
  static const red = Color(0xFFE23B3B);
  static const teal = Color(0xFF12A0A8);
  static const green = Color(0xFF16A34A);
  static const dark = Color(0xFF334155);
  static const text = Color(0xFF333333);
  static const sub = Color(0xFF7A7A7A);
  static const line = Color(0xFFE7E7E7);
  static const warnBg = Color(0xFFFFF8E1);
  static const warnText = Color(0xFF6B5900);
  static const warnIcon = Color(0xFFB79A2E);
  static const titleBg = Color(0xFFF7F7F7);
  static const hover = Color(0xFFF5F8FD);
}


/// 设备状态点的三色口径（和原生客户端的在线指示灯一致的方向）：
///   绿 = 在线、且存过密码，点开就能进
///   黄 = 在线，但没存密码，点开还要输一次
///   红 = 离线
/// 以前这里只有一个灰点，所有设备长得一样，等于没信息。
/// 状态点：绿=在线，红=离线。
///
/// 以前在线但本机没存密码会显示黄色，结果和设备真离线看起来一样，
/// 用户看到「对方明明在心跳，管理端却是黄点」就会怀疑是探测坏了。
/// 原生只区分在线/离线，这里也回到同样口径；有没有存密码用文字说明，
/// 不再拿颜色表达。
Color peerStatusColor(Peer p) =>
    p.online ? const Color(0xFF3DBE5B) : const Color(0xFFE23B3B);

/// 在线状态探针（照搬原生的驱动方式）。
///
/// 原生首页 ConnectionPage 里的 AllPeersLoader 会每 5 秒调一次
/// `bind.queryOnlines`，Rust 侧查到结果后才通过 `callback_query_onlines`
/// 事件把 onlines / offlines 回推给 gFFI.favoritePeersModel / recentPeersModel。
/// 首页换成自定义页面后这一步没人做了，`peer.online` 永远停在 false，
/// 于是所有设备的状态点都是红的（连在线的也红）。这里按原生同样的节奏
/// 与批量（20 个）补回来；设备多于一批时用游标轮转，多屏也能逐步刷全。
class PeerOnlineProbe {
  PeerOnlineProbe._();
  static final PeerOnlineProbe instance = PeerOnlineProbe._();

  static const _interval = Duration(seconds: 5);
  static const _batchSize = 20;

  Timer? _timer;
  int _cursor = 0;
  bool _busy = false;

  void start() {
    _timer?.cancel();
    _kick();
    _timer = Timer.periodic(_interval, (_) => _kick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  List<String> _allIds() {
    final ids = <String>[];
    final seen = <String>{};
    for (final peers in [
      gFFI.favoritePeersModel.peers,
      gFFI.recentPeersModel.peers,
    ]) {
      for (final p in peers) {
        final id = p.id.replaceAll(' ', '');
        if (id.isEmpty || !seen.add(id)) continue;
        ids.add(id);
      }
    }
    return ids;
  }

  void _kick() {
    if (_busy) return;
    final all = _allIds();
    if (all.isEmpty) return;
    final slice = <String>[];
    if (all.length <= _batchSize) {
      slice.addAll(all);
    } else {
      for (var i = 0; i < _batchSize; i++) {
        slice.add(all[(_cursor + i) % all.length]);
      }
      _cursor = (_cursor + _batchSize) % all.length;
    }
    _busy = true;
    Future(() async {
      try {
        await bind.queryOnlines(ids: slice);
      } catch (_) {
        // 内核不支持该接口时保持现状，不影响别的功能
      } finally {
        _busy = false;
      }
    });
  }
}

/// 原版 DesktopHomePage.initState 里 `Get.put<RxBool>(svcStopped, tag: 'stop-service')`，
/// 设置页 _General 用 `Get.find<RxBool>(tag: 'stop-service')` 直接取。
/// 我们把首页整个换掉了，没人再注册 → find 抛异常 → 设置页右侧内容区是 ErrorWidget，
/// release 下就表现为一片空白（左侧导航还在，因为它在异常页面之外）。
void ensureStopServiceState() {
  if (Get.isRegistered<RxBool>(tag: kOptionStopService)) return;
  final stopped = false.obs;
  Get.put<RxBool>(stopped, tag: kOptionStopService);
  mainGetBoolOption(kOptionStopService).then((v) {
    stopped.value = v;
  }, onError: (Object _) {});
}

class ClientHomePage extends StatefulWidget {
  const ClientHomePage({Key? key}) : super(key: key);

  @override
  State<ClientHomePage> createState() => _ClientHomePageState();
}

class _ClientHomePageState extends State<ClientHomePage> with WindowListener {
  final _idController = IDTextEditingController();
  final _idFocusNode = FocusNode();
  final _searchController = TextEditingController();

  Timer? _idTimer;
  /// API 服务器探针：1=可达 0=不可达。与 Rust 的 ID 服务器状态合并判断，
  /// 两者任一失败都算「未联网」——只看 connectStatus 时，API/部分组件挂掉
  /// 仍会显示已连接（用户 2026-11-09 报离线仍显示已连接）。
  int _apiOk = 1;
  Timer? _netProbe;
  int _tab = 1; // 0 最近, 1 收藏, 2 地址簿
  bool _grid = false;

  /// 文件传输宿主是否展开（宿主常驻 Stack，收起时传输继续跑）
  bool _ftOpen = false;
  bool _asc = true;
  bool _showSearch = true;
  // 批量模式：勾选多台设备一次性加入屏幕墙（最近/收藏页）
  bool _batch = false;
  final Set<String> _batchSel = {};
  // 鼠标悬停的设备：网格卡片上浮出「×」删除按钮（桌面端没有长按菜单）
  String? _hoverId;

  /// 收藏夹名单（去掉空格后的识别码）。收藏夹就是屏幕墙的名单，
  /// 所以「加入收藏夹」= 这台设备会出现在屏幕墙上，用户不用先开墙再加。
  List<String> _favIds = [];

  @override
  void initState() {
    super.initState();
    bind.mainLoadFavPeers();
    bind.mainLoadRecentPeers();
    _loadFavIds();
    AddressBookStore.instance.load();
    // 地址簿改名/同步完成后刷新列表名称（最近/收藏与地址簿名称同步）
    AddressBookStore.instance.addListener(_onAbChanged);
    // 设置页依赖的全局状态，原版由 DesktopHomePage 注册，这里必须补上
    ensureStopServiceState();
    // 屏幕墙进程如果是被任务栏 X 直接关掉的，低帧率配置可能没恢复，这里兜底
    WallFps.restore();
    // 主窗口设了 preventClose，必须自己接管关闭事件，否则任务栏的 X 也点不动
    windowManager.addListener(this);
    // 跨窗口指令（屏幕墙双击进入控制、文件传输窗口…）原来由 DesktopHomePage
    // 注册；首页被整个替换后 handler 跟着没了，必须在客户端首页重新装上，
    // 否则子窗口发来的 connect 请求全部石沉大海——表现就是「双击没反应」。
    _installWindowHandler();
    // 原版首页靠 1s 定时器刷新本机 ID，替换页面后必须自己拉
    _idTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _refreshLocalId());
    // API 服务器探针：立即探一次，之后每 20 秒复探。
    // 只靠 Rust 的 rendezvous 状态时，API 服务器挂掉状态栏仍绿 —— 加一道
    // 独立 HTTP 探测，任一失败即显示「未联网」。
    _probeApi();
    _netProbe =
        Timer.periodic(const Duration(seconds: 20), (_) => _probeApi());
    // 原版首页负责定期向 Rust 查询设备在线状态，丢了它所有点都是红的
    PeerOnlineProbe.instance.start();
    // 远程指令通道（远程运行程序 / 静默卸载员工端）：
    // 60s 周期校验授权时顺带取走服务端下发的指令
    LicenseClient.instance.startCommandPoll();
    _idFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  // ---------------- 跨窗口消息 ----------------

  void _installWindowHandler() {
    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      try {
        switch (call.method) {
          case kWindowMainWindowOnTop:
            await windowOnTop(null);
            break;
          case kWindowRefreshCurrentUser:
            gFFI.userModel.refreshCurrentUser();
            break;
          case kWindowGetScreenList:
            final screens = await window_size.getScreenList();
            return jsonEncode(screens
                .map((s) => {
                      'x': s.frame.left,
                      'y': s.frame.top,
                      'width': s.frame.width,
                      'height': s.frame.height,
                      'visibleFrame': {
                        'l': s.visibleFrame.left,
                        't': s.visibleFrame.top,
                        'r': s.visibleFrame.right,
                        'b': s.visibleFrame.bottom,
                      },
                      'scaleFactor': s.scaleFactor,
                    })
                .toList());
          case kWindowActionRebuild:
            reloadCurrentWindow();
            break;
          case kWindowEventShow:
            await rustDeskWinManager
                .registerActiveWindow(call.arguments['id'] as int);
            break;
          case kWindowEventHide:
            await rustDeskWinManager
                .unregisterActiveWindow(call.arguments['id'] as int);
            break;
          case 'wall_get_peers':
            // 屏幕墙进程定时来问一次：别名/在线/密码
            return _wallPeersJson();
          case kWindowConnect:
            final a = call.arguments as Map;
            await connectMainDesktop(
              a['id'] as String,
              isFileTransfer: a['isFileTransfer'] ?? false,
              isViewCamera: a['isViewCamera'] ?? false,
              isTerminal: a['isTerminal'] ?? false,
              isTcpTunneling: a['isTcpTunneling'] ?? false,
              isRDP: a['isRDP'] ?? false,
              password: a['password'],
              forceRelay: a['forceRelay'] ?? false,
              connToken: a['connToken'],
              loginMethod: (a['loginMethod'] ?? '') as String,
            );
            break;
          default:
            break;
        }
      } catch (e) {
        debugPrint('main window handler ${call.method} failed: $e');
      }
      return null;
    });
  }

  // ---------------- 屏幕墙数据 ----------------

  /// 屏幕墙跑在独立进程里，收藏模型在那边是空的（推送事件只到主窗口）。
  /// 它每隔几秒通过跨窗口 call 来找主窗口要一次快照：
  /// 别名、在线状态、密码都在这份 JSON 里。
  String _wallPeersJson() {
    try {
      final pwOf = <String, String>{};
      for (final r in gFFI.recentPeersModel.peers) {
        if (r.password.isNotEmpty) {
          pwOf[r.id.replaceAll(' ', '')] = r.password;
        }
      }
      final list = <Map<String, dynamic>>[];
      for (final p in gFFI.favoritePeersModel.peers) {
        final id = p.id.replaceAll(' ', '');
        list.add({
          'id': id,
          'alias': p.alias,
          'hostname': p.hostname,
          'online': p.online,
          'password': p.password.isNotEmpty ? p.password : (pwOf[id] ?? ''),
        });
      }
      return jsonEncode({'peers': list});
    } catch (_) {
      return '{"peers":[]}';
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    AddressBookStore.instance.removeListener(_onAbChanged);
    _idTimer?.cancel();
    _netProbe?.cancel();
    PeerOnlineProbe.instance.stop();
    _idController.dispose();
    _idFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ---------------- 窗口控制 ----------------

  @override
  void onWindowClose() async {
    await _closeWindow();
  }

  /// 关闭 = 收进系统托盘（RustDesk 桌面端的默认行为），托盘菜单里可以真正退出
  Future<void> _closeWindow() async {
    try {
      await windowManager.hide();
    } catch (_) {
      try {
        await windowManager.setPreventClose(false);
        await windowManager.close();
      } catch (_) {}
    }
  }

  Future<void> _quitApp() async {
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
  }

  Future<void> _refreshLocalId() async {
    try {
      await gFFI.serverModel.fetchID();
    } catch (_) {}
  }

  /// 探测 API 服务器可达性（状态栏离线判断的独立证据链）。
  Future<void> _probeApi() async {
    var ok = false;
    try {
      final res = await http
          .head(Uri.parse(kAbBase))
          .timeout(const Duration(seconds: 6));
      ok = res.statusCode < 500;
    } catch (_) {}
    if (mounted && _apiOk != (ok ? 1 : 0)) {
      setState(() => _apiOk = ok ? 1 : 0);
    }
  }

  // ---------------- 数据 ----------------

  String get _localId {
    try {
      return gFFI.serverModel.serverId.text;
    } catch (_) {
      return '';
    }
  }

  String get _localPwd {
    try {
      return gFFI.serverModel.serverPasswd.text;
    } catch (_) {
      return '';
    }
  }

  Peers get _peers =>
      _tab == 0 ? gFFI.recentPeersModel : gFFI.favoritePeersModel;

  List<Peer> _filtered(List<Peer> src) {
    final q = _searchController.text.trim().toLowerCase();
    final list = src.where((p) {
      if (q.isEmpty) return true;
      return p.id.toLowerCase().contains(q) ||
          p.alias.toLowerCase().contains(q) ||
          p.hostname.toLowerCase().contains(q);
    }).toList();
    list.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      final r = a.getId().toLowerCase().compareTo(b.getId().toLowerCase());
      return _asc ? r : -r;
    });
    return list;
  }

  // ---------------- 动作 ----------------

  void _copy(String text) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    showToast('已复制');
  }

  String get _groupedId {
    final raw = _localId.replaceAll(' ', '');
    if (raw.length < 6 || int.tryParse(raw) == null) return _localId;
    final buf = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      buf.write(raw[i]);
      if (i != raw.length - 1 && (raw.length - 1 - i) % 3 == 0) {
        buf.write(' ');
      }
    }
    return buf.toString();
  }

  Future<void> _refreshPwd() async {
    try {
      await bind.mainUpdateTemporaryPassword();
      showToast('验证码已刷新');
    } catch (_) {}
  }

  void _doConnect() {
    final id = _idController.id;
    if (id.isEmpty) {
      showToast('请输入远程识别码');
      _idFocusNode.requestFocus();
      return;
    }
    connect(context, id);
  }

  Future<void> _connectViewOnly() async {
    final id = _idController.id;
    if (id.isEmpty) {
      showToast('请输入远程识别码');
      _idFocusNode.requestFocus();
      return;
    }
    String prev = 'N';
    try {
      prev = await bind.mainGetUserDefaultOption(key: kOptionToggleViewOnly);
      await bind.mainSetUserDefaultOption(
          key: kOptionToggleViewOnly, value: 'Y');
    } catch (_) {}
    await connect(context, id);
    // 连上后恢复默认，避免影响下一次正常控制
    await Future.delayed(const Duration(seconds: 5));
    try {
      await bind.mainSetUserDefaultOption(
          key: kOptionToggleViewOnly, value: prev.isEmpty ? 'N' : prev);
    } catch (_) {}
  }

  void _openSettings() {
    // 原版靠 DesktopTabPage.onAddSetting 往标签页里塞设置页，我们换掉了整个首页，
    // 标签栏不存在了，switch2page() 里 Get 找不到控制器会直接 return —— 必须自己推路由。
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const SettingsRoute(),
    ));
  }

  void _openWall() {
    // 屏幕墙要开成独立窗口，不能盖住控制端首页（desktop_multi_window 会拉起子进程）。
    // 子窗口创建失败时退化成压栈页，至少还能用。
    _openWallInNewWindow();
  }

  // ---------------- 文件传输 / 远程指令 ----------------

  /// 打开（或聚焦）文件传输面板；presetId 为空时用输入框里的识别码
  Future<void> _openFileTransfer([String? presetId]) async {
    final id = (presetId ?? _idController.id).replaceAll(' ', '');
    if (id.isEmpty) {
      showToast('请输入远程识别码');
      return;
    }
    if (!mounted) return;
    setState(() => _ftOpen = true);
    // 宿主在 Stack 里常驻，首帧后即可用
    await Future.delayed(const Duration(milliseconds: 80));
    final host = FileTransferHost.instance;
    if (host == null) {
      showToast('传输面板初始化中，请再点一次');
      return;
    }
    host.openSession(id, password: _peerPassword(id), alias: _peerAlias(id));
  }

  String _peerPassword(String id) {
    try {
      for (final list
          in [gFFI.favoritePeersModel.peers, gFFI.recentPeersModel.peers]) {
        for (final p in list) {
          if (p.id.replaceAll(' ', '') == id && p.password.isNotEmpty) {
            return p.password;
          }
        }
      }
    } catch (_) {}
    return '';
  }

  String _peerAlias(String id) {
    // 优先地址簿别名：地址簿里改了名，文件传输标签/会话名同步用新名字
    final ab = _abAliasOf(id);
    if (ab.isNotEmpty) return ab;
    try {
      for (final list
          in [gFFI.favoritePeersModel.peers, gFFI.recentPeersModel.peers]) {
        for (final p in list) {
          if (p.id.replaceAll(' ', '') == id) return p.alias;
        }
      }
    } catch (_) {}
    return '';
  }

  // ---------------- 名称同步（地址簿 → 最近/收藏列表） ----------------
  //
  // 用户在地址簿里给设备改名后，最近/收藏列表也要用同一个名字
  // （2026-11-09 需求：最近的设备名字和地址簿名称同步）。
  // 地址簿是 ChangeNotifier，改名/同步完成会 notify，主页监听后刷新即可。

  void _onAbChanged() {
    if (mounted) setState(() {});
  }

  /// 设备在地址簿里的别名（没有则为空串）。
  String _abAliasOf(String id) {
    try {
      for (final e in AddressBookStore.instance.entries) {
        if (_normId(e.id) == _normId(id) && e.alias.trim().isNotEmpty) {
          return e.alias.trim();
        }
      }
    } catch (_) {}
    return '';
  }

  /// 显示名（可能为空）：地址簿别名 > peer 自身别名。
  String _displayName(Peer p) {
    final ab = _abAliasOf(p.id);
    if (ab.isNotEmpty) return ab;
    return p.alias;
  }

  /// 显示名兜底到 ID：列表卡片标题、删除确认等处使用。
  String _displayNameOrId(Peer p) {
    final n = _displayName(p);
    return n.isEmpty ? p.id : n;
  }

  /// 卡片副标题行：设备已命名（有别名）就不显示识别码，防止 ID 外泄
  /// （2026-11-09 需求：重命名后隐藏 ID 号）。未命名时仍显示 ID 便于辨认。
  String _subLineOf(Peer p) {
    if (_displayName(p).isNotEmpty) {
      return p.hostname.isEmpty ? '已命名设备' : p.hostname;
    }
    return p.id;
  }

  /// 群发文件：一份文件同时发给多台设备（后台并行传输）
  Future<void> _groupSend() async {
    final peers = <Peer>[];
    final seen = <String>{};
    try {
      for (final list
          in [gFFI.favoritePeersModel.peers, gFFI.recentPeersModel.peers]) {
        for (final p in list) {
          final k = p.id.replaceAll(' ', '');
          if (k.isEmpty || !seen.add(k)) continue;
          peers.add(p);
        }
      }
    } catch (_) {}
    if (peers.isEmpty) {
      showToast('设备列表为空，先连接或收藏几台设备');
      return;
    }
    await showGroupSendDialog(context, peers);
    if (mounted) setState(() => _ftOpen = true);
  }

  /// 设备右键菜单：传输文件 / 远程运行 / 远程卸载
  Future<void> _peerMenu(Peer p, Offset pos) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: const [
        PopupMenuItem(value: 'ft', child: Text('传输文件')),
        PopupMenuItem(value: 'run', child: Text('远程运行程序')),
        PopupMenuItem(
            value: 'uninstall',
            child: Text('卸载员工端（静默）', style: TextStyle(color: Color(0xFFE5484D)))),
      ],
    );
    if (v == null || !mounted) return;
    final id = p.id.replaceAll(' ', '');
    switch (v) {
      case 'ft':
        _openFileTransfer(id);
        break;
      case 'run':
        _remoteRunPrompt(id);
        break;
      case 'uninstall':
        _uninstallConfirm(id, p.alias.isEmpty ? id : p.alias);
        break;
    }
  }

  Future<void> _remoteRunPrompt(String id) async {
    final ctrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('远程运行程序', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: r'对方机器上的完整路径，如 C:\apps\tool.exe --silent',
            isDense: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('下发'),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    try {
      final r = await LicenseClient.instance
          .issueCommand(id, 'run', payload: path);
      showToast(r['ok'] == true ? '指令已下发，对方联网后自动执行' : (r['msg'] ?? '下发失败'));
    } catch (e) {
      showToast('下发失败: $e');
    }
  }

  Future<void> _uninstallConfirm(String id, String alias) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('远程卸载员工端', style: TextStyle(fontSize: 15)),
        content: Text(
          '将静默卸载「$alias」上的员工端程序（$id）。\n'
          '对方客户端联网校验后自动卸载并退出，不需要对方确认。',
          style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认卸载'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      final r = await LicenseClient.instance.issueCommand(id, 'uninstall');
      if (r['ok'] == true) {
        showToast('卸载指令已下发');
      } else {
        final msg = (r['msg'] ?? '下发失败').toString();
        if (msg.contains('未在本系统激活')) {
          // 该设备不在授权体系内：引导走会话直发（工具栏卸载按钮）
          showToast('该设备未在授权系统激活：请先连接它，'
              '会话工具栏点「卸载」图标即可远程静默卸载');
        } else {
          showToast(msg);
        }
      }
    } catch (e) {
      showToast('下发失败: $e');
    }
  }

  /// 传输浮球：后台有任务在跑时出现
  Widget _buildFtBall() {
    if (_ftOpen) return const SizedBox.shrink();
    return Positioned(
      right: 18,
      bottom: 54,
      child: ValueListenableBuilder<int>(
        valueListenable: FileTransferHost.activeJobs,
        builder: (context, n, _) {
          if (n <= 0) return const SizedBox.shrink();
          return GestureDetector(
            onTap: () {
              if (mounted) setState(() => _ftOpen = true);
            },
            child: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: const Color(0xFF2F6CF6),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0x332F6CF6),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  const Center(
                    child: Icon(Icons.swap_vert_circle_outlined,
                        color: Colors.white, size: 26),
                  ),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Color(0xFFE5484D),
                        shape: BoxShape.circle,
                      ),
                      child: Text('$n',
                          style: const TextStyle(
                              fontSize: 10, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openWallInNewWindow() async {
    try {
      await rustDeskWinManager.newScreenWall();
      return;
    } catch (e) {
      debugPrint('open screen wall window failed: $e');
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ScreenWallPage()),
    );
  }

  void _connectPeer(Peer p) {
    connect(context, p.id, password: p.password.isEmpty ? null : p.password);
  }

  Future<void> _addAddressEntry() async {
    if (_tab != 2) setState(() => _tab = 2);
    final entry = await showAddressEntryDialog(context);
    if (entry == null) return;
    await AddressBookStore.instance.upsert(entry);
    showToast('已加入地址簿');
  }

  @override
  Widget build(BuildContext context) {
    // 兜底：显式清掉可能从上层继承下来的文字装饰（下划线等），避免整页文字带横线；
    // 同时把字重压回 w400 —— 上游主题给 body 设了加粗，Text 不写字重时会继承过去，
    // 中文小字看起来就又粗又糊。
    return DefaultTextStyle.merge(
      style: const TextStyle(
        decoration: TextDecoration.none,
        fontWeight: FontWeight.w400,
        fontFamilyFallback: _cnFonts,
      ),
      child: Container(
        color: Colors.white,
        child: Stack(
          children: [
            Column(
              children: [
                _buildTitleBar(),
                _buildHeader(),
                Container(height: 1, color: _C.line),
                _buildToolbar(),
                if (_showSearch) _buildSearchRow(),
                Expanded(
                  child: _tab == 2
                      ? AddressBookView(
                          query: _searchController.text,
                          onConnect: (id) => connect(context, id),
                        )
                      : _buildPeerArea(),
                ),
                if (_batch && _tab != 2 && _batchSel.isNotEmpty) _batchBar(),
                _buildStatusBar(),
              ],
            ),
            // 常驻文件传输宿主：Offstage 只是不画，State/会话/任务都活着 ——
            // 收进后台传输继续，这就是「后台文件传输」
            Positioned.fill(
              child: Offstage(
                offstage: !_ftOpen,
                child: FileTransferHost(
                  onHide: () {
                    if (mounted) setState(() => _ftOpen = false);
                  },
                ),
              ),
            ),
            // 传输浮球：后台有任务时出现，点开回到传输面板
            _buildFtBall(),
          ],
        ),
      ),
    );
  }

  // ---------------- 标题栏 ----------------

  Widget _buildTitleBar() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) async {
        try {
          await windowManager.startDragging();
        } catch (_) {}
      },
      onDoubleTap: _toggleMaximize,
      child: Container(
        height: 32,
        color: _C.titleBg,
        child: Row(
          children: [
            const SizedBox(width: 10),
            // 品牌图标（内嵌 PNG）。以前这里是 Icons.desktop_windows 的蓝方块
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: brandLogo(16),
            ),
            const SizedBox(width: 8),
            Text(appName,
                style: const TextStyle(fontSize: 12, color: _C.text)),
            const Spacer(),
            _winButton(Icons.remove, () async {
              try {
                await windowManager.minimize();
              } catch (_) {}
            }, tooltip: '最小化'),
            _winButton(Icons.crop_square, _toggleMaximize,
                size: 12, tooltip: '最大化 / 还原'),
            _winButton(Icons.close, _closeWindow, tooltip: '关闭到托盘'),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {}
  }

  Widget _winButton(IconData icon, VoidCallback onTap,
      {double size = 14, String? tooltip}) {
    final btn = SizedBox(
      width: 34,
      height: 28,
      child: InkWell(
        onTap: onTap,
        child: Icon(icon, size: size, color: const Color(0xFF616161)),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: btn,
    );
  }

  // ---------------- 顶部信息 + 连接区 ----------------

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 330, child: _buildLocalInfo()),
          const SizedBox(width: 44),
          Expanded(child: _buildConnectPane()),
        ],
      ),
    );
  }

  Widget _buildLocalInfo() {
    return AnimatedBuilder(
      animation: gFFI.serverModel,
      builder: (context, _) {
        final pwd = _localPwd;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.person_outline, size: 16, color: _C.sub),
                const SizedBox(width: 7),
                // ID 两个字做视觉强调（2026-11-09 用户要求：只优化「ID」标签，
                // 数字保持常规样式）
                const Text('ID',
                    style: TextStyle(
                        fontSize: 15,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 3,
                        color: _C.text,
                        // 中文走雅黑；不写 fontFamily 时 Flutter 会先用 Roboto 再回退，
                        // 回退字形会带上 Roboto 的度量，小字更糊。
                        fontFamilyFallback: _cnFonts)),
                const SizedBox(width: 8),
                const Text('本机识别码',
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.2,
                        color: _C.sub,
                        fontFamilyFallback: _cnFonts)),
                const Spacer(),
                _squareIconButton(Icons.copy_rounded, () => _copy(_localId),
                    tooltip: '复制识别码'),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              _groupedId.isEmpty ? '...' : _groupedId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                // 数字恢复原设计样式（29/w700，2026-11-09 用户要求：
                // 优化的是「ID」标签，不是数字）
                fontSize: 29,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.0,
                color: _C.text,
                fontFamilyFallback: _cnFonts,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.lock_outline, size: 16, color: _C.sub),
                const SizedBox(width: 7),
                const Text('验证码',
                    style: TextStyle(
                        fontSize: 14,
                        height: 1.35,
                        color: _C.sub,
                        fontFamilyFallback: _cnFonts)),
                const Spacer(),
                SizedBox(
                  width: 30,
                  height: 30,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    splashRadius: 15,
                    tooltip: '刷新验证码',
                    icon: const Icon(Icons.refresh, size: 17, color: _C.sub),
                    onPressed: _refreshPwd,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              pwd.isEmpty ? '-' : pwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.4,
                color: _C.text,
                fontFamilyFallback: _cnFonts,
              ),
            ),
            const SizedBox(height: 14),
            _buildLicenseCard(),
          ],
        );
      },
    );
  }

  /// 授权信息卡：套餐类型 + 剩余天数，点「详情」看完整授权信息
  Widget _buildLicenseCard() {
    return AnimatedBuilder(
      animation: LicenseClient.instance.revoked,
      builder: (context, _) {
        final c = LicenseClient.instance;
        // 卡片主标题优先显示卡时长（季卡/年卡），比套餐名更直观
        final plan = c.savedCardType.isNotEmpty
            ? c.savedCardType
            : (c.savedPlanName.isEmpty ? '已授权' : c.savedPlanName);
        final days = c.daysLeft;
        final dayTxt = days >= 0 ? '剩 $days 天' : '生效中';
        final expDay = c.savedExpire.isEmpty ? '' : c.savedExpire.split(' ').first;
        final exp = expDay.isEmpty ? '' : '$expDay 到期';
        final sub = exp.isEmpty
            ? '授权生效中'
            : (days >= 0 ? '$exp · $dayTxt' : '$exp · 已到期');
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _showLicenseDetail,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFEDF7EE),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFCDEBD4)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 34,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2FA45C),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.verified_outlined,
                                size: 15, color: Color(0xFF2FA45C)),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text('$plan · $dayTxt',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFF1E6B3C),
                                      fontFamilyFallback: _cnFonts)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF5C8A67),
                                fontFamilyFallback: _cnFonts)),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFCDEBD4)),
                    ),
                    child: const Text('详情',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF2FA45C),
                            fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            ),
          ),
        );
    },
  );
  }

  void _showLicenseDetail() {
    showDialog(
      context: context,
      builder: (ctx) => const _LicenseDetailDialog(),
    );
  }

  Widget _buildConnectPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // 「控制远程桌面」前的图标也用正式 logo，不再用 Icons.settings 凑
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: brandLogo(24),
            ),
            const SizedBox(width: 9),
            const Text(
              '控制远程桌面',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: _C.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildIdField(),
        const SizedBox(height: 12),
        _buildButtonRow(),
        const SizedBox(height: 12),
        _buildWarning(),
      ],
    );
  }

  Widget _buildIdField() {
    final focus = _idFocusNode.hasFocus;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: focus ? _C.blue : const Color(0xFFD8D8D8),
          width: 1.4,
        ),
      ),
      child: Center(
        child: TextField(
          controller: _idController,
          focusNode: _idFocusNode,
          style: const TextStyle(
              fontSize: 17, letterSpacing: 1.2, color: _C.text),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: '输入远程识别码',
            hintStyle: TextStyle(
                fontSize: 15, letterSpacing: 0, color: Color(0xFFB5B5B5)),
          ),
          onSubmitted: (_) => _doConnect(),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
  }

  Widget _buildButtonRow() {
    return Row(
      children: [
        Expanded(flex: 84, child: _solidButton('官网', _C.red, () {
          launchUrlString(_kBrandUrl);
        })),
        const SizedBox(width: 8),
        Expanded(flex: 96, child: _solidButton('屏幕墙', _C.blue, _openWall)),
        const SizedBox(width: 8),
        Expanded(flex: 82, child: _solidButton('查看', _C.teal, _connectViewOnly)),
        const SizedBox(width: 8),
        Expanded(flex: 82, child: _solidButton('控制', _C.green, _doConnect)),
        const SizedBox(width: 8),
        SizedBox(width: 44, height: 40, child: _buildMoreButton()),
      ],
    );
  }

  Widget _solidButton(String label, Color color, VoidCallback onTap) {
    return SizedBox(
      height: 40,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      ),
    );
  }

  Widget _buildMoreButton() {
    return PopupMenuButton<String>(
      tooltip: '更多',
      color: Colors.white,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onSelected: (v) {
        if (v == 'quit') {
          _quitApp();
          return;
        }
        final id = _idController.id;
        if (id.isEmpty) {
          showToast('请输入远程识别码');
          return;
        }
        switch (v) {
          case 'file':
            _openFileTransfer();
            break;
          case 'terminal':
            connect(context, id, isTerminal: true);
            break;
          case 'approval':
            connect(context, id, loginMethod: 'request-approval');
            break;
        }
      },
      // 标准版不下发 file_transfer / terminal，这里直接不显示入口
      itemBuilder: (context) => [
        if (licenseFeature('file_transfer'))
          const PopupMenuItem(value: 'file', child: Text('传输文件')),
        if (licenseFeature('terminal'))
          const PopupMenuItem(value: 'terminal', child: Text('终端 (beta)')),
        const PopupMenuItem(value: 'approval', child: Text('请求授权连接')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'quit', child: Text('退出程序')),
      ],
      child: Container(
        decoration: BoxDecoration(
          color: _C.dark,
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Icon(Icons.keyboard_arrow_down,
            size: 20, color: Colors.white),
      ),
    );
  }

  Widget _buildWarning() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(
        color: _C.warnBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.warning_amber_rounded,
                size: 15, color: _C.warnIcon),
          ),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '温馨提醒：本软件仅用于本人拥有所有权或已获得设备所有者明确许可的设备。'
              '未经授权远程控制、监视他人电脑属于违法犯罪行为，一切违规使用后果由使用者自行承担。',
              style: TextStyle(
                fontSize: 12,
                height: 1.65,
                // Windows 中文只有常规/Light 两档字形，w300 配上雅黑 Light 才是真的细，
                // 只写 w300 会回退到常规，看起来仍然偏粗。
                fontWeight: FontWeight.w300,
                fontFamilyFallback: [
                  'Microsoft YaHei Light',
                  'Microsoft YaHei UI Light',
                  'Microsoft YaHei',
                  'PingFang SC',
                ],
                color: _C.warnText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 工具条 ----------------

  Widget _buildToolbar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          _tabIcon(Icons.history, '最近', 0),
          _tabIcon(Icons.star_border, '收藏', 1),
          _tabIcon(Icons.contacts_outlined, '地址簿', 2),
          const SizedBox(width: 4),
          _plainToolIcon(Icons.grid_view_rounded, '屏幕墙', _openWall),
          _plainToolIcon(Icons.campaign_outlined, '群发文件', _groupSend),
          _plainToolIcon(Icons.settings_outlined, '设置', _openSettings),
          const Spacer(),
          if (_tab == 2) ...[
            _plainToolIcon(Icons.add, '添加设备', _addAddressEntry),
            _plainToolIcon(Icons.search, '搜索', () {
              setState(() => _showSearch = !_showSearch);
            }, active: _showSearch),
          ] else ...[
            _plainToolIcon(
              Icons.search,
              '搜索',
              () => setState(() => _showSearch = !_showSearch),
              active: _showSearch,
            ),
            _plainToolIcon(Icons.post_add, '批量添加收藏', _showBatchFavDialog),
            _plainToolIcon(Icons.playlist_add_check, '批量', () {
              setState(() {
                _batch = !_batch;
                _batchSel.clear();
              });
            }, active: _batch),
            _plainToolIcon(Icons.refresh, '刷新', () {
              bind.mainLoadFavPeers();
              bind.mainLoadRecentPeers();
              _refreshLocalId();
            }),
            _plainToolIcon(
              _grid ? Icons.view_list_rounded : Icons.grid_on_rounded,
              _grid ? '列表' : '网格',
              () => setState(() => _grid = !_grid),
              active: _grid,
            ),
            _plainToolIcon(
              Icons.swap_vert,
              _asc ? '倒序' : '正序',
              () => setState(() => _asc = !_asc),
              active: !_asc,
            ),
          ],
        ],
      ),
    );
  }

  Widget _tabIcon(IconData icon, String label, int index) {
    final active = _tab == index;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: () {
          setState(() {
            _tab = index;
            _batch = false;
            _batchSel.clear();
          });
          // 收藏名单可能被屏幕墙那边改过（墙里移除设备 = 取消收藏），切页时对齐
          _loadFavIds();
          if (index == 0) {
            bind.mainLoadRecentPeers();
          } else if (index == 1) {
            bind.mainLoadFavPeers();
          } else {
            AddressBookStore.instance.load();
          }
        },
        child: Container(
          width: 38,
          height: 44,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? _C.blue : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Icon(icon, size: 19, color: active ? _C.text : _C.sub),
        ),
      ),
    );
  }

  Widget _plainToolIcon(IconData icon, String label, VoidCallback onTap,
      {bool active = false}) {
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: SizedBox(
        width: 34,
        height: 44,
        child: InkWell(
          onTap: onTap,
          child: Icon(icon, size: 18, color: active ? _C.blue : _C.sub),
        ),
      ),
    );
  }

  Widget _buildSearchRow() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _C.line)),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 16, color: Color(0xFFB0B0B0)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              style: const TextStyle(fontSize: 13, color: _C.text),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索',
                hintStyle: TextStyle(fontSize: 13, color: Color(0xFFB0B0B0)),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 设备区 ----------------

  /// 批量模式底部动作条：全选 / 添加到屏幕墙 / 取消
  Widget _batchBar() {
    final list = _filtered(_peers.peers);
    final allSel = list.isNotEmpty && list.every((p) => _batchSel.contains(p.id));
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: const Color(0xFFEDF4FC),
      child: Row(
        children: [
          Text('已选 ${_batchSel.length} 台',
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: _C.text)),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              if (allSel) {
                _batchSel.clear();
              } else {
                _batchSel.addAll(list.map((p) => p.id));
              }
            }),
            child: Text(allSel ? '全不选' : '全选',
                style: const TextStyle(fontSize: 12.5)),
          ),
          TextButton.icon(
            onPressed: _addSelectedToFav,
            icon: const Icon(Icons.star_border_rounded, size: 16),
            label: const Text('加入收藏夹', style: TextStyle(fontSize: 12.5)),
          ),
          TextButton.icon(
            onPressed: _addSelectedToWall,
            icon: const Icon(Icons.tv, size: 15),
            label: const Text('添加到屏幕墙', style: TextStyle(fontSize: 12.5)),
          ),
          TextButton.icon(
            onPressed: _deleteSelected,
            icon: const Icon(Icons.delete_outline,
                size: 15, color: Color(0xFFE23B3B)),
            label: const Text('删除',
                style: TextStyle(fontSize: 12.5, color: Color(0xFFE23B3B))),
          ),
          TextButton(
            onPressed: () => setState(() {
              _batch = false;
              _batchSel.clear();
            }),
            child: const Text('取消',
                style: TextStyle(fontSize: 12.5, color: _C.sub)),
          ),
        ],
      ),
    );
  }

  Future<void> _addSelectedToWall() async {
    final n = await addPeersToScreenWall(_batchSel.toList());
    if (!mounted) return;
    if (n < 0) {
      showToast('添加失败，请重试');
      return;
    }
    showToast(n == 0 ? '所选设备都已在屏幕墙里' : '已把 $n 台设备加入屏幕墙');
    setState(() {
      _batch = false;
      _batchSel.clear();
    });
  }

  // ---------------- 收藏夹 ----------------
  //
  // 收藏夹 = 屏幕墙的设备名单（墙就是按 mainGetFav 铺格子的）。
  // 所以这里加一个「加入收藏夹」按钮，用户在首页就能把设备放进墙里，
  // 不用先开屏幕墙再在墙里点「添加设备」。

  static String _normId(String id) => id.replaceAll(' ', '').trim();

  bool _isFav(String id) => _favIds.contains(_normId(id));

  Future<void> _loadFavIds() async {
    List<String> favs = [];
    try {
      favs = (await bind.mainGetFav()).toList();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _favIds = favs.map(_normId).toList());
  }

  /// add 为 null 时按当前状态取反
  Future<void> _toggleFav(List<String> ids, {bool? add}) async {
    if (ids.isEmpty) return;
    List<String> favs;
    try {
      favs = (await bind.mainGetFav()).toList();
    } catch (_) {
      if (!mounted) return;
      showToast('操作失败，请重试');
      return;
    }
    final want = ids.map(_normId).toSet();
    final exist = favs.map(_normId).toSet();
    final doAdd = add ?? !want.every(exist.contains);
    if (doAdd) {
      for (final id in want) {
        if (!exist.contains(id)) favs.add(id);
      }
    } else {
      favs.removeWhere((f) => want.contains(_normId(f)));
    }
    try {
      await bind.mainStoreFav(favs: favs);
      bind.mainLoadFavPeers();
    } catch (_) {
      if (!mounted) return;
      showToast('操作失败，请重试');
      return;
    }
    await _loadFavIds();
    if (!mounted) return;
    if (doAdd) {
      showToast(want.length > 1
          ? '已把 ${want.length} 台设备加入收藏夹'
          : '已加入收藏夹，屏幕墙会显示这台设备');
    } else {
      showToast(want.length > 1 ? '已移出收藏夹' : '已移出收藏夹');
    }
  }

  /// 收藏夹星标：实心=已在收藏夹（= 已在屏幕墙上），空心=没收藏，点一下切换
  Widget _favStar(Peer p, {double size = 18}) {
    final fav = _isFav(p.id);
    return Tooltip(
      message: fav ? '移出收藏夹（屏幕墙同步移除）' : '加入收藏夹（屏幕墙会显示这台设备）',
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: () => _toggleFav([p.id]),
        borderRadius: BorderRadius.circular(9),
        child: SizedBox(
          width: size + 12,
          height: size + 8,
          child: Icon(
            fav ? Icons.star_rounded : Icons.star_border_rounded,
            size: size,
            color: fav ? const Color(0xFFF5A623) : const Color(0xFFBDBDBD),
          ),
        ),
      ),
    );
  }

  Future<void> _addSelectedToFav() async {
    final ids = _batchSel.toList();
    if (ids.isEmpty) return;
    await _toggleFav(ids, add: true);
    if (!mounted) return;
    setState(() {
      _batch = false;
      _batchSel.clear();
    });
  }

  /// 批量添加收藏（2026-11-09）：一次粘贴多台设备。
  /// 每行一台，三种写法：`ID`、`ID 密码`、`ID:密码`（分隔符还支持中文冒号/逗号）。
  /// ID 必填；密码可选，写进 peer 配置后连接免输。收藏即屏幕墙名单。
  Future<void> _showBatchFavDialog() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('批量添加收藏',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                maxLines: 8,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '每行一台设备，例如：\n123456789\n987654321 密码\n555 666 777:密码',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                  'ID 必填；密码可选（ID后跟空格/冒号）。添加后设备进入收藏夹与屏幕墙。',
                  style: TextStyle(fontSize: 12, color: _C.sub)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _C.blue),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    final ids = <String>[];
    var pwdCount = 0;
    for (var raw in ctrl.text.split(RegExp(r'[\n;；]'))) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      String? pwd;
      final m = RegExp(r'^([0-9A-Za-z]+)\s*[:：,，\s]\s*(.+)$').firstMatch(line);
      if (m != null) {
        line = m.group(1)!;
        pwd = m.group(2)!.trim();
      }
      final id = line.replaceAll(' ', '');
      if (id.isEmpty) continue;
      if (!ids.contains(id)) ids.add(id);
      if (pwd != null && pwd.isNotEmpty) {
        pwdCount++;
        try {
          await bind.mainSetPeerOption(id: id, key: 'password', value: pwd);
        } catch (_) {}
      }
    }
    ctrl.dispose();
    if (ids.isEmpty) {
      showToast('没有识别到有效的设备 ID');
      return;
    }
    await _toggleFav(ids, add: true);
    if (!mounted) return;
    showToast('已处理 ${ids.length} 台设备' +
        (pwdCount > 0 ? '（含密码 ${pwdCount} 台）' : '') +
        '，收藏夹与屏幕墙已更新');
  }

  Future<void> _addOneToWall(String id) async {
    final n = await addPeersToScreenWall([id]);
    if (!mounted) return;
    if (n < 0) {
      showToast('添加失败，请重试');
      return;
    }
    showToast(n == 0 ? '该设备已在屏幕墙里' : '已加入屏幕墙');
  }

  // ---------------- 删除设备 ----------------
  //
  // 与原生一致：最近列表用 mainRemovePeer 从最近记录里删，收藏用 mainStoreFav
  // 重写收藏名单。只动本机列表，不会卸载对方、也不影响授权绑定。

  String get _listName => _tab == 1 ? '收藏' : '最近';

  Future<bool?> _confirmDelete(String title, String body) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: Text(body,
            style: const TextStyle(fontSize: 13, color: Color(0xFF666666))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除',
                style: TextStyle(fontSize: 13, color: Color(0xFFE23B3B))),
          ),
        ],
      ),
    );
  }

  Future<void> _removeIds(List<String> ids) async {
    if (ids.isEmpty) return;
    if (_tab == 1) {
      final favs = (await bind.mainGetFav()).toList();
      final before = favs.length;
      favs.removeWhere(ids.contains);
      if (favs.length != before) {
        await bind.mainStoreFav(favs: favs);
        bind.mainLoadFavPeers();
      }
    } else {
      for (final id in ids) {
        await bind.mainRemovePeer(id: id);
      }
      bind.mainLoadRecentPeers();
    }
  }

  Future<void> _deletePeer(Peer p) async {
    final name = _displayNameOrId(p);
    final ok = await _confirmDelete('删除「$name」？',
        '只从本机$_listName列表移除，不影响对方设备，也不会解绑授权。');
    if (ok != true) return;
    try {
      await _removeIds([p.id]);
      if (!mounted) return;
      showToast('已删除');
    } catch (_) {
      if (!mounted) return;
      showToast('删除失败，请重试');
    }
  }

  Future<void> _deleteSelected() async {
    final ids = _batchSel.toList();
    if (ids.isEmpty) return;
    final ok = await _confirmDelete('删除所选的 ${ids.length} 台设备？',
        '只从本机$_listName列表移除，不影响对方设备，也不会解绑授权。');
    if (ok != true) return;
    try {
      await _removeIds(ids);
      if (!mounted) return;
      showToast('已删除 ${ids.length} 台');
      setState(() {
        _batch = false;
        _batchSel.clear();
      });
    } catch (_) {
      if (!mounted) return;
      showToast('删除失败，请重试');
    }
  }

  Widget _buildPeerArea() {
    return AnimatedBuilder(
      animation: _peers,
      builder: (context, _) {
        final list = _filtered(_peers.peers);
        if (list.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.sentiment_very_dissatisfied_outlined,
                    size: 34, color: Color(0xFF9E9E9E)),
                SizedBox(height: 8),
                Text('空空如也',
                    style: TextStyle(fontSize: 13, color: _C.sub)),
              ],
            ),
          );
        }
        return _grid ? _buildGrid(list) : _buildList(list);
      },
    );
  }

  Widget _buildList(List<Peer> list) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: list.length,
      separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 1,
          color: const Color(0xFFF2F2F2),
          indent: _batch ? 84 : 74),
      itemBuilder: (context, i) => _peerRow(list[i]),
    );
  }

  Widget _peerRow(Peer p) {
    final checked = _batchSel.contains(p.id);
    // 右键：传输文件 / 远程运行 / 远程卸载（批量模式不响应）
    return GestureDetector(
      onSecondaryTapUp: _batch ? null : (d) => _peerMenu(p, d.globalPosition),
      child: InkWell(
      onTap: () {
        if (_batch) {
          setState(
              () => checked ? _batchSel.remove(p.id) : _batchSel.add(p.id));
        } else {
          _connectPeer(p);
        }
      },
      hoverColor: _C.hover,
      child: Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (_batch) ...[
              SizedBox(
                width: 30,
                child: Checkbox(
                  value: checked,
                  onChanged: (v) => setState(() =>
                      v == true ? _batchSel.add(p.id) : _batchSel.remove(p.id)),
                ),
              ),
              const SizedBox(width: 4),
            ],
            _avatar(p, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: peerStatusColor(p),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          _displayNameOrId(p),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: _C.text),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _subLineOf(p),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _C.sub),
                  ),
                ],
              ),
            ),
            _favStar(p, size: 19),
            const SizedBox(width: 2),
            SizedBox(
              width: 32,
              height: 30,
              child: PopupMenuButton<String>(
                tooltip: '更多',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_horiz,
                    size: 18, color: Color(0xFF9E9E9E)),
                onSelected: (v) {
                  final pid = p.id.replaceAll(' ', '');
                  if (v == 'connect') {
                    _connectPeer(p);
                  } else if (v == 'wall') {
                    _addOneToWall(p.id);
                  } else if (v == 'ft') {
                    _openFileTransfer(pid);
                  } else if (v == 'run') {
                    _remoteRunPrompt(pid);
                  } else if (v == 'uninstall') {
                    _uninstallConfirm(
                        pid, p.alias.isEmpty ? pid : p.alias);
                  } else if (v == 'fav') {
                    _toggleFav([p.id]);
                  } else if (v == 'copy') {
                    _copy(p.id);
                  } else if (v == 'delete') {
                    _deletePeer(p);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'connect',
                      height: 36,
                      child: Text('连接', style: TextStyle(fontSize: 13))),
                  const PopupMenuItem(
                      value: 'ft',
                      height: 36,
                      child: Text('传输文件',
                          style: TextStyle(fontSize: 13))),
                  const PopupMenuItem(
                      value: 'wall',
                      height: 36,
                      child: Text('添加到屏幕墙',
                          style: TextStyle(fontSize: 13))),
                  PopupMenuItem(
                      value: 'fav',
                      height: 36,
                      child: Text(_isFav(p.id) ? '移出收藏夹' : '添加到收藏夹',
                          style: const TextStyle(fontSize: 13))),
                  const PopupMenuItem(
                      value: 'copy',
                      height: 36,
                      child: Text('复制识别码',
                          style: TextStyle(fontSize: 13))),
                  const PopupMenuItem(
                      value: 'run',
                      height: 36,
                      child: Text('远程运行程序',
                          style: TextStyle(fontSize: 13))),
                  const PopupMenuDivider(height: 1),
                  const PopupMenuItem(
                      value: 'delete',
                      height: 36,
                      child: Text('删除',
                          style: TextStyle(
                              fontSize: 13, color: Color(0xFFE23B3B)))),
                  const PopupMenuItem(
                      value: 'uninstall',
                      height: 36,
                      child: Text('卸载员工端（静默）',
                          style: TextStyle(
                              fontSize: 13, color: Color(0xFFE5484D)))),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildGrid(List<Peer> list) {
    return GridView.builder(
      padding: const EdgeInsets.all(14),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // 与原生客户端卡片同量级：卡片更小更紧凑，信息密度靠数量取胜
        maxCrossAxisExtent: 208,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.55,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final p = list[i];
        final checked = _batchSel.contains(p.id);
        return MouseRegion(
          onEnter: (_) {
            if (_hoverId != p.id) setState(() => _hoverId = p.id);
          },
          onExit: (_) {
            if (_hoverId == p.id) setState(() => _hoverId = null);
          },
          child: InkWell(
            onTap: () {
              if (_batch) {
                setState(() =>
                    checked ? _batchSel.remove(p.id) : _batchSel.add(p.id));
              } else {
                _connectPeer(p);
              }
            },
            borderRadius: BorderRadius.circular(7),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                    color: checked ? _C.blue : _C.line,
                    width: checked ? 1.4 : 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _avatar(p, size: 22),
                      const SizedBox(width: 7),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: peerStatusColor(p),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          _displayNameOrId(p),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: _C.text),
                        ),
                      ),
                      if (_batch)
                        Icon(
                          checked
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 16,
                          color: checked ? _C.blue : const Color(0xFFB0B0B0),
                        ),
                      // 收藏夹星标常驻：卡片上直接能点，不用开菜单
                      if (!_batch) _favStar(p, size: 14),
                      if (!_batch && _hoverId == p.id)
                        Tooltip(
                          message: '从这个列表删除',
                          waitDuration: const Duration(milliseconds: 600),
                          child: InkWell(
                            onTap: () => _deletePeer(p),
                            borderRadius: BorderRadius.circular(9),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 4),
                              child: Icon(Icons.close_rounded,
                                  size: 13, color: Color(0xFF9E9E9E)),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _subLineOf(p),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: _C.sub),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 原生风格头像：彩色圆角方块（按名称哈希取色）+ 白色平台图标
  Widget _avatar(Peer p, {double size = 32}) {
    final seed = _displayNameOrId(p);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: abAvatarColor(seed),
        borderRadius: BorderRadius.circular(size * 0.24),
      ),
      alignment: Alignment.center,
      child: Icon(
        p.platform.toLowerCase().contains('linux')
            ? Icons.terminal
            : Icons.desktop_windows_outlined,
        size: size * 0.52,
        color: Colors.white,
      ),
    );
  }

  // ---------------- 状态条 ----------------

  Widget _buildStatusBar() {
    return AnimatedBuilder(
      animation: gFFI.serverModel,
      builder: (context, _) {
        // 真正的在线判断 = Rust 的 rendezvous 状态 + 独立 API 探测：
        //   status_num: 1=就绪 0=连接中 -1=未就绪/连不上；
        //   _apiOk: api.hydesk.cn 是否可达（20s 周期探针）。
        // 只看 connectStatus 时 API/组件挂掉仍显示绿（假在线），
        // 只看探针时 ID 服务器挂掉又测不出 —— 两者任一失败都算未联网。
        final st = gFFI.serverModel.connectStatus;
        final offline = st == -1 || _apiOk == 0;
        final hasId = _localId.isNotEmpty;
        final Color color;
        final String text;
        if (offline) {
          color = const Color(0xFFE5484D);
          text = '未联网（服务器不可达）';
        } else if (st == 1) {
          color = _C.green;
          text = hasId ? '已连接安全加密链路' : '正在获取设备ID…';
        } else {
          color = const Color(0xFFE0A100);
          text = '正在连接服务器…';
        }
        return Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: _C.line)),
          ),
          child: Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                text,
                style: const TextStyle(
                    fontSize: 13,
                    height: 1.3,
                    color: _C.sub,
                    fontFamilyFallback: _cnFonts),
              ),
              const Spacer(),
            ],
          ),
        );
      },
    );
  }

  Widget _squareIconButton(IconData icon, VoidCallback onTap,
      {String? tooltip}) {
    return Tooltip(
      message: tooltip ?? '',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE0E0E0)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 16, color: const Color(0xFF757575)),
        ),
      ),
    );
  }
}

/// 授权详情弹窗：套餐 / 到期 / 设备占用 / 激活码，支持续费升级与本机解绑。
class _LicenseDetailDialog extends StatefulWidget {
  const _LicenseDetailDialog();

  @override
  State<_LicenseDetailDialog> createState() => _LicenseDetailDialogState();
}

class _LicenseDetailDialogState extends State<_LicenseDetailDialog> {
  final LicenseClient _c = LicenseClient.instance;

  @override
  void initState() {
    super.initState();
    // 附加包可能刚在屏幕墙子窗口里激活，本进程读到的配置还是旧快照
    // （两个窗口是不同进程，Rust 侧的本地配置不互通）；
    // 打开详情时主动拉一次，避免「已开通却显示未开通」。
    _refreshConfig();
  }

  Future<void> _refreshConfig() async {
    try {
      await _c.check();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  String get _plan =>
      _c.savedPlanName.isEmpty ? '已授权' : _c.savedPlanName;

  /// 版本类型：标准版 / 专业版 / 手工授权（按套餐 id 显示）
  String get _planType {
    switch (_c.savedPlan) {
      case 'std':
        return '标准版';
      case 'pro':
        return '专业版';
      case 'manual':
        return '手工授权';
      default:
        return _c.savedPlan.isEmpty ? '—' : _c.savedPlan;
    }
  }

  /// 授权类型：卡时长（季卡/年卡…），服务端取不到时退回套餐名
  String get _cardName =>
      _c.savedCardType.isEmpty ? _plan : _c.savedCardType;

  @override
  Widget build(BuildContext context) {
    final days = _c.daysLeft;
    final used = _c.savedDevicesUsed;
    final max = _c.savedDevicesMax;
    final code = _c.savedCode;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      title: const Text('授权详情',
          style: TextStyle(
              fontSize: 16.5, fontWeight: FontWeight.w600, color: _C.text)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('版本类型', _planType, bold: true),
            _kv('授权类型', _cardName,
                valueColor: const Color(0xFF2FA45C),
                bold: true),
            _kv('到期时间',
                _c.savedExpire.isEmpty ? '—' : _c.savedExpire.split(' ').first),
            _kv('剩余天数', days >= 0 ? '$days 天' : '—'),
            _kv('设备占用',
                used < 0 ? '—' : (max > 0 ? '$used / $max 台' : '$used 台')),
            const SizedBox(height: 10),
            StatefulBuilder(builder: (ctx, setLocal) {
              final addons = _c.savedAddons;
              final blocked = _c.blockedAddons;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('附加功能',
                          style: TextStyle(fontSize: 12.5, color: _C.sub)),
                      const Spacer(),
                      InkWell(
                        onTap: () => _redeemAddon(ctx, () {
                          setLocal(() {});
                          _refreshConfig();
                        }),
                        child: const Text('兑换附加包',
                            style: TextStyle(
                                fontSize: 12.5, color: Color(0xFF1B72D6))),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (addons.isEmpty)
                    Text(
                        blocked.isEmpty
                            ? '未开通（屏幕墙 16/32/64 屏与群控需单独购买，绑定授权码后可随设备迁移）'
                            : '本机暂无可用附加包（已购的已达 3 台上限）',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF8A94A6)))
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: addons.map((a) {
                        final exp = (a['expire_at'] ?? '').toString();
                        final label =
                            (a['name'] ?? a['key'] ?? '').toString();
                        final used = a['devices'] ?? 0;
                        final maxDev = a['max_devices'] ?? 3;
                        final meta = [
                          if (exp.isNotEmpty) exp.split(' ').first,
                          '$used/$maxDev 台',
                          if (a['limited_by_license'] == true) '随主授权',
                        ].join(' · ');
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEAF6EE),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '$label · $meta',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF2FA45C)),
                          ),
                        );
                      }).toList(),
                    ),
                  if (blocked.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    ...blocked.map((a) => Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${a["name"] ?? a["key"]}：本机不在已占用的 ${a["max_devices"] ?? 3} 台内，'
                            '需先在旧设备解绑',
                            style: const TextStyle(
                                fontSize: 11.5, color: Color(0xFFC8811A)),
                          ),
                        )),
                  ],
                ],
              );
            }),
            const SizedBox(height: 12),
            const Text('激活码',
                style: TextStyle(fontSize: 12.5, color: _C.sub)),
            const SizedBox(height: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF6F8FB),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFE3E8F0)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      code.isEmpty ? '—' : code,
                      style: const TextStyle(
                          fontSize: 13.5,
                          letterSpacing: 0.6,
                          color: _C.text,
                          fontFamily: 'Consolas',
                          fontFamilyFallback: ['Menlo', 'monospace']),
                    ),
                  ),
                  InkWell(
                    onTap: () => _copy(context, code),
                    child: const Text('复制',
                        style: TextStyle(
                            fontSize: 12.5, color: Color(0xFF1B72D6))),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭',
              style: TextStyle(fontSize: 13.5, color: _C.sub)),
        ),
        TextButton(
          onPressed: () => _upgrade(context),
          child: const Text('续费升级',
              style: TextStyle(
                  fontSize: 13.5,
                  color: Color(0xFF1B72D6),
                  fontWeight: FontWeight.w500)),
        ),
        TextButton(
          onPressed: () => _unbind(context),
          child: const Text('解绑设备',
              style: TextStyle(
                  fontSize: 13.5,
                  color: _C.red,
                  fontWeight: FontWeight.w500)),
        ),
        ElevatedButton(
          onPressed: () => _copy(context, code),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1B72D6),
            elevation: 0,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('复制激活码',
              style: TextStyle(
                  fontSize: 13.5,
                  color: Colors.white,
                  fontWeight: FontWeight.w500)),
        ),
      ],
    );
  }

  Widget _kv(String k, String v,
      {Color? valueColor, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 74,
            child: Text(k,
                style:
                    const TextStyle(fontSize: 12.5, color: _C.sub)),
          ),
          Expanded(
            child: Text(v,
                style: TextStyle(
                    fontSize: 13.5,
                    color: valueColor ?? _C.text,
                    fontWeight:
                        bold ? FontWeight.w600 : FontWeight.w400)),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context, String text) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    Navigator.of(context).pop();
    showToast('已复制');
  }

  Future<void> _upgrade(BuildContext context) async {
    await gotoShop(context);
  }

  /// 兑换附加包：输入购买屏幕墙档位 / 群控后拿到的授权码。
  /// 附加包不动主授权，只把对应功能开关点亮，成功后刷新弹窗里的已购列表。
  Future<void> _redeemAddon(BuildContext context, VoidCallback refresh,
      {String? productId}) async {
    final ctrl = TextEditingController();
    final act = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('兑换附加包',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('输入购买屏幕墙档位或群控后拿到的授权码，开通后立即生效。\n'
                '权限绑定当前授权码，换设备后重新激活同一授权码仍然有效。',
                style: TextStyle(fontSize: 13, color: _C.sub, height: 1.6)),
            const SizedBox(height: 8),
            // 没买过的用户也要有明确出口，别只给一个输入框
            InkWell(
              onTap: () => Navigator.of(ctx).pop('buy'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
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
              style: const TextStyle(fontSize: 13.5, letterSpacing: 0.6),
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
            child: const Text('取消', style: TextStyle(color: _C.sub)),
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
      if (!context.mounted) return;
      await gotoShop(context, productId: productId);
      return;
    }
    if (act != 'ok') return;
    final code = ctrl.text.trim();
    if (code.isEmpty) {
      if (!context.mounted) return;
      showToast('请先填写附加包授权码；还没有码可点弹窗里的「去商城购买」');
      return;
    }
    try {
      final r = await LicenseClient.instance.activate(code);
      if (!context.mounted) return;
      refresh();
      final eff = r.addonEffectiveExpire.isNotEmpty
          ? r.addonEffectiveExpire
          : r.addonExpire;
      final effDay = eff.isEmpty ? '' : eff.split(' ').first;
      showToast(r.isAddon
          ? '已开通：${r.addonName}（已绑定当前授权码'
              '${effDay.isEmpty ? "" : "，${r.addonExpiresWithLicense ? "随主授权至" : "至"} $effDay"}）'
          : '授权已更新');
    } on LicenseException catch (e) {
      if (!context.mounted) return;
      showToast(e.msg);
    } catch (e) {
      if (!context.mounted) return;
      showToast('开通失败：$e');
    }
  }

  Future<void> _unbind(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('解绑本机',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600)),
        content: const Text(
            '解绑后本机会立即退出授权状态，需要重新输入激活码才能使用。确定解绑吗？',
            style: TextStyle(fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消',
                style: TextStyle(color: _C.sub)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _C.red,
              elevation: 0,
            ),
            child: const Text('确认解绑',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _c.localDeactivate();
  }
}
