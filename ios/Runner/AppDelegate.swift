import Flutter
import UIKit
import workmanager

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // El isolate de background de Workmanager corre con su propio registry:
    // hay que registrarle los plugins (shared_preferences, notifications, ...).
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

    // BGAppRefreshTask: el identificador debe coincidir con
    // BGTaskSchedulerPermittedIdentifiers (Info.plist) y con el nombre que
    // registra el lado Dart (kHealthTaskName). La frecuencia es un MINIMO:
    // iOS decide el momento real segun el patron de uso de la app.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "io.veridapt.merian.adaptmac.healthCheck",
      frequency: NSNumber(value: 15 * 60)
    )

    // Mostrar las notificaciones tambien con la app en primer plano.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
