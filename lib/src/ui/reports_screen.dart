/// Generador de reportes: periodo + datasets + formato → archivo compartible.
///
/// El dataset "Despachos" (detalle completo de repostajes) se retiro de la UI
/// a peticion del usuario: en periodos largos descargaba decenas de miles de
/// registros y generaba conflictos. Los despachos siguen usandose
/// INTERNAMENTE para calcular los sobrellenados SFL del periodo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../api/adaptiq_client.dart';
import '../i18n/l10n.dart';
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
  bool _overfills = true;

  bool _busy = false;
  String _status = '';

  Future<void> _generate() async {
    final l = L10n(ref.read(settingsProvider).languageCode);
    setState(() {
      _busy = true;
      _status = l.t('Preparando…', 'Preparing…');
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
          includeDispenses: false, // retirado de la UI (ver doc de la libreria)
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(l.t('No se pudo generar: $e', 'Could not generate: $e'))));
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
    final l = L10n(settings.languageCode);
    return Scaffold(
      appBar: AppBar(title: Text(l.t('Reportes', 'Reports'))),
      body: !settings.isConfigured
          ? Center(
              child: Text(l.t('Configura el token de la API primero.',
                  'Configure the API token first.')))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(l.t('Periodo', 'Period'),
                    style: Theme.of(context).textTheme.titleMedium),
                for (final p in ReportPeriod.values)
                  RadioListTile<ReportPeriod>(
                    dense: true,
                    title: Text(p.label(l)),
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
                      l.t(
                          'El reporte anual descarga todo el año desde la API '
                              '(paginado de a 100): puede tardar varios minutos.',
                          'The yearly report downloads the whole year from the '
                              'API (paged by 100): it can take several minutes.'),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.orange),
                    ),
                  ),
                const Divider(height: 24),
                Text(l.t('Contenido', 'Content'),
                    style: Theme.of(context).textTheme.titleMedium),
                CheckboxListTile(
                  dense: true,
                  title: Text(l.t('Entregas (deliveries)', 'Deliveries')),
                  subtitle: Text(l.t('Medido vs guia, varianza y estado',
                      'Metered vs docket, variance and status')),
                  value: _deliveries,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _deliveries = v ?? false),
                ),
                CheckboxListTile(
                  dense: true,
                  title: Text(l.t('Sobrellenados SFL', 'SFL overfills')),
                  subtitle: Text(l.t(
                      'Como el export de Alerts/Alarms (Equipment Overfill)',
                      'Like the Alerts/Alarms export (Equipment Overfill)')),
                  value: _overfills,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _overfills = v ?? false),
                ),
                const Divider(height: 24),
                Text(l.t('Formato', 'Format'),
                    style: Theme.of(context).textTheme.titleMedium),
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
                      _busy || !(_deliveries || _overfills) ? null : _generate,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.ios_share),
                  label: Text(_busy
                      ? _status
                      : l.t('Generar y compartir', 'Generate and share')),
                ),
                const SizedBox(height: 8),
                Text(
                  l.t(
                      'El archivo se genera en el dispositivo y se abre la hoja '
                          'de compartir del sistema (correo, WhatsApp, Drive, …).',
                      'The file is generated on the device and the system share '
                          'sheet opens (mail, WhatsApp, Drive, …).'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }
}
