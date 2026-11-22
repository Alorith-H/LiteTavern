import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:litetavern/services/storage.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
  });

  group('设置：必应（Azure 翻译）Key', () {
    test('默认留空', () {
      expect(AppSettings.azureTranslatorKey, '');
      expect(AppSettings.azureTranslatorRegion, '');
    });

    test('写入时去首尾空白，重新 init 后仍能读回', () async {
      AppSettings.azureTranslatorKey = '  abc-key  ';
      AppSettings.azureTranslatorRegion = ' eastasia ';
      expect(AppSettings.azureTranslatorKey, 'abc-key');
      expect(AppSettings.azureTranslatorRegion, 'eastasia');

      await AppSettings.init();
      expect(AppSettings.azureTranslatorKey, 'abc-key');
      expect(AppSettings.azureTranslatorRegion, 'eastasia');
    });

    test('清空即删除键（不会留下空字符串）', () async {
      AppSettings.azureTranslatorKey = 'abc';
      AppSettings.azureTranslatorKey = '   ';
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('azure_translator_key'), isNull);
      expect(AppSettings.azureTranslatorKey, '');
    });
  });
}
