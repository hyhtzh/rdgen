// 屏幕墙：把收藏夹里的受控端铺成网格，已保存密码的设备直接拉流做低帧预览。
// 未保存密码的设备只显示卡片，点击后走正常连接流程。
import 'package:flutter/material.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart';
import 'package:flutter_hbb/models/peer_model.dart';

const _kMaxTiles = 12;

class ScreenWallPage extends StatefulWidget {
  const ScreenWallPage({Key? key}) : super(key: key);

  @override
  State<ScreenWallPage> createState() => _ScreenWallPageState();
}

class _ScreenWallPageState extends State<ScreenWallPage> {
  int _columns = 3;
  bool _live = true;
  String _prevFps = '';

  @override
  void initState() {
    super.initState();
    bind.mainLoadFavPeers();
    // 墙页只需要低帧画面，压低帧率减少 CPU 占用；退出时恢复
    _prevFps = bind.mainGetUserDefaultOption(key: 'custom-fps');
    bind.mainSetUserDefaultOption(key: 'custom-fps', value: '2');
  }

  @override
  void dispose() {
    if (_prevFps.isNotEmpty) {
      bind.mainSetUserDefaultOption(key: 'custom-fps', value: _prevFps);
    }
    super.dispose();
  }

  List<Peer> get _peers {
    final all = gFFI.favoritePeersModel.peers;
    if (all.length <= _kMaxTiles) return all;
    return all.sublist(0, _kMaxTiles);
  }

  @override
  Widget build(BuildContext context) {
    final textColor =
        Theme.of(context).textTheme.titleLarge?.color ?? Colors.black87;
    return Scaffold(
      appBar: AppBar(
        title: const Text('屏幕墙', style: TextStyle(fontSize: 16)),
        centerTitle: false,
        toolbarHeight: 52,
        actions: [
          // 实时预览开关
          Row(
            children: [
              Text(
                '实时预览',
                style: TextStyle(fontSize: 12.5, color: textColor.withOpacity(0.6)),
              ),
              const SizedBox(width: 4),
              Switch(
                value: _live,
                onChanged: (v) => setState(() => _live = v),
              ),
              const SizedBox(width: 8),
            ],
          ),
          _columnsPicker(textColor),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () {
              bind.mainLoadFavPeers();
              setState(() {});
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AnimatedBuilder(
        animation: gFFI.favoritePeersModel,
        builder: (context, _) {
          final peers = _peers;
          if (peers.isEmpty) {
            return _buildEmpty(textColor);
          }
          return Padding(
            padding: const EdgeInsets.all(14),
            child: GridView.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 16 / 10.4,
              ),
              itemCount: peers.length,
              itemBuilder: (context, index) {
                final peer = peers[index];
                return _WallTile(
                  key: ValueKey('wall_${peer.id}'),
                  peer: peer,
                  live: _live && peer.password.isNotEmpty,
                  onOpen: () => connect(context, peer.id),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _columnsPicker(Color textColor) {
    return PopupMenuButton<int>(
      tooltip: '布局',
      initialValue: _columns,
      position: PopupMenuPosition.under,
      onSelected: (v) => setState(() => _columns = v),
      itemBuilder: (context) => const [
        PopupMenuItem(value: 2, child: Text('2 x 2')),
        PopupMenuItem(value: 3, child: Text('3 x 3')),
        PopupMenuItem(value: 4, child: Text('4 x 4')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_view_rounded,
                size: 18, color: textColor.withOpacity(0.7)),
            const SizedBox(width: 4),
            Text(
              '${_columns}x$_columns',
              style: TextStyle(fontSize: 12.5, color: textColor.withOpacity(0.7)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(Color textColor) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_border_rounded,
              size: 44, color: textColor.withOpacity(0.25)),
          const SizedBox(height: 12),
          Text(
            '收藏夹里还没有设备',
            style: TextStyle(fontSize: 14, color: textColor.withOpacity(0.6)),
          ),
          const SizedBox(height: 6),
          Text(
            '在首页连接一台设备后点「收藏」，它就会出现在屏幕墙上',
            style: TextStyle(fontSize: 12, color: textColor.withOpacity(0.4)),
          ),
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
        color: const Color(0xFF16181C),
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
                            color: peer.online
                                ? const Color(0xFF34C759)
                                : Colors.grey,
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
            color: const Color(0xFF1E2126),
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
                    color: widget.live
                        ? const Color(0xFF34C759)
                        : Colors.white38,
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
