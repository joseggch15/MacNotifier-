/// Pantalla de Auditoria SFL — equivalente movil de `SFLWindow` +
/// `DispenseReportDialog`.
///
/// Reune las tres vistas del escritorio que giran alrededor del Safe Fill
/// Level, porque comparten el dato (los despachos) y se leen juntas:
///
///   * EXCESOS: despachos que superan el SFL del equipo, con desgloses.
///   * CONFLICTOS: despachos sin equipo valido peligrosos para cualquiera.
///   * POR EQUIPO: cada equipo clasificado Normal / Over SFL.
///
/// El notificador ya AVISA de un sobrellenado; esto responde "quien y que tipo
/// de equipo los concentra".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/sfl_audit.dart';
import '../domain/equipment.dart';
import '../export/msgq_export_service.dart';
import '../state/msgq_providers.dart';
import 'msgq_export_button.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class SflScreen extends ConsumerWidget {
  const SflScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataset = ref.watch(msgqDatasetProvider);
    final audit = ref.watch(sflAuditProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Auditoria SFL'),
          actions: [
            MsgqExportButton(
              reportBuilder: () => audit == null
                  ? null
                  : buildSflReport(audit, scope: msgqScopeLabel(ref)),
            ),
            IconButton(
              tooltip: 'Sincronizar',
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.warning_amber_outlined), text: 'Excesos'),
            Tab(icon: Icon(Icons.gpp_maybe_outlined), text: 'Conflictos'),
            Tab(icon: Icon(Icons.precision_manufacturing_outlined),
                text: 'Por equipo'),
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
              const MsgqFilterBar(showCircuit: true, showPeriod: true),
              const Divider(height: 1),
              Expanded(
                child: audit == null
                    ? const MsgqEmpty(message: 'Sin datos replicados todavia.')
                    : TabBarView(children: [
                        _ExceedancesTab(audit: audit),
                        _ConflictsTab(audit: audit),
                        _ByEquipmentTab(audit: audit),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExceedancesTab extends ConsumerWidget {
  const _ExceedancesTab({required this.audit});

  final SflAudit audit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final kpis = audit.kpis;
    final dimension = ref.watch(msgqDimensionProvider);
    final byDim = dimension == EquipmentDimension.category
        ? audit.byCategory()
        : audit.byGroup();

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Excesos',
            value: formatCount(kpis.exceedances),
            emphasis: kpis.exceedances > 0 ? theme.colorScheme.error : null,
          ),
          MsgqKpiCard(label: 'Exceso total', value: formatLitres(kpis.totalExcessL)),
          MsgqKpiCard(label: 'Peor exceso', value: formatLitres(kpis.worstExcessL)),
          MsgqKpiCard(label: 'Equipos', value: formatCount(kpis.equipmentAffected)),
          MsgqKpiCard(
            label: '% de despachos',
            value: formatPercent(kpis.pctOfDispenses),
          ),
        ]),
        if (audit.exceedances.isEmpty)
          const MsgqEmpty(
            icon: Icons.verified_outlined,
            message: 'Ningun despacho supera el SFL de su equipo en el rango.',
          )
        else ...[
          MsgqSection(
            title: 'Por producto',
            child: MsgqBarList(
              bars: audit
                  .byProduct()
                  .map((r) => MsgqBar(
                        label: r.key,
                        value: r.totalExcessL,
                        caption: '${formatCount(r.exceedances)} excesos · '
                            'peor ${formatLitres(r.worstExcessL)}',
                      ))
                  .toList(),
            ),
          ),
          MsgqSection(
            title: 'Por operador',
            subtitle: 'Que operadores concentran los sobrellenados',
            child: MsgqBarList(
              bars: audit
                  .byFieldUser()
                  .map((r) => MsgqBar(
                        label: r.key,
                        value: r.totalExcessL,
                        caption: '${formatCount(r.exceedances)} excesos',
                      ))
                  .toList(),
            ),
          ),
          MsgqSection(
            title: 'Por ${dimension.label.toLowerCase()}',
            trailing: const MsgqDimensionMenu(),
            child: MsgqBarList(
              bars: byDim
                  .map((r) => MsgqBar(
                        label: r.key,
                        value: r.totalExcessL,
                        caption: '${formatCount(r.exceedances)} excesos · '
                            '${formatCount(r.equipmentCount ?? 0)} equipos',
                      ))
                  .toList(),
              emptyMessage: 'Sin maestro de equipos para resolver la dimension.',
            ),
          ),
          MsgqSection(
            title: 'Despachos con exceso',
            subtitle: 'Del mas reciente al mas antiguo',
            child: Column(
              children: audit.exceedances.take(60).map((e) {
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Icon(Icons.warning_amber_rounded,
                        color: theme.colorScheme.error),
                    title: Text('${e.equipmentId} · ${e.product ?? "—"}'),
                    subtitle: Text(
                      '${formatDateTime(e.date)}\n'
                      'despachado ${formatLitres(e.volume)} sobre SFL '
                      '${formatLitres(e.sfl)}'
                      '${e.fieldUser == null ? "" : " · ${e.fieldUser}"}',
                    ),
                    isThreeLine: true,
                    trailing: Text(
                      '+${formatLitres(e.excess)}\n${formatPercent(e.excessPct)}',
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ConflictsTab extends StatelessWidget {
  const _ConflictsTab({required this.audit});

  final SflAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.conflicts.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.gpp_good_outlined,
        message: 'Sin despachos sin equipo valido en el rango.',
      );
    }
    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Conflictos',
            value: formatCount(audit.kpis.conflicts),
          ),
          MsgqKpiCard(
            label: 'Sobre SFL flota',
            value: formatCount(audit.kpis.conflictsOverMax),
            hint: 'peligroso para cualquier equipo',
            emphasis: audit.kpis.conflictsOverMax > 0
                ? theme.colorScheme.error
                : null,
          ),
        ]),
        MsgqSection(
          title: 'Despachos sin equipo',
          subtitle: 'no_equip / Unauthorised. Los que superan el SFL maximo de '
              'la flota no son seguros para NINGUN equipo',
          child: Column(
            children: audit.conflicts.take(80).map((c) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: Icon(
                    c.overMax ? Icons.dangerous_outlined : Icons.help_outline,
                    color: c.overMax ? theme.colorScheme.error : null,
                  ),
                  title: Text(c.product ?? '—'),
                  subtitle: Text(
                    '${formatDateTime(c.date)} · ${c.type ?? c.status ?? "—"}\n'
                    'despachado ${formatLitres(c.volume)}'
                    '${c.fleetMaxSfl == null ? "" : " · SFL flota ${formatLitres(c.fleetMaxSfl!)}"}',
                  ),
                  isThreeLine: true,
                  trailing: c.overMax
                      ? Text('sobre\nmax',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error))
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
}

class _ByEquipmentTab extends StatelessWidget {
  const _ByEquipmentTab({required this.audit});

  final SflAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = audit.equipmentSummary();
    if (rows.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.precision_manufacturing_outlined,
        message: 'Sin despachos en el rango.',
      );
    }
    return ListView(
      children: [
        MsgqSection(
          title: 'Clasificacion por equipo',
          subtitle: 'Todos los despachos, con el % Over SFL de cada equipo',
          child: Column(
            children: rows.take(80).map((r) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: Icon(
                    r.overSfl > 0
                        ? Icons.warning_amber_rounded
                        : Icons.check_circle_outline,
                    color: r.overSfl > 0 ? theme.colorScheme.error : null,
                  ),
                  title: Text(r.description == null
                      ? r.equipmentId
                      : '${r.equipmentId} · ${r.description}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${formatCount(r.dispenses)} despachos · '
                    '${formatCount(r.overSfl)} over\n'
                    'SFL ${r.sfl == null ? "—" : formatLitres(r.sfl!)} '
                    '(${r.sflSource.label})',
                  ),
                  isThreeLine: true,
                  trailing: Text(
                    formatPercent(r.overPct),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: r.overSfl > 0 ? theme.colorScheme.error : null,
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
}
