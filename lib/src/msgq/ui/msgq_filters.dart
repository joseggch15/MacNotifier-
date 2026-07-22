/// Controles de filtrado y estado de sincronizacion de los modulos MSGQ.
///
/// Los filtros escriben en los providers de estado; las pantallas solo LEEN los
/// providers derivados. Esa direccion unica es lo que permite que dos pantallas
/// abiertas a la vez compartan circuito y rango sin sincronizarse a mano.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/grouping.dart';
import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../state/msgq_providers.dart';
import 'msgq_widgets.dart';

/// Barra de filtros: rango de historico, circuito y granularidad.
class MsgqFilterBar extends ConsumerWidget {
  const MsgqFilterBar({
    super.key,
    this.showCircuit = false,
    this.showPeriod = false,
  });

  final bool showCircuit;
  final bool showPeriod;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(msgqRangeProvider);
    final circuit = ref.watch(msgqCircuitProvider);
    final period = ref.watch(msgqPeriodProvider);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          _Dropdown<MsgqRange>(
            icon: Icons.date_range_outlined,
            value: range,
            items: MsgqRange.values,
            labelOf: (r) => r.label,
            onChanged: (r) =>
                ref.read(msgqRangeProvider.notifier).state = r,
          ),
          if (showPeriod) ...[
            const SizedBox(width: 8),
            _Dropdown<AnalyticsPeriod>(
              icon: Icons.timeline_outlined,
              value: period,
              items: AnalyticsPeriod.values,
              labelOf: (p) => p.label,
              onChanged: (p) =>
                  ref.read(msgqPeriodProvider.notifier).state = p,
            ),
          ],
          if (showCircuit) ...[
            const SizedBox(width: 12),
            // `null` = todos los circuitos: hay que poder ver el sitio entero
            // antes de decidir en cual mirar de cerca.
            ChoiceChip(
              label: const Text('Todos'),
              selected: circuit == null,
              onSelected: (_) =>
                  ref.read(msgqCircuitProvider.notifier).state = null,
            ),
            ...Circuit.values.map((c) => Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text(c.label),
                    selected: circuit == c,
                    onSelected: (_) =>
                        ref.read(msgqCircuitProvider.notifier).state = c,
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

/// Menu para elegir la dimension de agrupacion de la flota.
class MsgqDimensionMenu extends ConsumerWidget {
  const MsgqDimensionMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dimension = ref.watch(msgqDimensionProvider);
    return PopupMenuButton<EquipmentDimension>(
      tooltip: 'Agrupar por',
      initialValue: dimension,
      onSelected: (d) => ref.read(msgqDimensionProvider.notifier).state = d,
      itemBuilder: (_) => EquipmentDimension.values
          .map((d) => PopupMenuItem(value: d, child: Text(d.label)))
          .toList(),
      child: Chip(
        avatar: const Icon(Icons.category_outlined, size: 16),
        label: Text(dimension.label),
      ),
    );
  }
}

/// Estado de la sincronizacion: barra de progreso con la fase en curso, o la
/// antiguedad de lo replicado cuando esta inactiva.
class MsgqSyncStatusBar extends ConsumerWidget {
  const MsgqSyncStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final progress = ref.watch(msgqSyncProgressProvider);
    final dataset = ref.watch(msgqDatasetProvider).valueOrNull;

    if (progress != null) {
      return Column(
        children: [
          const LinearProgressIndicator(minHeight: 3),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    progress.records == 0
                        ? 'Sincronizando ${progress.phase.label.toLowerCase()}…'
                        : '${progress.phase.label}: '
                            '${formatCount(progress.records)} registros',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(msgqDatasetProvider.notifier).cancelSync(),
                  child: const Text('Cancelar'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final syncedAt = dataset?.lastSyncedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          Icon(Icons.storage_outlined,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              syncedAt == null
                  ? 'Replica local sin sincronizar'
                  : 'Replica al ${formatDateTime(syncedAt)} · '
                      '${formatCount(dataset?.movements.length ?? 0)} movimientos',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.icon,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
  });

  final IconData icon;
  final T value;
  final List<T> items;
  final String Function(T) labelOf;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          DropdownButton<T>(
            value: value,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: items
                .map((i) => DropdownMenuItem(value: i, child: Text(labelOf(i))))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      );
}
