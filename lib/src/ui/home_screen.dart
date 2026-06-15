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
import '../core/unauthorised_check.dart';
import '../core/util.dart';
import '../i18n/l10n.dart';
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
    final l = L10n(settings.languageCode);

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AdaptIQ Monitor'),
          actions: [
            IconButton(
              tooltip: l.t('Refrescar ahora', 'Refresh now'),
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.read(consolesProvider.notifier).refreshNow();
                ref.invalidate(unauthorisedViewProvider);
              },
            ),
            IconButton(
              tooltip: l.t('Reportes', 'Reports'),
              icon: const Icon(Icons.summarize_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ReportsScreen()),
              ),
            ),
            IconButton(
              tooltip: l.t('Configuracion', 'Settings'),
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
            ),
          ],
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(
                icon: const Icon(Icons.dns_outlined),
                text: l.t('Consolas', 'Consoles')),
            Tab(
                icon: const Icon(Icons.local_shipping_outlined),
                text: l.t('Entregas', 'Deliveries')),
            const Tab(icon: Icon(Icons.local_gas_station_outlined), text: 'SFL'),
            Tab(
                icon: const Icon(Icons.gpp_maybe_outlined),
                text: l.t('Sin ID', 'No ID')),
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
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search),
                          hintText: l.t('Filtrar…', 'Filter…'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    Expanded(
                      child: TabBarView(children: [
                        _ConsolesTab(
                          result: result,
                          filter: _filter,
                          settings: settings,
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
                        _UnauthorisedTab(
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
class _SetupPrompt extends ConsumerWidget {
  const _SetupPrompt();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L10n(ref.watch(settingsProvider).languageCode);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.vpn_key_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              l.t(
                  'Configura el token de la API de AdaptIQ para empezar a '
                      'monitorear las consolas y entregas del sitio.',
                  'Configure the AdaptIQ API token to start monitoring the '
                      'site consoles and deliveries.'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.settings),
              label: Text(l.t('Abrir configuracion', 'Open settings')),
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
    final l = L10n(ref.watch(settingsProvider).languageCode);
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
              label: Text(l.t('Reintentar', 'Retry')),
              onPressed: () => ref.read(consolesProvider.notifier).refreshNow(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Franja LIVE / hora de actualizacion / banner de error compartida.
class _SyncBar extends ConsumerWidget {
  const _SyncBar({required this.result, required this.syncError});

  final HealthCheckResult result;
  final String? syncError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L10n(ref.watch(settingsProvider).languageCode);
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
              Text(live ? 'LIVE' : l.t('SIN CONEXION', 'OFFLINE'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: live ? Colors.green : Colors.red,
                  )),
              const Spacer(),
              Text(
                '${l.t('Actualizado', 'Updated')} '
                '${DateFormat('HH:mm:ss').format(result.fetchedAt.toLocal())}',
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
              '${l.t('Mostrando el ultimo estado conocido', 'Showing the last known state')} — $syncError',
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
    required this.settings,
  });

  final HealthCheckResult result;
  final String filter;
  final AppSettings settings;

  /// Alterna el silenciado de UN MAC y lo persiste de inmediato (la campana
  /// del tile): sin pasar por la pantalla de configuracion.
  void _toggleMute(WidgetRef ref, String code) {
    final s = ref.read(settingsProvider);
    final muted = {...s.mutedConsoles};
    if (!muted.add(code)) muted.remove(code);
    ref
        .read(settingsProvider.notifier)
        .save(s.copyWith(mutedConsoles: muted.toList()..sort()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L10n(settings.languageCode);
    final now = DateTime.now().toUtc();
    final conditions =
        evaluateAll(result.consoles, staleAfter: settings.staleAfter, now: now);

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
                label: l.t('En linea', 'Online'),
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
                    children: [
                      const SizedBox(height: 120),
                      Center(
                          child: Text(l.t('Sin consolas que mostrar.',
                              'No consoles to show.'))),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visible.length,
                    itemBuilder: (context, i) => _ConsoleTile(
                      console: visible[i],
                      conditions: conditions[visible[i].code] ?? const {},
                      now: now,
                      l: l,
                      muted: settings.isConsoleMuted(visible[i].code),
                      onToggleMute: () => _toggleMute(ref, visible[i].code),
                      offlineSince: result.offlineSince[visible[i].code],
                      alarmAfter: settings.offlineAlarmAfter,
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
    required this.l,
    required this.muted,
    required this.onToggleMute,
    this.offlineSince,
    required this.alarmAfter,
  });

  final AdaptMac console;
  final Set<ConsoleCondition> conditions;
  final DateTime now;
  final L10n l;

  /// Notificaciones de ESTE MAC apagadas (la consola se sigue mostrando).
  final bool muted;
  final VoidCallback onToggleMute;

  /// Instante en que el monitor vio la consola OFFLINE por primera vez (para
  /// "lleva N min sin conexion" y la alarma de caida prolongada).
  final DateTime? offlineSince;
  final Duration alarmAfter;

  bool get _isOffline => conditions.contains(ConsoleCondition.offline);

  /// Duracion de la caida actual (si la consola esta offline y se conoce el
  /// inicio); null en cualquier otro caso.
  Duration? get _offlineFor {
    if (!_isOffline || offlineSince == null) return null;
    final d = now.difference(offlineSince!);
    return d.isNegative ? Duration.zero : d;
  }

  /// La caida ya cruzo el umbral de alarma "estilo despertador".
  bool get _alarming {
    final d = _offlineFor;
    return d != null && d >= alarmAfter;
  }

  Color get _statusColor {
    if (conditions.contains(ConsoleCondition.keyBypass)) return Colors.purpleAccent;
    if (conditions.contains(ConsoleCondition.offline)) return Colors.red;
    if (conditions.contains(ConsoleCondition.stale)) return Colors.orange;
    return Colors.green;
  }

  /// "32 min" / "2 h 5 min" — duracion compacta de la caida.
  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h <= 0) return l.t('$m min', '$m min');
    return l.t('$h h $m min', '$h h $m min');
  }

  @override
  Widget build(BuildContext context) {
    final relative = l.isEn ? relativeEn : relativeEs;
    final offlineFor = _offlineFor;
    final subtitleParts = <String>[
      if ((console.description ?? '').isNotEmpty) console.description!,
      if ((console.site ?? '').isNotEmpty) console.site!,
      if (offlineFor != null)
        l.t('sin conexion hace ${_fmtDuration(offlineFor)}',
            'offline for ${_fmtDuration(offlineFor)}')
      else if (console.lastSuccessfulComms != null)
        '${l.t('Ult. com.', 'Last comms')} '
            '${relative(console.lastSuccessfulComms!, now: now)}',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: _alarming
          ? RoundedRectangleBorder(
              side: const BorderSide(color: Colors.red, width: 1.5),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: ListTile(
        dense: true,
        leading: Icon(
            _alarming ? Icons.alarm : Icons.circle,
            size: _alarming ? 18 : 14,
            color: _statusColor),
        title: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 2,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(console.code,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (conditions.contains(ConsoleCondition.keyBypass))
              const _Badge('BYPASS', Colors.purpleAccent),
            if (conditions.contains(ConsoleCondition.offline))
              const _Badge('OFFLINE', Colors.red),
            if (conditions.contains(ConsoleCondition.stale))
              const _Badge('STALE', Colors.orange),
            if (conditions.isEmpty) const _Badge('ONLINE', Colors.green),
            if (_alarming && offlineFor != null)
              _Badge('⏰ ${_fmtDuration(offlineFor).toUpperCase()}', Colors.red),
            if (muted) _Badge(l.t('SILENCIADO', 'MUTED'), Colors.blueGrey),
          ],
        ),
        subtitle: subtitleParts.isEmpty
            ? null
            : Text(subtitleParts.join(' · '),
                maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          tooltip: muted
              ? l.t('Reactivar notificaciones de ${console.code}',
                  'Unmute ${console.code} notifications')
              : l.t('Silenciar notificaciones de ${console.code}',
                  'Mute ${console.code} notifications'),
          icon: Icon(
            muted
                ? Icons.notifications_off_outlined
                : Icons.notifications_active_outlined,
            size: 20,
            color: muted ? Colors.blueGrey : null,
          ),
          onPressed: onToggleMute,
        ),
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
    final l = L10n(settings.languageCode);
    if (!settings.monitorDeliveries) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l.t(
                'El monitoreo de entregas esta desactivado.\n'
                    'Activalo en Configuracion → Entregas.',
                'Delivery monitoring is disabled.\n'
                    'Enable it in Settings → Deliveries.'),
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
                label: l.t('Entregas ${kDeliveryKeepDays}d',
                    'Deliveries ${kDeliveryKeepDays}d'),
                value: '${result.deliveries.length}',
                color: Colors.blue,
              ),
              _Kpi(
                label: l.t('Sin confirmar', 'Unconfirmed'),
                value: '$unconfirmed',
                color: unconfirmed == 0 ? Colors.green : Colors.amber,
              ),
              _Kpi(
                label:
                    '${l.t('Varianza', 'Variance')} ≥${settings.varianceThresholdPct.toStringAsFixed(settings.varianceThresholdPct % 1 == 0 ? 0 : 1)}%',
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
                    children: [
                      const SizedBox(height: 120),
                      Center(
                          child: Text(l.t(
                              'Sin entregas en la ventana local todavia.',
                              'No deliveries in the local window yet.'))),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visible.length,
                    itemBuilder: (context, i) => _DeliveryTile(
                      delivery: visible[i],
                      conditions:
                          conditionsById[visible[i].id] ?? const {},
                      l: l,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _DeliveryTile extends StatelessWidget {
  const _DeliveryTile({
    required this.delivery,
    required this.conditions,
    required this.l,
  });

  final Delivery delivery;
  final Set<DeliveryCondition> conditions;
  final L10n l;

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
        ? l.t(
            'Medido ${_litres.format(d.volume)} L / Guia ${_litres.format(d.secondaryVolume)} L',
            'Metered ${_litres.format(d.volume)} L / Docket ${_litres.format(d.secondaryVolume)} L')
        : d.volume != null
            ? l.t('Medido ${_litres.format(d.volume)} L',
                'Metered ${_litres.format(d.volume)} L')
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
            if (d.isUnconfirmed)
              _Badge(l.t('SIN CONFIRMAR', 'UNCONFIRMED'), Colors.amber),
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
    final l = L10n(settings.languageCode);
    if (!settings.monitorOverfill) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l.t(
                'El monitoreo de sobrellenados SFL esta desactivado.\n'
                    'Activalo en Configuracion → Sobrellenados SFL.',
                'SFL overfill monitoring is disabled.\n'
                    'Enable it in Settings → SFL overfills.'),
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
                label: l.t('Excesos ${kOverfillKeepDays}d',
                    'Overfills ${kOverfillKeepDays}d'),
                value: '${visible.length}',
                color: visible.isEmpty ? Colors.green : Colors.red,
              ),
              _Kpi(
                label: l.t('Exceso total', 'Total excess'),
                value: '${_litres.format(totalExcess)} L',
                color: totalExcess == 0 ? Colors.green : Colors.orange,
              ),
              if (mutedCount > 0)
                _Kpi(
                  label: l.t('Silenciados', 'Muted'),
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
                    children: [
                      const SizedBox(height: 120),
                      Center(
                          child: Text(l.t(
                              'Sin sobrellenados de SFL en la ventana local.',
                              'No SFL overfills in the local window.'))),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visible.length,
                    itemBuilder: (context, i) => _OverfillTile(
                      alert: visible[i],
                      muted:
                          settings.isSflProductMuted(visible[i].product),
                      l: l,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _OverfillTile extends StatelessWidget {
  const _OverfillTile({
    required this.alert,
    required this.muted,
    required this.l,
  });

  final OverfillAlert alert;
  final bool muted;
  final L10n l;

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
            if (muted) _Badge(l.t('SILENCIADO', 'MUTED'), Colors.blueGrey),
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

// ===========================================================================
// Pestaña Sin ID (despachos UNAUTHORISED sin equipo asignado)
// ===========================================================================

class _UnauthorisedTab extends ConsumerWidget {
  const _UnauthorisedTab({
    required this.filter,
    required this.settings,
  });

  final String filter;
  final AppSettings settings;

  static final NumberFormat _litres = NumberFormat('#,##0.0');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L10n(settings.languageCode);
    if (!settings.monitorUnauthorised) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            l.t(
                'El monitoreo de despachos no autorizados esta desactivado.\n'
                    'Activalo en Configuracion → Despachos sin ID.',
                'Unauthorised dispense monitoring is disabled.\n'
                    'Enable it in Settings → Dispenses without ID.'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final period = ref.watch(unauthPeriodProvider);
    final viewAsync = ref.watch(unauthorisedViewProvider);

    return Column(
      children: [
        // Selector de segmento temporal (All/Diario/Semanal/Mensual/Anual),
        // inspirado en las ventanas de Reportes/SFL/Entregas.
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              for (final p in UnauthPeriod.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.label(l)),
                    selected: p == period,
                    onSelected: (_) =>
                        ref.read(unauthPeriodProvider.notifier).state = p,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: viewAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _ErrorView(message: e.toString()),
            data: (all) => _buildList(context, ref, l, period, all),
          ),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, L10n l,
      UnauthPeriod period, List<UnauthorisedTxn> all) {
    final query = filter.trim().toLowerCase();
    final visible = all.where((t) {
      if (query.isEmpty) return true;
      return '${t.lane ?? ''} ${t.product ?? ''} ${t.fieldUser ?? ''} ${t.adaptMac ?? ''}'
          .toLowerCase()
          .contains(query);
    }).toList();

    final totalVolume =
        visible.fold<double>(0, (acc, t) => acc + (t.volume ?? 0));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Kpi(
                label: '${l.t('Sin ID', 'Without ID')} · ${period.label(l)}',
                value: '${visible.length}',
                color: visible.isEmpty ? Colors.green : Colors.red,
              ),
              _Kpi(
                label: l.t('Volumen sin asignar', 'Unassigned volume'),
                value: '${_litres.format(totalVolume)} L',
                color: totalVolume == 0 ? Colors.green : Colors.orange,
              ),
              _Kpi(
                label: l.t('Lanes', 'Lanes'),
                value: '${settings.unauthorisedLanes.length}',
                color: Colors.blue,
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(unauthorisedViewProvider);
              await ref.read(unauthorisedViewProvider.future);
            },
            child: visible.isEmpty
                ? ListView(
                    children: [
                      const SizedBox(height: 120),
                      Center(
                          child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          l.t(
                              'Sin despachos no autorizados pendientes de '
                                  'asignar ID en los lanes vigilados '
                                  '(${period.label(l).toLowerCase()}).',
                              'No unauthorised dispenses awaiting an ID in the '
                                  'watched lanes (${period.label(l).toLowerCase()}).'),
                          textAlign: TextAlign.center,
                        ),
                      )),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: visible.length,
                    itemBuilder: (context, i) =>
                        _UnauthorisedTile(txn: visible[i], l: l),
                  ),
          ),
        ),
      ],
    );
  }
}

class _UnauthorisedTile extends StatelessWidget {
  const _UnauthorisedTile({required this.txn, required this.l});

  final UnauthorisedTxn txn;
  final L10n l;

  static final NumberFormat _litres = NumberFormat('#,##0.0');

  @override
  Widget build(BuildContext context) {
    final t = txn;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.gpp_maybe, size: 18, color: Colors.red),
        title: Row(
          children: [
            Flexible(
              child: Text(t.lane ?? l.t('Despacho sin ID', 'Dispense without ID'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            _Badge(l.t('SIN ID', 'NO ID'), Colors.red),
            if (t.volume != null)
              _Badge('${_litres.format(t.volume)} L', Colors.orange),
          ],
        ),
        subtitle: Text(
          [
            if ((t.product ?? '').isNotEmpty) t.product!,
            if ((t.fieldUser ?? '').isNotEmpty)
              '${l.t('Operador', 'Operator')}: ${t.fieldUser}',
            if ((t.adaptMac ?? '').isNotEmpty) t.adaptMac!,
            if (t.collectedAt != null)
              DateFormat('dd/MM HH:mm').format(t.collectedAt!.toLocal()),
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
