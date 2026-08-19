import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/Dise%C3%B1o.dart';
import 'package:molino_app/Login.dart';
import 'package:molino_app/Clientes.dart';
import 'package:molino_app/Admin.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molino_app/Repartidores.dart'; 
import 'package:molino_app/BloqueoCliente.dart'; 
import 'package:molino_app/config.dart'; 
import 'package:molino_app/BloqueoRepartidor.dart';
import 'package:molino_app/Trabajadadores.dart'; 
import 'package:molino_app/BloqueoTrabajo.dart';
import 'package:molino_app/Inicio.dart'; 
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:molino_app/AdminOrdenes.dart'; 
import 'package:molino_app/NotificacionesHelper.dart';
import 'package:molino_app/PanelTortilleria.dart'; 
import 'package:molino_app/Predeterminado.dart';
import 'package:molino_app/Tortillas.dart'; 
import 'package:molino_app/PerfilScreen.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint("Notificación recibida en background: ${message.notification?.title}");
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint("Error inicializando Firebase: $e");
  }

  // 🚀 FIX: Arrancamos la App de inmediato, sin bloqueos.
  // Le pasamos su GlobalKey para poder cambiar el modo oscuro desde las notificaciones
  runApp(MyApp(key: MyApp.appKey));

  // 🚀 Pedimos permisos en SEGUNDO PLANO
  NotificacionesHelper.inicializar().then((_) {
    FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  });
}

