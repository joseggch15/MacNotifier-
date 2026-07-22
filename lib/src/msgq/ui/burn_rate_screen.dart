/// Pantalla de Burn Rate — equivalente movil de `BurnRateWindow`.
///
///   * EQUIPOS: burn rate tipico de cada uno contra la linea base de su
///     categoria, con los anomalos arriba.
///   * CATEGORIAS: las lineas base y su dispersion.
///   * INTERVALOS: despachos puntuales fuera del historial del propio equipo.
///
/// El aviso de COBERTURA no es decorativo: el burn rate solo existe donde hay
/// lectura de SMU, y si el sensor dejo de reportar la mitad del periodo, dos
/// rangos distintos dan el mismo resultado. Sin ese aviso el auditor concluiria
/// que "no cambio nada".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/burn_rate.dart';
import '../state/msgq_providers.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class BurnRateScreen extends ConsumerWidget {
  const BurnRateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataset = ref.watch(msgqDatasetProvider);
    final audit = ref.watch(burnRateProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Burn Rate'),
          actions: [
            IconButton(
              tooltip: 'Sincronizar',
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.precision_manufacturing_outlined), text: 'Equipos'),
            Tab(icon: Icon(Icons.category_outlined), text: 'Categorias'),
            Tab(icon: Icon(Icons.show_chart), text: 'Intervalos'),
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
              if (audit != null) _ProductSelector(audit: audit),
              if (audit != null) _CoverageNotice(audit: audit),
              const Divider(height: 1),
              Expanded(
                child: audit == null || audit.samples.isEmpty
                    ? const MsgqEmpty(
                        icon: Icons.speed_outlined,
                        message: 'Sin intervalos de burn rate en el rango.\n'
                            'Solo se calcula con despachos que traen lectura de '
                            'SMU (horometro/odometro).',
                      )
                    : TabBarView(children: [
                        _EquipmentTab(audit: audit),
                        _CategoriesTab(audit: audit),
                        _IntervalsTab(audit: audit),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductSelector extends ConsumerWidget {
  const _ProductSelector({required this.audit});

  final BurnRateAudit audit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (audit.products.length < 2) return const SizedBox.shrink();
    final selected = ref.watch(burnRateProductProvider);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          // Agregar todos los productos mezcla litros de combustible con litros
          // de lubricante sobre las mismas horas: util como panorama, enganoso
          // como cifra. Por eso el selector esta a la vista.
          ChoiceChip(
            label: const Text('Todos'),
            selected: selected == null,
            onSelected: (_) =>
                ref.read(burnRateProductProvider.notifier).state = null,
          ),
          ...audit.products.map((p) => Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ChoiceChip(
                  label: Text(p),
                  selected: selected == p,
                  onSelected: (_) =>
                      ref.read(burnRateProductProvider.notifier).state = p,
                ),
              )),
        ],
      ),
    );
  }
}

class _CoverageNotice extends ConsumerWidget {
  const _CoverageNotice({required this.audit});

