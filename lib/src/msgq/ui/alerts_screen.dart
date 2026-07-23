/// Panel consolidado de alertas — la vista de aterrizaje que responde "que esta
/// mal ahora mismo" y lleva a cada modulo.
///
/// Es agregacion pura de los auditores ya calculados: cada fila enlaza al modulo
/// donde ver el detalle. No hay deteccion nueva aqui, asi que los conteos
/// coinciden con los de cada pantalla.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/alerts_overview.dart';
import '../state/msgq_providers.dart';
import 'activity_screen.dart';
import 'burn_rate_screen.dart';
import 'data_quality_screen.dart';
import 'hardware_screen.dart';
import 'mac_health_screen.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';
import 'sfl_screen.dart';
import 'tag_hopping_screen.dart';
import 'volume_deviation_screen.dart';

class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  bool _showClean = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dataset = ref.watch(msgqDatasetProvider);
    final overview = ref.watch(alertsOverviewProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Panel de alertas'),
        actions: [
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
          if (overview == null) {
            return const MsgqEmpty(message: 'Sin datos replicados todavia.');
          }
          final rows = _showClean ? overview.categories : overview.active;
          return Column(
            children: [
              if (syncError != null)
                MsgqErrorBanner(
                  message: syncError,
                  onRetry: () =>
                      ref.read(msgqDatasetProvider.notifier).syncNow(),
                ),
              const MsgqSyncStatusBar(),
              const MsgqFilterBar(showCircuit: true),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: [
                    MsgqKpiRow(cards: [
                      MsgqKpiCard(
                        label: 'Criticas',
                        value: formatCount(overview.criticalCount),
                        emphasis: overview.criticalCount > 0
                            ? theme.colorScheme.error
                            : null,
                      ),
                      MsgqKpiCard(
                        label: 'Advertencias',
                        value: formatCount(overview.warningCount),
                      ),
                      MsgqKpiCard(
                        label: 'Total',
                        value: formatCount(overview.totalCount),
                        hint: '${overview.activeCategories} categorias',
                      ),
                    ]),
                    MsgqSection(
                      title: 'Categorias de alerta',
                      subtitle: 'Toca una para ver el detalle en su modulo',
                      trailing: FilterChip(
                        label: const Text('Ver limpias'),
                        selected: _showClean,
                        onSelected: (v) => setState(() => _showClean = v),
                      ),
                      child: overview.active.isEmpty && !_showClean
                          ? const MsgqEmpty(
                              icon: Icons.verified_outlined,
                              message: 'Sin hallazgos en el rango y circuito '
                                  'seleccionados.',
                            )
                          : Column(
                              children: rows
                                  .map((c) => _AlertRow(category: c))
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

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.category});

  final AlertCategory category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (category.severity) {
      AlertSeverity.critical => theme.colorScheme.error,
      AlertSeverity.warning => theme.colorScheme.tertiary,
      AlertSeverity.info => theme.colorScheme.onSurfaceVariant,
    };
    final clean = !category.isActive;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(
          clean
              ? Icons.check_circle_outline
              : switch (category.severity) {
                  AlertSeverity.critical => Icons.error_outline,
                  AlertSeverity.warning => Icons.warning_amber_rounded,
                  AlertSeverity.info => Icons.info_outline,
                },
          color: clean ? theme.colorScheme.onSurfaceVariant : color,
        ),
        title: Text(category.title),
        subtitle: category.detail == null ? null : Text(category.detail!),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatCount(category.count),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: clean ? theme.colorScheme.onSurfaceVariant : color,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => _screenFor(category.module)),
        ),
      ),
    );
  }

  Widget _screenFor(AlertModule module) => switch (module) {
        AlertModule.burnRate => const BurnRateScreen(),
        AlertModule.hardware => const HardwareScreen(),
        AlertModule.activity => const ActivityScreen(),
        AlertModule.product => const ActivityScreen(), // producto vive alli
        AlertModule.sfl => const SflScreen(),
        AlertModule.tagHopping => const TagHoppingScreen(),
        AlertModule.volumeDeviation => const VolumeDeviationScreen(),
        AlertModule.macHealth => const MacHealthScreen(),
        AlertModule.dataQuality => const DataQualityScreen(),
      };
}
