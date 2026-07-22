/// Pantalla de Salud de Hardware — equivalente movil de `HardwareWindow`.
///
///   * ORDENES: el consolidado accionable (un ticket por activo y problema).
///   * SMU: regresiones y estancamientos del horometro/odometro.
///   * MEDIDORES: caudal reciente contra la linea base de cada manguera.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/hardware_health.dart';
import '../state/msgq_providers.dart';
import 'msgq_charts.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class HardwareScreen extends ConsumerWidget {
  const HardwareScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataset = ref.watch(msgqDatasetProvider);
    final audit = ref.watch(hardwareHealthProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Salud de hardware'),
          actions: [
            IconButton(
              tooltip: 'Sincronizar',
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.build_outlined), text: 'Ordenes'),
            Tab(icon: Icon(Icons.timer_outlined), text: 'SMU'),
            Tab(icon: Icon(Icons.water_drop_outlined), text: 'Medidores'),
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
              const MsgqFilterBar(),
              const Divider(height: 1),
              Expanded(
                child: audit == null
                    ? const MsgqEmpty(message: 'Sin datos replicados todavia.')
                    : TabBarView(children: [
                        _WorkOrdersTab(audit: audit),
                        _SmuTab(audit: audit),
                        _MetersTab(audit: audit),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkOrdersTab extends StatelessWidget {
  const _WorkOrdersTab({required this.audit});

  final HardwareAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kpis = audit.kpis;
    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Ordenes',
            value: formatCount(kpis.workOrders),
            emphasis: kpis.workOrders > 0 ? theme.colorScheme.error : null,
          ),
          MsgqKpiCard(
            label: 'SMU en regresion',
            value: formatCount(kpis.smuRegressions),
          ),
          MsgqKpiCard(
            label: 'SMU sin pulsos',
            value: formatCount(kpis.smuStagnations),
          ),
          MsgqKpiCard(
            label: 'Re-tagueo',
            value: formatCount(kpis.retagAlerts),
          ),
          MsgqKpiCard(
            label: 'Medidores degradados',
            value: formatCount(kpis.degradedMeters),
          ),
        ]),
        MsgqSection(
          title: 'Ordenes de trabajo',
          subtitle: 'Una por activo y problema, con el evento mas reciente',
          child: audit.workOrders.isEmpty
              ? const MsgqEmpty(
                  icon: Icons.verified_outlined,
                  message: 'Sin hallazgos de hardware en el rango replicado.',
                )
              : Column(
                  children: audit.workOrders.map((o) {
                    final critical = o.severity == WorkOrderSeverity.critical;
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: Icon(
                          critical
                              ? Icons.error_outline
                              : Icons.warning_amber_rounded,
                          color: critical ? theme.colorScheme.error : null,
                        ),
                        title: Text('${o.asset} · ${o.type}'),
                        subtitle: Text('${o.detail}\n${o.action}'),
                        isThreeLine: true,
                        trailing: Text(
                          o.date == null ? '—' : formatDay(o.date!),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
        if (audit.retagAlerts.isNotEmpty)
          MsgqSection(
            title: 'Re-tagueo sospechoso',
            subtitle: 'Mas de $retagMaxChangesHint reemplazos de tag en una '
                'ventana movil de 30 dias',
            child: Column(
              children: audit.retagAlerts
                  .map((r) => ListTile(
                        dense: true,
                        title: Text(r.equipmentId),
                        subtitle: Text([
                          if (r.equipmentDescription != null)
                            r.equipmentDescription!,
                          if (r.category != null) r.category!,
                          'del ${formatDay(r.firstChange!)} al '
                              '${formatDay(r.lastChange!)}',
                        ].join(' · ')),
                        trailing: Text(formatCount(r.changesInWindow),
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

/// Umbral mostrado en la UI, para no repetir la constante en el texto.
const String retagMaxChangesHint = '3';

class _SmuTab extends StatelessWidget {
  const _SmuTab({required this.audit});

  final HardwareAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.smuAnomalies.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.timer_outlined,
        message: 'Ningun sensor de SMU retrocedio ni se quedo quieto en el '
            'rango replicado.',
      );
    }
    return ListView(
      children: [
        MsgqSection(
          title: 'Anomalias del SMU',
          subtitle: 'El horometro/odometro siempre debe avanzar',
          child: Column(
            children: audit.smuAnomalies.take(60).map((a) {
              final isRegression = a.type == SmuAnomalyType.regression;
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: Icon(
                    isRegression ? Icons.trending_down : Icons.pause_circle_outline,
                    color: theme.colorScheme.error,
                  ),
                  title: Text('${a.equipmentId} · ${a.equipmentDescription}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${a.type.label} · ${formatDateTime(a.date)}\n'
                    '${isRegression ? 'Cayo ${a.drop} (de ${a.referenceValue} a ${a.smuValue}) en ${a.days} dias' : 'Mismo SMU ${a.smuValue} en ${a.repeats} despachos (${a.days} dias)'}',
                  ),
                  isThreeLine: true,
                  trailing: Text(a.category ?? '',
                      style: theme.textTheme.bodySmall),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _MetersTab extends StatelessWidget {
  const _MetersTab({required this.audit});

  final HardwareAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Distincion importante: sin datos de medidor no es que las mangueras esten
    // sanas, es que no hay con que evaluarlas.
    if (!audit.meterDataAvailable) {
      return const MsgqEmpty(
        icon: Icons.help_outline,
        message: 'El tenant no expone identificador de medidor en los '
            'despachos, asi que la salud de las mangueras no se puede auditar '
            'por esta via.',
      );
    }
    if (audit.meters.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.water_drop_outlined,
        message: 'Ninguna manguera tiene muestras suficientes a ambos lados de '
            'la ventana reciente para comparar su caudal.',
      );
    }
    // Serie por manguera: la degradacion se ve como pendiente, no como un
    // porcentaje suelto. Se limita a las mangueras evaluadas (las que tienen
    // muestras a ambos lados), que son de las que se puede afirmar algo.
    final evaluated = audit.meters.map((m) => m.meterId).toSet();
    final byMeter = <String, List<MsgqPoint>>{};
    for (final p in audit.meterSeries) {
      if (!evaluated.contains(p.meterId)) continue;
      byMeter.putIfAbsent(p.meterId, () => <MsgqPoint>[])
          .add(MsgqPoint(p.date, p.flow));
    }

    return ListView(
      children: [
        MsgqSection(
          title: 'Caudal en el tiempo',
          subtitle: '${audit.meters.first.metric} mediano por dia y manguera',
          child: MsgqTimeSeriesChart(
            series: [
              for (final e in byMeter.entries)
                MsgqSeries(label: e.key, points: e.value),
            ],
            valueFormatter: (v) => '${v.toStringAsFixed(1)} L/min',
            emptyMessage: 'Sin lecturas de caudal en el rango.',
          ),
        ),
        MsgqSection(
          title: 'Caudal por manguera',
          subtitle: '${audit.meters.first.metric} reciente contra su linea base',
          child: Column(
            children: audit.meters
                .map((m) => Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: Icon(
                          m.degraded
                              ? Icons.warning_amber_rounded
                              : Icons.check_circle_outline,
                          color: m.degraded ? theme.colorScheme.error : null,
                        ),
                        title: Text(m.meterDescription == null
                            ? m.meterId
                            : '${m.meterId} · ${m.meterDescription}'),
                        subtitle: Text(
                          'Base ${m.baseFlow} L/min '
                          '(${formatCount(m.baseSamples)} muestras) → '
                          'reciente ${m.recentFlow} L/min '
                          '(${formatCount(m.recentSamples)})',
                        ),
                        isThreeLine: true,
                        trailing: Text(
                          formatPercent(m.dropPct),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: m.degraded ? theme.colorScheme.error : null,
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
