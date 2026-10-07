import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/storage.dart';

/// 主题模式全局通知（设置页修改后即时生效）。
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(ThemeMode.system);

/// 主题色（seed）全局通知（设置页修改后即时生效，无需重启）。
final ValueNotifier<Color> themeSeedNotifier =
    ValueNotifier(const Color(0xFF8E4585));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Storage.init();
  await AppSettings.init();
  themeModeNotifier.value = switch (AppSettings.themeMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  themeSeedNotifier.value = Color(AppSettings.themeSeed);
  runApp(const LiteTavernApp());
}

class LiteTavernApp extends StatelessWidget {
  const LiteTavernApp({super.key});

  /// 主题对象缓存：seed × 亮度只构建一次，主题切换不重复 new ThemeData。
  static final Map<(Color, Brightness), ThemeData> _themeCache = {};

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return ValueListenableBuilder<Color>(
          valueListenable: themeSeedNotifier,
          builder: (context, seed, _) {
            return MaterialApp(
              title: 'LiteTavern',
              debugShowCheckedModeBanner: false,
              theme: _themeFor(seed, Brightness.light),
              darkTheme: _themeFor(seed, Brightness.dark),
              themeMode: mode,
              home: AppSettings.onboardingDone
                  ? const HomeScreen()
                  : const OnboardingScreen(),
            );
          },
        );
      },
    );
  }

  static ThemeData _themeFor(Color seed, Brightness brightness) {
    return _themeCache.putIfAbsent(
      (seed, brightness),
      () => _buildTheme(seed, brightness),
    );
  }

  static ThemeData _buildTheme(Color seed, Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        color: scheme.surfaceContainerLow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
    );
  }
}
