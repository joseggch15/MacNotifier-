/// Pantalla de Calidad de datos — equivalente movil de la ventana de dirty data.
///
/// Corre sobre el maestro COMPLETO replicado: la calidad del dato es una
/// propiedad del registro, no del filtro de la vista. Por eso esta pantalla NO
/// lleva la barra de rango ni de circuito.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/data_quality.dart';
import '../export/msgq_export_service.dart';
import '../state/msgq_providers.dart';
import 'msgq_export_button.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class DataQualityScreen extends ConsumerWidget {
  const DataQualityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dataset = ref.watch(msgqDatasetProvider);
    final audit = ref.watch(dataQualityProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Calidad de datos'),
          actions: [
            MsgqExportButton(
              reportBuilder: () => audit == null
                  ? null
                  : buildDataQualityReport(audit,
                      scope: 'Maestro de equipos completo'),
            ),
            IconButton(
              tooltip: 'Sincronizar',
              icon: const Icon(Icons.sync),
              onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.summarize_outlined), text: 'Resumen'),
            Tab(icon: Icon(Icons.merge_type_outlined), text: 'Variantes'),
            Tab(icon: Icon(Icons.compare_outlined), text: 'Similares'),
          ]),
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
            if (audit.summary.isEmpty) {
              return const MsgqEmpty(
                icon: Icons.inventory_2_outlined,
                message: 'El maestro de equipos aun no esta replicado.\n'
                    'Sincroniza para poder auditar sus campos.',
              );
            }
            return Column(
              children: [
                if (syncError != null)
                  MsgqErrorBanner(
                    message: syncError,
                    onRetry: () =>
                        ref.read(msgqDatasetProvider.notifier).syncNow(),
                  ),
                const MsgqSyncStatusBar(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Se audita el maestro completo, no el rango: la '
                          'calidad del dato no depende de la consulta.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 12),
                Expanded(
                  child: TabBarView(children: [
                    _SummaryTab(audit: audit),
                    _VariantsTab(audit: audit),
                    _FuzzyTab(audit: audit),
                  ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SummaryTab extends StatelessWidget {
  const _SummaryTab({required this.audit});

  final DataQualityAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kpis = audit.kpis;
    return ListView(
      children: [
        MsgqKpiRow(cards: [
          MsgqKpiCard(
            label: 'Campos con problemas',
            value: formatCount(kpis.fieldsWithProblems),
            emphasis:
                kpis.fieldsWithProblems > 0 ? theme.colorScheme.error : null,
          ),
          MsgqKpiCard(label: 'Grupos sucios', value: formatCount(kpis.dirtyGroups)),
          MsgqKpiCard(
            label: 'Equipos afectados',
            value: formatCount(kpis.equipmentAffected),
          ),
          MsgqKpiCard(
            label: 'Pares similares',
            value: formatCount(kpis.similarPairs),
          ),
        ]),
        MsgqSection(
          title: 'Por campo',
          subtitle: 'La brecha entre valores distintos y reales es la magnitud '
              'del dirty data',
          child: Column(
            children: audit.summary.map((s) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: Icon(
                    s.hasProblems
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    color: s.hasProblems ? theme.colorScheme.error : null,
                  ),
                  title: Text(s.field),
                  subtitle: Text(
                    '${formatCount(s.distinctValues)} escrituras → '
                    '${formatCount(s.realValues)} valores reales\n'
                    '${formatCount(s.dirtyGroups)} grupos sucios · '
                    '${formatCount(s.similarPairs)} pares similares',
                  ),
                  isThreeLine: true,
                  trailing: Text(
                    formatCount(s.equipmentAffected),
                    style: theme.textTheme.titleSmall,
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

class _VariantsTab extends StatelessWidget {
  const _VariantsTab({required this.audit});

  final DataQualityAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.clusters.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.verified_outlined,
        message: 'Ningun campo tiene el mismo valor escrito de varias formas.',
      );
    }
    return ListView(
      children: [
        MsgqSection(
          title: 'Grupos de variantes',
          subtitle: 'Escrituras del mismo valor; la mas frecuente se sugiere '
              'como canonica',
          child: Column(
            children: audit.clusters.map((c) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ExpansionTile(
                  leading: const Icon(Icons.merge_type_outlined),
                  title: Text('${c.field}: ${c.canonical}'),
                  subtitle: Text('${formatCount(c.variants)} variantes · '
                      '${formatCount(c.equipmentCount)} equipos'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(c.writings,
                          style: theme.textTheme.bodyMedium),
                    ),
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

class _FuzzyTab extends StatelessWidget {
  const _FuzzyTab({required this.audit});

  final DataQualityAudit audit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (audit.fuzzy.isEmpty) {
      return const MsgqEmpty(
        icon: Icons.verified_outlined,
        message: 'Sin duplicados probables por typo u OCR.',
      );
    }
    return ListView(
      children: [
        MsgqSection(
          title: 'Duplicados probables',
          subtitle: 'Valores parecidos que la normalizacion no fusiono '
              '(Caterpillar vs Caterpilar)',
          child: Column(
            children: audit.fuzzy.map((f) {
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.compare_outlined),
                  title: Text('${f.valueA}  ↔  ${f.valueB}'),
                  subtitle: Text('${f.field} · '
                      '${formatCount(f.equipmentA)} vs '
                      '${formatCount(f.equipmentB)} equipos'),
                  trailing: Text(
                    formatPercent(f.similarityPct),
                    style: theme.textTheme.titleSmall,
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
