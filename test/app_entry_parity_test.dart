import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ecohub_android/utils/server_config_manager.dart';
import 'package:ecohub_android/common/app_config.dart';
import 'package:ecohub_android/utils/history_manager.dart';
import 'package:ecohub_android/pages/splash_page.dart';
import 'package:ecohub_android/pages/main_scaffold_page.dart';
import 'package:ecohub_android/utils/source_guard.dart';
import 'package:ecohub_android/components/notice_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('built-in source overrides a previously saved source', () async {
    SharedPreferences.setMockInitialValues({
      'server_base_url': 'https://old.example.com/api',
    });
    await ServerConfigManager.instance.init();
    expect(await ServerConfigManager.instance.getServerUrl(), AppConfig.serverUrl);
    expect(ServerConfigManager.instance.provideKey, 'wan');
    expect(ServerConfigManager.instance.getApiBase(), 'https://tv.336824.xyz:666/api');
  });

  group('HistoryManager migrateLegacy Tests', () {
    test('migrates unscoped film_history to scoped key when scoped key is empty', () async {
      SharedPreferences.setMockInitialValues({
        'server_base_url': 'https://example.com/api',
        'film_history': jsonEncode({
          'item1': {
            'id': 'item1',
            'name': 'Test Movie',
            'picture': 'https://example.com/cover.jpg',
            'sourceId': 'src1',
            'sourceName': '源1',
            'episodeIndex': 0,
            'episode': 'EP1',
            'currentTime': 120.0,
            'duration': 3600.0,
            'timeStamp': 1700000000,
          }
        }),
      });

      await ServerConfigManager.instance.init();
      final scopedKey = ServerConfigManager.instance.scopedKey('film_history');
      expect(scopedKey, 'film_history@tv.336824.xyz:666');

      // Before migration
      final pref = ServerConfigManager.instance.preferences!;
      expect(pref.getString(scopedKey), isNull);
      expect(pref.getString('film_history'), isNotNull);

      // Run migration
      await HistoryManager.migrateLegacy();

      // After migration: scoped key has the data, legacy unscoped key removed
      expect(pref.getString(scopedKey), isNotNull);
      expect(pref.getString('film_history'), isNull);

      final list = await HistoryManager.list();
      expect(list.length, 1);
      expect(list.first.name, 'Test Movie');
      expect(list.first.id, 'item1');
    });

    test('migrates http/https protocol alias history to scoped key', () async {
      SharedPreferences.setMockInitialValues({
        'server_base_url': 'https://movie.demo.com/api',
        // Legacy entry saved under http origin
        'film_history@http://tv.336824.xyz:666': jsonEncode({
          'item2': {
            'id': 'item2',
            'name': 'HTTP Alias Movie',
            'picture': 'https://example.com/cover2.jpg',
            'sourceId': 'src2',
            'sourceName': '源2',
            'episodeIndex': 1,
            'episode': 'EP2',
            'currentTime': 240.0,
            'duration': 5400.0,
            'timeStamp': 1700000100,
          }
        }),
      });

      await ServerConfigManager.instance.init();
      final scopedKey = ServerConfigManager.instance.scopedKey('film_history');
      expect(scopedKey, 'film_history@tv.336824.xyz:666');

      final pref = ServerConfigManager.instance.preferences!;
      expect(pref.getString(scopedKey), isNull);
      expect(pref.getString('film_history@http://tv.336824.xyz:666'), isNotNull);

      await HistoryManager.migrateLegacy();

      expect(pref.getString(scopedKey), isNotNull);
      expect(pref.getString('film_history@http://tv.336824.xyz:666'), isNull);

      final item = await HistoryManager.find('item2');
      expect(item, isNotNull);
      expect(item!.name, 'HTTP Alias Movie');
    });
  });

  group('SplashPage Layout & Entry Pipeline Tests', () {
    testWidgets('SplashPage uses built-in source and opens server_config on connection failure', (tester) async {
      SharedPreferences.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: AppConfig.name,
        packageName: 'com.ecohub.ecohub',
        version: '1.1.5',
        buildNumber: '9',
        buildSignature: '',
      );
      await ServerConfigManager.instance.init();

      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/',
          routes: {
            '/': (_) => const SplashPage(),
            '/server_config': (_) => const Scaffold(body: Text('Server Config Page')),
          },
        ),
      );

      // Initial frame renders splash UI
      expect(find.text('余以为的小站'), findsOneWidget);
      expect(find.text('正在接入服务...'), findsOneWidget);

      // Let the built-in source probes fail under the test HTTP client.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();

      // Should have navigated to /server_config
      expect(find.text('Server Config Page'), findsOneWidget);
    });
  });

  group('MainScaffoldPage Notice Session Persistence Tests', () {
    testWidgets('Notice dialog dismissed in session is remembered', (tester) async {
      var dismissed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                NoticeDialog(
                  title: '站点公告',
                  content: '欢迎使用 EcoHub',
                  onClose: () {
                    dismissed = true;
                  },
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('站点公告'), findsOneWidget);
      expect(find.text('欢迎使用 EcoHub'), findsOneWidget);
      expect(find.text('我知道了'), findsOneWidget);

      // Click "我知道了"
      await tester.tap(find.text('我知道了'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
    });

    test('MainScaffoldPage resetNoticeSession and SourceGuard cooldown', () async {
      MainScaffoldPage.resetNoticeSession();
      SourceGuard.markReconnectedCooldown(const Duration(milliseconds: 50));
      expect(SourceGuard.skipCount, 1);
      SourceGuard.intercept();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(SourceGuard.skipCount, 0);
    });

    test('SourceGuard 重复进入 cooldown 不会累加 skipCount', () async {
      SourceGuard.markReconnectedCooldown(const Duration(milliseconds: 80));
      expect(SourceGuard.skipCount, 1);
      SourceGuard.markReconnectedCooldown(const Duration(milliseconds: 80));
      expect(SourceGuard.skipCount, 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(SourceGuard.skipCount, 0);
    });
  });
}
