/// Pantalla de Tanques y Consumo — equivalente movil de `TankWindow` del
/// dashboard de escritorio.
///
/// Tres vistas sobre el mismo conjunto ya filtrado por circuito y rango:
///
///   * CONSUMO: que se despacha, a quien y en que ritmo.
///   * FLUJO: entradas vs salidas por tanque y en el tiempo.
///   * RECONCILIACION: stock medido vs movimiento registrado, y su descuadre.
///
/// Todo se recalcula en memoria desde [tankAnalyticsProvider], asi que cambiar
/// un filtro no dispara ni una peticion.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/grouping.dart';
import '../analytics/tank_analytics.dart';
import '../domain/fms_vocabulary.dart';
import '../state/msgq_providers.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class TankScreen extends ConsumerWidget {
  const TankScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataset = ref.watch(msgqDatasetProvider);
    final analytics = ref.watch(tankAnalyticsProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tanques y consumo'),
          actions: [
            IconButton(
              tooltip: 'Sincronizar',
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.local_gas_station_outlined), text: 'Consumo'),
            Tab(icon: Icon(Icons.swap_vert), text: 'Flujo'),
            Tab(icon: Icon(Icons.balance_outlined), text: 'Reconciliacion'),
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
                child: analytics == null
                    ? const MsgqEmpty(message: 'Sin datos replicados todavia.')
                    : TabBarView(children: [
                        _ConsumptionTab(analytics: analytics),
                        _FlowTab(analytics: analytics),
                        _ReconciliationTab(analytics: analytics),
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
// Consumo
// ===========================================================================

class _ConsumptionTab extends ConsumerWidget {
  const _ConsumptionTab({required this.analytics});

  final TankAnalytics analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(msgqPeriodProvider);
    final dimension = ref.watch(msgqDimensionProvider);
    final byProduct = analytics.consumptionByProduct();
    final byTank = analytics.consumptionByTank();
    final byCostCentre = analytics.consumptionByCostCentre();
    final byDimension = analytics.consumptionByDimension(dimension);
    final top = analytics.topConsumers(n: 15);
    final series = analytics.burnRate(period: period);
    final circuits = analytics.circuitSummary();

    final totalDispensed =
        byProduct.fold<double>(0, (acc, g) => acc + g.volumeL);
    final totalDispenses = byProduct.fold<int>(0, (acc, g) => acc + g.count);

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Despachado',
            value: formatLitres(totalDispensed),
            hint: '${formatCount(totalDispenses)} despachos',
          ),
          MsgqKpiCard(
            label: 'Productos',
            value: formatCount(byProduct.length),
            hint: '${circuits.length} circuitos',
          ),
          MsgqKpiCard(
            label: 'Tanques activos',
            value: formatCount(byTank.length),
          ),
          MsgqKpiCard(
            label: 'Equipos servidos',
            value: formatCount(top.length),
            hint: 'top mostrado',
          ),
        ]),
        MsgqSection(
          title: 'Consumo en el tiempo',
          subtitle: '${period.label} · volumen despachado por periodo',
          child: MsgqBarList(
            bars: series.reversed
                .map((p) => MsgqBar(
                      label: period == AnalyticsPeriod.monthly
                          ? formatMonth(p.period)
                          : formatDay(p.period),
                      value: p.volumeL,
                      caption: '${formatCount(p.dispenses)} despachos',
                    ))
                .toList(),
            maxItems: 14,
          ),
        ),
        MsgqSection(
          title: 'Por producto',
          child: MsgqBarList(bars: _toBars(byProduct)),
        ),
        MsgqSection(
          title: 'Por tanque',
          child: MsgqBarList(bars: _toBars(byTank)),
        ),
        MsgqSection(
          title: 'Por ${dimension.label.toLowerCase()}',
          subtitle: 'Une los despachos al maestro de equipos por equipment id',
          trailing: const MsgqDimensionMenu(),
          child: MsgqBarList(
            bars: _toBars(byDimension),
            emptyMessage: 'Sin maestro de equipos replicado: sincroniza para '
                'poder agrupar por ${dimension.label.toLowerCase()}.',
          ),
        ),
        MsgqSection(
          title: 'Por cost centre',
          child: MsgqBarList(bars: _toBars(byCostCentre)),
        ),
        MsgqSection(
          title: 'Mayores consumidores',
          child: MsgqBarList(
            bars: top
                .map((t) => MsgqBar(
                      label: t.description == null
                          ? t.equipmentId
                          : '${t.equipmentId} · ${t.description}',
                      value: t.volumeL,
                      caption: '${formatCount(t.dispenses)} despachos',
                    ))
                .toList(),
            maxItems: 15,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  List<MsgqBar> _toBars(List<VolumeGroup> groups) => groups
      .map((g) => MsgqBar(
            label: g.key,
            value: g.volumeL,
            caption: '${formatCount(g.count)} despachos',
          ))
      .toList();
}

// ===========================================================================
// Flujo
// ===========================================================================

class _FlowTab extends ConsumerWidget {
  const _FlowTab({required this.analytics});

  final TankAnalytics analytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(msgqPeriodProvider);
    final theme = Theme.of(context);
    final flows = analytics.flowByTank();
    final series = analytics.flowOverTime(period: period);

    final inflow = series.fold<double>(0, (acc, p) => acc + p.inflowL);
    final outflow = series.fold<double>(0, (acc, p) => acc + p.outflowL);

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(label: 'Inflow', value: formatLitres(inflow)),
          MsgqKpiCard(label: 'Outflow', value: formatLitres(outflow)),
          MsgqKpiCard(
            label: 'Neto',
            value: formatLitres(inflow - outflow),
            emphasis: inflow - outflow < 0 ? theme.colorScheme.error : null,
          ),
        ]),
        MsgqSection(
          title: 'Neto por periodo',
          subtitle: '${period.label} · entregas menos despachos y transferencias',
          child: MsgqBarList(
            bars: series.reversed
                .map((p) => MsgqBar(
                      label: period == AnalyticsPeriod.monthly
                          ? formatMonth(p.period)
                          : formatDay(p.period),
                      value: p.netL,
                      caption: 'in ${formatLitres(p.inflowL)} · '
                          'out ${formatLitres(p.outflowL)}',
                    ))
                .toList(),
            maxItems: 14,
          ),
        ),
        MsgqSection(
          title: 'Por tanque',
          subtitle: 'Las transferencias cuentan como salida del tanque origen: '
              'el destino no viaja en el registro',
          child: flows.isEmpty
              ? const MsgqEmpty(message: 'Sin movimientos en el periodo.')
              : Column(
                  children: flows
                      .take(20)
                      .map((f) => Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              title: Text(f.tank),
                              subtitle: Text(
                                'Entregas ${formatLitres(f.deliveriesL)}\n'
                                'Despachos ${formatLitres(f.dispensesL)} · '
                                'Transf. ${formatLitres(f.transfersOutL)}',
                              ),
                              isThreeLine: true,
                              trailing: Text(
                                formatLitres(f.netL),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: f.netL < 0
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

// ===========================================================================
// Reconciliacion
// ===========================================================================

class _ReconciliationTab extends StatelessWidget {
  const _ReconciliationTab({required this.analytics});

  final TankAnalytics analytics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kpis = analytics.reconciliationKpis();
    final detail = analytics.reconciliationDetail();
    final daily = analytics.reconciliationDaily();

    if (kpis == null) {
      return const MsgqEmpty(
        icon: Icons.balance_outlined,
        message: 'Sin reconciliaciones replicadas en el rango elegido.\n'
            'Sincroniza o amplia el rango.',
      );
    }

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(label: 'Tanques', value: formatCount(kpis.tanks)),
          MsgqKpiCard(
            label: 'Error total',
            value: formatLitres(kpis.totalErrorL),
            emphasis: theme.colorScheme.error,
          ),
          MsgqKpiCard(
            label: 'Error % outflow',
            value: formatPercent(kpis.errorPctOfOutflow),
          ),
          MsgqKpiCard(
            label: 'Peor tanque',
            value: kpis.worstTank,
            hint: formatLitres(kpis.worstErrorL),
          ),
        ]),
        MsgqSection(
          title: 'Descuadre por tanque',
          subtitle: 'Stock medido por el sensor menos movimiento registrado',
          child: Column(
            children: detail
                .map((r) => Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ExpansionTile(
                        title: Text(r.tank),
                        subtitle: Text(r.product ?? noDataLabel),
                        trailing: Text(
                          formatLitres(r.errorL),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: r.errorL.abs() > 0
                                ? theme.colorScheme.error
                                : null,
                          ),
                        ),
                        children: [
                          _kv(context, 'Stock inicial',
                              formatLitres(r.openingStockL)),
                          _kv(context, 'Stock final',
                              formatLitres(r.closingStockL)),
                          _kv(context, 'Cambio de stock',
                              formatLitres(r.stockChangeL)),
                          _kv(context, 'Inflow', formatLitres(r.inflowL)),
                          _kv(context, 'Outflow', formatLitres(r.outflowL)),
                          _kv(context, 'Cambio por movimiento',
                              formatLitres(r.movementChangeL)),
                          _kv(context, 'Error % outflow',
                              formatPercent(r.errorPctOfOutflow)),
                        ],
                      ),
                    ))
                .toList(),
          ),
        ),
        MsgqSection(
          title: 'Dia a dia',
          subtitle: '${formatCount(daily.length)} registros',
          child: Column(
            children: daily
                .take(60)
                .map((r) => ListTile(
                      dense: true,
                      title: Text('${r.tank ?? noDataLabel} · '
                          '${formatDay(r.periodEnd!)}'),
                      subtitle: Text(
                        'in ${formatLitres(r.inflow ?? 0)} · '
                        'out ${formatLitres(r.outflow ?? 0)} · ${r.status ?? "—"}',
                      ),
                      trailing: Text(
                        formatLitres(r.error ?? 0),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: (r.error ?? 0) != 0
                              ? theme.colorScheme.error
                              : null,
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

  Widget _kv(BuildContext context, String key, String value) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(key, style: Theme.of(context).textTheme.bodySmall),
            Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
}
