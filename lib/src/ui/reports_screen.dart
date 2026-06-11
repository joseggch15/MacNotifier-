/// Generador de reportes: periodo + datasets + formato → archivo compartible.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../api/adaptiq_client.dart';
import '../reports/report_service.dart';
import '../state/providers.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  ReportPeriod _period = ReportPeriod.daily;
  ReportFormat _format = ReportFormat.csv;
  bool _deliveries = true;
  bool _dispenses = false;
  bool _overfills = true;

  bool _busy = false;
  String _status = '';

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _status = 'Preparando…';
    });
    try {
      final service = ReportService(
        ref.read(settingsProvider),
        ref.read(appStoreProvider),
      );
      final result = await service.generate(
        ReportRequest(
          period: _period,
          format: _format,
          includeDeliveries: _deliveries,
          includeDispenses: _dispenses,
          includeOverfills: _overfills,
        ),
        onProgress: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      if (!mounted) return;
      await Share.shareXFiles(result.files, text: result.summary);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('No se pudo generar: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Reportes')),
      body: !settings.isConfigured
          ? const Center(
              child: Text('Configura el token de la API primero.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Periodo', style: Theme.of(context).textTheme.titleMedium),
                for (final p in ReportPeriod.values)
                  RadioListTile<ReportPeriod>(
                    dense: true,
                    title: Text(p.label),
                    value: p,
                    groupValue: _period,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _period = v ?? _period),
                  ),
                if (_period == ReportPeriod.yearly)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'El reporte anual descarga todo el año desde la API '
                      '(paginado de a 100): puede tardar varios minutos, '
                      'sobre todo con despachos incluidos.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.orange),
                    ),
                  ),
                const Divider(height: 24),
                Text('Contenido',
                    style: Theme.of(context).textTheme.titleMedium),
                CheckboxListTile(
                  dense: true,
                  title: const Text('Entregas (deliveries)'),
                  subtitle:
                      const Text('Medido vs guia, varianza y estado'),
                  value: _deliveries,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _deliveries = v ?? false),
                ),
                CheckboxListTile(
                  dense: true,
                  title: const Text('Sobrellenados SFL'),
                  subtitle: const Text(
                      'Como el export de Alerts/Alarms (Equipment Overfill)'),
                  value: _overfills,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _overfills = v ?? false),
                ),
                CheckboxListTile(
                  dense: true,
                  title: const Text('Despachos (dispenses)'),
                  subtitle: const Text(
                      'Detalle completo de repostajes — pesado en periodos largos'),
                  value: _dispenses,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _dispenses = v ?? false),
                ),
                const Divider(height: 24),
                Text('Formato', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<ReportFormat>(
                  segments: const [
                    ButtonSegment(
                        value: ReportFormat.csv,
                        icon: Icon(Icons.table_chart_outlined),
                        label: Text('CSV')),
                    ButtonSegment(
                        value: ReportFormat.pdf,
                        icon: Icon(Icons.picture_as_pdf_outlined),
                        label: Text('PDF')),
                  ],
                  selected: {_format},
                  onSelectionChanged: _busy
                      ? null
                      : (v) => setState(() => _format = v.first),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed:
                      _busy || !(_deliveries || _dispenses || _overfills)
                          ? null
                          : _generate,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.ios_share),
                  label: Text(_busy ? _status : 'Generar y compartir'),
                ),
                const SizedBox(height: 8),
                Text(
                  'El archivo se genera en el dispositivo y se abre la hoja '
                  'de compartir del sistema (correo, WhatsApp, Drive, …).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
