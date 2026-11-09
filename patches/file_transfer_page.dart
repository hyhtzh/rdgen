// 文件传输（重新设计版）：不用原生界面，双栏自定义 UI + 拖动互传 + 后台传输 + 群发。
//
// 形态：FileTransferHost 常驻在主窗口的 Stack 里（Offstage 隐藏），关掉界面传输
// 继续跑 —— 这就是「后台文件传输」：会话 FFI、任务队列都不随页面销毁。
// 入口（主页菜单「传输文件」/ 设备右键 / 群发）都调 openSession()。
//
// 拖动互传：
//   · 从资源管理器拖文件进「对方」栏 → 上传到对方当前目录（desktop_drop）；
//   · 「本机」栏选中项拖到「对方」栏 → 上传；「对方」栏选中项拖到「本机」栏 → 下载；
//   · 栏头按钮同样支持上传/下载选中项（拖拽不便时的兜底）。
//
// 远程运行：对方栏选中 .exe →「远程运行」经授权服务指令通道下发，
// 对方客户端轮询校验时取到并在本地启动（受控端无需在线会话）。
import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/desktop/pages/license_client.dart';

// ---------------------------------------------------------------------------
// 颜色（与主页一致的浅色系）
// ---------------------------------------------------------------------------
class _C {
  static const bg = Color(0xFFF7F8FA);
  static const panel = Colors.white;
  static const line = Color(0xFFE8E8EC);
  static const sub = Color(0xFF8A8F99);
  static const accent = Color(0xFF2F6CF6);
  static const accentBg = Color(0xFFEEF3FF);
  static const ok = Color(0xFF2FA45C);
  static const danger = Color(0xFFE5484D);
  static const hover = Color(0xFFF3F5F9);
  static const dropMask = Color(0x332F6CF6);
}

String _fmtSize(double b) {
  if (b < 1024) return '${b.round()} B';
  if (b < 1024 * 1024) return '${b.toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) return '${b.toStringAsFixed(1)} MB';
  return '${b.toStringAsFixed(2)} GB';
}

String _jobStateText(JobProgress j) {
  switch (j.state) {
    case JobState.inProgress:
      return '传输中';
    case JobState.done:
      return (j.err == 'cancel') ? '已取消' : '已完成';
    case JobState.error:
      return '出错';
    case JobState.paused:
      return '已暂停';
    default:
      return '等待中';
  }
}

// ---------------------------------------------------------------------------
// 会话
// ---------------------------------------------------------------------------
class _FtSession {
  final String id; // 识别码（已去空格）
  final String password;
  String alias;
  late final FFI ffi;
  bool ready = false; // 远端目录已就绪
  bool failed = false;
  Timer? _watch;

  _FtSession(this.id, this.password, this.alias);

  FileModel get model => ffi.fileModel;

