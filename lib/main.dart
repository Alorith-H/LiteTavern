import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/storage.dart';

// ---------------------------------------------------------- 设计令牌 --
// v0.5.0「克制编辑风」色板：排版驱动、去卡片堆砌、细线分隔。
// 所有页面共用这套精确值，不放任 M3 默认派生色（薰衣草等）。

/// 默认主题色 seed：赤陶酒红（编辑风、呼应酒馆）。
/// 仅在用户从未设置过主题色时生效，已有选择保留在 prefs。
const Color kDefaultSeed = Color(0xFF9C4632);

/// 浅色色板
const Color kLightBackground = Color(0xFFFAF9F6); // 暖纸白
const Color kLightSurface = Color(0xFFFFFFFF);
const Color kLightInk = Color(0xFF1C1B19); // 正文
const Color kLightSecondary = Color(0xFF6E6A63);

/// 深色色板
const Color kDarkBackground = Color(0xFF151412);
const Color kDarkSurface = Color(0xFF1E1C1A);
const Color kDarkInk = Color(0xFFEDEAE4);
const Color kDarkSecondary = Color(0xFF9A958C);

/// 分隔线（hairline）：浅色 = 正文 ink @ 8%，深色 = 白 @ 10%。
Color hairlineColor(Brightness brightness) => brightness == Brightness.light
    ? kLightInk.withValues(alpha: 0.08)
    : const Color(0xFFFFFFFF).withValues(alpha: 0.10);

/// 主题模式全局通知（设置页修改后即时生效）。
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier(ThemeMode.system);

/// 主题色（seed）全局通知（设置页修改后即时生效，无需重启）。
final ValueNotifier<Color> themeSeedNotifier = ValueNotifier(kDefaultSeed);

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
              theme: buildTheme(Brightness.light, seed),
              darkTheme: buildTheme(Brightness.dark, seed),
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
}

/// 主题对象缓存：亮度 × seed 只构建一次，切换不重复 new ThemeData。
final Map<(Brightness, Color), ThemeData> _themeCache = {};

/// 主题构造（main.dart 集中）：M3 `ColorScheme.fromSeed` 派生强调色，
/// 但 background/surface/outline/onSurface 等色板值强制覆写为设计令牌
/// 的精确值——浅/暗默认值即新色板，不使用 M3 默认派生的表面色。
ThemeData buildTheme(Brightness brightness, Color seed) =>
    _themeCache.putIfAbsent((brightness, seed), () {
      final light = brightness == Brightness.light;
      final background = light ? kLightBackground : kDarkBackground;
      final surface = light ? kLightSurface : kDarkSurface;
      final ink = light ? kLightInk : kDarkInk;
      final secondary = light ? kLightSecondary : kDarkSecondary;
      final hairline = hairlineColor(brightness);

      final scheme =
          ColorScheme.fromSeed(seedColor: seed, brightness: brightness)
              .copyWith(
        surface: surface,
        onSurface: ink,
        onSurfaceVariant: secondary,
        outline: hairline,
        outlineVariant: hairline,
      );

      return ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: background,
        // 页面标题 20sp w700；顶栏 surface 底、无阴影
        appBarTheme: AppBarTheme(
          backgroundColor: surface,
          foregroundColor: ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          iconTheme: IconThemeData(color: ink, size: 22),
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
        ),
        // 全局返回键换描边族
        actionIconTheme: ActionIconThemeData(
          backButtonIconBuilder: (_) =>
              const Icon(Icons.arrow_back_outlined, size: 22),
          closeButtonIconBuilder: (_) =>
              const Icon(Icons.close_outlined, size: 22),
        ),
        // 细线分隔（组件内用 Divider，默认即 hairline）
        dividerTheme: DividerThemeData(color: hairline, thickness: 1),
        // 输入框：面板圆角 10、hairline 描边、聚焦 accent 细线
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: background,
          hintStyle: TextStyle(fontSize: 14, color: secondary),
          labelStyle: TextStyle(fontSize: 14, color: secondary),
          helperStyle: TextStyle(fontSize: 13, color: secondary),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: hairline),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: hairline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: scheme.primary, width: 1.4),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          elevation: 0,
        ),
        // chip 胶囊
        chipTheme: ChipThemeData(
          shape: const StadiumBorder(),
          side: BorderSide(color: hairline),
        ),
        // 面板/对话框：圆角 10、无阴影
        dialogTheme: DialogThemeData(
          elevation: 0,
          backgroundColor: surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: hairline),
          ),
        ),
        bottomSheetTheme: BottomSheetThemeData(
          elevation: 0,
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
          ),
        ),
        // FAB tonal：accent 10% 底 + accent 图标，无阴影
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          elevation: 0,
          highlightElevation: 0,
          backgroundColor: scheme.primary.withValues(alpha: 0.10),
          foregroundColor: scheme.primary,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            side: BorderSide(color: secondary),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
        ),
      );
    });
