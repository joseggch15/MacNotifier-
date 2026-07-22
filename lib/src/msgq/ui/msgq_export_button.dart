/// Boton de export de las pantallas MSGQ.
///
/// Comparte lo que el auditor esta viendo AHORA: el reporte se arma con la
/// auditoria ya calculada en memoria y el alcance vigente (rango, circuito,
/// producto), no con una consulta nueva. Un PDF que no coincide con la pantalla
/// que lo genero es peor que no tener PDF.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../export/msgq_export_service.dart';
import '../export/msgq_report.dart';
import '../state/msgq_providers.dart';

/// Descripcion legible del alcance vigente, para la cabecera del reporte.
String msgqScopeLabel(WidgetRef ref) {
  final range = ref.read(msgqRangeProvider);
  final circuit = ref.read(msgqCircuitProvider);
  return [
    'Ultimos ${range.label.toLowerCase()}',
    if (circuit != null) 'circuito ${circuit.label}',
  ].join(' · ');
}

/// Menu de export (PDF / CSV) que construye el reporte bajo demanda.
class MsgqExportButton extends ConsumerStatefulWidget {
  const MsgqExportButton({super.key, required this.reportBuilder});

  /// Se invoca al elegir el formato, no al pintar el boton: armar el reporte
  /// recorre todas las tablas y no hay por que pagarlo en cada rebuild.
  final MsgqReport? Function() reportBuilder;

  @override
  ConsumerState<MsgqExportButton> createState() => _MsgqExportButtonState();
}

class _MsgqExportButtonState extends ConsumerState<MsgqExportButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return PopupMenuButton<MsgqExportFormat>(
      tooltip: 'Exportar',
      icon: const Icon(Icons.ios_share),
      onSelected: _export,
      itemBuilder: (_) => [
        for (final format in MsgqExportFormat.values)
          PopupMenuItem(
            value: format,
            child: Row(children: [
              Icon(
                format == MsgqExportFormat.pdf
                    ? Icons.picture_as_pdf_outlined
                    : Icons.table_chart_outlined,
                size: 18,
              ),
              const SizedBox(width: 10),
              Text('Compartir ${format.label}'),
            ]),
          ),
      ],
    );
  }

  Future<void> _export(MsgqExportFormat format) async {
    final report = widget.reportBuilder();
    final messenger = ScaffoldMessenger.of(context);
    if (report == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Aun no hay datos que exportar. Sincroniza primero.'),
      ));
      return;
    }
    setState(() => _busy = true);
    try {
      await const MsgqExportService().share(report, format: format);
    } on Object catch (e) {
      // Un fallo al escribir o al compartir se dice; quedarse en silencio deja
      // al usuario esperando una hoja de compartir que nunca aparece.
      messenger.showSnackBar(
        SnackBar(content: Text('No se pudo exportar: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
