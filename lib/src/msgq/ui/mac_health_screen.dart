/// Pantalla de Salud de consolas — equivalente movil de `MacWindow`.
///
///   * RESUMEN: caidas en el tiempo y taxonomia de fallas.
///   * CONSOLAS: quien se cae mas, con su estado vigente.
///   * CORTES: episodios caida -> recuperacion con su duracion.
///   * EVENTOS: el log crudo observado.
///
/// A diferencia de la pestaña "Consolas" del notificador —que pinta el estado
/// ACTUAL para avisar de transiciones— esto es el HISTORICO acumulado. Y ese
/// historico es forward-only: solo existe desde que la app empezo a observar,
/// porque el endpoint no lo guarda.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/mac_health.dart';
import '../domain/mac_event.dart';
import '../export/msgq_export_service.dart';
import '../state/msgq_providers.dart';
import 'msgq_charts.dart';
import 'msgq_export_button.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class MacHealthScreen extends ConsumerWidget {
  const MacHealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataset = ref.watch(msgqDatasetProvider);
    final audit = ref.watch(macHealthProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Salud de consolas'),
          actions: [
            MsgqExportButton(
              reportBuilder: () => audit == null
                  ? null
                  : buildMacHealthReport(audit, scope: msgqScopeLabel(ref)),
            ),
            IconButton(
              tooltip: 'Sincronizar',
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
            ),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(icon: Icon(Icons.insights_outlined), text: 'Resumen'),
            Tab(icon: Icon(Icons.dns_outlined), text: 'Consolas'),
            Tab(icon: Icon(Icons.power_off_outlined), text: 'Cortes'),
            Tab(icon: Icon(Icons.list_alt_outlined), text: 'Eventos'),
          ]),
        ),
        body: dataset.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => MsgqEmpty(
            icon: Icons.error_outline,
            message: 'No se pudo leer la replica local.\n$e',
          ),
          data: (_) => Column(
            children: [
              if (syncError != null)
                MsgqErrorBanner(
                  message: syncError,
                  onRetry: () =>
                      ref.read(msgqDatasetProvider.notifier).syncNow(),
                ),
              const MsgqSyncStatusBar(),
              const MsgqFilterBar(showPeriod: true),
              const Divider(height: 1),
              Expanded(
                child: audit == null
                    ? const MsgqEmpty(message: 'Sin datos replicados todavia.')
                    : TabBarView(children: [
                        _SummaryTab(audit: audit),
                        _ConsolesTab(audit: audit),
                        _OutagesTab(audit: audit),
                        _EventsTab(audit: audit),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Aviso permanente: el historial arranca cuando arranco la observacion.
class _ForwardOnlyNote extends StatelessWidget {
  const _ForwardOnlyNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'El endpoint no guarda historial de consolas: estos eventos se '
              'construyen comparando cada sincronizacion con la anterior, asi '
              'que solo cubren desde que la app empezo a observar.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryTab extends ConsumerWidget {
  const _SummaryTab({required this.audit});

  final MacHealthAudit audit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final period = ref.watch(msgqPeriodProvider);
    final range = ref.watch(msgqRangeProvider);
    final kpis = audit.kpis;
    final series = faultsOverTime(
      audit.events,
      period: period,
      from: range.start(),
      to: DateTime.now().toUtc(),
    );

    return ListView(
      children: [
        const _ForwardOnlyNote(),
        MsgqKpiRow(cards: [
          MsgqKpiCard(label: 'Consolas', value: formatCount(kpis.consoles)),
          MsgqKpiCard(
            label: 'Online ahora',
            value: '${kpis.onlineNow}/${kpis.consoles}',
            emphasis: kpis.onlineNow < kpis.consoles
                ? theme.colorScheme.error
                : null,
          ),
          MsgqKpiCard(label: 'Caidas', value: formatCount(kpis.drops)),
          MsgqKpiCard(
            label: 'Fallos de comms',
            value: formatCount(kpis.commsFailures),
          ),
          MsgqKpiCard(
            label: 'Corte tipico',
            value: '${kpis.medianOutageMinutes.toStringAsFixed(0)} min',
            hint: 'mediana',
          ),
          MsgqKpiCard(
            label: 'Mas inestable',
            value: kpis.worstConsole ?? '—',
            hint: kpis.worstConsole == null
                ? null
                : '${kpis.worstConsoleDrops} caidas',
          ),
        ]),
        MsgqSection(
          title: 'Fallas en el tiempo',
          subtitle: '${period.label} · los dias sin eventos se dibujan en cero',
          child: MsgqTimeSeriesChart(
            series: [
              MsgqSeries(
                label: MacEventKind.offline.label,
                points: series
                    .map((p) => MsgqPoint(p.period, p.drops.toDouble()))
                    .toList(),
              ),
              MsgqSeries(
                label: MacEventKind.failedComms.label,
                points: series
                    .map((p) => MsgqPoint(p.period, p.commsFailures.toDouble()))
                    .toList(),
              ),
              MsgqSeries(
                label: MacEventKind.bypassOn.label,
                points: series
                    .map((p) => MsgqPoint(p.period, p.bypassEvents.toDouble()))
                    .toList(),
              ),
            ],
            valueFormatter: (v) => v.toStringAsFixed(0),
            emptyMessage: 'Sin eventos observados en el rango.',
          ),
        ),
        MsgqSection(
          title: 'Que fallas se presentan mas',
          subtitle: 'Taxonomia observable: la API no expone codigos de falla '
              'del hardware',
          child: MsgqBarList(
            bars: audit.faults
                .map((f) => MsgqBar(
                      label: f.kind.label,
                      value: f.events.toDouble(),
                      caption: '${formatCount(f.consolesAffected)} consolas · '
                          'ultimo ${formatDateTime(f.lastEvent)}',
                    ))
                .toList(),
            valueFormatter: formatCount,
            emptyMessage: 'Sin fallas observadas en el rango.',
          ),
        ),
        MsgqSection(
          title: 'Peores dias',
          subtitle: 'En que fechas hubo mas fallas y cual predomino',
          child: audit.byDay.isEmpty
              ? const MsgqEmpty(message: 'Sin fallas en el rango.')
              : Column(
                  children: audit.byDay
                      .take(20)
                      .map((d) => ListTile(
                            dense: true,
                            title: Text(formatDay(d.day)),
                            subtitle: Text(
                              '${formatCount(d.drops)} caidas · '
                              '${formatCount(d.commsFailures)} comms · '
                              '${formatCount(d.bypassEvents)} bypass\n'
                              '${d.mainFault.label} · '
                              '${formatCount(d.consolesAffected)} consolas',
                            ),
                            isThreeLine: true,
                            trailing: Text(formatCount(d.total),
                                style: theme.textTheme.titleSmall),
                          ))
                      .toList(),
                ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ConsolesTab extends StatelessWidget {
  const _ConsolesTab({required this.audit});

  final MacHealthAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.byConsole.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.dns_outlined,
        message: 'Sin eventos observados todavia.\n\nEl historial se llena a '
            'medida que la app sincroniza y detecta cambios de estado.',
      );
    }
    return ListView(
      children: [
        if (audit.flapping.isNotEmpty)
          MsgqSection(
            title: 'Consolas inestables',
            subtitle: 'Tres o mas caidas en las ultimas 24 h: es un problema '
                'fisico, no algo que arregle un reinicio remoto',
            child: Column(
              children: audit.flapping
                  .map((f) => ListTile(
                        dense: true,
                        leading: Icon(Icons.priority_high,
                            color: theme.colorScheme.error),
                        title: Text(f.description == null
                            ? f.code
                            : '${f.code} · ${f.description}'),
                        subtitle:
                            Text('ultima ${formatDateTime(f.lastDrop)}'),
                        trailing: Text(formatCount(f.drops),
                            style: theme.textTheme.titleSmall),
                      ))
                  .toList(),
            ),
          ),
        MsgqSection(
          title: 'Por consola',
          subtitle: 'Ordenadas por numero de caidas',
          child: Column(
            children: audit.byConsole
                .map((c) => Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: Icon(
                          c.onlineNow == false
                              ? Icons.cloud_off_outlined
                              : Icons.cloud_done_outlined,
                          color: c.onlineNow == false
                              ? theme.colorScheme.error
                              : null,
                        ),
                        title: Text(c.description == null
                            ? c.code
                            : '${c.code} · ${c.description}'),
                        subtitle: Text(
                          '${formatCount(c.drops)} caidas · '
                          '${formatCount(c.commsFailures)} comms · '
                          '${formatCount(c.bypassEvents)} bypass\n'
                          'ultima caida ${formatDateTime(c.lastDrop)}',
                        ),
                        isThreeLine: true,
                        trailing: Text(
                          c.onlineNow == null
                              ? '—'
                              : (c.onlineNow! ? 'online' : 'offline'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: c.onlineNow == false
                                ? theme.colorScheme.error
                                : null,
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _OutagesTab extends StatelessWidget {
  const _OutagesTab({required this.audit});

  final MacHealthAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.outages.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.power_off_outlined,
        message: 'Sin cortes de conexion observados en el rango.',
      );
    }
    return ListView(
      children: [
        MsgqSection(
          title: 'Cortes de conexion',
          subtitle: 'De la caida a la recuperacion. Los que siguen abiertos '
              'cuentan hasta ahora',
          child: Column(
            children: audit.outages.take(80).map((o) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: Icon(
                    o.ongoing ? Icons.error_outline : Icons.history,
                    color: o.ongoing ? theme.colorScheme.error : null,
                  ),
                  title: Text(o.description == null
                      ? o.code
                      : '${o.code} · ${o.description}'),
                  subtitle: Text(
                    'Caida ${formatDateTime(o.droppedAt)}\n'
                    '${o.ongoing ? "EN CURSO" : "Recuperada ${formatDateTime(o.recoveredAt)}"}',
                  ),
                  isThreeLine: true,
                  trailing: Text(
                    o.durationMinutes == null
                        ? '—'
                        : _duration(o.durationMinutes!),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: o.ongoing ? theme.colorScheme.error : null,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Minutos crudos son ilegibles pasadas unas horas: un corte de 2.880 min se
  /// entiende mucho mejor como "2 d".
  String _duration(double minutes) {
    if (minutes < 60) return '${minutes.toStringAsFixed(0)} min';
    if (minutes < 60 * 24) return '${(minutes / 60).toStringAsFixed(1)} h';
    return '${(minutes / 1440).toStringAsFixed(1)} d';
  }
}

class _EventsTab extends StatelessWidget {
  const _EventsTab({required this.audit});

  final MacHealthAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.events.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.list_alt_outlined,
        message: 'Sin eventos observados en el rango.',
      );
    }
    return ListView(
      children: [
        MsgqSection(
          title: 'Eventos observados',
          subtitle: '${formatCount(audit.events.length)} en el rango',
          child: Column(
            children: audit.events
                .take(100)
                .map((e) => ListTile(
                      dense: true,
                      leading: Icon(_iconFor(e.kind),
                          size: 18,
                          color: e.kind.isFault
                              ? theme.colorScheme.error
                              : null),
                      title: Text('${e.code} · ${e.kind.label}'),
                      subtitle: Text([
                        formatDateTime(e.ts),
                        if (e.detail != null) e.detail!,
                      ].join('\n')),
                      isThreeLine: true,
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  IconData _iconFor(MacEventKind kind) => switch (kind) {
        MacEventKind.offline => Icons.cloud_off_outlined,
        MacEventKind.online => Icons.cloud_done_outlined,
        MacEventKind.failedComms => Icons.sync_problem_outlined,
        MacEventKind.bypassOn => Icons.key_off_outlined,
        MacEventKind.bypassOff => Icons.key_outlined,
      };
}
