/// Pantalla principal: tres pestañas espejo del dashboard de escritorio MSGQ.
///
///   * Consolas — la pestaña "AdaptMAC consoles": KPIs, filtro y lista
///     ordenada por gravedad.
///   * Entregas — la auditoria de deliveries: entregas sin confirmar y con
///     varianza medidor-vs-guia, las problematicas primero.
///   * SFL — sobrellenados (la alarma "Equipment Overfill" de AdaptIQ
///     reconstruida desde despachos × limites SFL).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../background/health_runner.dart';
import '../config/app_settings.dart';
import '../core/delivery_check.dart';
import '../core/health_check.dart';
import '../core/sfl_check.dart';
import '../core/util.dart';
import '../models/adapt_mac.dart';
import '../models/delivery.dart';
import '../notifications/notification_service.dart';
import '../state/providers.dart';
import 'reports_screen.dart';
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

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AdaptIQ Monitor'),
          actions: [
            IconButton(
              tooltip: 'Refrescar ahora',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.read(consolesProvider.notifier).refreshNow(),
            ),
            IconButton(
              tooltip: 'Reportes',
              icon: const Icon(Icons.summarize_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ReportsScreen()),
              ),
            ),
            IconButton(
              tooltip: 'Configuracion',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.dns_outlined), text: 'Consolas'),
            Tab(icon: Icon(Icons.local_shipping_outlined), text: 'Entregas'),
            Tab(icon: Icon(Icons.local_gas_station_outlined), text: 'SFL'),
          ]),
        ),
        body: !settings.isConfigured
            ? const _SetupPrompt()
            : board.when(
                data: (result) => Column(
                  children: [
                    _SyncBar(result: result, syncError: syncError),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                      child: TextField(
                        onChanged: (v) => setState(() => _filter = v),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Filtrar…',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    Expanded(
                      child: TabBarView(children: [
                        _ConsolesTab(
                          result: result,
                          filter: _filter,
                          staleAfter: settings.staleAfter,
                        ),
                        _DeliveriesTab(
                          result: result,
                          filter: _filter,
                          settings: settings,
                        ),
                        _OverfillTab(
                          result: result,
                          filter: _filter,
                          settings: settings,
                        ),
                      ]),
                    ),
                  ],
                ),
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => e is NotConfiguredException
                    ? const _SetupPrompt()
                    : _ErrorView(message: e.toString()),
              ),
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
              'monitorear las consolas y entregas del sitio.',
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

/// Franja LIVE / hora de actualizacion / banner de error compartida.
class _SyncBar extends StatelessWidget {
  const _SyncBar({required this.result, required this.syncError});

  final HealthCheckResult result;
  final String? syncError;

