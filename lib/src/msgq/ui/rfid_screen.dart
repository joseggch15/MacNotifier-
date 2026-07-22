/// Pantalla de Inventario RFID — equivalente movil de `InventoryWindow`.
///
///   * REPORTE: el 'Inventory Tag Installed' con la fecha REAL de cada cambio.
///   * RESUMEN: agrupaciones por grupo, departamento y cost centre, y los
///     equipos con mas churn de tag.
///   * VALIDACIONES: las anomalias del inventario (tags duplicados, tags en
///     equipos fuera de servicio, altas sin equipo identificable).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/rfid_inventory.dart';
import '../domain/fms_vocabulary.dart';
import '../state/msgq_providers.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class RfidScreen extends ConsumerWidget {
  const RfidScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataset = ref.watch(msgqDatasetProvider);
    final audit = ref.watch(rfidInventoryProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Inventario RFID'),
          actions: [
            IconButton(
              tooltip: 'Sincronizar',
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.list_alt_outlined), text: 'Reporte'),
            Tab(icon: Icon(Icons.donut_small_outlined), text: 'Resumen'),
            Tab(icon: Icon(Icons.rule_outlined), text: 'Validaciones'),
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
                        _ReportTab(audit: audit),
                        _SummaryTab(audit: audit),
                        _ValidationsTab(audit: audit),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportTab extends StatelessWidget {
  const _ReportTab({required this.audit});

  final RfidInventoryAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kpis = audit.kpis;
    // Del mas reciente al mas antiguo: en el telefono lo que se mira primero es
    // lo que acaba de pasar (el reporte se genera en orden cronologico).
    final rows = audit.report.reversed.toList();

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Nuevas',
            value: formatCount(kpis.newInstallations),
          ),
          MsgqKpiCard(
            label: 'Reemplazos',
            value: formatCount(kpis.replacements),
          ),
          MsgqKpiCard(
            label: 'Remociones',
            value: formatCount(kpis.removals),
            emphasis: kpis.removals > 0 ? theme.colorScheme.error : null,
          ),
          MsgqKpiCard(
            label: 'Tags distintos',
            value: formatCount(kpis.distinctTags),
          ),
          MsgqKpiCard(
            label: 'Equipos con RFID',
            value: formatCount(kpis.equipmentWithRfid),
            hint: 'de ${formatCount(kpis.totalEquipment)}',
          ),
        ]),
        MsgqSection(
          title: 'Movimientos de tag',
          subtitle: 'Fecha real del cambio, en hora local del sitio',
          child: rows.isEmpty
              ? const MsgqEmpty(
                  message: 'Sin cambios de RFID en el rango replicado.')
              : Column(
                  children: rows.take(80).map((r) {
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: Icon(_iconFor(r.operation),
                            color: r.isAnomalous
                                ? theme.colorScheme.error
                                : null),
                        title: Text('${r.equipmentId} · ${r.operation.label}'),
                        subtitle: Text([
                          formatDateTime(r.date),
                          if (r.tag != null) 'tag ${r.tag}',
                          if (r.product != null) r.product!,
                          if (r.department != null) r.department!,
                          if (r.whodunnit != null) 'por ${r.whodunnit}',
                        ].join(' · ')),
                        isThreeLine: true,
                        trailing: r.status == statusOutOfService
                            ? Icon(Icons.report_problem_outlined,
                                size: 18, color: theme.colorScheme.error)
                            : null,
                      ),
                    );
                  }).toList(),
                ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  IconData _iconFor(RfidOperation op) => switch (op) {
        RfidOperation.newInstallation => Icons.add_circle_outline,
        RfidOperation.replacement => Icons.swap_horiz,
        RfidOperation.removal => Icons.remove_circle_outline,
      };
}

class _SummaryTab extends ConsumerWidget {
  const _SummaryTab({required this.audit});

  final RfidInventoryAudit audit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(msgqPeriodProvider);
    final trends = audit.auditTrends(period: period);
    final churn = audit.tagChangeFrequency(topN: 20);

