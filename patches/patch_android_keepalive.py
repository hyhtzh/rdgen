# -*- coding: utf-8 -*-
"""【HyDesk】安卓远控端后台保活 + 新设备上线通知注入（2026-11-28）

在 generator-android.yml 的补丁段调用：
  python3 patch_android_keepalive.py .

完成 4 处注入（均幂等）：
1. 把 HyKeepAliveService.kt 拷到 flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/
2. AndroidManifest.xml 增加 <service> 声明
3. MainActivity.kt 的 initFlutterChannel 增加 start_keepalive / stop_keepalive 分支
4. license_page.dart 的 _check() 在 licensed 时通过 MethodChannel 拉起保活服务

凭证（token/machine_id/base）由 Dart 侧从 LicenseClient 读出，经 MethodChannel
传给 Kotlin 存入 SharedPreferences，Kotlin 服务独立跑 30s 心跳，不依赖 Dart 常驻。
"""
import os
import shutil
import sys

KT_SRC = 'HyKeepAliveService.kt'
KT_REL = os.path.join('flutter', 'android', 'app', 'src', 'main', 'kotlin',
                      'com', 'carriez', 'flutter_hbb', 'HyKeepAliveService.kt')
MANIFEST = os.path.join('flutter', 'android', 'app', 'src', 'main',
                        'AndroidManifest.xml')
MAIN_ACT = os.path.join('flutter', 'android', 'app', 'src', 'main', 'kotlin',
                        'com', 'carriez', 'flutter_hbb', 'MainActivity.kt')
LICENSE_PAGE = os.path.join('flutter', 'lib', 'desktop', 'pages',
                            'license_page.dart')
MARK = 'HyDeskKeepAlive'


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


def write(p, s):
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(s)


def patch_kt_file(root):
    """1) 拷贝 Kotlin 服务到源码树。"""
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), KT_SRC)
    if not os.path.isfile(src):
        # 兜底：workflow 里补丁脚本与 kt 模板同在仓库根
        src = os.path.join(root, KT_SRC)
    dst = os.path.join(root, KT_REL)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.isfile(dst) and MARK in read(dst):
        print('HyKeepAliveService.kt already in place')
        return
    if not os.path.isfile(src):
        raise SystemExit('HyKeepAliveService.kt template not found')
    shutil.copyfile(src, dst)
    print('copied HyKeepAliveService.kt -> source tree')


def patch_manifest(root):
    """2) Manifest 增加保活服务声明。"""
    p = os.path.join(root, MANIFEST)
    src = read(p)
    if 'HyKeepAliveService' in src:
        print('manifest keepalive service already patched')
        return
    anchor = '    </application>'
    if anchor not in src:
        raise SystemExit('manifest application close anchor not found')
    svc = ('        <!-- 【HyDesk】后台保活 + 设备上线通知 -->\n'
           '        <service\n'
           '            android:name=".HyKeepAliveService"\n'
           '            android:exported="false"\n'
           '            android:foregroundServiceType="dataSync" />\n')
    src = src.replace(anchor, svc + anchor, 1)
    # Android 14 (API 34) 起 dataSync 前台服务必须声明对应权限，否则启动崩溃
    if 'FOREGROUND_SERVICE_DATA_SYNC' not in src:
        perm_anchor = '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />'
        if perm_anchor in src:
            src = src.replace(
                perm_anchor,
                perm_anchor + '\n'
                '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />',
                1)
        else:
            # 兜底：找不到锚点就插到 <manifest> 后
            mi = src.find('<manifest')
            if mi >= 0:
                gt = src.find('>', mi)
                src = (src[:gt + 1] + '\n'
                       '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />'
                       + src[gt + 1:])
    write(p, src)
    print('patched manifest: HyKeepAliveService declared + DATA_SYNC permission')


def patch_main_activity(root):
    """3) MainActivity MethodChannel 增加 start_keepalive / stop_keepalive。"""
    p = os.path.join(root, MAIN_ACT)
    src = read(p)
    if 'start_keepalive' in src:
        print('MainActivity keepalive channel already patched')
        return
    anchor = '            when (call.method) {\n'
    if anchor not in src:
        raise SystemExit('MainActivity when(call.method) anchor not found')
    block = (
        '            when (call.method) {\n'
        '                // 【HyDesk】后台保活：由 Dart 传入授权凭证，Kotlin 独立心跳\n'
        '                "start_keepalive" -> {\n'
        '                    val m = call.arguments as? Map<*, *>\n'
        '                    val token = m?.get("token") as? String ?: ""\n'
        '                    val mid = m?.get("mid") as? String ?: ""\n'
        '                    val base = m?.get("base") as? String ?: ""\n'
        '                    HyKeepAliveService.start(context, token, mid, base)\n'
        '                    result.success(true)\n'
        '                }\n'
        '                "stop_keepalive" -> {\n'
        '                    HyKeepAliveService.stop(context)\n'
        '                    result.success(true)\n'
        '                }\n'
    )
    src = src.replace(anchor, block, 1)
    write(p, src)
    print('patched MainActivity: keepalive method channel added')


def patch_dart(root):
    """4) license_page _check() licensed 时拉起保活服务。"""
    p = os.path.join(root, LICENSE_PAGE)
    src = read(p)
    if MARK in src:
        print('license_page keepalive already patched')
        return
    anchor = ('  Future<void> _check() async {\n'
              '    final r = await LicenseClient.instance.check();\n'
              '    if (!mounted) return;\n')
    if anchor not in src:
        raise SystemExit('license_page _check anchor not found')
    new = (
        '  Future<void> _check() async {\n'
        '    final r = await LicenseClient.instance.check();\n'
        '    // 【HyDesk】' + MARK + '：授权有效时拉起后台保活（切后台仍在线 + 新设备上线通知）\n'
        '    if (r.status == LicenseStatus.licensed) {\n'
        '      try {\n'
        '        final mid = await LicenseClient.instance.machineId();\n'
        '        final tok = LicenseClient.instance.savedToken;\n'
        '        if (mid.isNotEmpty && tok.isNotEmpty) {\n'
        '          const ch = MethodChannel(\'mChannel\');\n'
        '          await ch.invokeMethod(\'start_keepalive\', <String, dynamic>{\n'
        '            \'token\': tok,\n'
        '            \'mid\': mid,\n'
        '            \'base\': kLicenseBase,\n'
        '          });\n'
        '        }\n'
        '      } catch (_) {}\n'
        '    }\n'
        '    if (!mounted) return;\n'
    )
    src = src.replace(anchor, new, 1)
    write(p, src)
    print('patched license_page: start keepalive on licensed')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    patch_kt_file(root)
    patch_manifest(root)
    patch_main_activity(root)
    patch_dart(root)


if __name__ == '__main__':
    main()