  @override
  Widget build(BuildContext context) {
    final live = syncError == null;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
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
        if (syncError != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
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

// ===========================================================================
// Pestaña Consolas
// ===========================================================================

class _ConsolesTab extends ConsumerWidget {
  const _ConsolesTab({
    required this.result,
    required this.filter,
    required this.staleAfter,
  });

  final HealthCheckResult result;
  final String filter;
  final Duration staleAfter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now().toUtc();
    final conditions =
        evaluateAll(result.consoles, staleAfter: staleAfter, now: now);

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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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

// ===========================================================================
// Pestaña Entregas
// ===========================================================================

class _DeliveriesTab extends ConsumerWidget {
  const _DeliveriesTab({
    required this.result,
    required this.filter,
    required this.settings,
  });

  final HealthCheckResult result;
  final String filter;
  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!settings.monitorDeliveries) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'El monitoreo de entregas esta desactivado.\n'
            'Activalo en Configuracion → Entregas.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final query = filter.trim().toLowerCase();
    final conditionsById = <String, Set<DeliveryCondition>>{
      for (final d in result.deliveries)
        d.id: conditionsForDelivery(d,
            thresholdPct: settings.varianceThresholdPct),
    };

    int rank(Delivery d) {
      final c = conditionsById[d.id] ?? const <DeliveryCondition>{};
      if (c.isEmpty) return 2;
      return c.contains(DeliveryCondition.unconfirmed) ||
              (d.deviationPct ?? 0) >= kDeliveryCriticalPct
          ? 0
          : 1;
    }

    final visible = result.deliveries.where((d) {
      if (query.isEmpty) return true;
      return '${d.label} ${d.tank ?? ''} ${d.product ?? ''} ${d.status ?? ''} ${d.company ?? ''}'
          .toLowerCase()
          .contains(query);
    }).toList()
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        final ta = a.collectedAt ?? a.updatedAt ?? DateTime(0);
        final tb = b.collectedAt ?? b.updatedAt ?? DateTime(0);
        return tb.compareTo(ta);
      });

    final unconfirmed = conditionsById.values
        .where((c) => c.contains(DeliveryCondition.unconfirmed))
        .length;
    final flaggedVariance = conditionsById.values
        .where((c) => c.contains(DeliveryCondition.highVariance))
        .length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Kpi(
                label: 'Entregas ${kDeliveryKeepDays}d',
                value: '${result.deliveries.length}',
                color: Colors.blue,
              ),
              _Kpi(
                label: 'Sin confirmar',
                value: '$unconfirmed',
                color: unconfirmed == 0 ? Colors.green : Colors.amber,
              ),
              _Kpi(
                label: 'Varianza ≥${settings.varianceThresholdPct.toStringAsFixed(settings.varianceThresholdPct % 1 == 0 ? 0 : 1)}%',
                value: '$flaggedVariance',
                color: flaggedVariance == 0 ? Colors.green : Colors.red,
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(consolesProvider.notifier).refreshNow(),
            child: visible.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 120),
                      Center(
                          child: Text(
                              'Sin entregas en la ventana local todavia.')),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visible.length,
                    itemBuilder: (context, i) => _DeliveryTile(
                      delivery: visible[i],
                      conditions:
                          conditionsById[visible[i].id] ?? const {},
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _DeliveryTile extends StatelessWidget {
  const _DeliveryTile({required this.delivery, required this.conditions});

  final Delivery delivery;
  final Set<DeliveryCondition> conditions;

  static final NumberFormat _litres = NumberFormat('#,##0.0');

  @override
  Widget build(BuildContext context) {
    final d = delivery;
    final critical = (d.deviationPct ?? 0) >= kDeliveryCriticalPct;
    final color = conditions.isEmpty
        ? Colors.green
        : conditions.contains(DeliveryCondition.unconfirmed) || critical
            ? Colors.red
            : Colors.orange;

    final volumes = (d.volume != null && d.secondaryVolume != null)
        ? 'Medido ${_litres.format(d.volume)} L / Guia ${_litres.format(d.secondaryVolume)} L'
        : d.volume != null
            ? 'Medido ${_litres.format(d.volume)} L'
            : null;
    final when = d.collectedAt;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.circle, size: 14, color: color),
        title: Row(
          children: [
            Flexible(
              child: Text(d.label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            if (d.isUnconfirmed) const _Badge('SIN CONFIRMAR', Colors.amber),
            if (conditions.contains(DeliveryCondition.highVariance))
              _Badge(
                '▼ ${d.deviationPct!.toStringAsFixed(2)}%',
                critical ? Colors.red : Colors.orange,
              ),
            if (conditions.isEmpty) const _Badge('OK', Colors.green),
          ],
        ),
        subtitle: Text(
          [
            if ((d.tank ?? '').isNotEmpty) d.tank!,
            if ((d.product ?? '').isNotEmpty) d.product!,
            if (volumes != null) volumes,
            if (when != null)
              DateFormat('dd/MM HH:mm').format(when.toLocal()),
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

// ===========================================================================
// Pestaña SFL (sobrellenados)
// ===========================================================================

class _OverfillTab extends ConsumerWidget {
  const _OverfillTab({
    required this.result,
    required this.filter,
    required this.settings,
  });

  final HealthCheckResult result;
  final String filter;
  final AppSettings settings;

  static final NumberFormat _litres = NumberFormat('#,##0.0');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!settings.monitorOverfill) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'El monitoreo de sobrellenados SFL esta desactivado.\n'
            'Activalo en Configuracion → Sobrellenados SFL.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final query = filter.trim().toLowerCase();
    final visible = result.overfills.where((o) {
      if (query.isEmpty) return true;
      return '${o.equipmentId} ${o.equipmentDescription ?? ''} ${o.product ?? ''} ${o.tank ?? ''} ${o.fieldUser ?? ''}'
          .toLowerCase()
          .contains(query);
    }).toList();

    final totalExcess =
        visible.fold<double>(0, (acc, o) => acc + o.excess);
    final mutedCount = visible
        .where((o) => settings.isSflProductMuted(o.product))
        .length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Kpi(
                label: 'Excesos ${kOverfillKeepDays}d',
                value: '${visible.length}',
                color: visible.isEmpty ? Colors.green : Colors.red,
              ),
              _Kpi(
                label: 'Exceso total',
                value: '${_litres.format(totalExcess)} L',
                color: totalExcess == 0 ? Colors.green : Colors.orange,
              ),
              if (mutedCount > 0)
                _Kpi(
                  label: 'Silenciados',
                  value: '$mutedCount',
                  color: Colors.blueGrey,
                ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(consolesProvider.notifier).refreshNow(),
            child: visible.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 120),
                      Center(
                          child: Text(
                              'Sin sobrellenados de SFL en la ventana local.')),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visible.length,
                    itemBuilder: (context, i) => _OverfillTile(
                      alert: visible[i],
                      muted:
                          settings.isSflProductMuted(visible[i].product),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _OverfillTile extends StatelessWidget {
  const _OverfillTile({required this.alert, required this.muted});

  final OverfillAlert alert;
  final bool muted;

  static final NumberFormat _litres = NumberFormat('#,##0.0');

  @override
  Widget build(BuildContext context) {
    final o = alert;
    final color = muted
        ? Colors.blueGrey
        : o.isCritical
            ? Colors.red
            : Colors.orange;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        dense: true,
        leading: Icon(
            muted ? Icons.notifications_off_outlined : Icons.local_gas_station,
            size: 18,
            color: color),
        title: Row(
          children: [
            Flexible(
              child: Text(o.equipmentId,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            _Badge('+${_litres.format(o.excess)} L', color),
            if (muted) const _Badge('SILENCIADO', Colors.blueGrey),
          ],
        ),
        subtitle: Text(
          [
            if ((o.equipmentDescription ?? '').isNotEmpty)
              o.equipmentDescription!,
            if ((o.product ?? '').isNotEmpty) o.product!,
            '${_litres.format(o.volume)} L vs SFL ${_litres.format(o.sfl)} L',
            if ((o.fieldUser ?? '').isNotEmpty) o.fieldUser!,
            if (o.collectedAt != null)
              DateFormat('dd/MM HH:mm').format(o.collectedAt!.toLocal()),
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
