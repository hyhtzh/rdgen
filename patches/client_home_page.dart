// 管理端（控制端）主页：按设计稿重做。
// 顶部：本机识别码 / 验证码 / IP 直连 + 右侧「控制远程桌面」连接区（5 个实色按钮）
// 中部：工具条 + 搜索 + 设备列表（最近 / 收藏），底部状态条。
// 由 patch_client_ui.py 注入到 flutter/lib/desktop/pages/ 下。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/pages/screen_wall_page.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';

const _kBrandUrl = 'https://rd.wh2028.cn';

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
  static const warnBg = Color(0xFFFEF8E7);
  static const warnBorder = Color(0xFFF3E2B4);
  static const warnText = Color(0xFF8A6A2F);
  static const titleBg = Color(0xFFF7F7F7);
  static const hover = Color(0xFFF5F8FD);
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
  int _tab = 1; // 0 最近, 1 收藏
  bool _grid = false;
  bool _asc = true;
  bool _showSearch = true;
  String _localIp = '';

  @override
  void initState() {
    super.initState();
    bind.mainLoadFavPeers();
    bind.mainLoadRecentPeers();
    _loadLocalIp();
    // 屏幕墙进程如果是被任务栏 X 直接关掉的，低帧率配置可能没恢复，这里兜底
    WallFps.restore();
    // 主窗口设了 preventClose，必须自己接管关闭事件，否则任务栏的 X 也点不动
    windowManager.addListener(this);
    // 原版首页靠 1s 定时器刷新本机 ID，替换页面后必须自己拉
    _idTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _refreshLocalId());
    _idFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _idTimer?.cancel();
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

  Future<void> _loadLocalIp() async {
    String ip = '';
    try {
      final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in list) {
        for (final a in i.addresses) {
          if (a.isLoopback) continue;
          final s = a.address;
          if (s.startsWith('192.168.') || s.startsWith('10.')) {
            ip = s;
            break;
          }
          if (ip.isEmpty) ip = s;
        }
        if (ip.startsWith('192.168.') || ip.startsWith('10.')) break;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _localIp = ip.isEmpty ? '-' : ip);
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

  @override
  Widget build(BuildContext context) {
    // 兜底：显式清掉可能从上层继承下来的文字装饰（下划线等），避免整页文字带横线
    return DefaultTextStyle.merge(
      style: const TextStyle(decoration: TextDecoration.none),
      child: Container(
        color: Colors.white,
        child: Column(
          children: [
            _buildTitleBar(),
            _buildHeader(),
            Container(height: 1, color: _C.line),
            _buildToolbar(),
            if (_showSearch) _buildSearchRow(),
            Expanded(child: _buildPeerArea()),
            _buildStatusBar(),
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
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: _C.blue,
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Icon(Icons.desktop_windows,
                  size: 11, color: Colors.white),
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
                const Text('本机识别码',
                    style: TextStyle(fontSize: 13, color: _C.sub)),
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
                fontSize: 29,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.8,
                color: _C.text,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.lock_outline, size: 16, color: _C.sub),
                const SizedBox(width: 7),
                const Text('验证码',
                    style: TextStyle(fontSize: 13, color: _C.sub)),
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
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: _C.text,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: const [
                Icon(Icons.public, size: 16, color: _C.sub),
                SizedBox(width: 7),
                Text('IP 直连',
                    style: TextStyle(fontSize: 13, color: _C.sub)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              _localIp.isEmpty ? '获取中…' : _localIp,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w400,
                color: _C.text,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildConnectPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: _C.blue,
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Icon(Icons.settings, size: 16, color: Colors.white),
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
            connect(context, id, isFileTransfer: true);
            break;
          case 'terminal':
            connect(context, id, isTerminal: true);
            break;
          case 'approval':
            connect(context, id, loginMethod: 'request-approval');
            break;
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'file', child: Text('传输文件')),
        PopupMenuItem(value: 'terminal', child: Text('终端 (beta)')),
        PopupMenuItem(value: 'approval', child: Text('请求授权连接')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'quit', child: Text('退出程序')),
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
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
      decoration: BoxDecoration(
        color: _C.warnBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _C.warnBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.warning_amber_rounded,
                size: 15, color: Color(0xFFE0A100)),
          ),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '温馨提醒：本软件仅用于本人拥有所有权或已获得设备所有者明确许可的设备。'
              '未经授权远程控制、监视他人电脑属于违法犯罪行为，一切违规使用后果由使用者自行承担。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
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
          const SizedBox(width: 4),
          _plainToolIcon(Icons.grid_view_rounded, '屏幕墙', _openWall),
          _plainToolIcon(Icons.settings_outlined, '设置', _openSettings),
          const Spacer(),
          _plainToolIcon(
            Icons.search,
            '搜索',
            () => setState(() => _showSearch = !_showSearch),
            active: _showSearch,
          ),
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
          setState(() => _tab = index);
          index == 0 ? bind.mainLoadRecentPeers() : bind.mainLoadFavPeers();
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
      separatorBuilder: (_, __) => const Divider(
          height: 1, thickness: 1, color: Color(0xFFF2F2F2), indent: 58),
      itemBuilder: (context, i) => _peerRow(list[i]),
    );
  }

  Widget _peerRow(Peer p) {
    return InkWell(
      onTap: () => _connectPeer(p),
      hoverColor: _C.hover,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _avatar(p),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.alias.isEmpty ? p.id : p.alias,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _C.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    p.alias.isEmpty
                        ? (p.hostname.isEmpty ? '未命名设备' : p.hostname)
                        : p.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _C.sub),
                  ),
                ],
              ),
            ),
            Text(
              p.online ? '在线' : '离线',
              style: TextStyle(
                fontSize: 12,
                color: p.online ? _C.green : const Color(0xFFAAAAAA),
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(
              height: 30,
              child: TextButton(
                onPressed: () => _connectPeer(p),
                style: TextButton.styleFrom(
                  backgroundColor: _C.blue.withOpacity(0.08),
                  foregroundColor: _C.blue,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5)),
                ),
                child: const Text('连接', style: TextStyle(fontSize: 12.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(List<Peer> list) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 2.1,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final p = list[i];
        return InkWell(
          onTap: () => _connectPeer(p),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _C.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    _avatar(p, size: 26),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.alias.isEmpty ? p.id : p.alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: _C.text),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  p.id,
                  style: const TextStyle(fontSize: 12, color: _C.sub),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _avatar(Peer p, {double size = 32}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: p.online
            ? _C.blue.withOpacity(0.1)
            : const Color(0xFFF0F0F0),
        shape: BoxShape.circle,
      ),
      child: Icon(
        p.platform.toLowerCase().contains('linux')
            ? Icons.terminal
            : Icons.desktop_windows_outlined,
        size: size * 0.55,
        color: p.online ? _C.blue : const Color(0xFF9E9E9E),
      ),
    );
  }

  // ---------------- 状态条 ----------------

  Widget _buildStatusBar() {
    return AnimatedBuilder(
      animation: gFFI.serverModel,
      builder: (context, _) {
        final ok = _localId.isNotEmpty;
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
                  color: ok ? _C.green : const Color(0xFFE0A100),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                ok ? '已连接安全加密链路' : '正在连接服务器…',
                style: const TextStyle(fontSize: 12.5, color: _C.sub),
              ),
              const Spacer(),
              Text(
                _localIp.isEmpty ? '' : '本机 IP $_localIp',
                style: const TextStyle(fontSize: 12, color: Color(0xFFAAAAAA)),
              ),
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

/// 设置页路由：原版是塞进 DesktopTabPage 的标签页里，我们换掉了整个首页，
/// 标签栏不存在，所以改成独立页面压栈，顶部自绘一条返回栏（无边框窗口没有系统标题栏）。
class SettingsRoute extends StatelessWidget {
  const SettingsRoute({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          _bar(context),
          Expanded(
            child: DesktopSettingPage(initialTabkey: SettingsTabKey.general),
          ),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) async {
        try {
          await windowManager.startDragging();
        } catch (_) {}
      },
      child: Container(
        height: 40,
        decoration: const BoxDecoration(
          color: _C.titleBg,
          border: Border(bottom: BorderSide(color: _C.line)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              borderRadius: BorderRadius.circular(6),
              child: const SizedBox(
                width: 30,
                height: 26,
                child: Icon(Icons.arrow_back,
                    size: 18, color: Color(0xFF616161)),
              ),
            ),
            const SizedBox(width: 6),
            const Text('设置',
                style: TextStyle(fontSize: 13.5, color: _C.text)),
            const Spacer(),
            _winBtn(Icons.remove, () async {
              try {
                await windowManager.minimize();
              } catch (_) {}
            }),
            _winBtn(Icons.close, () async {
              try {
                await windowManager.hide();
              } catch (_) {}
            }),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _winBtn(IconData icon, VoidCallback onTap) {
    return SizedBox(
      width: 34,
      height: 28,
      child: InkWell(
        onTap: onTap,
        child: Icon(icon, size: 14, color: const Color(0xFF616161)),
      ),
    );
  }
}
