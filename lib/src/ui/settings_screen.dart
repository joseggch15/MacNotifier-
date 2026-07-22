/// Configuracion: conexion + apariencia (idioma/tema) + cadencias +
/// monitoreos + silenciados (por producto y por consola) + notificaciones.
///
/// "Probar conexion" ejecuta la query `sites` con lo que hay EN EL FORMULARIO
/// (sin guardar), igual que el dialogo de conexion de MSGQ: valida token y
/// endpoint y muestra que sitio quedaria seleccionado.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/adaptiq_client.dart';
import '../config/app_settings.dart';
import '../core/util.dart';
import '../i18n/l10n.dart';
import '../models/adapt_mac.dart';
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

  late TextEditingController _unauthLanes;

  late int _pollSeconds;
  late int _backgroundMinutes;
  late int _staleMinutes;
  late int _offlineAlarmMinutes;
  late bool _notificationsEnabled;
  late bool _notifyRecovery;
  late bool _monitorDeliveries;
  late double _varianceThresholdPct;
  late bool _monitorOverfill;
  late bool _monitorUnauthorised;
  late bool _monitorFlowTemp;
  late double _flowMinLpm;
  late double _flowMaxLpm;
  late double _tempMaxCelsius;
  late Set<String> _mutedSfl;
  late Set<String> _mutedDeliveries;
  late Set<String> _mutedFlowTemp;
  late Set<String> _mutedConsoles;
  late List<String> _knownProducts;
  late List<String> _knownConsoles;
  late String _languageCode;
  late String _themeMode;

  bool _tokenVisible = false;
  bool _testing = false;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _endpoint = TextEditingController(text: s.endpoint);
    _token = TextEditingController(text: s.token);
    _siteMatch = TextEditingController(text: s.siteMatch);
    _siteId = TextEditingController(text: s.siteId);
    _unauthLanes = TextEditingController(text: s.unauthorisedLanes.join('\n'));
    _pollSeconds = s.pollSeconds;
    _backgroundMinutes = s.backgroundMinutes;
    _staleMinutes = s.staleMinutes;
    _offlineAlarmMinutes = s.offlineAlarmMinutes;
    _notificationsEnabled = s.notificationsEnabled;
    _notifyRecovery = s.notifyRecovery;
    _monitorDeliveries = s.monitorDeliveries;
    _varianceThresholdPct = s.varianceThresholdPct;
    _monitorOverfill = s.monitorOverfill;
    _monitorUnauthorised = s.monitorUnauthorised;
    _monitorFlowTemp = s.monitorFlowTemp;
    _flowMinLpm = s.flowMinLpm;
    _flowMaxLpm = s.flowMaxLpm;
    _tempMaxCelsius = s.tempMaxCelsius;
    _mutedSfl = s.mutedSflProducts.toSet();
    _mutedDeliveries = s.mutedDeliveryProducts.toSet();
    _mutedFlowTemp = s.mutedFlowTempProducts.toSet();
    _mutedConsoles = s.mutedConsoles.toSet();
    _languageCode = s.languageCode;
    _themeMode = s.themeMode;
    final store = ref.read(appStoreProvider);
    // Productos vistos en los datos + los ya silenciados (por si un producto
    // silenciado dejo de aparecer: debe poder des-silenciarse igual).
    _knownProducts = {
      ...store.knownProducts,
      ..._mutedSfl,
      ..._mutedDeliveries,
      ..._mutedFlowTemp,
    }.toList()
      ..sort();
    // Consolas del ultimo snapshot + las ya silenciadas.
    final snapshotConsoles =
        store.loadSnapshot()?.consoles ?? const <AdaptMac>[];
    _knownConsoles = <String>{
      for (final c in snapshotConsoles) c.code,
      ..._mutedConsoles,
    }.toList()
      ..sort(naturalCompare);
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    _siteMatch.dispose();
    _siteId.dispose();
    _unauthLanes.dispose();
    super.dispose();
  }

  L10n get _l => L10n(_languageCode);

  /// Lanes vigilados desde el editor multilinea: una por linea (o separadas por
  /// coma), sin vacios ni duplicados, preservando el orden de entrada.
  List<String> _parseLanes() {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in _unauthLanes.text.split(RegExp(r'[\n,]'))) {
      final lane = raw.trim();
      if (lane.isEmpty) continue;
      if (seen.add(lane.toUpperCase())) out.add(lane);
    }
    return out;
  }

  AppSettings _fromForm() => ref.read(settingsProvider).copyWith(
        endpoint: _endpoint.text.trim(),
        token: _token.text.trim(),
        siteMatch: _siteMatch.text.trim(),
        siteId: _siteId.text.trim(),
        pollSeconds: _pollSeconds,
        backgroundMinutes: _backgroundMinutes,
        staleMinutes: _staleMinutes,
        offlineAlarmMinutes: _offlineAlarmMinutes,
        notificationsEnabled: _notificationsEnabled,
        notifyRecovery: _notifyRecovery,
        monitorDeliveries: _monitorDeliveries,
        varianceThresholdPct: _varianceThresholdPct,
        monitorOverfill: _monitorOverfill,
        monitorUnauthorised: _monitorUnauthorised,
        unauthorisedLanes: _parseLanes(),
        monitorFlowTemp: _monitorFlowTemp,
        flowMinLpm: _flowMinLpm,
        flowMaxLpm: _flowMaxLpm,
        tempMaxCelsius: _tempMaxCelsius,
        mutedSflProducts: _mutedSfl.toList()..sort(),
        mutedDeliveryProducts: _mutedDeliveries.toList()..sort(),
        mutedFlowTempProducts: _mutedFlowTemp.toList()..sort(),
        mutedConsoles: _mutedConsoles.toList()..sort(),
        languageCode: _languageCode,
        themeMode: _themeMode,
      );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final l = _l;
    await ref.read(settingsProvider.notifier).save(_fromForm());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l.t('Configuracion guardada.', 'Settings saved.'))),
    );
    Navigator.of(context).pop();
  }

  Future<void> _testConnection() async {
    final l = _l;
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
          title: Text(l.t('Conexion OK — ${sites.length} sitio(s)',
              'Connection OK — ${sites.length} site(s)')),
          content: Text(lines.isEmpty
              ? l.t('El token no ve ningun sitio.', 'The token sees no sites.')
              : lines),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l.t('Cerrar', 'Close'))),
          ],
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text(l.t('Fallo la conexion: $e', 'Connection failed: $e'))),
      );
    } finally {
      client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  /// DIAGNOSTICO: introspecciona el tipo de movimiento del tenant y muestra
  /// que campos de caudal/temperatura expone — para verificar viabilidad antes
  /// de activar esas alertas. Usa lo que hay EN EL FORMULARIO (sin guardar).
  Future<void> _probeMovementFields() async {
    final l = _l;
    setState(() => _probing = true);
    final client = AdaptIQClient(_fromForm());
    try {
      final probe = await client.probeMovementFields();
      if (!mounted) return;
      String fieldLabel(String f) => switch (f) {
            'peakFlowRate' => l.t('peakFlowRate — caudal pico', 'peakFlowRate — peak flow'),
            'averageFlowRate' =>
              l.t('averageFlowRate — caudal promedio', 'averageFlowRate — avg flow'),
            'duration' => l.t('duration — duracion (s)', 'duration — duration (s)'),
            'transactionTemperature' => l.t(
                'transactionTemperature — temperatura', 'transactionTemperature — temperature'),
            _ => f,
          };
      final lines = [
        for (final f in probe.present) '✅ ${fieldLabel(f)}',
        for (final f in probe.missing) '❌ ${fieldLabel(f)}',
      ].join('\n');
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.t('Campos de caudal/temp — tipo ${probe.typeName}',
              'Flow/temp fields — type ${probe.typeName}')),
          content: Text(
            '${l.t('Campos visibles en el tipo: ${probe.totalFields}', 'Fields on type: ${probe.totalFields}')}\n\n$lines',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l.t('Cerrar', 'Close'))),
          ],
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.t('Fallo el diagnostico: $e', 'Probe failed: $e'))),
      );
    } finally {
      client.close();
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = _l;
    return Scaffold(
      appBar: AppBar(title: Text(l.t('Configuracion', 'Settings'))),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ---- Apariencia -----------------------------------------------------
            Text(l.t('Apariencia', 'Appearance'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _languageCode,
              decoration: InputDecoration(
                labelText: l.t('Idioma', 'Language'),
                border: const OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'es', child: Text('Español')),
                DropdownMenuItem(value: 'en', child: Text('English')),
              ],
              onChanged: (v) => setState(() => _languageCode = v ?? 'es'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _themeMode,
              decoration: InputDecoration(
                labelText: l.t('Tema', 'Theme'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                    value: 'dark', child: Text(l.t('Oscuro', 'Dark'))),
                DropdownMenuItem(
                    value: 'light', child: Text(l.t('Claro', 'Light'))),
                DropdownMenuItem(
                    value: 'system',
                    child: Text(l.t('Segun el sistema', 'Follow system'))),
              ],
              onChanged: (v) => setState(() => _themeMode = v ?? 'dark'),
            ),
            const Divider(height: 32),
            // ---- Conexion -------------------------------------------------------
            Text(l.t('Conexion AdaptIQ', 'AdaptIQ connection'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextFormField(
              controller: _endpoint,
              decoration: InputDecoration(
                labelText: l.t('Endpoint GraphQL', 'GraphQL endpoint'),
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              validator: (v) {
                final uri = Uri.tryParse((v ?? '').trim());
                if (uri == null || !uri.isAbsolute || !uri.scheme.startsWith('http')) {
                  return l.t('URL invalida', 'Invalid URL');
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _token,
              obscureText: !_tokenVisible,
              decoration: InputDecoration(
                labelText: l.t('Token de la API', 'API token'),
                helperText: l.t('Viaja como  Authorization: Token token=<token>',
                    'Sent as  Authorization: Token token=<token>'),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                      _tokenVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
                ),
              ),
              validator: (v) => (v ?? '').trim().isEmpty
                  ? l.t('El token es obligatorio', 'The token is required')
                  : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _siteMatch,
                    decoration: InputDecoration(
                      labelText: l.t('Sitio (texto a buscar)',
                          'Site (text to match)'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _siteId,
                    decoration: InputDecoration(
                      labelText: l.t('Site ID (opcional)', 'Site ID (optional)'),
                      border: const OutlineInputBorder(),
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
              label: Text(l.t('Probar conexion', 'Test connection')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _probing ? null : _probeMovementFields,
              icon: _probing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.science_outlined),
              label: Text(l.t('Diagnostico caudal/temperatura',
                  'Probe flow/temperature')),
            ),
            const Divider(height: 32),
            // ---- Cadencias ------------------------------------------------------
            Text(l.t('Cadencias', 'Polling'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _pollSeconds,
              decoration: InputDecoration(
                labelText:
                    l.t('Polling con la app abierta', 'Polling while app open'),
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final secs in const [10, 20, 30, 60])
                  DropdownMenuItem(
                      value: secs,
                      child: Text(l.t('Cada $secs segundos',
                          'Every $secs seconds'))),
              ],
              onChanged: (v) => setState(() => _pollSeconds = v ?? 20),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _backgroundMinutes,
              decoration: InputDecoration(
                labelText:
                    l.t('Chequeo con la app cerrada', 'Check while app closed'),
                helperText: l.t('Android no permite menos de 15 minutos',
                    'Android does not allow less than 15 minutes'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                    value: 15,
                    child: Text(l.t('Cada 15 minutos', 'Every 15 minutes'))),
                DropdownMenuItem(
                    value: 30,
                    child: Text(l.t('Cada 30 minutos', 'Every 30 minutes'))),
                DropdownMenuItem(
                    value: 60, child: Text(l.t('Cada hora', 'Every hour'))),
              ],
              onChanged: (v) => setState(() => _backgroundMinutes = v ?? 15),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _staleMinutes,
              decoration: InputDecoration(
                labelText: l.t('Umbral de comunicacion stale',
                    'Stale comms threshold'),
                helperText: l.t(
                    'Online pero sin comunicacion exitosa hace mas de N min',
                    'Online but without successful comms for more than N min'),
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final mins in const [15, 30, 60, 120])
                  DropdownMenuItem(
                      value: mins,
                      child: Text(l.t('$mins minutos', '$mins minutes'))),
              ],
              onChanged: (v) => setState(() => _staleMinutes = v ?? 30),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _offlineAlarmMinutes,
              decoration: InputDecoration(
                labelText: l.t('Alarma de caida prolongada',
                    'Prolonged-outage alarm'),
                helperText: l.t(
                    'Una consola OFFLINE no silenciada que lleve este tiempo '
                        'caida dispara una alarma estilo despertador',
                    'An un-muted OFFLINE console down for this long triggers an '
                        'alarm-clock alert'),
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final mins in const [15, 30, 45, 60])
                  DropdownMenuItem(
                      value: mins,
                      child: Text(l.t('A los $mins minutos', 'After $mins minutes'))),
              ],
              onChanged: (v) => setState(() => _offlineAlarmMinutes = v ?? 30),
            ),
            const Divider(height: 32),
            // ---- Consolas silenciadas -------------------------------------------
            Text(l.t('Consolas AdaptMAC', 'AdaptMAC consoles'),
                style: Theme.of(context).textTheme.titleMedium),
            _MuteChipList(
              title: l.t('Silenciar consolas especificas',
                  'Mute specific consoles'),
              subtitle: l.t(
                  'Los MACs marcados (p. ej. los service trucks) NO notifican '
                      'caidas ni bypass; siguen visibles en la pestaña '
                      'Consolas. Tambien puedes usar la campana de cada tile.',
                  'Marked MACs (e.g. service trucks) do NOT notify offline or '
                      'bypass events; they stay visible in the Consoles tab. '
                      'You can also use the bell on each tile.'),
              emptyText: l.t(
                  'Aun no hay consolas detectadas: apareceran tras la primera '
                      'sincronizacion.',
                  'No consoles detected yet: they will appear after the first '
                      'sync.'),
              items: _knownConsoles,
              muted: _mutedConsoles,
              onChanged: (code, mute) => setState(() =>
                  mute ? _mutedConsoles.add(code) : _mutedConsoles.remove(code)),
            ),
            const Divider(height: 32),
            // ---- Entregas -------------------------------------------------------
            Text(l.t('Entregas (deliveries)', 'Deliveries'),
                style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: Text(l.t('Monitorear entregas', 'Monitor deliveries')),
              subtitle: Text(l.t(
                  'Alerta entregas sin confirmar y varianza medidor vs guia',
                  'Alerts unconfirmed deliveries and metered-vs-docket variance')),
              value: _monitorDeliveries,
              onChanged: (v) => setState(() => _monitorDeliveries = v),
            ),
            if (_monitorDeliveries) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<double>(
                value: _varianceThresholdPct,
                decoration: InputDecoration(
                  labelText: l.t('Umbral de varianza', 'Variance threshold'),
                  helperText: l.t(
                      '|medido − guia| / guia. A partir de 5% la alerta es critica.',
                      '|metered − docket| / docket. From 5% the alert is critical.'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: 0.5, child: Text('0.5 %')),
                  DropdownMenuItem(
                      value: 1.0,
                      child: Text(l.t('1 % (recomendado)', '1 % (recommended)'))),
                  const DropdownMenuItem(value: 2.0, child: Text('2 %')),
                  const DropdownMenuItem(value: 5.0, child: Text('5 %')),
                ],
                onChanged: (v) =>
                    setState(() => _varianceThresholdPct = v ?? 1.0),
              ),
              const SizedBox(height: 4),
              _MuteChipList(
                title: l.t('Silenciar entregas por producto',
                    'Mute deliveries by product'),
                subtitle: l.t(
                    'Los productos marcados NO notifican anomalias de entrega '
                        '(siguen visibles en la pestaña Entregas).',
                    'Marked products do NOT notify delivery anomalies '
                        '(they stay visible in the Deliveries tab).'),
                emptyText: l.t(
                    'Aun no hay productos detectados: apareceran cuando el '
                        'monitor sincronice datos.',
                    'No products detected yet: they will appear once the '
                        'monitor syncs data.'),
                items: _knownProducts,
                muted: _mutedDeliveries,
                onChanged: (p, mute) => setState(() => mute
                    ? _mutedDeliveries.add(p)
                    : _mutedDeliveries.remove(p)),
              ),
            ],
            const Divider(height: 32),
            // ---- SFL ------------------------------------------------------------
            Text(l.t('Sobrellenados SFL', 'SFL overfills'),
                style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: Text(
                  l.t('Monitorear sobrellenados', 'Monitor overfills')),
              subtitle: Text(l.t(
                  'Despachos que exceden el Safe Fill Level del equipo '
                      '(la alarma "Equipment Overfill" de AdaptIQ)',
                  'Dispenses exceeding the equipment Safe Fill Level '
                      '(the AdaptIQ "Equipment Overfill" alarm)')),
              value: _monitorOverfill,
              onChanged: (v) => setState(() => _monitorOverfill = v),
            ),
            if (_monitorOverfill)
              _MuteChipList(
                title: l.t('Silenciar SFL por producto', 'Mute SFL by product'),
                subtitle: l.t(
                    'Si solo interesa el diesel, silencia aqui el resto de '
                        'productos (coolant, aceites, …).',
                    'If only diesel matters, mute the other products here '
                        '(coolant, oils, …).'),
                emptyText: l.t(
                    'Aun no hay productos detectados: apareceran cuando el '
                        'monitor sincronice datos.',
                    'No products detected yet: they will appear once the '
                        'monitor syncs data.'),
                items: _knownProducts,
                muted: _mutedSfl,
                onChanged: (p, mute) => setState(
                    () => mute ? _mutedSfl.add(p) : _mutedSfl.remove(p)),
              ),
            const Divider(height: 32),
            // ---- Caudal y temperatura -------------------------------------------
            Text(l.t('Caudal y temperatura', 'Flow rate and temperature'),
                style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: Text(l.t('Monitorear caudal y temperatura',
                  'Monitor flow rate and temperature')),
              subtitle: Text(l.t(
                  'Cruza volumen y duracion (caudal L/min) y vigila la '
                      'temperatura: caudal bajo = obstruccion, alto = medidor en '
                      'vacio/bypass, temperatura extrema = sensor averiado',
                  'Crosses volume and duration (flow L/min) and watches '
                      'temperature: low flow = obstruction, high = meter '
                      'spinning/bypass, extreme temp = faulty sensor')),
              value: _monitorFlowTemp,
              onChanged: (v) => setState(() => _monitorFlowTemp = v),
            ),
            if (_monitorFlowTemp) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<double>(
                value: _flowMinLpm,
                decoration: InputDecoration(
                  labelText: l.t('Caudal minimo (obstruccion)',
                      'Minimum flow (obstruction)'),
                  helperText: l.t(
                      'Por debajo de este caudal medio se alerta obstruccion.',
                      'Below this average flow an obstruction is alerted.'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final v in const [5.0, 10.0, 15.0, 25.0])
                    DropdownMenuItem(value: v, child: Text('${v.toStringAsFixed(0)} L/min')),
                ],
                onChanged: (v) =>
                    setState(() => _flowMinLpm = v ?? kDefaultFlowMinLpm),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<double>(
                value: _flowMaxLpm,
                decoration: InputDecoration(
                  labelText: l.t('Caudal maximo (vacio/bypass)',
                      'Maximum flow (air/bypass)'),
                  helperText: l.t(
                      'Por encima sugiere medidor girando en vacio (bypass).',
                      'Above this suggests the meter spinning in air (bypass).'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final v in const [120.0, 150.0, 180.0, 220.0])
                    DropdownMenuItem(value: v, child: Text('${v.toStringAsFixed(0)} L/min')),
                ],
                onChanged: (v) =>
                    setState(() => _flowMaxLpm = v ?? kDefaultFlowMaxLpm),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<double>(
                value: _tempMaxCelsius,
                decoration: InputDecoration(
                  labelText: l.t('Temperatura maxima', 'Maximum temperature'),
                  helperText: l.t(
                      'Por encima se alerta posible sensor termico averiado.',
                      'Above this a possible faulty thermal sensor is alerted.'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final v in const [45.0, 50.0, 60.0, 70.0])
                    DropdownMenuItem(value: v, child: Text('${v.toStringAsFixed(0)} °C')),
                ],
                onChanged: (v) =>
                    setState(() => _tempMaxCelsius = v ?? kDefaultTempMaxCelsius),
              ),
              const SizedBox(height: 4),
              _MuteChipList(
                title: l.t('Silenciar caudal/temp por producto',
                    'Mute flow/temp by product'),
                subtitle: l.t(
                    'Los productos marcados NO notifican anomalias de caudal '
                        'ni temperatura.',
                    'Marked products do NOT notify flow or temperature '
                        'anomalies.'),
                emptyText: l.t(
                    'Aun no hay productos detectados: apareceran cuando el '
                        'monitor sincronice datos.',
                    'No products detected yet: they will appear once the '
                        'monitor syncs data.'),
                items: _knownProducts,
                muted: _mutedFlowTemp,
                onChanged: (p, mute) => setState(() => mute
                    ? _mutedFlowTemp.add(p)
                    : _mutedFlowTemp.remove(p)),
              ),
            ],
            const Divider(height: 32),
            // ---- Despachos sin ID (no autorizados) ------------------------------
            Text(l.t('Despachos sin ID (no autorizados)',
                'Dispenses without ID (unauthorised)'),
                style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: Text(l.t('Monitorear despachos sin ID',
                  'Monitor dispenses without ID')),
              subtitle: Text(l.t(
                  'Despachos Unauthorised SIN equipo asignado en los lanes '
                      'vigilados; salen de la lista cuando AdaptIQ les asigna ID',
                  'Unauthorised dispenses with NO equipment assigned in the '
                      'watched lanes; they leave the list once AdaptIQ assigns an ID')),
              value: _monitorUnauthorised,
              onChanged: (v) => setState(() => _monitorUnauthorised = v),
            ),
            if (_monitorUnauthorised)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextFormField(
                  controller: _unauthLanes,
                  maxLines: null,
                  minLines: 3,
                  decoration: InputDecoration(
                    labelText: l.t('Lanes vigilados (uno por linea)',
                        'Watched lanes (one per line)'),
                    helperText: l.t(
                        'El punto de despacho exacto como aparece en AdaptIQ '
                            '(Dispensing Point).',
                        'The exact dispensing point as shown in AdaptIQ '
                            '(Dispensing Point).'),
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            const Divider(height: 32),
            // ---- Notificaciones -------------------------------------------------
            Text(l.t('Notificaciones', 'Notifications'),
                style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: Text(
                  l.t('Notificaciones activas', 'Notifications enabled')),
              subtitle: Text(l.t(
                  'Tambien controla el chequeo en segundo plano',
                  'Also controls the background check')),
              value: _notificationsEnabled,
              onChanged: (v) => setState(() => _notificationsEnabled = v),
            ),
            SwitchListTile(
              title: Text(l.t('Avisar recuperaciones', 'Notify recoveries')),
              subtitle: Text(l.t(
                  'Consola reconectada / bypass desactivado',
                  'Console back online / bypass cleared')),
              value: _notifyRecovery,
              onChanged: (v) => setState(() => _notifyRecovery = v),
            ),
            OutlinedButton.icon(
              onPressed: () => NotificationService.instance.showTest(l),
              icon: const Icon(Icons.notifications_active_outlined),
              label: Text(l.t('Notificacion de prueba', 'Test notification')),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: Text(l.t('Guardar', 'Save')),
            ),
            const SizedBox(height: 8),
            Text(
              l.t(
                  'El token se guarda en el almacenamiento local del '
                      'dispositivo. Usa un token de SOLO LECTURA emitido para '
                      'este monitor.',
                  'The token is stored on the device. Use a READ-ONLY token '
                      'issued for this monitor.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// Lista de chips donde "seleccionado" = SILENCIADO (productos o consolas).
class _MuteChipList extends StatelessWidget {
  const _MuteChipList({
    required this.title,
    required this.subtitle,
    required this.emptyText,
    required this.items,
    required this.muted,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final String emptyText;
  final List<String> items;
  final Set<String> muted;
  final void Function(String item, bool mute) onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          if (items.isEmpty)
            Text(
              emptyText,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(fontStyle: FontStyle.italic),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final item in items)
                  FilterChip(
                    label: Text(item, style: const TextStyle(fontSize: 12)),
                    avatar: muted.contains(item)
                        ? const Icon(Icons.notifications_off, size: 16)
                        : null,
                    selected: muted.contains(item),
                    onSelected: (v) => onChanged(item, v),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
