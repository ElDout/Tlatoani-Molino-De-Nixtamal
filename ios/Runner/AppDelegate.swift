import UIKit
import Flutter
import Firebase 
import flutter_local_notifications 
import GoogleMaps // 👈 1. IMPORTAMOS GOOGLE MAPS

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    
    // 👇 2. INICIALIZAMOS GOOGLE MAPS CON TU API KEY 👇
    // Usé la que vi en tu AndroidManifest, si tienes una exclusiva para iOS, cámbiala aquí
    GMSServices.provideAPIKey("AIzaSyArmA4eDBu5Qy_PedPFtq0u3y1CEdPKAR0") 
    
    // Inicializamos Firebase
    FirebaseApp.configure()
    
    // Conectamos notificaciones locales
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { (registry) in
        GeneratedPluginRegistrant.register(with: registry)
    }
    
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}