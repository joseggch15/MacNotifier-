/// Pantalla de Equipos — equivalente movil de `EquipmentWindow` del dashboard
/// de escritorio.
///
///   * FLOTA: KPIs, composicion por dimension y completitud del maestro.
///   * ESTADOS: transiciones In/Out, quienes entran y salen mas, y cuanto
///     aguantan en servicio.
///   * RFID: ritmo de altas, cambios y remociones de tag.
///   * AUDITORIA: que atributos se tocan y quien los toca.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/equipment_analytics.dart';
import '../analytics/grouping.dart';
import '../domain/fms_vocabulary.dart';
import '../export/msgq_export_service.dart';
import '../state/msgq_providers.dart';
import 'msgq_export_button.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class EquipmentScreen extends ConsumerWidget {
  const EquipmentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataset = ref.watch(msgqDatasetProvider);
    final analytics = ref.watch(equipmentAnalyticsProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Equipos'),
          actions: [
            MsgqExportButton(
              reportBuilder: () => analytics == null
                  ? null
                  : buildEquipmentReport(
                      analytics,
                      scope: msgqScopeLabel(ref),
                      dimension: ref.read(msgqDimensionProvider),
                    ),
            ),
            IconButton(
              tooltip: 'Sincronizar',
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
            ),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(icon: Icon(Icons.precision_manufacturing_outlined), text: 'Flota'),
            Tab(icon: Icon(Icons.swap_horiz), text: 'Estados'),
            Tab(icon: Icon(Icons.nfc_outlined), text: 'RFID'),
            Tab(icon: Icon(Icons.history_edu_outlined), text: 'Auditoria'),
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
                child: analytics == null
                    ? const MsgqEmpty(message: 'Sin datos replicados todavia.')
                    : TabBarView(children: [
                        _FleetTab(analytics: analytics),
                        _StatusTab(analytics: analytics),
                        _RfidTab(analytics: analytics),
                        _AuditTab(analytics: analytics),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Flota
// ===========================================================================

class _FleetTab extends ConsumerWidget {
  const _FleetTab({required this.analytics});

  final EquipmentAnalytics analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dimension = ref.watch(msgqDimensionProvider);
    final kpis = analytics.fleetKpis();
    if (kpis == null) {
      return const MsgqEmpty(
        icon: Icons.precision_manufacturing_outlined,
        message: 'El maestro de equipos aun no esta replicado.\n'
            'Pulsa sincronizar para descargarlo.',
      );
    }
    final byDimension = analytics.groupSummary(dimension);
    final statuses = analytics.statusBreakdown();
    final completeness = analytics.dataCompleteness();
    final contractors = analytics.contractorSummary();

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(label: 'Equipos', value: formatCount(kpis.total)),
          MsgqKpiCard(
            label: 'Disponibilidad',
            value: formatPercent(kpis.availabilityPct),
            hint: '${formatCount(kpis.inService)} en servicio',
          ),
          MsgqKpiCard(
            label: 'Fuera de servicio',
            value: formatCount(kpis.outOfService),
            emphasis: kpis.outOfService > 0 ? theme.colorScheme.error : null,
          ),
          MsgqKpiCard(
            label: 'Dados de baja',
            value: formatCount(kpis.decommissioned),
          ),
          MsgqKpiCard(
            label: 'Contratistas',
            value: formatCount(kpis.contractorVehicles),
            hint: formatPercent(kpis.contractorPct),
          ),
          MsgqKpiCard(
            label: 'Vehiculos ligeros',
            value: formatCount(kpis.lightVehicles),
          ),
        ]),
        MsgqSection(
          title: 'Por estado',
          child: MsgqBarList(
            bars: statuses
                .map((s) => MsgqBar(
                      label: s.status,
                      value: s.equipment.toDouble(),
                      color: s.status == statusOutOfService
                          ? theme.colorScheme.error
                          : null,
                    ))
                .toList(),
            valueFormatter: formatCount,
          ),
        ),
        MsgqSection(
          title: 'Por ${dimension.label.toLowerCase()}',
          trailing: const MsgqDimensionMenu(),
          child: byDimension.isEmpty
              ? const MsgqEmpty(message: 'Sin datos.')
              : Column(
                  children: byDimension
                      .take(20)
                      .map((g) => ListTile(
                            dense: true,
                            title: Text(g.key),
                            subtitle: Text(
                              '${formatCount(g.inService)} en servicio · '
                              '${formatCount(g.outOfService)} fuera · '
                              '${formatCount(g.decommissioned)} de baja',
                            ),
                            trailing: Text(
                              '${formatCount(g.total)}\n'
                              '${formatPercent(g.availabilityPct)}',
                              textAlign: TextAlign.right,
                              style: theme.textTheme.bodySmall,
                            ),
                          ))
                      .toList(),
                ),
        ),
        if (contractors.isNotEmpty)
          MsgqSection(
            title: 'Flota de contratistas',
            subtitle: 'Agrupada por departamento (el maestro no trae columna '
                'de contratista)',
            child: MsgqBarList(
              bars: contractors
                  .map((g) => MsgqBar(
                        label: g.key,
                        value: g.total.toDouble(),
                        caption: '${formatPercent(g.availabilityPct)} disponible',
                      ))
                  .toList(),
              valueFormatter: formatCount,
            ),
          ),
        MsgqSection(
          title: 'Completitud del maestro',
          subtitle: 'Que porcentaje de equipos tiene cada campo cargado',
          child: MsgqBarList(
            bars: completeness
                .map((c) => MsgqBar(
                      label: c.field,
                      value: c.completenessPct,
                      caption: '${formatCount(c.missing)} sin dato',
                      color: c.completenessPct < 80
                          ? theme.colorScheme.error
                          : null,
                    ))
                .toList(),
            maxItems: completeness.length,
            valueFormatter: formatPercent,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ===========================================================================
// Estados
// ===========================================================================

class _StatusTab extends ConsumerWidget {
  const _StatusTab({required this.analytics});

  final EquipmentAnalytics analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final period = ref.watch(msgqPeriodProvider);
    final dimension = ref.watch(msgqDimensionProvider);
    final transitions = ref.watch(statusTransitionsProvider);

    if (transitions.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.swap_horiz,
        message: 'Sin transiciones de estado en el rango.\n'
            'El log de auditoria se descarga al sincronizar.',
      );
    }

    final summary = analytics.statusTransitionSummary(transitions);
    final series = analytics.inToOutOverTime(transitions, period: period);
    final byDimension =
        analytics.transitionsByDimension(transitions, dimension);
    final topOutToIn = analytics.topEquipmentByTransition(
      transitions,
      from: statusOutOfService,
      to: statusInService,
      n: 15,
    );
    final dwell = analytics.timeInService(transitions);
    final inToOut = transitions.where((t) => t.isInToOut).length;

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(label: 'Transiciones', value: formatCount(transitions.length)),
          MsgqKpiCard(
            label: 'In → Out',
            value: formatCount(inToOut),
            emphasis: theme.colorScheme.error,
          ),
          MsgqKpiCard(
            label: 'Out → In',
            value: formatCount(transitions.where((t) => t.isOutToIn).length),
          ),
          MsgqKpiCard(
            label: 'Equipos afectados',
            value: formatCount(
                transitions.map((t) => t.recordId).toSet().length),
          ),
        ]),
        MsgqSection(
          title: 'Salidas de servicio en el tiempo',
          subtitle: '${period.label} · transiciones In Service → Out of Service',
          child: MsgqBarList(
            bars: series.reversed
                .map((p) => MsgqBar(
                      label: period == AnalyticsPeriod.monthly
                          ? formatMonth(p.period)
                          : formatDay(p.period),
                      value: p.count.toDouble(),
                    ))
                .toList(),
            maxItems: 14,
            valueFormatter: formatCount,
          ),
        ),
        MsgqSection(
          title: 'Tipos de transicion',
          child: MsgqBarList(
            bars: summary
                .map((s) => MsgqBar(
                      label: s.transition,
                      value: s.times.toDouble(),
                    ))
                .toList(),
            valueFormatter: formatCount,
          ),
        ),
        MsgqSection(
          title: 'Por ${dimension.label.toLowerCase()}',
          trailing: const MsgqDimensionMenu(),
          child: MsgqBarList(
            bars: byDimension
                .map((d) => MsgqBar(
                      label: d.key,
                      value: d.total.toDouble(),
                      caption: 'In→Out ${formatCount(d.inToOut)} · '
                          'Out→In ${formatCount(d.outToIn)}',
                    ))
                .toList(),
            valueFormatter: formatCount,
          ),
        ),
        MsgqSection(
          title: 'Vuelven a servicio mas veces',
          subtitle: 'Un equipo que entra y sale sin parar suele ser una averia '
              'recurrente mal cerrada',
          child: Column(
            children: topOutToIn
                .map((t) => ListTile(
                      dense: true,
                      title: Text(t.equipmentId ?? t.recordId),
                      subtitle: Text([
                        if (t.description != null) t.description!,
                        if (t.group != null) t.group!,
                        if (t.last != null) 'ultimo ${formatDateTime(t.last)}',
                      ].join(' · ')),
                      trailing: Text(formatCount(t.times),
                          style: theme.textTheme.titleSmall),
                    ))
                .toList(),
          ),
        ),
        MsgqSection(
          title: 'Tiempo en servicio antes de salir',
          child: Column(
            children: dwell
                .where((d) => d.avgDaysInService != null)
                .take(20)
                .map((d) => ListTile(
                      dense: true,
                      title: Text(d.equipmentId ?? d.recordId),
                      subtitle: Text(d.description ?? ''),
                      trailing: Text(
                        '${d.avgDaysInService!.toStringAsFixed(1)} d\n'
                        '${formatCount(d.exitsToOutOfService)} salidas',
                        textAlign: TextAlign.right,
                        style: theme.textTheme.bodySmall,
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

// ===========================================================================
// RFID
// ===========================================================================

class _RfidTab extends ConsumerWidget {
  const _RfidTab({required this.analytics});

  final EquipmentAnalytics analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final period = ref.watch(msgqPeriodProvider);
    final summary = analytics.rfidChangeSummary();
    if (summary.events == 0) {
      return const MsgqEmpty(
        icon: Icons.nfc_outlined,
        message: 'Sin eventos de RFID en el rango replicado.',
      );
    }
    final series = analytics.rfidChangesOverTime(period: period);
    final churn = analytics.rfidChurnByTag(n: 20);

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(label: 'Eventos', value: formatCount(summary.events)),
          MsgqKpiCard(label: 'Asignados', value: formatCount(summary.assigned)),
          MsgqKpiCard(label: 'Cambiados', value: formatCount(summary.changed)),
          MsgqKpiCard(
            label: 'Removidos',
            value: formatCount(summary.removed),
            emphasis: theme.colorScheme.error,
          ),
          MsgqKpiCard(
            label: 'Registros de tag',
            value: formatCount(summary.tagRecords),
          ),
        ]),
        MsgqSection(
          title: 'Eventos en el tiempo',
          subtitle: period.label,
          child: MsgqBarList(
            bars: series.reversed
                .map((p) => MsgqBar(
                      label: period == AnalyticsPeriod.monthly
                          ? formatMonth(p.period)
                          : formatDay(p.period),
                      value: p.total.toDouble(),
                      caption: 'alta ${formatCount(p.assigned)} · '
                          'cambio ${formatCount(p.changed)} · '
                          'baja ${formatCount(p.removed)}',
                    ))
                .toList(),
            maxItems: 14,
            valueFormatter: formatCount,
          ),
        ),
        MsgqSection(
          title: 'Tags con mas movimiento',
          subtitle: 'El log no enlaza el tag con su equipo, asi que el conteo '
              'es por registro de tag',
          child: MsgqBarList(
            bars: churn
                .map((c) => MsgqBar(
                      label: c.recordId,
                      value: c.events.toDouble(),
                      caption: 'ultimo ${formatDateTime(c.lastChange)}',
                    ))
                .toList(),
            maxItems: 20,
            valueFormatter: formatCount,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ===========================================================================
// Auditoria
// ===========================================================================

class _AuditTab extends StatelessWidget {
  const _AuditTab({required this.analytics});

  final EquipmentAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attributes = analytics.attributeChangeSummary();
    final users = analytics.auditByUser();

    if (attributes.isEmpty && users.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.history_edu_outlined,
        message: 'Sin cambios registrados en el rango replicado.',
      );
    }

    return ListView(
      children: [
        MsgqSection(
          title: 'Atributos mas modificados',
          subtitle: 'Solo reasignaciones reales, no altas iniciales',
          child: MsgqBarList(
            bars: attributes
                .map((a) => MsgqBar(
                      label: a.label,
                      value: a.changes.toDouble(),
                      caption: '${formatCount(a.equipmentCount)} equipos',
                    ))
                .toList(),
            maxItems: 15,
            valueFormatter: formatCount,
          ),
        ),
        MsgqSection(
          title: 'Quien hace los cambios',
          child: Column(
            children: users
                .take(20)
                .map((u) => ListTile(
                      dense: true,
                      title: Text(u.user),
                      subtitle: Text(
                        '${formatCount(u.equipmentChanges)} equipos · '
                        '${formatCount(u.rfidChanges)} RFID · '
                        'ultimo ${formatDateTime(u.lastChange)}',
                      ),
                      trailing: Text(formatCount(u.changes),
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