class MyApp extends StatefulWidget {
  // 🚀 LLAVE PARA EL TEMA OSCURO
  static final GlobalKey<_MyAppState> appKey = GlobalKey<_MyAppState>();
  // 🚀 LLAVE DEL NAVEGADOR
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  // ====================================================================
  // 🚀 LÓGICA MAESTRA DE SALTOS (PANTALLA NEGRA ERRADICADA Y REGLAS AL 100%)
  // ====================================================================
  static void procesarNavegacionNotificacion(Map<String, dynamic> payload) async {
    // 🔥 FIX VITAL: Esperamos a que la UI respire un microsegundo antes de saltar
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final nav = navigatorKey.currentState;
      if (nav == null) return;
      
      String tipo = payload['tipo'] ?? '';
      int? idOrden = payload['id_orden'] != null ? int.tryParse(payload['id_orden'].toString()) : null;
      
      if (tipo == 'rep_solicita_compartir') return; // Se ignora si es solo popup
      
      final prefs = await SharedPreferences.getInstance();
      final String? userRole = prefs.getString('userRole');
      final int? userId = prefs.getInt('userId');

      // Función puente para no perder la capacidad de cambiar Tema en las pantallas de destino
      void cambiarTemaGlobal(ThemeMode m) { appKey.currentState?._changeTheme(m); }

      // ----------------------------------------------------
      // 1. REGLAS ADMINISTRADOR
      // ----------------------------------------------------
      if (userRole == 'admin') {
        if (tipo == 'admin_solicitud_edicion' && idOrden != null) {
          try {
            final resOrden = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/$idOrden'));
            if (resOrden.statusCode == 200) {
              final dataOrden = jsonDecode(resOrden.body);
              if (dataOrden['success'] == true && dataOrden['orden']['id_tortilleria'] != null) {
                final int idTortilleria = dataOrden['orden']['id_tortilleria'];
                final resTort = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/tortilleria/$idTortilleria'));
                if (resTort.statusCode == 200) {
                  List<dynamic> ordenesTort = jsonDecode(resTort.body);
                  final ordenEspecifica = ordenesTort.firstWhere((o) => o['id'].toString() == idOrden.toString(), orElse: () => null);
                  
                  if (ordenEspecifica != null && ordenEspecifica['id_solicitud'] != null) {
                    nav.push(MaterialPageRoute(builder: (_) => RevisarSolicitudScreen(orden: ordenEspecifica)));
                    return; 
                  }
                }
              }
            }
          } catch (e) { debugPrint("Error en salto a edicion: $e"); }
          nav.push(MaterialPageRoute(builder: (_) => TortillasScreen(onThemeChanged: cambiarTemaGlobal)));
        } else {
          // Va directo a la orden (Notis 1, 2, 3, 4)
          nav.push(
            MaterialPageRoute(builder: (_) => OrdenesAdmin(onThemeChanged: cambiarTemaGlobal, abrirPedidoId: idOrden))
          );
        }
      } 
      // ----------------------------------------------------
      // 2. REGLAS REPARTIDOR
      // ----------------------------------------------------
      else if (userRole == 'repartidor') {
        if (tipo == 'rep_resena') {
          // Si es reseña, va a Completadas
          nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => RepartidoresScreen(onThemeChanged: cambiarTemaGlobal, initialTab: 2)), (route) => false);
        } else {
          // Demás Notis: Verificamos si tiene orden activa para mandarlo al Bloqueo o a la lista
          try {
            final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/activa/repartidor/$userId')).timeout(const Duration(seconds: 3));
            if (res.statusCode == 200 && jsonDecode(res.body)['success'] == true) {
              nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => BloqueoRepartidorScreen(onThemeChanged: cambiarTemaGlobal)), (route) => false);
            } else {
              nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => RepartidoresScreen(onThemeChanged: cambiarTemaGlobal)), (route) => false);
            }
          } catch (e) {
            nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => RepartidoresScreen(onThemeChanged: cambiarTemaGlobal)), (route) => false);
          }
        }
      }
      // ----------------------------------------------------
      // 3. REGLAS TRABAJADOR
      // ----------------------------------------------------
      else if (userRole == 'trabajador') {
        if (tipo == 'mercancia_modificada' || tipo == 'faltante') {
          nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => TrabajadoresScreen(onThemeChanged: cambiarTemaGlobal, initialTab: 2)), (route) => false);
        } else if (tipo == 'admin_autorizo_edicion' || tipo == 'admin_rechazo_edicion') {
          nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => TrabajadoresScreen(onThemeChanged: cambiarTemaGlobal, initialTab: 0)), (route) => false);
        } else {
          // Revisa si tiene orden activa
          try {
            final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/activa/trabajador/$userId')).timeout(const Duration(seconds: 3));
            if (res.statusCode == 200 && jsonDecode(res.body)['success'] == true) {
              final Map<String, dynamic> ordenActiva = jsonDecode(res.body)['orden'];
              nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => BloqueoTrabajoScreen(onThemeChanged: cambiarTemaGlobal, ordenInicial: ordenActiva)), (route) => false);
            } else {
              nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => TrabajadoresScreen(onThemeChanged: cambiarTemaGlobal)), (route) => false);
            }
          } catch (e) {
            nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => TrabajadoresScreen(onThemeChanged: cambiarTemaGlobal)), (route) => false);
          }
        }
      }
      // ----------------------------------------------------
      // 4. REGLAS CLIENTE
      // ----------------------------------------------------
      else if (userRole == 'cliente') {
        if (tipo == 'mercancia_modificada' || tipo == 'faltante') {
          nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => ClientesScreen(onThemeChanged: cambiarTemaGlobal, initialTab: 2)), (route) => false);
        } else {
          // Revisa si tiene orden activa
          try {
            final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/activa/cliente/$userId')).timeout(const Duration(seconds: 3)); 
            if (res.statusCode == 200 && jsonDecode(res.body)['success'] == true) {
              final Map<String, dynamic> ordenActiva = jsonDecode(res.body)['orden'];
              nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => BloqueoClienteScreen(onThemeChanged: cambiarTemaGlobal, ordenInicial: ordenActiva)), (route) => false);
            } else {
              nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => ClientesScreen(onThemeChanged: cambiarTemaGlobal)), (route) => false);
            }
          } catch (e) {
            nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => ClientesScreen(onThemeChanged: cambiarTemaGlobal)), (route) => false);
          }
        }
      }
    });
  }
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system;
  Widget? _initialScreen;

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
    _setupInteractions();
  }

  void _setupInteractions() {
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      if (message.data.isNotEmpty) {
        MyApp.procesarNavegacionNotificacion(message.data);
      }
    });

    FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
      if (message != null && message.data.isNotEmpty) {
        Future.delayed(const Duration(seconds: 2), () {
          MyApp.procesarNavegacionNotificacion(message.data);
        });
      }
    });
  }

  Future<void> _updateFcmToken(int userId, String role) async {
    try {
      String? token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await http.put(
          Uri.parse('${AppConfig.apiHost}/perfil/fcm-token'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'id': userId,
            'rol': role,
            'fcm_token': token
          }),
        );
        debugPrint("Token FCM actualizado en BD");
      }
    } catch (e) {
      debugPrint("Error guardando token: $e");
    }
  }

  int? _obtenerIdSeguro(SharedPreferences prefs) {
    int? id = prefs.getInt('userId');
    if (id == null) {
      String? idStr = prefs.getString('userId');
      if (idStr != null) id = int.tryParse(idStr);
    }
    return id;
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    final String? userRole = prefs.getString('userRole');
    final int? userId = _obtenerIdSeguro(prefs);

    if (isLoggedIn && userId != null && userRole != null) {
      
      // 🚀 FIX: Dejamos correr la petición de token en segundo plano sin 'await'
      _updateFcmToken(userId, userRole);

      if (userRole == 'admin') {
        setState(() => _initialScreen = AdminScreen(onThemeChanged: _changeTheme));
      } else if (userRole == 'repartidor') {
        try {
          final res = await http.get(
            Uri.parse('${AppConfig.apiHost}/ordenes/activa/repartidor/$userId')
          ).timeout(const Duration(seconds: 3));
          if (res.statusCode == 200 && jsonDecode(res.body)['success'] == true) {
            setState(() => _initialScreen = BloqueoRepartidorScreen(onThemeChanged: _changeTheme));
            return;
          }
        } catch (e) { debugPrint('Error al verificar repartidor: $e'); }
        
        setState(() => _initialScreen = RepartidoresScreen(onThemeChanged: _changeTheme));
      } else if (userRole == 'trabajador') {
        try {
          final res = await http.get(
            Uri.parse('${AppConfig.apiHost}/ordenes/activa/trabajador/$userId')
          ).timeout(const Duration(seconds: 3));
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            if (data['success'] == true) {
              final Map<String, dynamic> ordenActiva = data['orden'];
              setState(() => _initialScreen = BloqueoTrabajoScreen(onThemeChanged: _changeTheme, ordenInicial: ordenActiva));
              return;
            }
          }
        } catch (e) { debugPrint('Error al verificar trabajador: $e'); }

        setState(() => _initialScreen = TrabajadoresScreen(onThemeChanged: _changeTheme));
      } else {
        try {
          final res = await http.get(
            Uri.parse('${AppConfig.apiHost}/ordenes/activa/cliente/$userId')
          ).timeout(const Duration(seconds: 3)); 
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            if (data['success'] == true) {
              final Map<String, dynamic> ordenActiva = data['orden'];
              setState(() => _initialScreen = BloqueoClienteScreen(onThemeChanged: _changeTheme, ordenInicial: ordenActiva));
              return;
            }
          }
        } catch (e) { debugPrint('Error al verificar cliente: $e'); }
        
        setState(() => _initialScreen = ClientesScreen(onThemeChanged: _changeTheme));
      }
    } else {
      FirebaseMessaging.instance.deleteToken();
      setState(() => _initialScreen = InicioScreen(onThemeChanged: _changeTheme));
    }
  }

  void _changeTheme(ThemeMode themeMode) {
    setState(() {
      _themeMode = themeMode;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: MyApp.navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Molino App',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _themeMode,
      home: _initialScreen ?? const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}