  void start(_FileTransferHostState host) {
    ffi = FFI(null);
    Get.put<FFI>(ffi, tag: 'ft_$id');
    ffi.dialogManager.setOverlayState(host.overlayKeyState);
    ffi.start(id,
        isFileTransfer: true,
        password: password.isEmpty ? null : password,
        forceRelay: false);
    // 轮询连接状态：远端目录出现 = 就绪；会话被关 = 失败
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (!ready &&
          model.remoteController.directory.value.path.isNotEmpty) {
        ready = true;
        host._tick();
      }
      if (!ready && !failed && ffi.closed) {
        failed = true;
        host._tick();
      }
    });
  }

  void dispose() {
    _watch?.cancel();
    try {
      model.close().whenComplete(() {
        ffi.close();
        Get.delete<FFI>(tag: 'ft_$id');
      });
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// 宿主：常驻 + 多会话标签 + 底部任务抽屉
// ---------------------------------------------------------------------------
class FileTransferHost extends StatefulWidget {
  final VoidCallback? onHide; // 「收进后台」按钮 → 主页收起浮球化
  const FileTransferHost({Key? key, this.onHide}) : super(key: key);

  static _FileTransferHostState? instance;

  /// 正在传输的任务数（主页浮球监听；static 保证宿主未建时也可安全监听）
  static final ValueNotifier<int> activeJobs = ValueNotifier<int>(0);

  @override
  State<FileTransferHost> createState() => _FileTransferHostState();
}

class _FileTransferHostState extends State<FileTransferHost> {
  final Map<String, _FtSession> _sessions = {};
  final List<String> _order = [];
  String? _cur;
  bool _drawerOpen = true;

  OverlayKeyState get overlayKeyState => _overlayKeyState;
  final _overlayKeyState = OverlayKeyState();

  Timer? _jobTicker;

  @override
  void initState() {
    super.initState();
    FileTransferHost.instance = this;
    _jobTicker = Timer.periodic(const Duration(seconds: 2), (_) {
      _updateActiveJobs();
    });
  }

  @override
  void dispose() {
    FileTransferHost.instance = null;
    _jobTicker?.cancel();
    for (final s in _sessions.values) {
      s.dispose();
    }
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
    _updateActiveJobs();
  }

  void _updateActiveJobs() {
    var n = 0;
    for (final s in _sessions.values) {
      try {
        n += s.model.jobController.jobTable
            .where((j) => j.state == JobState.inProgress)
            .length;
      } catch (_) {}
    }
    if (FileTransferHost.activeJobs.value != n) FileTransferHost.activeJobs.value = n;
  }

  _FtSession? sessionOf(String id) => _sessions[id.replaceAll(' ', '')];

  /// 打开（或聚焦）一个设备的传输会话
  void openSession(String id, {String? password, String? alias}) {
    final key = id.replaceAll(' ', '');
    if (key.isEmpty) return;
    if (_sessions.containsKey(key)) {
      setState(() => _cur = key);
      return;
    }
    final s = _FtSession(key, password ?? '', alias ?? key);
    _sessions[key] = s;
    _order.add(key);
    s.start(this);
    setState(() => _cur = key);
  }

  void closeSession(String key) {
    _sessions.remove(key)?.dispose();
    _order.remove(key);
    setState(() {
      if (_cur == key) _cur = _order.isEmpty ? null : _order.last;
    });
    _updateActiveJobs();
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(
      key: _overlayKeyState.key,
      initialEntries: [
        OverlayEntry(builder: (_) => _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    final s = _cur == null ? null : _sessions[_cur];
    return Container(
      color: _C.bg,
      child: Column(
        children: [
          _buildHeader(),
          Container(height: 1, color: _C.line),
          Expanded(
            child: s == null ? _buildEmpty() : _buildWorkArea(s),
          ),
          if (s != null) _buildDrawer(),
        ],
      ),
    );
  }

  // 顶栏：会话标签 + 收进后台
  Widget _buildHeader() {
    return Container(
      height: 42,
      color: _C.panel,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          const SizedBox(width: 4),
          for (final key in _order) _buildTab(key),
          const Spacer(),
          InkWell(
            onTap: widget.onHide,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _C.hover,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('收进后台 · 传输继续',
                  style: TextStyle(fontSize: 12, color: _C.sub)),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildTab(String key) {
    final s = _sessions[key]!;
    final sel = _cur == key;
    return InkWell(
      onTap: () => setState(() => _cur = key),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.only(left: 10),
        height: 30,
        decoration: BoxDecoration(
          color: sel ? _C.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: sel ? _C.accent : _C.line),
        ),
        child: Row(
          children: [
            Icon(
              s.ready
                  ? Icons.check_circle_outline
                  : (s.failed ? Icons.error_outline : Icons.hourglass_empty),
              size: 14,
              color: s.ready
                  ? _C.ok
                  : (s.failed ? _C.danger : _C.sub),
            ),
            const SizedBox(width: 5),
            Text(
              s.alias.isEmpty ? key : s.alias,
              style: TextStyle(
                  fontSize: 12,
                  color: sel ? _C.accent : _C.sub,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400),
            ),
            InkWell(
              onTap: () => closeSession(key),
              child: const Padding(
                padding: EdgeInsets.only(left: 6, right: 4),
                child: Icon(Icons.close, size: 13, color: _C.sub),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_open, size: 44, color: Color(0xFFC7CBD4)),
          const SizedBox(height: 10),
          const Text('还没有传输会话',
              style: TextStyle(fontSize: 14, color: _C.sub)),
          const SizedBox(height: 4),
          const Text('主页输入识别码 → 菜单「传输文件」，或设备右键「传输文件」',
              style: TextStyle(fontSize: 12, color: _C.sub)),
        ],
      ),
    );
  }

  Widget _buildWorkArea(_FtSession s) {
    if (s.failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 40, color: _C.sub),
            const SizedBox(height: 10),
            Text('连接 ${s.alias} 失败（识别码或密码错误 / 对方不在线）',
                style: const TextStyle(fontSize: 13, color: _C.sub)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                closeSession(s.id);
                openSession(s.id, password: s.password, alias: s.alias);
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (!s.ready) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: _C.accent),
        ),
      );
    }
    // 参考图样式：上下双栏 —— 远程目录在上、本机目录在下（Win7 经典布局），
    // 每栏带「标题 + 路径条 + 图标工具条」，盘符根目录平铺成瓷砖。
    return Column(
      children: [
        Expanded(flex: 11, child: _FilePane(session: s, isLocal: false)),
        Container(height: 1, color: _C.line),
        Expanded(flex: 9, child: _FilePane(session: s, isLocal: true)),
      ],
    );
  }

  // 底部任务抽屉（全部会话汇总）
  Widget _buildDrawer() {
    return Container(
      decoration: const BoxDecoration(
        color: _C.panel,
        border: Border(top: BorderSide(color: _C.line)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _drawerOpen = !_drawerOpen),
            child: SizedBox(
              height: 34,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(_drawerOpen
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up),
                  const SizedBox(width: 6),
                  const Text('传输任务',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<int>(
                    valueListenable: FileTransferHost.activeJobs,
                    builder: (_, n, __) => Text(
                      n > 0 ? '$n 个进行中' : '无进行中任务',
                      style: const TextStyle(fontSize: 12, color: _C.sub),
                    ),
                  ),
                  const Spacer(),
                  const Text('拖文件到对方栏即可上传',
                      style: TextStyle(fontSize: 11, color: _C.sub)),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
          _overallProgress(),
          if (_drawerOpen)
            Container(
              constraints: const BoxConstraints(maxHeight: 210),
              child: _buildJobList(),
            ),
        ],
      ),
    );
  }

  /// 全部会话的总进度条（参考图底部那条进度显示），无任务时不占位。
  Widget _overallProgress() {
    var sum = 0.0;
    var total = 0;
    for (final s in _sessions.values) {
      try {
        for (final j in s.model.jobController.jobTable) {
          if (j.state == JobState.inProgress) {
            total++;
            sum += j.percent;
          }
        }
      } catch (_) {}
    }
    if (total == 0) return const SizedBox.shrink();
    return Container(
      height: 3,
      color: const Color(0xFFEEF0F4),
      child: LinearProgressIndicator(
        value: sum / total,
        minHeight: 3,
        backgroundColor: Colors.transparent,
        valueColor: const AlwaysStoppedAnimation(_C.accent),
      ),
    );
  }

  Widget _buildJobList() {
    final rows = <Widget>[];
    for (final key in _order) {
      final s = _sessions[key]!;
      List<JobProgress> jobs;
      try {
        jobs = s.model.jobController.jobTable.toList();
      } catch (_) {
        jobs = [];
      }
      for (final j in jobs) {
        rows.add(_jobRow(s, j));
      }
    }
    if (rows.isEmpty) {
      return const SizedBox(
        height: 52,
        child: Center(
            child: Text('暂无任务',
                style: TextStyle(fontSize: 12, color: _C.sub))),
      );
    }
    return ListView(shrinkWrap: true, children: rows);
  }

  Widget _jobRow(_FtSession s, JobProgress j) {
    final running = j.state == JobState.inProgress;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFF2F2F4)))),
      child: Row(
        children: [
          Icon(
            j.isRemoteToLocal ? Icons.south_west : Icons.north_east,
            size: 16,
            color: j.isRemoteToLocal ? _C.ok : _C.accent,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(s.alias.isEmpty ? s.id : s.alias,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: _C.sub)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  j.fileName.isEmpty ? j.jobName : j.fileName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(
                    height: 4,
                    child: LinearProgressIndicator(
                      value: j.state == JobState.done ? 1 : j.percent,
                      minHeight: 4,
                      backgroundColor: const Color(0xFFEEF0F4),
                      valueColor:
                          const AlwaysStoppedAnimation(_C.accent),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 150,
            child: Text(
              running
                  ? '${_fmtSize(j.speed)}/s · ${j.percentText}'
                  : _jobStateText(j),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                color: j.state == JobState.done
                    ? _C.ok
                    : (j.state == JobState.error ? _C.danger : _C.sub),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (running || j.state == JobState.paused)
            InkWell(
              onTap: () {
                try {
                  s.model.jobController.cancelJob(j.id);
                } catch (_) {}
              },
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 14, color: _C.danger),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 单侧文件面板
// ---------------------------------------------------------------------------
class _FilePane extends StatefulWidget {
  final _FtSession session;
  final bool isLocal;
  const _FilePane({Key? key, required this.session, required this.isLocal})
      : super(key: key);

  @override
  State<_FilePane> createState() => _FilePaneState();
}

class _FilePaneState extends State<_FilePane> {
  bool _hovering = false; // 拖拽悬停高亮
  FileController get controller =>
      widget.isLocal ? widget.session.model.localController : widget.session.model.remoteController;

  _FileTransferHostState get _host =>
      FileTransferHost.instance as _FileTransferHostState;

  void _toast(String msg) {
    try {
      showToast(msg);
    } catch (_) {}
  }

  // ---- 上传/下载 ----

  /// OS 拖入（只能发生在“本机”来源）：把系统文件推到对方当前目录。
  /// 参数用 List<dynamic>：desktop_drop 不导出 XFile 类型，这里不显式引用。
  Future<void> _sendDroppedFiles(List<dynamic> files) async {
    if (files.isEmpty) return;
    final m = widget.session.model;
    final items = SelectedItems(isLocal: true);
    for (final f in files) {
      final name = (f.name as String?) ?? '';
      final path = (f.path as String?) ?? '';
      if (path.isEmpty) continue;
      final e = Entry();
      e.name = name.isEmpty ? path.split(RegExp(r'[\\/]')).last : name;
      e.path = path;
      final t = FileSystemEntity.typeSync(path);
      e.entryType = t == FileSystemEntityType.directory ? 1 : 4;
      items.add(e);
    }
    if (items.items.isEmpty) return;
    try {
      await m.localController
          .sendFiles(items, m.remoteController.directoryData());
      _toast('开始上传 ${items.items.length} 项到对方');
    } catch (e) {
      _toast('上传失败: $e');
    }
  }

  /// 面板间拖拽 / 按钮发送：把这一侧选中项发到对面
  Future<void> _sendSelection() async {
    final m = widget.session.model;
    final from = controller;
    final items = from.selectedItems;
    if (items.items.isEmpty) {
      _toast(widget.isLocal ? '先在本机栏选择要发送的文件' : '先在对方栏选择要下载的文件');
      return;
    }
    final other = widget.isLocal ? m.remoteController : m.localController;
    try {
      await from.sendFiles(items, other.directoryData());
    } catch (e) {
      _toast('传输失败: $e');
    }
  }

  /// 面板间拖拽落点：外来 Entry（可能不在选中集里）→ 选中并发送
  Future<void> _sendExternal(Entry entry) async {
    final m = widget.session.model;
    final from = controller;
    final items = from.selectedItems;
    if (!items.items.contains(entry)) {
      items.clear();
      items.add(entry);
    }
    final other = widget.isLocal ? m.remoteController : m.localController;
    try {
      await from.sendFiles(items, other.directoryData());
    } catch (e) {
      _toast('传输失败: $e');
    }
  }

  // ---- 远程运行 ----
  Future<void> _remoteRun(Entry entry) async {
    try {
      final r = await LicenseClient.instance
          .issueCommand(widget.session.id, 'run', payload: entry.path);
      if (r['ok'] == true) {
        _toast('已下发运行指令，对方联网后自动执行');
      } else {
        _toast((r['msg'] ?? '下发失败').toString());
      }
    } catch (e) {
      _toast('下发失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return Container(
      color: _C.panel,
      child: Column(
        children: [
          _buildHeader(s),
          Container(height: 1, color: _C.line),
          Expanded(child: _buildDropArea(s)),
        ],
      ),
    );
  }

  Widget _buildHeader(_FtSession s) {
    final isRemote = !widget.isLocal;
    return Container(
      height: 38,
      padding: const EdgeInsets.only(left: 10, right: 8),
      decoration: BoxDecoration(
        color: _C.panel,
        border: Border(
            bottom: BorderSide(
                color: isRemote ? _C.accentBg : _C.line, width: 1)),
      ),
      child: Row(
        children: [
          Icon(isRemote ? Icons.computer_outlined : Icons.desktop_windows,
              size: 15, color: isRemote ? _C.accent : _C.sub),
          const SizedBox(width: 5),
          Text(
            isRemote ? '远程目录 · ${s.alias}' : '本地目录',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isRemote ? _C.accent : Colors.black87),
          ),
          const SizedBox(width: 10),
          // 路径条：点击弹输入框跳转（参考图里的目录下拉）
          Expanded(child: _pathBar(s)),
          const SizedBox(width: 8),
          _hBtn(Icons.home_outlined, '主目录', () async {
            await controller.openDirectory(controller.homePath);
          }),
          _hBtn(Icons.arrow_upward, '上一级', () async {
            final cur = controller.directory.value.path;
            final parent = _parentOf(cur, controller.options.value.isWindows);
            if (parent != null && parent != cur) {
              await controller.openDirectory(parent);
            }
          }),
          _hBtn(Icons.refresh, '刷新', () async {
            await controller.openDirectory(controller.directory.value.path,
                isBack: true);
          }),
          if (isRemote) ...[
            _hBtn(Icons.play_arrow_rounded, '远程运行选中的 .exe', () => _runSelected()),
          ],
          const SizedBox(width: 6),
          InkWell(
            onTap: _sendSelection,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: widget.isLocal ? _C.accent : _C.ok,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                widget.isLocal ? '发送 →' : '← 下载',
                style: const TextStyle(
                    fontSize: 12, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 路径条：等宽字体显示当前目录，点击弹框跳转任意目录。
  Widget _pathBar(_FtSession s) {
    return Obx(() {
      final path = controller.directory.value.path;
      final label = path.isEmpty ? '根目录' : path;
      return InkWell(
        onTap: () => _jumpDialog(s, path),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _C.bg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: _C.line),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_outlined, size: 12, color: _C.sub),
              const SizedBox(width: 5),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace', color: _C.sub)),
              ),
              const Icon(Icons.keyboard_arrow_down, size: 14, color: _C.sub),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _jumpDialog(_FtSession s, String cur) async {
    final ctrl = TextEditingController(text: cur);
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.isLocal ? '跳转本地目录' : '跳转远程目录',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: r'例如 C:\Users 或 /home', isDense: true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _C.accent),
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('跳转')),
        ],
      ),
    );
    if (target is String && target.isNotEmpty) {
      try {
        await controller.openDirectory(target);
      } catch (_) {
        _toast('目录不存在或无法打开');
      }
    }
  }

  Future<void> _runSelected() async {
    final items = controller.selectedItems.items;
    final exes = items.where((e) => e.isFile && e.name.toLowerCase().endsWith('.exe')).toList();
    if (exes.isEmpty) {
      _toast('先在对方栏选择一个 .exe 程序');
      return;
    }
    for (final e in exes) {
      await _remoteRun(e);
    }
  }

  Widget _hBtn(IconData icon, String tip, Future<void> Function() onTap) {
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Icon(icon, size: 15, color: _C.sub),
        ),
      ),
    );
  }

  String? _parentOf(String path, bool isWin) {
    if (path.isEmpty) return null;
    var p = path;
    if (isWin) {
      // 盘符根（C:\ 或 C:）没有上级
      final r = RegExp(r'^[a-zA-Z]:\\?$');
      if (r.hasMatch(p)) return null;
      final i = p.lastIndexOf('\\');
      if (i <= 2) return p.substring(0, 3);
      return p.substring(0, i);
    }
    p = p.endsWith('/') && p.length > 1 ? p.substring(0, p.length - 1) : p;
    final i = p.lastIndexOf('/');
    if (i <= 0) return i == 0 ? '/' : null;
    return p.substring(0, i);
  }

  // 拖放区：OS 拖入（仅本机→对方方向）+ 面板间拖拽 + 点击浏览
  Widget _buildDropArea(_FtSession s) {
    return DropTarget(
      onDragDone: (detail) {
        // 只处理“拖到对方栏 = 上传”；拖到本机栏没有意义（文件本来就在本机）
        if (!widget.isLocal) {
          _sendDroppedFiles(detail.files);
        }
      },
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragUpdated: (_) {},
      child: DragTarget<Entry>(
        onWillAccept: (data) => data != null,
        onAccept: (entry) => _sendExternal(entry),
        builder: (context, _, __) {
          return Container(
            color: _hovering ? _C.dropMask : null,
            child: _buildList(s),
          );
        },
      ),
    );
  }

  Widget _buildList(_FtSession s) {
    return Obx(() {
      final dir = controller.directory.value;
      final entries = dir.entries;
      final selected = controller.selectedItems.items;
      if (entries.isEmpty && dir.path.isEmpty) {
        return const Center(
            child: Text('读取目录中…',
                style: TextStyle(fontSize: 12, color: _C.sub)));
      }
      // 盘符根目录（参考图样式）：平铺成大瓷砖，不再是窄列表行
      final allDrives = entries.isNotEmpty && entries.every((e) => e.isDrive);
      if (allDrives) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final e in entries) _driveTile(s, e),
            ],
          ),
        );
      }
      return ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, i) => _entryRow(s, entries[i], selected),
      );
    });
  }

  /// 盘符瓷砖：大图标 + 卷标，单击进入。
  Widget _driveTile(_FtSession s, Entry e) {
    return InkWell(
      onTap: () => controller.openDirectory(e.path),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 96,
        height: 84,
        decoration: BoxDecoration(
          color: _C.panel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _C.line),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.storage, size: 30, color: _C.sub),
            const SizedBox(height: 8),
            Text(e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.black87)),
          ],
        ),
      ),
    );
  }

  Widget _entryRow(_FtSession s, Entry e, List<Entry> selected) {
    final sel = selected.contains(e);
    final isRemote = !widget.isLocal;
    final isExe = e.isFile && e.name.toLowerCase().endsWith('.exe');
    return Draggable<Entry>(
      data: e,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade700,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_entryIcon(e), size: 14, color: Colors.white),
              const SizedBox(width: 5),
              Text(e.name,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white)),
            ],
          ),
        ),
      ),
      child: InkWell(
        onTap: () {
          if (e.isDrive || e.isDirectory) {
            controller.openDirectory(e.path);
          } else {
            controller.selectedItems.items.contains(e)
                ? controller.selectedItems.remove(e)
                : controller.selectedItems.add(e);
            // selectedItems 是 RxList，UI 会自动刷新
          }
        },
        onSecondaryTap: e.isFile && isRemote && isExe
            ? () => _remoteRun(e)
            : null,
        hoverColor: _C.hover,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: sel ? _C.accentBg : null,
          child: Row(
            children: [
              Icon(_entryIcon(e), size: 15,
                  color: e.isDirectory ? _C.accent : (e.isDrive ? _C.sub : _C.sub)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: sel ? _C.accent : Colors.black87,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
              if (isRemote && isExe)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: InkWell(
                    onTap: () => _remoteRun(e),
                    child: const Tooltip(
                      message: '远程运行（经授权服务下发）',
                      child: Icon(Icons.play_arrow_rounded,
                          size: 15, color: _C.ok),
                    ),
                  ),
                ),
              SizedBox(
                width: 72,
                child: Text(
                  e.isDrive
                      ? ''
                      : (e.isDirectory ? '文件夹' : _fmtSize(e.size.toDouble())),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 11, color: _C.sub),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  IconData _entryIcon(Entry e) {
    if (e.isDrive) return Icons.storage;
    if (e.isDirectory) return Icons.folder_outlined;
    if (e.name.toLowerCase().endsWith('.exe')) return Icons.apps;
    return Icons.insert_drive_file_outlined;
  }
}

// ---------------------------------------------------------------------------
// 群发：一份文件 → 多台设备
// ---------------------------------------------------------------------------
class _SendFile {
  final String name;
  final String path;
  final bool isDir;
  _SendFile(this.name, this.path, this.isDir);
}

Future<void> showGroupSendDialog(BuildContext context, List<Peer> peers) async {
  final files = <_SendFile>[];
  final sel = <String>{};
  final pathCtrl = TextEditingController();
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDg) {
        final online = peers;
        return AlertDialog(
          title: const Row(children: [
            Icon(Icons.campaign_outlined, size: 20, color: _C.accent),
            SizedBox(width: 8),
            Text('群发文件', style: TextStyle(fontSize: 16)),
          ]),
          content: SizedBox(
            width: 520,
            height: 440,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('① 要发送的文件（拖进来，或输入路径添加）',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                DropTarget(
                  onDragDone: (detail) {
                    for (final f in detail.files) {
                      if (files.any((x) => x.path == f.path)) continue;
                      final t = FileSystemEntity.typeSync(f.path);
                      files.add(_SendFile(
                          f.name, f.path, t == FileSystemEntityType.directory));
                    }
                    setDg(() {});
                  },
                  onDragEntered: (_) => setDg(() {}),
                  onDragExited: (_) => setDg(() {}),
                  child: Container(
                    height: 96,
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: files.isEmpty ? _C.line : _C.accent),
                      borderRadius: BorderRadius.circular(8),
                      color: _C.bg,
                    ),
                    child: files.isEmpty
                        ? const Center(
                            child: Text('把文件/文件夹拖到这里',
                                style:
                                    TextStyle(fontSize: 12, color: _C.sub)))
                        : ListView(
                            children: files
                                .map((f) => Row(
                                      children: [
                                        Icon(
                                            f.isDir
                                                ? Icons.folder_outlined
                                                : Icons.insert_drive_file_outlined,
                                            size: 15,
                                            color: _C.sub),
                                        const SizedBox(width: 6),
                                        Expanded(
                                            child: Text(f.path,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontSize: 12))),
                                        InkWell(
                                          onTap: () => setDg(
                                              () => files.remove(f)),
                                          child: const Icon(Icons.close,
                                              size: 14, color: _C.sub),
                                        ),
                                        const SizedBox(width: 6),
                                      ],
                                    ))
                                .toList(),
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: pathCtrl,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '或输入本机路径，如 D:\\资料\\手册.pdf',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton(
                      onPressed: () {
                        final p = pathCtrl.text.trim();
                        if (p.isEmpty) return;
                        final t = FileSystemEntity.typeSync(p);
                        if (t == FileSystemEntityType.notFound) {
                          showToast('路径不存在');
                          return;
                        }
                        if (files.any((x) => x.path == p)) return;
                        files.add(_SendFile(
                            p.split(RegExp(r'[\\/]')).last,
                            p,
                            t == FileSystemEntityType.directory));
                        pathCtrl.clear();
                        setDg(() {});
                      },
                      child: const Text('添加', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('② 发给哪些设备（发送到对方主目录）',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Text('已选 ${sel.length}/${online.length}',
                        style: const TextStyle(fontSize: 11, color: _C.sub)),
                    const Spacer(),
                    InkWell(
                      onTap: () => setDg(() {
                        if (sel.length == online.length) {
                          sel.clear();
                        } else {
                          sel
                            ..clear()
                            ..addAll(online.map((p) => p.id));
                        }
                      }),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        child: Row(
                          children: [
                            Icon(
                              online.isNotEmpty &&
                                      sel.length == online.length
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank,
                              size: 15,
                              color: online.isNotEmpty &&
                                      sel.length == online.length
                                  ? _C.accent
                                  : _C.sub,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              online.isNotEmpty &&
                                      sel.length == online.length
                                  ? '取消全选'
                                  : '全选',
                              style: const TextStyle(
                                  fontSize: 12, color: _C.accent),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: _C.line),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView(
                      children: online
                          .map((p) => InkWell(
                                onTap: () => setDg(() => sel.contains(p.id)
                                    ? sel.remove(p.id)
                                    : sel.add(p.id)),
                                child: Container(
                                  height: 34,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10),
                                  color: sel.contains(p.id)
                                      ? _C.accentBg
                                      : null,
                                  child: Row(
                                    children: [
                                      Icon(
                                        sel.contains(p.id)
                                            ? Icons.check_box
                                            : Icons
                                                .check_box_outline_blank,
                                        size: 16,
                                        color: sel.contains(p.id)
                                            ? _C.accent
                                            : _C.sub,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '${p.alias.isEmpty ? p.id : p.alias}（${p.id}）',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _C.accent),
              onPressed: () {
                if (files.isEmpty || sel.isEmpty) {
                  showToast(files.isEmpty ? '先添加要发送的文件' : '先勾选目标设备');
                  return;
                }
                Navigator.of(ctx).pop();
                _startGroupSend(files, sel.toList(), peers);
              },
              child: Text('开始群发（${sel.length} 台）'),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> _startGroupSend(
    List<_SendFile> files, List<String> ids, List<Peer> peers) async {
  final host = FileTransferHost.instance;
  if (host == null) {
    showToast('传输面板尚未就绪，请先打开一次「传输文件」');
    return;
  }
  showToast('开始群发 ${files.length} 个文件到 ${ids.length} 台设备');
  for (final id in ids) {
    Peer? p;
    for (final x in peers) {
      if (x.id.replaceAll(' ', '') == id) {
        p = x;
        break;
      }
    }
    host.openSession(id,
        password: p?.password ?? '', alias: (p != null && p.alias.isNotEmpty) ? p.alias : id);
    // 等远端目录就绪（最多 45s）再发，发送目标 = 对方主目录
    unawaited(() async {
      for (var i = 0; i < 90; i++) {
        final s = host.sessionOf(id);
        if (s == null) return;
        if (s.ready) break;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      final s = host.sessionOf(id);
      if (s == null || !s.ready) {
        showToast('$id 连接超时，跳过');
        return;
      }
      // 发送目标：优先 D:\群发文件，D 盘不可用时回退主目录
      await _switchGroupSendTarget(id, s);
      final items = SelectedItems(isLocal: true);
      for (final f in files) {
        final e = Entry();
        e.name = f.name;
        e.path = f.path;
        e.entryType = f.isDir ? 1 : 4;
        items.add(e);
      }
      try {
        await s.model.localController
            .sendFiles(items, s.model.remoteController.directoryData());
      } catch (e) {
        showToast('$id 发送失败: $e');
      }
    }());
  }
}

/// 群发落点：D:\群发文件（无则创建），D 盘不存在/无权限时保持主目录。
/// openDirectory 会真实读取远端目录并更新 currentDir，失败仅返回 false，
/// 不会弹错误框，适合无人值守链路。
Future<void> _switchGroupSendTarget(String id, _FtSession s) async {
  const target = r'D:\群发文件';
  const dRoot = r'D:\';
  final rc = s.model.remoteController;
  var rootOk = false;
  try {
    rootOk = await rc.openDirectory(dRoot);
  } catch (_) {}
  if (!rootOk) {
    // 对方没有 D 盘或拒绝访问：留在主目录
    return;
  }
  var dirOk = false;
  try {
    dirOk = await rc.openDirectory(target);
  } catch (_) {}
  if (!dirOk) {
    // 目录不存在：远端创建后重试一次（createDir 无回执，稍等）
    try {
      await rc.createDir(target);
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 600));
    try {
      dirOk = await rc.openDirectory(target);
    } catch (_) {}
  }
  // dirOk == false 时留在 D:\ 根目录（仍优于主目录散放）
}