  final BurnRateAudit audit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(msgqRangeProvider);
    final coverage = audit.coverage(range.start(), DateTime.now().toUtc());
    if (!coverage.partial || coverage.first == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Row(
          children: [
            Icon(Icons.info_outline,
                size: 16, color: theme.colorScheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Cobertura parcial: hay datos de SMU del '
                '${formatDay(coverage.first!)} al ${formatDay(coverage.last!)} '
                '(${coverage.spanDays} de ${coverage.rangeDays} dias del rango). '
                'Ampliar el rango puede no cambiar el resultado.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Equipos
// ===========================================================================

class _EquipmentTab extends StatelessWidget {
  const _EquipmentTab({required this.audit});

  final BurnRateAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kpis = audit.kpis;
    final anomalies = audit.equipmentAnomalies;

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Equipos analizados',
            value: formatCount(kpis.equipmentAnalysed),
            hint: 'con $burnRateMinSamplesHint',
          ),
          MsgqKpiCard(
            label: 'Anomalos',
            value: formatCount(kpis.anomalousEquipment),
            emphasis:
                kpis.anomalousEquipment > 0 ? theme.colorScheme.error : null,
          ),
          MsgqKpiCard(
            label: 'Burn rate flota',
            value: '${kpis.fleetBurnRate} L/h',
          ),
          MsgqKpiCard(
            label: 'Peor desviacion',
            value: formatPercent(kpis.worstDeviationPct),
          ),
          MsgqKpiCard(
            label: 'Intervalos',
            value: formatCount(kpis.intervals),
            hint: '${formatCount(kpis.atypicalIntervals)} atipicos',
          ),
        ]),
        MsgqSection(
          title: 'Equipos anomalos',
          subtitle: 'Alto = sobre-consumo (fuga, robo, falla). '
              'Bajo = sub-consumo (medidor mal o despachos sin registrar)',
          child: anomalies.isEmpty
              ? const MsgqEmpty(
                  icon: Icons.verified_outlined,
                  message: 'Ningun equipo se desvia de su categoria por encima '
                      'de los umbrales.',
                )
              : Column(children: anomalies.map(_tile).toList()),
        ),
        MsgqSection(
          title: 'Todos los equipos',
          subtitle: 'Incluye los que aun no tienen muestras suficientes',
          child: Column(
            children: audit.equipment.take(50).map(_tile).toList(),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _tile(EquipmentBurnRate e) => Builder(builder: (context) {
        final theme = Theme.of(context);
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: e.anomalous
                ? Icon(Icons.warning_amber_rounded,
                    color: theme.colorScheme.error)
                : Icon(
                    e.isReliable
                        ? Icons.check_circle_outline
                        : Icons.help_outline,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
            title: Text('${e.equipmentId} · ${e.equipmentDescription}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text([
              e.category,
              '${e.samples} muestras',
              if (e.baseline != null) 'base ${e.baseline} L/h',
              if (e.deviationPct != null)
                '${e.direction.label} ${formatPercent(e.deviationPct!.abs())}',
            ].join(' · ')),
            isThreeLine: true,
            trailing: Text(
              '${e.burnRate}\nL/h',
              textAlign: TextAlign.right,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: e.anomalous ? theme.colorScheme.error : null,
              ),
            ),
          ),
        );
      });
}

/// Texto del minimo de muestras, para no repetir la constante en la UI.
const String burnRateMinSamplesHint = '3+ intervalos';

// ===========================================================================
// Categorias
// ===========================================================================

class _CategoriesTab extends StatelessWidget {
  const _CategoriesTab({required this.audit});

  final BurnRateAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.categories.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.category_outlined,
        message: 'Ninguna categoria tiene equipos confiables suficientes para '
            'fijar una linea base.',
      );
    }
    return ListView(
      children: [
        MsgqSection(
          title: 'Linea base por categoria',
          subtitle: 'Mediana de los equipos confiables de cada categoria',
          child: MsgqBarList(
            bars: audit.categories
                .map((c) => MsgqBar(
                      label: c.category,
                      value: c.baseline,
                      caption: '${formatCount(c.equipmentCount)} equipos · '
                          'rango ${c.min}–${c.max} L/h'
                          '${c.anomalous > 0 ? ' · ${c.anomalous} anomalos' : ''}',
                      color: c.anomalous > 0 ? theme.colorScheme.error : null,
                    ))
                .toList(),
            maxItems: audit.categories.length,
            valueFormatter: (v) => '$v L/h',
          ),
        ),
        MsgqSection(
          title: 'Dispersion',
          subtitle: 'Cuanto varian los equipos dentro de su categoria. Una '
              'dispersion muy baja hace que cualquier diferencia parezca '
              'significativa',
          child: MsgqBarList(
            bars: audit.categories
                .map((c) => MsgqBar(label: c.category, value: c.dispersion))
                .toList(),
            maxItems: audit.categories.length,
            valueFormatter: (v) => '$v L/h',
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ===========================================================================
// Intervalos
// ===========================================================================

class _IntervalsTab extends StatelessWidget {
  const _IntervalsTab({required this.audit});

  final BurnRateAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = audit.intervalAnomalies;
    if (rows.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.show_chart,
        message: 'Ningun despacho se aparta del historial de su propio equipo.',
      );
    }
    return ListView(
      children: [
        MsgqSection(
          title: 'Despachos atipicos',
          subtitle: 'Comparados contra el historial del MISMO equipo y producto',
          child: Column(
            children: rows.take(60).map((a) {
              final s = a.sample;
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text('${s.equipmentId} · ${s.equipmentDescription}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${s.date == null ? '—' : formatDateTime(s.date)} · '
                    '${s.product}\n'
                    '${formatLitres(s.litres)} sobre ${s.smuDelta} de SMU · '
                    'tipico ${a.typicalBurnRate} L/h',
                  ),
                  isThreeLine: true,
                  trailing: Text(
                    '${s.burnRate}\nL/h',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.error,
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
