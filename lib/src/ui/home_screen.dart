/// Pantalla principal: la pestaña "AdaptMAC consoles" del dashboard de
/// escritorio MSGQ, en version movil — KPIs arriba, filtro de texto y la lista
/// de consolas ordenada por gravedad (las problematicas primero).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../background/health_runner.dart';
import '../core/health_check.dart';
import '../core/util.dart';
import '../models/adapt_mac.dart';
import '../notifications/notification_service.dart';
import '../state/providers.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String _filter = '';

  @override
  void initState() {
    super.initState();
    // Android 13+ / iOS piden el permiso de notificaciones en runtime.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => NotificationService.instance.requestPermissions(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final board = ref.watch(consolesProvider);
    final syncError = ref.watch(lastSyncErrorProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AdaptMAC consoles'),
        actions: [
          IconButton(
            tooltip: 'Refrescar ahora',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(consolesProvider.notifier).refreshNow(),
          ),
          IconButton(
            tooltip: 'Configuracion',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: !settings.isConfigured
          ? const _SetupPrompt()
          : board.when(
              data: (result) => _Board(
                result: result,
                syncError: syncError,
                filter: _filter,
                staleAfter: settings.staleAfter,
                onFilter: (v) => setState(() => _filter = v),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => e is NotConfiguredException
                  ? const _SetupPrompt()
                  : _ErrorView(message: e.toString()),
            ),
    );
  }
}

/// Sin token: guia al usuario a la configuracion en vez de mostrar un error.
class _SetupPrompt extends StatelessWidget {
  const _SetupPrompt();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.vpn_key_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              'Configura el token de la API de AdaptIQ para empezar a '
              'monitorear las consolas del sitio.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.settings),
              label: const Text('Abrir configuracion'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends ConsumerWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 56),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
              onPressed: () => ref.read(consolesProvider.notifier).refreshNow(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Board extends ConsumerWidget {
  const _Board({
    required this.result,
    required this.syncError,
    required this.filter,
    required this.staleAfter,
    required this.onFilter,
  });

  final HealthCheckResult result;
  final String? syncError;
  final String filter;
  final Duration staleAfter;
  final ValueChanged<String> onFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now().toUtc();
    final conditions = evaluateAll(result.consoles, staleAfter: staleAfter, now: now);

    final query = filter.trim().toLowerCase();
    final visible = result.consoles.where((c) {
      if (query.isEmpty) return true;
      return '${c.code} ${c.description ?? ''} ${c.site ?? ''}'
          .toLowerCase()
          .contains(query);
    }).toList()
      ..sort((a, b) {
        final bySeverity = severityRank(conditions[a.code] ?? const {})
            .compareTo(severityRank(conditions[b.code] ?? const {}));
        if (bySeverity != 0) return bySeverity;
        return naturalCompare(a.code, b.code);
      });

    final staleCount = conditions.values
        .where((c) => c.contains(ConsoleCondition.stale))
        .length;

    return Column(
      children: [
        _StatusHeader(
          result: result,
          staleCount: staleCount,
          syncError: syncError,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: TextField(
            onChanged: onFilter,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Filtrar por codigo, descripcion o sitio…',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(consolesProvider.notifier).refreshNow(),
            child: visible.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 120),
                      Center(child: Text('Sin consolas que mostrar.')),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visible.length,
                    itemBuilder: (context, i) => _ConsoleTile(
                      console: visible[i],
                      conditions: conditions[visible[i].code] ?? const {},
                      now: now,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({
    required this.result,
    required this.staleCount,
    required this.syncError,
  });

  final HealthCheckResult result;
  final int staleCount;
  final String? syncError;

  @override
  Widget build(BuildContext context) {
    final live = syncError == null;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Icon(Icons.circle, size: 12, color: live ? Colors.green : Colors.red),
              const SizedBox(width: 6),
              Text(live ? 'LIVE' : 'SIN CONEXION',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: live ? Colors.green : Colors.red,
                  )),
              const Spacer(),
              Text(
                'Actualizado ${DateFormat('HH:mm:ss').format(result.fetchedAt.toLocal())}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Kpi(
                label: 'En linea',
                value: '${result.onlineCount}/${result.total}',
                color: result.onlineCount == result.total
                    ? Colors.green
                    : Colors.orange,
              ),
              _Kpi(
                label: 'Offline',
                value: '${result.offlineCount}',
                color: result.offlineCount == 0 ? Colors.green : Colors.red,
              ),
              _Kpi(
                label: 'Bypass',
                value: '${result.bypassCount}',
                color: result.bypassCount == 0 ? Colors.green : Colors.red,
              ),
              if (staleCount > 0)
                _Kpi(label: 'Stale', value: '$staleCount', color: Colors.orange),
            ],
          ),
        ),
        if (syncError != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Mostrando el ultimo estado conocido — $syncError',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: color)),
          Text(value,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}

class _ConsoleTile extends StatelessWidget {
  const _ConsoleTile({
    required this.console,
    required this.conditions,
    required this.now,
  });

  final AdaptMac console;
  final Set<ConsoleCondition> conditions;
  final DateTime now;

  Color get _statusColor {
    if (conditions.contains(ConsoleCondition.keyBypass)) return Colors.purpleAccent;
    if (conditions.contains(ConsoleCondition.offline)) return Colors.red;
    if (conditions.contains(ConsoleCondition.stale)) return Colors.orange;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    final subtitleParts = <String>[
      if ((console.description ?? '').isNotEmpty) console.description!,
      if ((console.site ?? '').isNotEmpty) console.site!,
      if (console.lastSuccessfulComms != null)
        'Ult. com. ${relativeEs(console.lastSuccessfulComms!, now: now)}',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.circle, size: 14, color: _statusColor),
        title: Row(
          children: [
            Text(console.code,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            if (conditions.contains(ConsoleCondition.keyBypass))
              const _Badge('BYPASS', Colors.purpleAccent),
            if (conditions.contains(ConsoleCondition.offline))
              const _Badge('OFFLINE', Colors.red),
            if (conditions.contains(ConsoleCondition.stale))
              const _Badge('STALE', Colors.orange),
            if (conditions.isEmpty) const _Badge('ONLINE', Colors.green),
          ],
        ),
        subtitle: subtitleParts.isEmpty
            ? null
            : Text(subtitleParts.join(' · '),
                maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    );
  }
}
