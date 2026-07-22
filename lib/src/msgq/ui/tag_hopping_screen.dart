/// Pantalla de Tag Hopping — equivalente movil de `TagHoppingWindow`.
///
/// Lista los pares de despachos del mismo tag en dos lugares en un lapso
/// imposible. Los CRITICOS (solapamiento temporal o teletransporte) van
/// primero: son los que no admiten explicacion operativa.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/tag_hopping.dart';
import '../domain/fms_vocabulary.dart';
import '../state/msgq_providers.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';

class TagHoppingScreen extends ConsumerStatefulWidget {
  const TagHoppingScreen({super.key});

  @override
  ConsumerState<TagHoppingScreen> createState() => _TagHoppingScreenState();
}

class _TagHoppingScreenState extends ConsumerState<TagHoppingScreen> {
  bool _onlyCritical = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dataset = ref.watch(msgqDatasetProvider);
    final audit = ref.watch(tagHoppingProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tag hopping'),
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
          if (audit == null) {
            return const MsgqEmpty(message: 'Sin datos replicados todavia.');
          }
          final events =
              _onlyCritical ? audit.criticalEvents : audit.events;
          return Column(
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
                child: ListView(
                  children: [
                    MsgqKpiRow(cards: [
                      MsgqKpiCard(
                        label: 'Eventos',
                        value: formatCount(audit.kpis.events),
                      ),
                      MsgqKpiCard(
                        label: 'Criticos',
                        value: formatCount(audit.kpis.critical),
                        emphasis: audit.kpis.critical > 0
                            ? theme.colorScheme.error
                            : null,
                      ),
                      MsgqKpiCard(
                        label: 'Equipos',
                        value: formatCount(audit.kpis.equipmentInvolved),
                      ),
                      MsgqKpiCard(
                        label: 'Por velocidad GPS',
                        value: formatCount(audit.kpis.bySpeed),
                        hint: 'requiere coordenadas',
                      ),
                    ]),
                    MsgqSection(
                      title: 'Eventos detectados',
                      subtitle: 'El lugar es el ACTIVO surtidor: dos tanques '
                          'del mismo camion no son dos lugares',
                      trailing: FilterChip(
                        label: const Text('Solo criticos'),
                        selected: _onlyCritical,
                        onSelected: (v) => setState(() => _onlyCritical = v),
                      ),
                      child: events.isEmpty
                          ? const MsgqEmpty(
                              icon: Icons.verified_outlined,
                              message: 'Ningun tag aparecio en dos lugares en '
                                  'un lapso imposible.',
                            )
                          : Column(
                              children: events
                                  .take(60)
                                  .map((e) => _EventCard(event: e))
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

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});

  final TagHopEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Un evento por velocidad con `speedKmh` nulo es un teletransporte: los dos
    // despachos comparten instante. Decirlo asi es mas claro que un "∞ km/h".
    final teleport =
        event.reason == tagHopReasonSpeed && event.speedKmh == null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: Icon(
          event.critical ? Icons.gpp_bad_outlined : Icons.warning_amber_rounded,
          color: event.critical ? theme.colorScheme.error : null,
        ),
        title: Text(
          event.equipmentDescription == null
              ? event.equipmentId
              : '${event.equipmentId} · ${event.equipmentDescription}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${teleport ? 'Teletransporte' : event.reason} · '
          '${event.gapMinutes} min de diferencia',
          style: theme.textTheme.bodySmall?.copyWith(
            color: event.critical ? theme.colorScheme.error : null,
          ),
        ),
        children: [
          _row(context, 'Antes',
              '${event.previousLocation}\n${formatDateTime(event.previousDate)}'),
          _row(context, 'Despues',
              '${event.location}\n${formatDateTime(event.date)}'),
          if (event.tag != null) _row(context, 'Tag', event.tag!),
          _row(context, 'Categoria', event.category),
          if (event.distanceKm != null)
            _row(context, 'Distancia', '${event.distanceKm} km'),
          if (event.speedKmh != null)
            _row(context, 'Velocidad implicita', '${event.speedKmh} km/h'),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String key, String value) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(key, style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(
              child: Text(value,
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      );
}
