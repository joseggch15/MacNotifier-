/// Pantalla de Desviacion de volumen — equivalente movil de
/// `VolumeDeviationWindow`.
///
/// Compara, entrega por entrega, el volumen MEDIDO contra el DIGITADO desde la
/// guia del camion. El notificador ya avisa de una entrega concreta; esto es lo
/// que responde "cuanto nos han cobrado de mas en el periodo".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/volume_deviation.dart';
import '../export/msgq_export_service.dart';
import '../state/msgq_providers.dart';
import 'msgq_charts.dart';
import 'msgq_export_button.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class VolumeDeviationScreen extends ConsumerStatefulWidget {
  const VolumeDeviationScreen({super.key});

  @override
  ConsumerState<VolumeDeviationScreen> createState() =>
      _VolumeDeviationScreenState();
}

class _VolumeDeviationScreenState extends ConsumerState<VolumeDeviationScreen> {
  bool _onlyFlagged = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dataset = ref.watch(msgqDatasetProvider);
    final audit = ref.watch(volumeDeviationProvider);
    final period = ref.watch(msgqPeriodProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Desviacion de volumen'),
        actions: [
          MsgqExportButton(
            reportBuilder: () => audit == null
                ? null
                : buildVolumeDeviationReport(audit, scope: msgqScopeLabel(ref)),
          ),
          IconButton(
            tooltip: 'Sincronizar',
            icon: const Icon(Icons.sync),
            onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
          ),
        ],
      ),
      body: dataset.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => MsgqEmpty(
          icon: Icons.error_outline,
          message: 'No se pudo leer la replica local.\n$e',
        ),
        data: (_) {
          if (audit == null) {
            return const MsgqEmpty(message: 'Sin datos replicados todavia.');
          }
          if (audit.deviations.isEmpty) {
            return const MsgqEmpty(
              icon: Icons.compare_arrows,
              message: 'Ninguna entrega del rango trae los DOS volumenes.\n\n'
                  'La comparacion necesita el medido y el de guia: sin ambos no '
                  'hay nada que contrastar.',
            );
          }
          final kpis = audit.kpis;
          final rows = _onlyFlagged ? audit.flaggedDeliveries : audit.deviations;
          final series = deviationOverTime(audit.deviations, period: period);

          return Column(
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
                child: ListView(
                  children: [
                    MsgqKpiRow(cards: [
                      MsgqKpiCard(
                        label: 'Entregas',
                        value: formatCount(kpis.analysed),
                        hint: 'con ambos volumenes',
                      ),
                      MsgqKpiCard(
                        label: 'Marcadas',
                        value: formatCount(kpis.flagged),
                        emphasis:
                            kpis.flagged > 0 ? theme.colorScheme.error : null,
                      ),
                      MsgqKpiCard(
                        label: 'Peor desviacion',
                        value: formatPercent(kpis.worstDeviationPct),
                      ),
                      MsgqKpiCard(
                        label: 'En disputa',
                        value: formatLitres(kpis.disputedL),
                      ),
                      MsgqKpiCard(
                        label: 'Saldo',
                        value: formatLitres(kpis.netOverbilledL),
                        hint: kpis.netOverbilledL >= 0
                            ? 'la guia cobra de mas'
                            : 'la guia cobra de menos',
                        emphasis: kpis.netOverbilledL > 0
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ]),
                    MsgqSection(
                      title: 'Saldo en el tiempo',
                      subtitle: '${period.label} · positivo = la guia reclama '
                          'mas de lo medido',
                      child: MsgqPeriodBarChart(
                        points: series
                            .map((p) => MsgqPoint(p.period, p.netOverbilledL))
                            .toList(),
                      ),
                    ),
                    MsgqSection(
                      title: 'Por tanque',
                      child: Column(
                        children: audit.byTank
                            .map((t) => ListTile(
                                  dense: true,
                                  title: Text(t.tank),
                                  subtitle: Text(
                                    '${formatCount(t.deliveries)} entregas · '
                                    '${formatCount(t.flagged)} marcadas\n'
                                    'medido ${formatLitres(t.measuredL)} · '
                                    'guia ${formatLitres(t.fieldL)}',
                                  ),
                                  isThreeLine: true,
                                  trailing: Text(
                                    formatLitres(t.netOverbilledL),
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: t.netOverbilledL > 0
                                          ? theme.colorScheme.error
                                          : null,
                                    ),
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                    MsgqSection(
                      title: 'Entregas',
                      subtitle: 'Ordenadas por magnitud de la desviacion',
                      trailing: FilterChip(
                        label: const Text('Solo marcadas'),
                        selected: _onlyFlagged,
                        onSelected: (v) => setState(() => _onlyFlagged = v),
                      ),
                      child: rows.isEmpty
                          ? const MsgqEmpty(
                              icon: Icons.verified_outlined,
                              message:
                                  'Ninguna entrega supera el umbral de desviacion.',
                            )
                          : Column(
                              children: rows
                                  .take(60)
                                  .map((d) => _DeviationCard(deviation: d))
                                  .toList(),
                            ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DeviationCard extends StatelessWidget {
  const _DeviationCard({required this.deviation});

  final VolumeDeviation deviation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overbilled = deviation.direction == DeviationDirection.overbilled;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: Icon(
          deviation.isCritical
              ? Icons.error_outline
              : (deviation.flagged
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline),
          color: deviation.flagged ? theme.colorScheme.error : null,
        ),
        title: Text(deviation.tank ?? '—'),
        subtitle: Text(
          '${formatDateTime(deviation.date)} · '
          '${deviation.product ?? "—"}\n${deviation.direction.label}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: Text(
          formatPercent(deviation.deviationPct),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color:
                overbilled && deviation.flagged ? theme.colorScheme.error : null,
          ),
        ),
        children: [
          _kv(context, 'Volumen medido',
              formatLitres(deviation.measuredVolume)),
          _kv(context, 'Volumen de guia', formatLitres(deviation.fieldVolume)),
          _kv(context, 'Diferencia', formatLitres(deviation.deviationL)),
          if (deviation.measuredSource != null)
            _kv(context, 'Fuente medida', deviation.measuredSource!),
          if (deviation.fieldSource != null)
            _kv(context, 'Fuente guia', deviation.fieldSource!),
          if (deviation.transactionType != null)
            _kv(context, 'Tipo', deviation.transactionType!),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String key, String value) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(key, style: Theme.of(context).textTheme.bodySmall),
            Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
}
