// Smoke test del arranque de la UI.
//
// (Reemplaza el contador por defecto de Flutter, que referenciaba un `MyApp`
// inexistente en este proyecto.)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:adapt_mac_notifier/src/state/providers.dart';
import 'package:adapt_mac_notifier/src/storage/app_store.dart';
import 'package:adapt_mac_notifier/src/ui/home_screen.dart';

void main() {
  testWidgets('sin token configurado, la pantalla principal monta el prompt '
      'de configuracion con sus 4 pestañas', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(await SharedPreferences.getInstance());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    // El AppBar y la barra de pestañas se montan aunque falte el token.
    expect(find.text('AdaptIQ Monitor'), findsOneWidget);
    expect(find.text('Consolas'), findsOneWidget);
    expect(find.text('Sin ID'), findsOneWidget);
    // Sin token configurado, el cuerpo guia a la configuracion.
    expect(find.text('Abrir configuracion'), findsOneWidget);
  });
}
