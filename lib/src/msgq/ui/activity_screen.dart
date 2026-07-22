/// Pantalla de Auditoria de Actividad — equivalente movil de `ActivityWindow`,
/// con la auditoria de Producto en su propia pestaña.
///
///   * FANTASMAS: equipos 'In Service' que no consumen.
///   * SIN REPOSTAR: intervalos en los que el equipo trabajo mas de lo que su
///     tanque permite sin repostar dentro del FMS.
///   * SIN OPERAR: rachas de despachos con el SMU congelado.
///   * PRODUCTO: despachos de producto ajeno al equipo (posible tag clonado).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/activity_audit.dart';
import '../analytics/product_audit.dart';
import '../state/msgq_providers.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataset = ref.watch(msgqDatasetProvider);
    final activity = ref.watch(activityAuditProvider);
    final product = ref.watch(productAuditProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Actividad'),
          actions: [
            IconButton(
              tooltip: 'Sincronizar',
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
            ),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(icon: Icon(Icons.visibility_off_outlined), text: 'Fantasmas'),
            Tab(icon: Icon(Icons.local_gas_station_outlined), text: 'Sin repostar'),
            Tab(icon: Icon(Icons.pause_circle_outline), text: 'Sin operar'),
            Tab(icon: Icon(Icons.science_outlined), text: 'Producto'),
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
                child: activity == null || product == null
                    ? const MsgqEmpty(message: 'Sin datos replicados todavia.')
                    : TabBarView(children: [
                        _IdleTab(audit: activity),
                        _UnfueledTab(audit: activity),
                        _FrozenTab(audit: activity),
                        _ProductTab(audit: product),
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
// Fantasmas
// ===========================================================================

class _IdleTab extends ConsumerWidget {
  const _IdleTab({required this.audit});

  final ActivityAudit audit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final kpis = audit.kpis;
    if (kpis.equipmentInService == 0) {
      return const MsgqEmpty(
        icon: Icons.visibility_off_outlined,
        message: 'El maestro de equipos aun no esta replicado.\n'
            'Pulsa sincronizar para descargarlo.',
      );
    }
    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'En servicio',
            value: formatCount(kpis.equipmentInService),
          ),
          MsgqKpiCard(
            label: 'Fantasmas',
            value: formatCount(kpis.idleAssets),
            hint: '≥ ${audit.idleDays} dias sin despachar',
            emphasis: kpis.idleAssets > 0 ? theme.colorScheme.error : null,
          ),
          MsgqKpiCard(
            label: 'Nunca despacharon',
            value: formatCount(kpis.neverDispensed),
          ),
          MsgqKpiCard(
            label: '% de la flota',
            value: formatPercent(kpis.idlePctOfFleet),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text('Umbral', style: theme.textTheme.bodySmall),
              const SizedBox(width: 8),
              // El umbral es del auditor, no del software: 15 dias sirve para
              // una flota de mina, 30 para equipos de apoyo.
              ...[7, 15, 30, 60].map((d) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('$d d'),
                      selected: audit.idleDays == d,
                      onSelected: (_) =>
                          ref.read(idleDaysProvider.notifier).state = d,
                    ),
                  )),
            ],
          ),
        ),
        MsgqSection(
          title: 'Equipos sin consumo',
          subtitle: 'Figuran operativos pero no despachan: inflan la '
              'disponibilidad reportada',
          child: audit.idleAssets.isEmpty
              ? const MsgqEmpty(
                  icon: Icons.verified_outlined,
                  message: 'Todos los equipos en servicio han despachado '
                      'dentro del umbral.',
                )
              : Column(
                  children: audit.idleAssets
                      .take(80)
                      .map((a) => Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              leading: Icon(
                                a.idleClass == IdleClass.neverDispensed
                                    ? Icons.block
                                    : Icons.schedule,
                                color: a.isCritical
                                    ? theme.colorScheme.error
                                    : null,
                              ),
                              title: Text(a.description == null
                                  ? a.equipmentId
                                  : '${a.equipmentId} · ${a.description}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text([
                                a.idleClass.label,
                                if (a.category != null) a.category!,
                                if (a.lastDispense != null)
                                  'ultimo ${formatDay(a.lastDispense!)}',
                                '${formatCount(a.historicDispenses)} despachos historicos',
                              ].join(' · ')),
                              isThreeLine: true,
                              trailing: Text(
                                a.daysIdle == null
                                    ? '—'
                                    : '${a.daysIdle!.toStringAsFixed(0)} d',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: a.isCritical
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
// Trabaja sin repostar
// ===========================================================================

class _UnfueledTab extends StatelessWidget {
  const _UnfueledTab({required this.audit});

  final ActivityAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.unfueled.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.local_gas_station_outlined,
        message: 'Ningun equipo trabajo mas de lo que su tanque permite sin '
            'repostar dentro del FMS.\n\nRequiere lectura de SMU por despacho: '
            'los equipos sin horometro no participan de esta regla.',
      );
    }
    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Intervalos',
            value: formatCount(audit.kpis.unfueledIntervals),
            emphasis: theme.colorScheme.error,
          ),
          MsgqKpiCard(
            label: 'Combustible no registrado',
            value: formatLitres(audit.kpis.unregisteredLitres),
            hint: 'estimado',
          ),
        ]),
        MsgqSection(
          title: 'Combustible fuera del FMS',
          subtitle: 'Consumo estimado por el SMU contra todo lo que si quedo '
              'registrado en la ventana',
          child: Column(
            children: audit.unfueled.take(60).map((u) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ExpansionTile(
                  leading: Icon(Icons.warning_amber_rounded,
                      color: theme.colorScheme.error),
                  title: Text(
                    u.equipmentDescription == null
                        ? u.equipmentId
                        : '${u.equipmentId} · ${u.equipmentDescription}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${formatDay(u.from)} → ${formatDay(u.to)} · '
                    '${u.days.toStringAsFixed(0)} dias',
                  ),
                  trailing: Text(
                    formatLitres(u.unregisteredLitres),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  children: [
                    _kv(context, 'Avance de SMU',
                        '${u.smuDelta} ${u.smuType ?? ""}'),
                    _kv(context, 'Burn rate tipico',
                        '${u.typicalBurnRate} L/h'),
                    _kv(context, 'Consumo esperado',
                        formatLitres(u.expectedLitres)),
                    _kv(context, 'Registrado en el FMS',
                        formatLitres(u.dispensedLitres)),
                    _kv(context, 'Safe Fill Level', formatLitres(u.sfl)),
                    const SizedBox(height: 8),
                  ],
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

// ===========================================================================
// Repostado sin operar
// ===========================================================================

class _FrozenTab extends StatelessWidget {
  const _FrozenTab({required this.audit});

  final ActivityAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.frozen.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.pause_circle_outline,
        message: 'Ninguna racha de despachos con el SMU congelado.',
      );
    }
    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Rachas',
            value: formatCount(audit.kpis.frozenRuns),
          ),
          MsgqKpiCard(
            label: 'Sobre el SFL',
            value: formatCount(audit.kpis.runsOverSfl),
            hint: 'el tanque no pudo absorberlos',
            emphasis:
                audit.kpis.runsOverSfl > 0 ? theme.colorScheme.error : null,
          ),
        ]),
        MsgqSection(
          title: 'Despachos sin operacion',
          subtitle: 'El equipo recibe combustible pero su SMU no avanza. Puede '
              'ser un sensor dañado; si los litros superan el SFL, es desvio',
          child: Column(
            children: audit.frozen.take(60).map((f) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: Icon(
                    f.overSfl
                        ? Icons.error_outline
                        : Icons.pause_circle_outline,
                    color: f.overSfl ? theme.colorScheme.error : null,
                  ),
                  title: Text(
                    f.equipmentDescription == null
                        ? f.equipmentId
                        : '${f.equipmentId} · ${f.equipmentDescription}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${formatDay(f.from)} → ${formatDay(f.to)} · '
                    '${f.days.toStringAsFixed(0)} dias · '
                    '${formatCount(f.dispenses)} despachos\n'
                    'SMU congelado en ${f.frozenSmu}'
                    '${f.sfl == null ? "" : " · SFL ${formatLitres(f.sfl!)}"}',
                  ),
                  isThreeLine: true,
                  trailing: Text(
                    formatLitres(f.litres),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: f.overSfl ? theme.colorScheme.error : null,
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

// ===========================================================================
// Producto
// ===========================================================================

class _ProductTab extends StatefulWidget {
  const _ProductTab({required this.audit});

  final ProductAudit audit;

  @override
  State<_ProductTab> createState() => _ProductTabState();
}

class _ProductTabState extends State<_ProductTab> {
  bool _onlyCrossClass = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kpis = widget.audit.kpis;
    final rows = _onlyCrossClass
        ? widget.audit.crossClassMismatches
        : widget.audit.mismatches;

    if (widget.audit.mismatches.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.verified_outlined,
        message: 'Ningun despacho de producto ajeno al equipo.\n\n'
            'Un equipo sin productos establecidos se omite: no hay base con '
            'que juzgarlo.',
      );
    }

    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Despachos ajenos',
            value: formatCount(kpis.mismatches),
          ),
          MsgqKpiCard(
            label: 'Cruce de clase',
            value: formatCount(kpis.crossClass),
            hint: 'combustible vs fluido',
            emphasis: kpis.crossClass > 0 ? theme.colorScheme.error : null,
          ),
          MsgqKpiCard(
            label: 'Equipos',
            value: formatCount(kpis.equipmentAffected),
          ),
        ]),
        MsgqSection(
          title: 'Producto ajeno al equipo',
          subtitle: 'Un cruce ENTRE clases es la señal fuerte de tag clonado: '
              'no es mala configuracion, es otra maquina',
          trailing: FilterChip(
            label: const Text('Solo cruces'),
            selected: _onlyCrossClass,
            onSelected: (v) => setState(() => _onlyCrossClass = v),
          ),
          child: Column(
            children: rows.take(60).map((m) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ExpansionTile(
                  leading: Icon(
                    m.crossClass ? Icons.dangerous_outlined : Icons.help_outline,
                    color: m.crossClass ? theme.colorScheme.error : null,
                  ),
                  title: Text(
                    m.equipmentDescription == null
                        ? m.equipmentId
                        : '${m.equipmentId} · ${m.equipmentDescription}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${m.product ?? "—"} (${m.productClassOf.label}) · '
                    '${m.date == null ? "—" : formatDay(m.date!)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: m.crossClass ? theme.colorScheme.error : null,
                    ),
                  ),
                  children: [
                    _kv(context, 'Alerta', m.alertCategory),
                    if (m.expectedProducts != null)
                      _kv(context, 'Productos del equipo', m.expectedProducts!),
                    if (m.expectedClasses != null)
                      _kv(context, 'Clases esperadas', m.expectedClasses!),
                    if (m.volume != null)
                      _kv(context, 'Volumen', formatLitres(m.volume!)),
                    if (m.dispensingPoint != null)
                      _kv(context, 'Punto', m.dispensingPoint!),
                    if (m.fieldUser != null)
                      _kv(context, 'Operador', m.fieldUser!),
                    const SizedBox(height: 8),
                  ],
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

Widget _kv(BuildContext context, String key, String value) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(key, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
