// 控制端主页：左侧本机识别码/一次性密码，右侧远程连接 + 屏幕墙入口 + 收藏列表。
// 由 patch_client_ui.py 注入到 flutter/lib/desktop/pages/ 下，由 DesktopTabPage 在非被控端模式下使用。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/pages/screen_wall_page.dart';

const _kBrandUrl = 'https://rd.wh2028.cn';

class ClientHomePage extends StatefulWidget {
  const ClientHomePage({Key? key}) : super(key: key);

  @override
  State<ClientHomePage> createState() => _ClientHomePageState();
}

class _ClientHomePageState extends State<ClientHomePage> {
  final _idController = IDTextEditingController();
  final _idFocusNode = FocusNode();
  bool _showPwd = true;

  @override
  void initState() {
    super.initState();
    // 预载收藏列表，屏幕墙与下方收藏区共用这份数据
    bind.mainLoadFavPeers();
    _idFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _idController.dispose();
    _idFocusNode.dispose();
    super.dispose();
  }

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

  void _copy(String text) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    showToast(translate('Copied'));
  }

  void _doConnect() {
    final id = _idController.id;
    if (id.isEmpty) {
      showToast('请输入远程识别码');
      return;
    }
    connect(context, id);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildLeftPane(context),
        const VerticalDivider(width: 1),
        Expanded(child: _buildRightPane(context)),
      ],
    );
  }

  // ---------------- 左栏 ----------------

  Widget _buildLeftPane(BuildContext context) {
    final textColor =
        Theme.of(context).textTheme.titleLarge?.color ?? Colors.black87;
    return Container(
      width: 320,
      color: Theme.of(context).colorScheme.background,
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: _buildLogo()),
          const SizedBox(height: 28),
          _buildIdBlock(context, textColor),
          const SizedBox(height: 20),
          _buildPwdBlock(context, textColor),
          const SizedBox(height: 22),
          _buildNotice(textColor),
          const Spacer(),
          _buildLeftFooter(context, textColor),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: MyTheme.accent,
        borderRadius: BorderRadius.circular(15),
      ),
      child: const Icon(Icons.settings, color: Colors.white, size: 40),
    );
  }

  Widget _buildIdBlock(BuildContext context, Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.person_outline,
                size: 15, color: textColor.withOpacity(0.65)),
            const SizedBox(width: 5),
            Text(
              translate('Your Desktop'),
              style: TextStyle(fontSize: 13, color: textColor.withOpacity(0.65)),
            ),
            const Spacer(),
            _miniAction(
              icon: Icons.copy_rounded,
              label: '复制',
              onTap: () => _copy(_localId),
              color: textColor,
            ),
          ],
        ),
        const SizedBox(height: 7),
        Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: MyTheme.accent, width: 3),
            ),
          ),
          padding: const EdgeInsets.only(left: 10, top: 2),
          child: AnimatedBuilder(
            animation: gFFI.serverModel,
            builder: (context, _) {
              final id = _localId;
              return Text(
                id.isEmpty ? '...' : id,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: _fontSizeForId(id),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.6,
                  color: textColor,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  double _fontSizeForId(String id) {
    if (id.length > 12) return 22;
    if (id.length > 9) return 25;
    return 28;
  }

  Widget _buildPwdBlock(BuildContext context, Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.lock_outline,
                size: 15, color: textColor.withOpacity(0.65)),
            const SizedBox(width: 5),
            Text(
              translate('One-time password'),
              style: TextStyle(fontSize: 13, color: textColor.withOpacity(0.65)),
            ),
            const Spacer(),
            _miniAction(
              icon: _showPwd
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              label: _showPwd ? '隐藏' : '显示',
              onTap: () => setState(() => _showPwd = !_showPwd),
              color: textColor,
            ),
          ],
        ),
        const SizedBox(height: 7),
        Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: MyTheme.accent, width: 3),
            ),
          ),
          padding: const EdgeInsets.only(left: 10, top: 2),
          child: Row(
            children: [
              Expanded(
                child: AnimatedBuilder(
                  animation: gFFI.serverModel,
                  builder: (context, _) {
                    final pwd = _localPwd;
                    final shown =
                        _showPwd ? pwd : ('•' * (pwd.length.clamp(6, 12)));
                    return Text(
                      shown.isEmpty ? '...' : shown,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        letterSpacing: _showPwd ? 1.6 : 2.4,
                        color: textColor,
                      ),
                    );
                  },
                ),
              ),
              _miniAction(
                icon: Icons.copy_rounded,
                label: '复制',
                onTap: () => _copy(_localPwd),
                color: textColor,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _miniAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color.withOpacity(0.55)),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: color.withOpacity(0.55)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotice(Color textColor) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E3),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0xFFFFE1A8)),
      ),
      child: Text(
        '温馨提示：本软件仅用于本人所有或已获得所有者明确许可的设备。'
        '未经授权远程控制、监视他人电脑属于违法行为，一切后果由使用者自行承担。',
        style: TextStyle(
          fontSize: 12,
          height: 1.65,
          color: Color(0xFF8A6A24),
        ),
      ),
    );
  }

  Widget _buildLeftFooter(BuildContext context, Color textColor) {
    return Row(
      children: [
        AnimatedBuilder(
          animation: gFFI.serverModel,
          builder: (context, _) {
            final ok = gFFI.serverModel.connectStatus == 0;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: ok ? const Color(0xFF34C759) : const Color(0xFFFF9F0A),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  ok ? '就绪' : '连接中',
                  style:
                      TextStyle(fontSize: 12, color: textColor.withOpacity(0.5)),
                ),
              ],
            );
          },
        ),
        const Spacer(),
        IconButton(
          icon: Icon(Icons.settings_outlined,
              size: 18, color: textColor.withOpacity(0.5)),
          tooltip: translate('Settings'),
          onPressed: () {
            if (DesktopSettingPage.tabKeys.isNotEmpty) {
              DesktopSettingPage.switch2page(DesktopSettingPage.tabKeys[0]);
            }
          },
        ),
      ],
    );
  }

  // ---------------- 右栏 ----------------

  Widget _buildRightPane(BuildContext context) {
    final textColor =
        Theme.of(context).textTheme.titleLarge?.color ?? Colors.black87;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '控制远程桌面',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 12),
          _buildRemoteIdField(context, textColor),
          const SizedBox(height: 14),
          _buildActionRow(context),
          const SizedBox(height: 16),
          _buildTip(textColor),
          const SizedBox(height: 14),
          Divider(height: 1, color: textColor.withOpacity(0.08)),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.star_outline_rounded,
                  size: 16, color: textColor.withOpacity(0.55)),
              const SizedBox(width: 6),
              Text(
                '收藏的控端',
                style: TextStyle(
                  fontSize: 13,
                  color: textColor.withOpacity(0.55),
                ),
              ),
            ],
          ),
          Expanded(
            child: ChangeNotifierProvider.value(
              value: gFFI.peerTabModel,
              child: FavoritePeersView(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteIdField(BuildContext context, Color textColor) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _idFocusNode.hasFocus
              ? MyTheme.accent
              : textColor.withOpacity(0.18),
          width: _idFocusNode.hasFocus ? 1.6 : 1,
        ),
      ),
      child: Center(
        child: TextField(
          controller: _idController,
          focusNode: _idFocusNode,
          style: TextStyle(
            fontSize: 20,
            letterSpacing: 1.4,
            color: textColor,
          ),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: '输入远程识别码',
            hintStyle: TextStyle(
              fontSize: 16,
              letterSpacing: 0,
              color: textColor.withOpacity(0.35),
            ),
          ),
          onSubmitted: (_) => _doConnect(),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
  }

  Widget _buildActionRow(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _plainButton(
          icon: Icons.language,
          label: '官网',
          onTap: () => launchUrlString(_kBrandUrl),
        ),
        _plainButton(
          icon: Icons.grid_view_rounded,
          label: '屏幕墙',
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ScreenWallPage()),
            );
          },
        ),
        _primaryButton(
          label: '控制',
          icon: Icons.desktop_windows_outlined,
          onTap: _doConnect,
        ),
        _moreButton(context),
      ],
    );
  }

  Widget _plainButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 36,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 13.5)),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 36,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 13.5)),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2FA84F),
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  Widget _moreButton(BuildContext context) {
    return SizedBox(
      height: 36,
      child: PopupMenuButton<String>(
        tooltip: '更多',
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onSelected: (v) {
          final id = _idController.id;
          if (id.isEmpty) return;
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
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'file', child: Text('传输文件')),
          const PopupMenuItem(value: 'terminal', child: Text('终端 (beta)')),
          const PopupMenuItem(value: 'approval', child: Text('请求授权连接')),
        ],
        child: Container(
          width: 44,
          height: 36,
          decoration: BoxDecoration(
            border: Border.all(
              color:
                  (Theme.of(context).textTheme.titleLarge?.color ?? Colors.black)
                      .withOpacity(0.18),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Icon(Icons.keyboard_arrow_down, size: 20),
        ),
      ),
    );
  }

  Widget _buildTip(Color textColor) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E6),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        '安全提醒：连接前请确认对方已授权。若对方开启「需确认」，会弹出接受窗口；'
        '使用一次性密码连接后建议在对方设备上重置密码。',
        style: TextStyle(
          fontSize: 12,
          height: 1.65,
          color: const Color(0xFF8A6A24).withOpacity(0.95),
        ),
      ),
    );
  }
}
