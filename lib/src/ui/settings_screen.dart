/// Configuracion: token/endpoint/sitio + cadencias + notificaciones.
///
/// "Probar conexion" ejecuta la query `sites` con lo que hay EN EL FORMULARIO
/// (sin guardar), igual que el dialogo de conexion de MSGQ: valida token y
/// endpoint y muestra que sitio quedaria seleccionado.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/adaptiq_client.dart';
import '../config/app_settings.dart';
import '../notifications/notification_service.dart';
import '../state/providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _endpoint;
  late final TextEditingController _token;
  late final TextEditingController _siteMatch;
  late final TextEditingController _siteId;

  late int _pollSeconds;
  late int _backgroundMinutes;
  late int _staleMinutes;
  late bool _notificationsEnabled;
  late bool _notifyRecovery;
  late bool _monitorDeliveries;
  late double _varianceThresholdPct;

  bool _tokenVisible = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _endpoint = TextEditingController(text: s.endpoint);
    _token = TextEditingController(text: s.token);
    _siteMatch = TextEditingController(text: s.siteMatch);
    _siteId = TextEditingController(text: s.siteId);
    _pollSeconds = s.pollSeconds;
    _backgroundMinutes = s.backgroundMinutes;
    _staleMinutes = s.staleMinutes;
    _notificationsEnabled = s.notificationsEnabled;
    _notifyRecovery = s.notifyRecovery;
    _monitorDeliveries = s.monitorDeliveries;
    _varianceThresholdPct = s.varianceThresholdPct;
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    _siteMatch.dispose();
    _siteId.dispose();
    super.dispose();
  }

  AppSettings _fromForm() => ref.read(settingsProvider).copyWith(
        endpoint: _endpoint.text.trim(),
        token: _token.text.trim(),
        siteMatch: _siteMatch.text.trim(),
        siteId: _siteId.text.trim(),
        pollSeconds: _pollSeconds,
        backgroundMinutes: _backgroundMinutes,
        staleMinutes: _staleMinutes,
        notificationsEnabled: _notificationsEnabled,
        notifyRecovery: _notifyRecovery,
        monitorDeliveries: _monitorDeliveries,
        varianceThresholdPct: _varianceThresholdPct,
      );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await ref.read(settingsProvider.notifier).save(_fromForm());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Configuracion guardada.')),
    );
    Navigator.of(context).pop();
  }

  Future<void> _testConnection() async {
    setState(() => _testing = true);
    final client = AdaptIQClient(_fromForm());
    try {
      final sites = await client.fetchSites();
      if (!mounted) return;
      final match = _siteMatch.text.trim().toLowerCase();
      final lines = sites.map((s) {
        final blob = '${s['code'] ?? ''} ${s['description'] ?? ''}';
        final hit = match.isNotEmpty && blob.toLowerCase().contains(match);
        return '${hit ? '✅' : '•'} [${s['id']}] $blob';
      }).join('\n');
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Conexion OK — ${sites.length} sitio(s)'),
          content: Text(lines.isEmpty ? 'El token no ve ningun sitio.' : lines),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cerrar')),
          ],
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fallo la conexion: $e')),
      );
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuracion')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Conexion AdaptIQ',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextFormField(
              controller: _endpoint,
              decoration: const InputDecoration(
                labelText: 'Endpoint GraphQL',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              validator: (v) {
                final uri = Uri.tryParse((v ?? '').trim());
                if (uri == null || !uri.isAbsolute || !uri.scheme.startsWith('http')) {
                  return 'URL invalida';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _token,
              obscureText: !_tokenVisible,
              decoration: InputDecoration(
                labelText: 'Token de la API',
                helperText: 'Viaja como  Authorization: Token token=<token>',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                      _tokenVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
                ),
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'El token es obligatorio' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _siteMatch,
                    decoration: const InputDecoration(
                      labelText: 'Sitio (texto a buscar)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _siteId,
                    decoration: const InputDecoration(
                      labelText: 'Site ID (opcional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: const Text('Probar conexion'),
            ),
            const Divider(height: 32),
            Text('Cadencias', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _pollSeconds,
              decoration: const InputDecoration(
                labelText: 'Polling con la app abierta',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 10, child: Text('Cada 10 segundos')),
                DropdownMenuItem(value: 20, child: Text('Cada 20 segundos')),
                DropdownMenuItem(value: 30, child: Text('Cada 30 segundos')),
                DropdownMenuItem(value: 60, child: Text('Cada 60 segundos')),
              ],
              onChanged: (v) => setState(() => _pollSeconds = v ?? 20),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _backgroundMinutes,
              decoration: const InputDecoration(
                labelText: 'Chequeo con la app cerrada',
                helperText: 'Android no permite menos de 15 minutos',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 15, child: Text('Cada 15 minutos')),
                DropdownMenuItem(value: 30, child: Text('Cada 30 minutos')),
                DropdownMenuItem(value: 60, child: Text('Cada hora')),
              ],
              onChanged: (v) => setState(() => _backgroundMinutes = v ?? 15),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _staleMinutes,
              decoration: const InputDecoration(
                labelText: 'Umbral de comunicacion stale',
                helperText:
                    'Online pero sin comunicacion exitosa hace mas de N min',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 15, child: Text('15 minutos')),
                DropdownMenuItem(value: 30, child: Text('30 minutos')),
                DropdownMenuItem(value: 60, child: Text('60 minutos')),
                DropdownMenuItem(value: 120, child: Text('2 horas')),
              ],
              onChanged: (v) => setState(() => _staleMinutes = v ?? 30),
            ),
            const Divider(height: 32),
            Text('Entregas (deliveries)',
                style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: const Text('Monitorear entregas'),
              subtitle: const Text(
                  'Alerta entregas sin confirmar y varianza medidor vs guia'),
              value: _monitorDeliveries,
              onChanged: (v) => setState(() => _monitorDeliveries = v),
            ),
            if (_monitorDeliveries) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<double>(
                value: _varianceThresholdPct,
                decoration: const InputDecoration(
                  labelText: 'Umbral de varianza',
                  helperText:
                      '|medido − guia| / guia. A partir de 5% la alerta es critica.',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 0.5, child: Text('0.5 %')),
                  DropdownMenuItem(value: 1.0, child: Text('1 % (recomendado)')),
                  DropdownMenuItem(value: 2.0, child: Text('2 %')),
                  DropdownMenuItem(value: 5.0, child: Text('5 %')),
                ],
                onChanged: (v) =>
                    setState(() => _varianceThresholdPct = v ?? 1.0),
              ),
              const SizedBox(height: 4),
            ],
            const Divider(height: 32),
            Text('Notificaciones',
                style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: const Text('Notificaciones activas'),
              subtitle: const Text(
                  'Tambien controla el chequeo en segundo plano'),
              value: _notificationsEnabled,
              onChanged: (v) => setState(() => _notificationsEnabled = v),
            ),
            SwitchListTile(
              title: const Text('Avisar recuperaciones'),
              subtitle:
                  const Text('Consola reconectada / bypass desactivado'),
              value: _notifyRecovery,
              onChanged: (v) => setState(() => _notifyRecovery = v),
            ),
            OutlinedButton.icon(
              onPressed: () => NotificationService.instance.showTest(),
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Notificacion de prueba'),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Guardar'),
            ),
            const SizedBox(height: 8),
            Text(
              'El token se guarda en el almacenamiento local del dispositivo. '
              'Usa un token de SOLO LECTURA emitido para este monitor.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