    if (audit.report.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.donut_small_outlined,
        message: 'Sin cambios de RFID en el rango replicado.',
      );
    }

    return ListView(
      children: [
        MsgqSection(
          title: 'Tendencia de auditoria',
          subtitle: '${period.label} · actividad, remociones y anomalias',
          child: MsgqBarList(
            bars: trends.reversed
                .map((p) => MsgqBar(
                      label: formatMonth(p.period),
                      value: p.activity.toDouble(),
                      caption: '${formatCount(p.removals)} remociones · '
                          '${formatCount(p.anomalies)} anomalias',
                    ))
                .toList(),
            maxItems: 14,
            valueFormatter: formatCount,
          ),
        ),
        _GroupSection(title: 'Por grupo', rows: audit.byGroup()),
        _GroupSection(title: 'Por departamento', rows: audit.byDepartment()),
        _GroupSection(title: 'Por cost centre', rows: audit.byCostCentre()),
        MsgqSection(
          title: 'Equipos con mas cambios de tag',
          subtitle: 'Un tag que se cambia seguido señala un problema fisico o '
              'un proceso mal aplicado',
          child: MsgqBarList(
            bars: churn
                .map((c) => MsgqBar(
                      label: c.description == null
                          ? c.equipmentId
                          : '${c.equipmentId} · ${c.description}',
                      value: c.changes.toDouble(),
                      caption: 'alta ${formatCount(c.newInstallations)} · '
                          'reemplazo ${formatCount(c.replacements)} · '
                          'baja ${formatCount(c.removals)}',
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

class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.title, required this.rows});

  final String title;
  final List<RfidGroupSummary> rows;

  @override
  Widget build(BuildContext context) => MsgqSection(
        title: title,
        child: MsgqBarList(
          bars: rows
              .map((g) => MsgqBar(
                    label: g.key,
                    value: g.installations.toDouble(),
                    caption: 'alta ${formatCount(g.newInstallations)} · '
                        'reemplazo ${formatCount(g.replacements)} · '
                        'baja ${formatCount(g.removals)}',
                  ))
              .toList(),
          valueFormatter: formatCount,
        ),
      );
}

class _ValidationsTab extends StatelessWidget {
  const _ValidationsTab({required this.audit});

  final RfidInventoryAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final validations = audit.validationSummary();
    final duplicates = audit.duplicateTags();
    final outOfService = audit.outOfServiceInstallations();
    final incomplete = audit.incompleteRecords();

    return ListView(
      children: [
        MsgqSection(
          title: 'Resumen de validaciones',
          child: Column(
            children: validations
                .map((v) => ListTile(
                      dense: true,
                      leading: Icon(
                        v.anomalies == 0
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        color:
                            v.anomalies == 0 ? null : theme.colorScheme.error,
                      ),
                      title: Text(v.name),
                      subtitle: Text(v.description),
                      trailing: Text(formatCount(v.anomalies),
                          style: theme.textTheme.titleSmall),
                    ))
                .toList(),
          ),
        ),
        if (duplicates.isNotEmpty)
          MsgqSection(
            title: 'Tags duplicados',
            subtitle: 'Un tag fisico no puede estar en dos equipos a la vez',
            child: Column(
              children: duplicates
                  .map((d) => ListTile(
                        dense: true,
                        title: Text(d.tag),
                        subtitle: Text([
                          d.equipmentId,
                          if (d.description != null) d.description!,
                          if (d.status != null) d.status!,
                        ].join(' · ')),
                        trailing: Text('${d.equipmentCount} equipos',
                            style: theme.textTheme.bodySmall),
                      ))
                  .toList(),
            ),
          ),
        if (outOfService.isNotEmpty)
          MsgqSection(
            title: 'Tags en equipos fuera de servicio',
            child: Column(
              children: outOfService
                  .map((r) => ListTile(
                        dense: true,
                        title: Text('${r.equipmentId} · ${r.operation.label}'),
                        subtitle: Text(
                            '${formatDateTime(r.date)} · tag ${r.tag ?? "—"}'),
                      ))
                  .toList(),
            ),
          ),
        if (incomplete.isNotEmpty)
          MsgqSection(
            title: 'Altas y reemplazos sin equipo',
            subtitle: 'El tag no esta en el maestro vigente ni en el historial '
                'observado de asignaciones',
            child: Column(
              children: incomplete
                  .map((r) => ListTile(
                        dense: true,
                        title: Text(r.tag ?? unidentifiedLabel),
                        subtitle: Text(
                            '${r.operation.label} · ${formatDateTime(r.date)}'),
                      ))
                  .toList(),
            ),
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}
