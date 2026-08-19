import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:molino_app/main.dart'; 

class NotificacionesHelper {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  
  // 🚀 OPTIMIZACIÓN: Una sola instancia de Random en memoria para toda la app
  static final Random _random = Random(); 

  static const AndroidNotificationChannel canalUrgente = AndroidNotificationChannel(
    'canal_molino_popup', 
    'Avisos Urgentes Molino',
    description: 'Canal principal para los avisos que saltan en la pantalla',
    importance: Importance.max, 
    playSound: true,
    enableVibration: true,
  );

  static Future<void> inicializar() async {
    const initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/launcher_icon');
    
    // 🚀 FIX CRÍTICO: Faltaba la configuración para que funcione en iOS (TestFlight)
    const initializationSettingsIOS = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS, // 👈 Ahora sí saltarán en iPhone
    );
    
    await _notificationsPlugin.initialize(
      settings: initializationSettings, // 🚀 FIX DE LA NUEVA VERSIÓN: Parámetro nombrado
      onDidReceiveNotificationResponse: (NotificationResponse response) { 
        if (response.payload != null) {
          _manejarTapNotificacion(response.payload!);
        }
      },
    );

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(canalUrgente);

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint("📲 Notificación en FOREGROUND: ${message.notification?.title}");
      
      if (message.notification != null) {
        mostrarNotificacion(
          titulo: message.notification!.title ?? 'Notificación',
          cuerpo: message.notification!.body ?? '',
          payload: message.data,
        );
      }
    });
  }

  static Future<void> mostrarNotificacion({
    required String titulo, 
    required String cuerpo, 
    required Map<String, dynamic> payload
  }) async {
    
    final androidPlatformChannelSpecifics = AndroidNotificationDetails(
      canalUrgente.id, 
      canalUrgente.name,
      channelDescription: canalUrgente.description,
      importance: canalUrgente.importance,
      priority: Priority.high,
      playSound: canalUrgente.playSound, 
      enableVibration: canalUrgente.enableVibration,
      showProgress: false,
    );
    
    // 🚀 FIX CRÍTICO: Detalles visuales y sonoros para la notificación en iOS
    const iosPlatformChannelSpecifics = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    
    final platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
      iOS: iosPlatformChannelSpecifics, // 👈 Integrado para Apple
    );
    
    // 🚀 Usamos la instancia estática para no saturar al Recolector de Basura
    int idAleatorio = _random.nextInt(100000);

    try {
      await _notificationsPlugin.show(
        id: idAleatorio,
        title: titulo,
        body: cuerpo,
        notificationDetails: platformChannelSpecifics,
        payload: jsonEncode(payload),
      );
    } catch (e) {
      debugPrint("❌ Error mostrando notificación: $e");
    }
  }

  static void _manejarTapNotificacion(String payloadStr) {
    try {
      final payload = jsonDecode(payloadStr);
      MyApp.procesarNavegacionNotificacion(payload);
    } catch (e) {
      debugPrint("❌ Error al navegar: $e");
    }
  }
}