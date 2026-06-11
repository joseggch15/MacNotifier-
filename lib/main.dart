/// adaptMacNotifier — monitor movil de salud de consolas AdaptMAC.
///
/// Cliente "standalone" (pull-based) contra la API GraphQL de AdaptIQ del
/// sitio Merian: sin servidor intermedio. Companion movil de la pestaña
/// "AdaptMAC consoles" del dashboard de escritorio MSGQ.
///
///   * App abierta: polling cada 20 s (configurable).
///   * App cerrada: Workmanager cada 15-30 min (Android) / Background Fetch (iOS).
///   * Solo las TRANSICIONES de estado notifican (sin duplicados).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/background/background_scheduler.dart';
import 'src/notifications/notification_service.dart';
import 'src/state/providers.dart';
import 'src/storage/app_store.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore(await SharedPreferences.getInstance());
  await NotificationService.instance.init();
  await BackgroundScheduler.init();
  // Alinea la tarea periodica con la configuracion vigente en cada arranque
  // (si aun no hay token, la cancela).
  await BackgroundScheduler.sync(store.loadSettings());
  runApp(
    ProviderScope(
      overrides: [appStoreProvider.overrideWithValue(store)],
      child: const AdaptMacNotifierApp(),
    ),
  );
}

class AdaptMacNotifierApp extends StatelessWidget {
  const AdaptMacNotifierApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Tema oscuro para hermanar con el dashboard de escritorio MSGQ.
    return MaterialApp(
      title: 'AdaptMAC Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E6FD9),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
