/// Internacionalizacion minima (es / en).
///
/// En vez de arb + codegen (gen-l10n), un helper `t(es, en)` con los textos
/// CO-LOCADOS en el punto de uso: la app tiene una sola pantalla de cada cosa
/// y los textos viven al lado del widget que los muestra. Funciona igual en
/// el isolate de background (las notificaciones se localizan con el idioma
/// guardado en la configuracion).
library;

class L10n {
  const L10n(this.code);

  /// 'es' (defecto) o 'en'.
  final String code;

  bool get isEn => code == 'en';

  /// Devuelve [es] o [en] segun el idioma configurado.
  String t(String es, String en) => isEn ? en : es;
}
