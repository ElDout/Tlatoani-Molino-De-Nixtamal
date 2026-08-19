import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molino_app/config.dart';
import 'package:molino_app/Repartidores.dart';
import 'package:geolocator/geolocator.dart'; 
import 'package:url_launcher/url_launcher.dart'; 
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/foundation.dart'; // 🚀 ESTE ES EL QUE FALTABA

const String kGoogleApiKey = "AIzaSyCY5cOcVAzNpNfR_uSoOpC245m6fAtqdoU";

List<dynamic> extraerProductosSeguro(dynamic prodsRaw) {
  if (prodsRaw == null) return [];
  try {
    List<dynamic> lista = prodsRaw is String ? jsonDecode(prodsRaw) : List.from(prodsRaw);
    return lista.where((p) => p != null).toList(); 
  } catch (e) {
    return [];
  }
}

Map<String, dynamic> parseSocketData(dynamic data) {
  if (data == null) return {};
  try {
    if (data is String) return jsonDecode(data);
    if (data is List) return data.isNotEmpty ? Map<String, dynamic>.from(data[0]) : {};
    return Map<String, dynamic>.from(data);
  } catch (e) {
    return {};
  }
}

class CuatroBloquesNip extends StatefulWidget {
  final Function(String) onCompleted;
  final Color borderColor;
  final Color textColor;
  
  const CuatroBloquesNip({
    super.key, 
    required this.onCompleted, 
    this.borderColor = Colors.orangeAccent, 
    this.textColor = Colors.white
  });

  @override
  State<CuatroBloquesNip> createState() => _CuatroBloquesNipState();
}

class _CuatroBloquesNipState extends State<CuatroBloquesNip> {
  List<TextEditingController> controllers = List.generate(4, (_) => TextEditingController());
  List<FocusNode> nodes = List.generate(4, (_) => FocusNode());
  String pin = "";

  @override
  void dispose() {
    for(var c in controllers) { c.dispose(); }
    for(var n in nodes) { n.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280, 
      height: 70,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(4, (index) => Container(
          width: 55, height: 65,
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: widget.borderColor, width: 3),
            borderRadius: BorderRadius.circular(8)
          ),
          child: Material( 
            color: Colors.transparent,
            child: TextField(
              controller: controllers[index],
              focusNode: nodes[index],
              textAlign: TextAlign.center,
              textAlignVertical: TextAlignVertical.center, 
              maxLength: 1,
              keyboardType: TextInputType.number,
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: widget.textColor),
              decoration: const InputDecoration(counterText: "", border: InputBorder.none, contentPadding: EdgeInsets.zero),
              onChanged: (val) {
                if (val.isNotEmpty) {
                  if (index < 3) {
                    FocusScope.of(context).requestFocus(nodes[index+1]);
                  } else {
                    nodes[index].unfocus();
                    pin = controllers.map((c) => c.text).join();
                    if (pin.length == 4) widget.onCompleted(pin);
                  }
                } else if (index > 0) {
                  FocusScope.of(context).requestFocus(nodes[index-1]);
                }
              }
            ),
          ),
        ))
      ),
    );
  }
}

class BloqueoRepartidorScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  const BloqueoRepartidorScreen({super.key, required this.onThemeChanged});

  @override
  State<BloqueoRepartidorScreen> createState() => _BloqueoRepartidorScreenState();
}

class _BloqueoRepartidorScreenState extends State<BloqueoRepartidorScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<dynamic> _ordenesActivas = []; 
  List<dynamic> _ordenesPendientes = []; 
  List<dynamic> _repartidoresEnProceso = []; 
  Map<int, List<dynamic>> _ticketsDiarios = {}; 
  
  Set<int> _pedidosSeleccionadosPendientes = {};
  // 🚀 AQUÍ GUARDAMOS EL GPS EN TIEMPO REAL DEL OTRO COMPAÑERO
  Map<int, LatLng> _ubicacionesCompaneros = {};
  Set<int> _pedidosEnEspera = {};
  
  bool _isLoading = true;
  IO.Socket? _socket; 
  String _firmaDeLaOrden = ""; 
  Set<int> _ordenesEnLugar = {};
  int? _mild;
  StreamSubscription<Position>? _positionStream; 
  BitmapDescriptor? _iconoMoto;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      _obtenerDatosDePestanaActual();
    });

    _revisarOrdenAsignada();
    _cargarIconoMoto();
    
    _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'forceNew': true, 
    });

    _socket!.on('actualizacion_ordenes', (_) {
      if (mounted) {
        _revisarOrdenAsignada(silencioso: true); 
        _obtenerDatosDePestanaActual(silencioso: true);
      }
    });

    _socket!.on('peticion_compartir', (data) async {
      try {
        final safeData = parseSocketData(data);
        if (safeData.isEmpty) return;
        final prefs = await SharedPreferences.getInstance();
        final miId = _obtenerIdSeguro(prefs);
        
        if (miId != null && safeData['id_repartidor_origen']?.toString() == miId.toString() && mounted) {
          _mostrarPeticionCompartir(safeData);
        }
      } catch (e) { debugPrint("Error peticion_compartir: $e"); }
    });

    _socket!.on('compartir_aceptado', (data) async {
      try {
        final safeData = parseSocketData(data);
        if (safeData.isEmpty) return;
        final prefs = await SharedPreferences.getInstance();
        final miId = _obtenerIdSeguro(prefs);

        if (miId != null && safeData['id_repartidor_destino']?.toString() == miId.toString() && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ ¡El compañero aceptó la transferencia! Revisa "Mis Viajes".', style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
          setState(() {
            if (safeData['ids_ordenes'] != null) {
              for(var oId in safeData['ids_ordenes']) _pedidosEnEspera.remove(int.tryParse(oId.toString()) ?? 0);
            }
          });
          await _revisarOrdenAsignada(); 
        }
      } catch (_) {}
    });

    _socket!.on('compartir_rechazado', (data) async {
      try {
        final safeData = parseSocketData(data);
        if (safeData.isEmpty) return;
        final prefs = await SharedPreferences.getInstance();
        final miId = _obtenerIdSeguro(prefs);

        if (miId != null && safeData['id_repartidor_destino']?.toString() == miId.toString() && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('❌ El compañero denegó la solicitud.', style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.red));
          setState(() {
            List<dynamic> rechazadas = safeData['ids_ordenes'] ?? safeData['ordenes'] ?? [];
            for(var oId in rechazadas) {
              _pedidosEnEspera.remove(int.tryParse(oId.toString()) ?? 0); 
            }
          });
        }
      } catch (_) {}
    });
    
    _socket!.on('notify_nuevo_pedido', (_) {
      if (mounted) _obtenerDatosDePestanaActual(silencioso: true);
    });

    _socket!.on('notify_pedido_asignado', (data) async {
      final safeData = parseSocketData(data);
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt('userId') == safeData['id_repartidor'] && mounted) {
        _obtenerDatosDePestanaActual(silencioso: true);
      }
    });
    // 🚀 ESCUCHAMOS AL OTRO REPARTIDOR PARA ACTUALIZAR SU UBICACIÓN
    _socket!.on('ubicacion_repartidor', (data) {
      final safeData = parseSocketData(data);
      if (safeData['id_orden'] != null && safeData['lat'] != null && safeData['lng'] != null) {
        int idRepartidorEmisor = int.tryParse(safeData['id_repartidor']?.toString() ?? '0') ?? 0;
        
        // Guardar la ubicación SOLO si viene del compañero, no de nuestra propia moto
        if (idRepartidorEmisor != 0 && idRepartidorEmisor != _mild) {
          int idOrden = int.tryParse(safeData['id_orden'].toString()) ?? 0;
          double lat = double.tryParse(safeData['lat'].toString()) ?? 0.0;
          double lng = double.tryParse(safeData['lng'].toString()) ?? 0.0;
          
          if (mounted) {
            setState(() {
              _ubicacionesCompaneros[idOrden] = LatLng(lat, lng);
            });
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _detenerRastreoGPS();
    _socket?.disconnect();
    _tabController.dispose();
    super.dispose();
  }
  
  int? _obtenerIdSeguro(SharedPreferences prefs) {
    int? id = prefs.getInt('userId');
    if (id == null) {
      String? idStr = prefs.getString('userId');
      if (idStr != null) id = int.tryParse(idStr);
    }
    return id;
  }
  Future<void> _cargarIconoMoto() async {
    _iconoMoto = await BitmapDescriptor.fromAssetImage(
      const ImageConfiguration(size: Size(48, 48)), // Ajusta el tamaño si lo ves muy grande/chico
      'assets/moto_icon.png', 
    );
    if (mounted) setState(() {});
  }
  
 void _iniciarRastreoGPS() async {
    if (_positionStream != null) return; 

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint("❌ GPS APAGADO EN EL CELULAR DEL REPARTIDOR");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) return;

    debugPrint("✅ GPS INICIADO. LEYENDO COORDENADAS EN SEGUNDO PLANO...");

    late LocationSettings locationSettings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        forceLocationManager: true,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationText: "Tu ruta está activa en segundo plano",
          notificationTitle: "Molino - Repartidor Activo",
          enableWakeLock: true,
        ),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 10,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
      );
    } else {
      locationSettings = const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10);
    }

    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        // 🚀 SALVAVIDAS EMULADOR: No mandes coordenadas si no tienen formato correcto
        if (position.latitude == 0.0 && position.longitude == 0.0) return;

        debugPrint("📍 GPS LEÍDO: ${position.latitude}, ${position.longitude}");
        
        if (_socket != null && _socket!.connected) {
          for (var orden in _ordenesActivas) {
            if (orden['estado'] == 'En Camino' || orden['estado'] == 'Asignado') {
              _socket!.emit('ubicacion_repartidor', {
                'id_orden': orden['id'],
                'id_repartidor': _mild, // 🚀 AÑADIMOS NUESTRO ID AQUÍ
                'lat': position.latitude,
                'lng': position.longitude,
              });
            }
          }
        }
      },
      onError: (e) {
        debugPrint("❌ Error leyendo GPS: $e");
      }
    );
  }

  void _detenerRastreoGPS() {
    _positionStream?.cancel();
    _positionStream = null;
  }

  Future<void> _obtenerDatosDePestanaActual({bool silencioso = false}) async {
    if (_tabController.index == 0) await _revisarOrdenAsignada(silencioso: silencioso);
    else if (_tabController.index == 1) await _obtenerPendientes(silencioso: silencioso);
    else if (_tabController.index == 2) await _obtenerEnProceso(silencioso: silencioso);
  }

  List<dynamic> _optimizarOrdenes(List<dynamic> ordenesCrudas) {
  return ordenesCrudas.map((orden) {
    if (orden['productos'] != null && orden['productos'] is String) {
      try {
        orden['productos'] = jsonDecode(orden['productos']);
      } catch(e) {
        orden['productos'] = [];
      }
    }
    
    if (orden['productos'] is List) {
      for (var prod in orden['productos']) {
        if (prod['imagen'] != null && prod['imagen'].toString().isNotEmpty) {
          prod['imagenBytes'] = base64Decode(prod['imagen'].toString().replaceAll(RegExp(r'\s+'), ''));
        }
      }
    }
    return orden;
  }).toList();
}

  void _mostrarPeticionCompartir(Map<String, dynamic> data) {
    try {
      final isDarkMode = Theme.of(context).brightness == Brightness.dark;
      List<dynamic> productos = [];
      if (data['productos'] != null && data['productos'].toString().isNotEmpty) {
        try { productos = data['productos'] is String ? jsonDecode(data['productos']) : List.from(data['productos']); } catch(_) {}
      }

      bool yaRecogido = false;
      String estadoViaje = 'Pendiente';
      String tituloViaje = 'Viaje';

      if (data['ordenes'] != null) {
        List<dynamic> ordenesList = data['ordenes'] is String ? jsonDecode(data['ordenes']) : List.from(data['ordenes']);
        if (ordenesList.isNotEmpty) {
          int idPrimeraOrden = int.tryParse(ordenesList[0].toString()) ?? 0;
          for (var o in _ordenesActivas) {
            if (o['id'] == idPrimeraOrden) {
              estadoViaje = o['estado'] ?? 'Pendiente';
              tituloViaje = o['viaje_programado'] ?? 'Viaje';
              if (o['estado'] == 'En Camino') yaRecogido = true; 
              break;
            }
          }
        }
      }

      List<dynamic> masas = [];
      List<dynamic> mercancia = [];
      for(var p in productos) {
        bool esMasa = p['detalle']?.toString().toLowerCase().contains('kilo') == true || p['detalle']?.toString().toLowerCase().contains('gramo') == true;
        if (esMasa) masas.add(p);
        else mercancia.add(p);
      }

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Dialog(
          backgroundColor: isDarkMode ? const Color(0xFF1E1E1E) : const Color(0xFF0052CC), 
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("El repartidor ${data['nombre_destino'] ?? 'Compañero'} solicita compartir el siguiente pedido:", style: const TextStyle(color: Colors.white, fontSize: 16)),
                const SizedBox(height: 16),
                
                Card(
                  elevation: 0,
                  color: isDarkMode ? Colors.grey[900] : Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.orangeAccent, width: 2.5)),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text('Entrega: $tituloViaje', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange[700]))),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.receipt_long, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 16),
                            const SizedBox(width: 6),
                            Expanded(child: Text('Estado: $estadoViaje', style: TextStyle(color: isDarkMode ? Colors.cyanAccent : Colors.blue[800], fontWeight: FontWeight.bold, fontSize: 14))),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.person, color: isDarkMode ? Colors.grey[400] : Colors.grey[600], size: 16),
                            const SizedBox(width: 6),
                            Expanded(child: Text('Para: ${data['cliente_nombre'] ?? 'Cliente'}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 14))),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 16),
                            const SizedBox(width: 6),
                            Expanded(child: Text('Local: Ubicación', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 13))),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Divider(height: 1, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black87),
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (masas.isNotEmpty)
                              Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: masas.map((m) => Text("${m['nombre_producto'] ?? 'Masa'}: ${m['cantidad']} Kl.", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black))).toList())),
                            if (masas.isNotEmpty && mercancia.isNotEmpty)
                              const Padding(padding: EdgeInsets.symmetric(horizontal: 8.0), child: Text("!", style: TextStyle(fontSize: 20, color: Colors.orange, fontWeight: FontWeight.bold))),
                            if (mercancia.isNotEmpty)
                              Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: mercancia.map((m) => Text("${m['nombre_producto'] ?? 'Producto'}: ${m['cantidad']} U.", style: const TextStyle(fontSize: 12, color: Colors.grey))).toList())),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () { Navigator.pop(ctx); _aceptarCompartir(data, yaRecogido); }, 
                      child: const Text("Aceptar", style: TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold))
                    ),
                    const SizedBox(width: 16),
                    TextButton(
                      onPressed: () { Navigator.pop(ctx); _rechazarCompartir(data); }, 
                      child: const Text("Rechazar", style: TextStyle(color: Colors.redAccent, fontSize: 20, fontWeight: FontWeight.bold))
                    ),
                  ],
                )
              ],
            ),
          )
        )
      );
    } catch (e) { debugPrint("Error Dialog de compartir: $e"); }
  }

  Future<void> _rechazarCompartir(Map<String, dynamic> data) async {
    setState(() => _isLoading = true);
    try {
      await http.post(Uri.parse('${AppConfig.apiHost}/ordenes/rechazar-compartir'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'id_repartidor_destino': data['id_repartidor_destino'], 'ids_ordenes': data['ordenes']}));
    } catch (e) { } finally { if (mounted) setState(() => _isLoading = false); }
  }

  Future<void> _aceptarCompartir(Map<String, dynamic> data, bool yaRecogido) async {
    setState(() => _isLoading = true);
    try {
      final payload = {'id_repartidor_origen': data['id_repartidor_origen'], 'id_repartidor_destino': data['id_repartidor_destino'], 'ids_ordenes': data['ordenes'], 'tipo_transferencia': yaRecogido ? 'con_nip' : 'directa'};
      final res = await http.post(Uri.parse('${AppConfig.apiHost}/ordenes/aceptar-compartir'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));
      if (res.statusCode == 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(yaRecogido ? '✅ Solicitud aceptada. Se requiere NIP para transferir.' : '✅ Pedido transferido directamente al compañero.'), backgroundColor: Colors.green));
        await _revisarOrdenAsignada();
      }
    } catch (e) { } finally { if (mounted) setState(() => _isLoading = false); }
  }

  // 🚀 LÓGICA REPARADA: LIMPIAMOS LAS IMÁGENES ANTES DE ENVIARLAS AL SERVIDOR
  Future<void> _solicitarCompartirUna(int idOrden, int idDueno, String? cliente, dynamic productos) async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final miId = _obtenerIdSeguro(prefs);
      
      List<Map<String, dynamic>> prodsLimpios = [];
      if (productos is List) {
        for(var p in productos) {
          prodsLimpios.add({
            'nombre_producto': p['nombre_producto'] ?? p['nombre'], 
            'cantidad': p['cantidad'], 
            'detalle': p['detalle']
          });
        }
      }

      final payload = {
        'id_repartidor_origen': idDueno, 
        'id_repartidor_destino': miId, 
        'nombre_destino': prefs.getString('userUser') ?? prefs.getString('userName') ?? 'Repartidor', 
        'ordenes': [idOrden], 
        'cliente_nombre': cliente ?? 'Sin nombre', 
        'productos': prodsLimpios // 🚀 EVITAMOS EL CRASHEO DE FIREBASE Y EL SOCKET
      };

      await http.post(Uri.parse('${AppConfig.apiHost}/ordenes/solicitar-compartir'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));
      
      if (mounted) setState(() { _pedidosEnEspera.add(idOrden); });
    } catch (e) { } finally { if (mounted) setState(() => _isLoading = false); }
  }

  Future<void> _entregarPedidoCompartido(int idOrden, int idDestino, String codigoIngresado) async {
    setState(() => _isLoading = true);
    try {
      final res = await http.post(Uri.parse('${AppConfig.apiHost}/ordenes/confirmar-transferencia'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'ids_ordenes': [idOrden], 'id_repartidor_destino': idDestino, 'codigo': codigoIngresado}));
      final d = jsonDecode(res.body);
      if (d['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Transferencia exitosa. El pedido ahora es del compañero.'), backgroundColor: Colors.green));
        await _revisarOrdenAsignada();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('❌ NIP incorrecto'), backgroundColor: Colors.red));
      }
    } catch (e) {} finally { if (mounted) setState(() => _isLoading = false); }
  }

  Future<void> _revisarOrdenAsignada({bool silencioso = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idRepartidor = _obtenerIdSeguro(prefs); 
      _mild = idRepartidor;
      if (idRepartidor == null) return;

      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/activa/repartidor/$idRepartidor'));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['ordenes'] != null && (data['ordenes'] as List).isNotEmpty) {
          List<dynamic> ordenes = data['ordenes'];
          String nuevaFirma = ordenes.map((o) => "${o['id']}_${o['estado']}").join('-');
          if (silencioso && _firmaDeLaOrden.isNotEmpty && _firmaDeLaOrden != nuevaFirma && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('🔄 Actualización en tus pedidos.', style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.blue, duration: Duration(seconds: 3)));
          }
          _firmaDeLaOrden = nuevaFirma; 
          for (var ord in ordenes) {
            if (ord['ultima_entrega'] == true && ord['id_cliente'] != null) {
              final resTicket = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/ticket_diario/cliente/${ord['id_cliente']}'));
              if (resTicket.statusCode == 200) _ticketsDiarios[ord['id']] = jsonDecode(resTicket.body)['ticket'] ?? [];
            }
          }
          if (mounted) setState(() { _ordenesActivas = _optimizarOrdenes(ordenes); _isLoading = false; });
          _iniciarRastreoGPS();
        } else {
          _detenerRastreoGPS();
          if (mounted) Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => RepartidoresScreen(onThemeChanged: widget.onThemeChanged)), (route) => false);
        }
      }
    } catch (e) { debugPrint('Error: $e'); } finally { if (mounted && !silencioso) setState(() => _isLoading = false); }
  }

  Future<void> _obtenerPendientes({bool silencioso = false}) async {
    if (!silencioso) setState(() => _isLoading = true);
    try {
      final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/pendientes'));
      if (res.statusCode == 200 && mounted) {
        setState(() { 
          _ordenesPendientes = _optimizarOrdenes(jsonDecode(res.body)); 
          _pedidosSeleccionadosPendientes.removeWhere((id) => !_ordenesPendientes.any((o) => o['id'] == id));
        });
      }
    } catch (e) {} finally { if (mounted && !silencioso) setState(() => _isLoading = false); }
  }

  Future<void> _obtenerEnProceso({bool silencioso = false}) async {
    if (!silencioso) setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? myId = _obtenerIdSeguro(prefs);
      final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/en-proceso/repartidores'));
      if (res.statusCode == 200 && mounted) {
        List<dynamic> rows = jsonDecode(res.body);
        Map<int, Map<String, dynamic>> agrupados = {};
        for (var row in rows) {
          int idRep = row['id_repartidor'];
          if (idRep == myId) continue; 
          if (!agrupados.containsKey(idRep)) {
            agrupados[idRep] = {'id_repartidor': idRep, 'nombre': row['nombre_repartidor'], 'foto': row['foto_repartidor'], 'ordenes': []};
          }
          agrupados[idRep]!['ordenes'].add(row);
        }
        setState(() => _repartidoresEnProceso = agrupados.values.toList());
      }
    } catch (e) {} finally { if (mounted && !silencioso) setState(() => _isLoading = false); }
  }

  Future<void> _aceptarPedidosEnLote() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await http.put(Uri.parse('${AppConfig.apiHost}/ordenes/aceptar-multiples'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'id_repartidor': _obtenerIdSeguro(prefs), 'ids_ordenes': _pedidosSeleccionadosPendientes.toList()}));
      _pedidosSeleccionadosPendientes.clear();
      _tabController.animateTo(0);
      await _revisarOrdenAsignada();
    } catch (e) { if (mounted) setState(() => _isLoading = false); }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDarkMode ? const Color(0xFF121212) : const Color(0xFF0052CC);

    return WillPopScope(
      onWillPop: () async => false, 
      child: Scaffold(
        backgroundColor: backgroundColor,
        appBar: AppBar(
          backgroundColor: Colors.transparent, elevation: 0, automaticallyImplyLeading: false,
          title: const Text('Envíos Activos', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          centerTitle: true,
          bottom: TabBar(
            controller: _tabController,
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            tabs: const [
              Tab(icon: Icon(Icons.motorcycle), text: "Mis Viajes"),
              Tab(icon: Icon(Icons.list_alt), text: "Pendientes"),
              Tab(icon: Icon(Icons.people), text: "Compañeros"),
            ],
          ),
        ),
        body: _isLoading 
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : TabBarView(
                controller: _tabController,
                children: [
                  _buildMisViajesTab(isDarkMode),
                  _buildPendientesTab(isDarkMode),
                  _buildCompanerosTab(isDarkMode)
                ],
              ),
        
        floatingActionButton: _construirFloatingButton(),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      ),
    );
  }

  Widget? _construirFloatingButton() {
    if (_tabController.index == 1 && _pedidosSeleccionadosPendientes.isNotEmpty) {
      return ElevatedButton(
        style: ElevatedButton.styleFrom(minimumSize: const Size(0, 50), backgroundColor: const Color(0xFF00C853), padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 30), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 5),
        onPressed: _aceptarPedidosEnLote,
        child: Text('AGREGAR ${_pedidosSeleccionadosPendientes.length} PEDIDO(S)', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
      );
    } 
    return null;
  }

  Widget _buildMisViajesTab(bool isDarkMode) {
    if (_ordenesActivas.isEmpty) return const Center(child: Text("No tienes órdenes activas", style: TextStyle(color: Colors.white)));
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 20),
      itemCount: _ordenesActivas.length,
      itemBuilder: (context, index) {
        final orden = _ordenesActivas[index];
        if (orden['ultima_entrega'] == true && orden['id_cliente'] != null) return _construirTicketFinal(orden);
        return _construirTarjetaNormal(orden, isDarkMode);
      },
    );
  }

  Widget _buildPendientesTab(bool isDarkMode) {
    if (_ordenesPendientes.isEmpty) return const Center(child: Text("No hay pedidos pendientes libres", style: TextStyle(color: Colors.white)));
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80, left: 16, right: 16, top: 16),
      itemCount: _ordenesPendientes.length,
      itemBuilder: (context, index) {
        final orden = _ordenesPendientes[index];
        final bool estaSeleccionado = _pedidosSeleccionadosPendientes.contains(orden['id']);
        return _construirTarjetaMini(orden, estaSeleccionado, isDarkMode, () {
          setState(() { estaSeleccionado ? _pedidosSeleccionadosPendientes.remove(orden['id']) : _pedidosSeleccionadosPendientes.add(orden['id']); });
        });
      },
    );
  }

  Widget _buildCompanerosTab(bool isDarkMode) {
    if (_repartidoresEnProceso.isEmpty) return const Center(child: Text("No hay compañeros activos", style: TextStyle(color: Colors.white)));
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80, left: 16, right: 16, top: 16),
      itemCount: _repartidoresEnProceso.length,
      itemBuilder: (context, index) {
        final rep = _repartidoresEnProceso[index];
        final List<dynamic> ordenes = rep['ordenes'];
        return Card(
          color: isDarkMode ? Colors.grey[900] : Colors.blue[50],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          margin: const EdgeInsets.only(bottom: 16),
          child: ExpansionTile(
            leading: CircleAvatar(backgroundColor: Colors.blueAccent, backgroundImage: rep['foto'] != null 
    ? ResizeImage(MemoryImage(base64Decode(rep['foto'])), width: 120) 
    : null, child: rep['foto'] == null ? const Icon(Icons.motorcycle, color: Colors.white) : null),
            title: Text(rep['nombre']?.toString() ?? 'Compañero', style: TextStyle(fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black)),
            subtitle: Text('${ordenes.length} pedidos activos', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87)),
            children: ordenes.map((o) {
              return _construirTarjetaMiniCompanero(o, rep['id_repartidor'], isDarkMode);
            }).toList(),
          ),
        );
      },
    );
  }

  Widget _construirTarjetaMiniCompanero(Map<String, dynamic> orden, int idDueno, bool isDarkMode) {
    final List<dynamic> productos = extraerProductosSeguro(orden['productos']);
    final bool enEspera = _pedidosEnEspera.contains(orden['id_orden'] ?? orden['id']);

    String tituloViaje = orden['viaje_programado']?.toString() ?? 'Viaje';
    final bool esFuturo = tituloViaje.startsWith('Prog:');
    tituloViaje = esFuturo ? 'Programado: ${tituloViaje.replaceAll('Prog: ', '')}' : 'Entrega: $tituloViaje';

    List<dynamic> masas = [];
    List<dynamic> mercancia = [];
    for(var p in productos) {
      bool esMasa = p['detalle']?.toString().toLowerCase().contains('kilo') == true || p['detalle']?.toString().toLowerCase().contains('gramo') == true;
      if (esMasa) masas.add(p);
      else mercancia.add(p);
    }

    return Card(
      color: isDarkMode ? Colors.grey[900] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.orangeAccent, width: 2.5)),
      margin: const EdgeInsets.only(bottom: 12, left: 16, right: 16),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text(tituloViaje, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange[700]))),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.receipt_long, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text('Estado: ${orden['estado'] ?? 'Pendiente'}', style: TextStyle(color: isDarkMode ? Colors.cyanAccent : Colors.blue[800], fontWeight: FontWeight.bold, fontSize: 14))),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.person, color: isDarkMode ? Colors.grey[400] : Colors.grey[600], size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text('Para: ${orden['cliente'] ?? 'Sin nombre'}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 14))),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text('Local: ${orden['local'] ?? 'No especificado'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 13))),
              ],
            ),
            const SizedBox(height: 8),
            Divider(height: 1, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black87),
            const SizedBox(height: 8),
            
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (masas.isNotEmpty)
                  Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: masas.map((m) => Text("${m['nombre_producto'] ?? 'Masa'}: ${m['cantidad']} Kl.", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black))).toList())),
                if (masas.isNotEmpty && mercancia.isNotEmpty)
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 8.0), child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold))),
                if (mercancia.isNotEmpty)
                  Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: mercancia.map((m) => Text("${m['nombre_producto'] ?? 'Producto'}: ${m['cantidad']} U.", style: const TextStyle(fontSize: 13, color: Colors.grey))).toList())),
                
                if (enEspera)
                  const Padding(
                    padding: EdgeInsets.only(left: 8.0),
                    child: SizedBox(
                      width: 110,
                      child: Text('Esperando a Confirmacion', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 12), textAlign: TextAlign.center),
                    )
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: SizedBox(
                      width: 130, 
                      height: 35,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white, padding: EdgeInsets.zero),
                        onPressed: () => _solicitarCompartirUna(orden['id_orden'] ?? orden['id'], idDueno, orden['cliente'], orden['productos']),
                        child: const Text('Solicitar Compartir', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12), textAlign: TextAlign.center)
                      ),
                    ),
                  )
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _construirTarjetaMini(Map<String, dynamic> orden, bool estaSeleccionado, bool isDarkMode, VoidCallback onTap) {
    final List<dynamic> productos = extraerProductosSeguro(orden['productos']);
    final double cambio = double.tryParse(orden['cambio_efectivo']?.toString() ?? '0') ?? 0;
    
    String tituloViaje = orden['viaje_programado']?.toString() ?? 'Viaje';
    final bool esFuturo = tituloViaje.startsWith('Prog:');
    tituloViaje = esFuturo ? 'Programado: ${tituloViaje.replaceAll('Prog: ', '')}' : 'Entrega: $tituloViaje';

    List<dynamic> masas = [];
    List<dynamic> mercancia = [];
    for(var p in productos) {
      bool esMasa = p['detalle']?.toString().toLowerCase().contains('kilo') == true || p['detalle']?.toString().toLowerCase().contains('gramo') == true;
      if (esMasa) masas.add(p);
      else mercancia.add(p);
    }

    return Card(
      color: isDarkMode ? Colors.grey[900] : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12), 
        side: BorderSide(color: Colors.orangeAccent, width: estaSeleccionado ? 3.5 : 2.0)
      ),
      margin: const EdgeInsets.only(bottom: 12, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _mostrarDetalleSinMapa(orden, masas, mercancia, tituloViaje, isDarkMode, cambio),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: Text(tituloViaje, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange[700]))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.person, color: isDarkMode ? Colors.grey[400] : Colors.grey[600], size: 16),
                      const SizedBox(width: 6),
                      Expanded(child: Text('Para: ${orden['cliente'] ?? 'Sin nombre'}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 14))),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 16),
                      const SizedBox(width: 6),
                      Expanded(child: Text('Local: ${orden['local'] ?? orden['direccion'] ?? 'No especificado'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 13))),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          Divider(height: 1, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black87),
          
          InkWell(
            onTap: onTap,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (masas.isNotEmpty)
                    Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: masas.map((m) => Text("${m['nombre_producto'] ?? 'Masa'}: ${m['cantidad']} Kl.", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black))).toList())),
                  
                  if (masas.isNotEmpty && mercancia.isNotEmpty)
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8.0), child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold))),
                  
                  if (mercancia.isNotEmpty)
                    Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: mercancia.map((m) => Text("${m['nombre_producto'] ?? 'Producto'}: ${m['cantidad']} U.", style: const TextStyle(fontSize: 13, color: Colors.grey))).toList())),
                  
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle, 
                      color: estaSeleccionado ? Colors.orange : (isDarkMode ? Colors.grey[800] : Colors.grey.withOpacity(0.2)),
                      border: Border.all(color: estaSeleccionado ? Colors.transparent : Colors.grey, width: 1.5)
                    ),
                    padding: const EdgeInsets.all(10),
                    child: Icon(estaSeleccionado ? Icons.check : Icons.circle_outlined, color: estaSeleccionado ? Colors.white : Colors.transparent, size: 24),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _marcarRecogido(int idOrden) async {
    setState(() {
      final index = _ordenesActivas.indexWhere((o) => o['id'] == idOrden);
      if (index != -1) {
        _ordenesActivas[index]['estado'] = 'En Camino';
      }
    });
    _iniciarRastreoGPS();
    try {
      await http.put(Uri.parse('${AppConfig.apiHost}/ordenes/estado/$idOrden'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'estado': 'En Camino'}));
    } catch (e) { debugPrint('$e'); }
  }

  void _marcarYaLlegue(int idOrden) { 
    if (!_ordenesEnLugar.contains(idOrden)) {
      setState(() => _ordenesEnLugar.add(idOrden)); 
      _detenerRastreoGPS();
      http.put(Uri.parse('${AppConfig.apiHost}/ordenes/llegada/$idOrden'));
    }
  }

  void _mostrarDialogoVerificacion(Map<String, dynamic> orden, bool isDarkMode) {
    final List<dynamic> productos = extraerProductosSeguro(orden['productos']);
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDarkMode ? Colors.grey[900] : Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Verificar Pedido', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black)),
        content: SizedBox(width: double.maxFinite, child: ListView.builder(shrinkWrap: true, itemCount: productos.length, itemBuilder: (c, i) { final prod = productos[i]; return Card(color: isDarkMode ? Colors.grey[800] : Colors.white, child: ListTile(leading: Icon(Icons.inventory, color: isDarkMode ? Colors.blue[300] : Colors.blue), title: Text(prod['nombre_producto']?.toString() ?? prod['nombre']?.toString() ?? 'Producto', style: TextStyle(fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black)), trailing: Text('${prod['cantidad']} U.', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black)))); })),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          SizedBox( 
            width: 100, height: 40,
            child: ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: Size.zero, backgroundColor: Colors.red, padding: EdgeInsets.zero), onPressed: () { Navigator.pop(ctx); _mostrarDialogoEdicionFaltante(orden, productos, isDarkMode); }, child: const Text('Faltante', style: TextStyle(color: Colors.white))),
          ),
          SizedBox( 
            width: 100, height: 40,
            child: ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: Size.zero, backgroundColor: Colors.green, padding: EdgeInsets.zero), onPressed: () { Navigator.pop(ctx); _marcarRecogido(orden['id']); }, child: const Text('Completa', style: TextStyle(color: Colors.white))),
          ),
        ],
      ),
    );
  }

  void _mostrarDialogoEdicionFaltante(Map<String, dynamic> orden, List<dynamic> productosOriginales, bool isDarkMode) {
    List<Map<String, dynamic>> prodsEditables = List<Map<String, dynamic>>.from(productosOriginales.map((p) => Map<String, dynamic>.from(p)));
    showDialog(
      context: context, barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (context, setStateLocal) {
        return AlertDialog(
          backgroundColor: isDarkMode ? Colors.grey[900] : Colors.white,
          title: Text('Ajustar Unidades', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black)),
          content: SizedBox(width: double.maxFinite, child: ListView.builder(shrinkWrap: true, itemCount: prodsEditables.length, itemBuilder: (c, i) {
            final p = prodsEditables[i];
            return Card(color: isDarkMode ? Colors.grey[800] : Colors.white, child: Padding(padding: const EdgeInsets.all(8.0), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Expanded(child: Text(p['nombre_producto']?.toString() ?? p['nombre']?.toString() ?? '', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black))),
              Row(children: [
                IconButton(icon: const Icon(Icons.remove_circle, color: Colors.red), onPressed: () { if (p['cantidad'] > 0) setStateLocal(() => p['cantidad']--); }),
                Text('${p['cantidad']}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black)),
                IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => setStateLocal(() => p['cantidad'] = 0)),
              ])
            ])));
          })),
          actions: [
            TextButton(child: Text('Cancelar', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87)), onPressed: () => Navigator.pop(ctx)),
            SizedBox( 
              width: 150, height: 40,
              child: ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: Size.zero, padding: EdgeInsets.zero), child: const Text('Guardar y Recoger'), onPressed: () { Navigator.pop(ctx); _guardarMercanciaYRecoger(orden['id'], prodsEditables, productosOriginales); }),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _guardarMercanciaYRecoger(int idOrden, List<Map<String, dynamic>> prodsEditables, List<dynamic> productosOriginales) async {
    double nuevoTotal = 0;
    List<String> faltasText = [];
    List<Map<String, dynamic>> arrayFaltantes = [];

    for (int i = 0; i < prodsEditables.length; i++) {
      var p = prodsEditables[i];
      nuevoTotal += (p['cantidad'] * (double.tryParse(p['precio'].toString()) ?? 0));
      
      int origQty = int.tryParse(productosOriginales[i]['cantidad'].toString()) ?? 0;
      int newQty = p['cantidad'];
      if (origQty > newQty) {
        int faltan = origQty - newQty;
        faltasText.add("${faltan}x ${p['nombre_producto'] ?? p['nombre']}");
        
        arrayFaltantes.add({
          'nombre_producto': p['nombre_producto'] ?? p['nombre'],
          'cantidad_faltante': faltan
        });
      }
    }

    String detallesFaltante = faltasText.isNotEmpty ? faltasText.join(', ') : "Se ajustaron los productos";

    setState(() {
      final index = _ordenesActivas.indexWhere((o) => o['id'] == idOrden);
      if (index != -1) {
        _ordenesActivas[index]['productos'] = prodsEditables;
        _ordenesActivas[index]['total'] = nuevoTotal;
        _ordenesActivas[index]['hubo_faltante'] = true;
        _ordenesActivas[index]['detalles_faltante'] = detallesFaltante;
        _ordenesActivas[index]['estado'] = 'En Camino';
      }
    });
    _iniciarRastreoGPS();
    try {
      await http.put(
        Uri.parse('${AppConfig.apiHost}/ordenes/modificar-productos/$idOrden'), 
        headers: {'Content-Type': 'application/json'}, 
        body: jsonEncode({
          'productos': prodsEditables, 
          'total': nuevoTotal,
          'detalles_faltante': detallesFaltante,
          'productos_faltantes': arrayFaltantes 
        })
      );
      await http.put(Uri.parse('${AppConfig.apiHost}/ordenes/estado/$idOrden'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'estado': 'En Camino'}));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Mercancía actualizada y en camino.'))); 
    } catch(e) { }
  }

  void _mostrarDialogoPIN(Map<String, dynamic> orden) {
    showDialog(
      context: context,
      builder: (ctx) { 
        return AlertDialog(
          backgroundColor: const Color(0xFF0052CC),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          contentPadding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CuatroBloquesNip(
                borderColor: Colors.black, 
                textColor: Colors.black, 
                onCompleted: (pin) {
                  Navigator.pop(ctx); 
                  int idDestino = int.tryParse(orden['id_repartidor_destino'].toString()) ?? 0;
                  _entregarPedidoCompartido(orden['id'], idDestino, pin); 
                }
              ),
              const SizedBox(height: 30),
              SizedBox( 
                width: 200, height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(minimumSize: Size.zero, backgroundColor: const Color(0xFF00C853), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: const Text('Validar NIP', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                  onPressed: () {}
                ),
              )
            ],
          ),
        );
      }
    );
  }

  void _abrirRutaGPS(Map<String, dynamic> orden) {
    Navigator.push(context, MaterialPageRoute(builder: (context) => MapaRutaRepartidorScreen(
      destino: LatLng(double.tryParse(orden['latitud']?.toString() ?? '19.4') ?? 19.4, double.tryParse(orden['longitud']?.toString() ?? '-99.1') ?? -99.1), 
      cliente: orden['cliente']?.toString() ?? 'Cliente', 
      direccion: orden['direccion']?.toString() ?? 'Ubicación'
    )));
  }

  Future<void> _llamarCliente(String? telefonoRaw) async {
    final String telefono = telefonoRaw?.toString() ?? '';
    final String num = telefono.replaceAll(RegExp(r'[^0-9+]'), '');
    if (num.isNotEmpty && await canLaunchUrl(Uri.parse('tel:$num'))) await launchUrl(Uri.parse('tel:$num'));
  }

  Widget _construirTicketFinal(Map<String, dynamic> orden) {
    List<dynamic> ticketActual = _ticketsDiarios[orden['id']] ?? [];
    double granTotal = 0;
    for (var o in ticketActual) granTotal += double.tryParse(o['total'].toString()) ?? 0;
    
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0), child: Column(children: [
      Text('Ticket Total de ${orden['cliente']}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      
      if (orden['hubo_faltante'] == true)
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.red.withOpacity(0.2), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.redAccent)),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text('🚨 ATENCIÓN:\nReportaste un faltante: ${orden['detalles_faltante'] ?? 'se ajustaron los productos.'}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))),
            ],
          ),
        ),

      Container(constraints: const BoxConstraints(maxHeight: 300), child: ListView.builder(shrinkWrap: true, itemCount: ticketActual.length, itemBuilder: (context, i) {
        final o = ticketActual[i];
        final List<dynamic> productos = extraerProductosSeguro(o['productos']);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(o['viaje_programado']?.toString() ?? 'Viaje', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...productos.map<Widget>((prod) => Padding(padding: const EdgeInsets.only(bottom: 12.0), child: Row(children: [ Expanded(child: Text(prod['nombre_producto']?.toString() ?? prod['nombre']?.toString() ?? 'Producto', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))), Text('${prod['cantidad']} U.', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)) ]))).toList(),
        ]);
      })),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [ 
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Ubicación:', style: TextStyle(color: Colors.white, fontSize: 12)), Text(orden['direccion']?.toString() ?? 'Sin dirección', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14))])), 
        Column(children: [ 
          SizedBox( 
            width: 120, height: 35,
            child: ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: Size.zero, backgroundColor: const Color(0xFF90A4AE), foregroundColor: Colors.black, padding: EdgeInsets.zero), onPressed: () => _abrirRutaGPS(orden), child: const Text('¿Cómo llegar?'))
          ) 
        ]) 
      ]),
      const SizedBox(height: 16),
      Container(padding: const EdgeInsets.all(16.0), decoration: BoxDecoration(color: const Color(0xFF0040A0), borderRadius: BorderRadius.circular(16)), child: Column(children: [ Row(mainAxisAlignment: MainAxisAlignment.end, children: [Text('TOTAL: $granTotal MXN', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))]), const SizedBox(height: 16) ]))
    ]));
  }

  Widget _construirTarjetaNormal(Map<String, dynamic> orden, bool isDarkMode) {
    final List<dynamic> productos = extraerProductosSeguro(orden['productos']);
    final double cambio = double.tryParse(orden['cambio_efectivo']?.toString() ?? '0') ?? 0;
    final String? telefonoStr = orden['telefono']?.toString();
    final bool tieneTelefono = telefonoStr != null && telefonoStr.trim().isNotEmpty;

    final bool enTransferencia = orden['codigo_transferencia'] != null;
    final bool soyDestino = enTransferencia && (orden['id_repartidor_destino'] == _mild);

    String tituloViaje = orden['viaje_programado']?.toString() ?? 'Viaje';
    final bool esFuturo = tituloViaje.startsWith('Prog:');
    tituloViaje = esFuturo ? 'Programado: ${tituloViaje.replaceAll('Prog: ', '')}' : 'Entrega: $tituloViaje';

    List<dynamic> masas = [];
    List<dynamic> mercancia = [];
    for(var p in productos) {
      bool esMasa = p['detalle']?.toString().toLowerCase().contains('kilo') == true || p['detalle']?.toString().toLowerCase().contains('gramo') == true;
      if (esMasa) masas.add(p);
      else mercancia.add(p);
    }

    final estado = orden['estado'];
    final bool huboFaltante = orden['hubo_faltante'] == true;

    if (enTransferencia && soyDestino) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 4,
              color: isDarkMode ? Colors.grey[900] : Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.orangeAccent, width: 2.5)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(tituloViaje, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange[700]))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.receipt_long, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 16),
                        const SizedBox(width: 6),
                        Expanded(child: Text('Estado: Buscando Repartidor', style: TextStyle(color: isDarkMode ? Colors.cyanAccent : Colors.blue[800], fontWeight: FontWeight.bold, fontSize: 14))),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.person, color: isDarkMode ? Colors.grey[400] : Colors.grey[600], size: 16),
                        const SizedBox(width: 6),
                        Expanded(child: Text('Para: ${orden['cliente'] ?? 'Cliente'}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 14))),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 16),
                        const SizedBox(width: 6),
                        Expanded(child: Text('Local: ${orden['local'] ?? 'No especificado'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 13))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Divider(height: 1, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black87),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (masas.isNotEmpty)
                          Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: masas.map((m) => Text("${m['nombre_producto']}: ${m['cantidad']} Kl.", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black))).toList())),
                        if (masas.isNotEmpty && mercancia.isNotEmpty)
                          const Padding(padding: EdgeInsets.symmetric(horizontal: 8.0), child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold))),
                        if (mercancia.isNotEmpty)
                          Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: mercancia.map((m) => Text("${m['nombre_producto']}: ${m['cantidad']} U.", style: const TextStyle(fontSize: 12, color: Colors.grey))).toList())),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text("Transferencia en curso", style: TextStyle(fontSize: 16, color: isDarkMode ? Colors.white70 : Colors.black87)),
                    Text("CODIGO NIP", style: TextStyle(fontSize: 16, color: isDarkMode ? Colors.white70 : Colors.black87)),
                    Text(orden['codigo_transferencia']?.toString() ?? '0000', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black)),
                    Text("Dale este codigo al repartidor", style: TextStyle(fontSize: 16, color: isDarkMode ? Colors.white70 : Colors.black87)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red[500], foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: EdgeInsets.zero),
                      icon: const Icon(Icons.phone, size: 22),
                      label: const Text('Llamar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      onPressed: tieneTelefono ? () => _llamarCliente(telefonoStr) : null,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
               Expanded(
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF90A4AE), foregroundColor: Colors.black87, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: EdgeInsets.zero),
                      icon: const Icon(Icons.map, size: 22),
                      label: const Text('Ruta al compañero', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      onPressed: () {
                        final LatLng? destinoCompanero = _ubicacionesCompaneros[orden['id']];
                        if (destinoCompanero != null) {
                          Navigator.push(context, MaterialPageRoute(builder: (context) => MapaRutaRepartidorScreen(
                            destino: destinoCompanero,
                            cliente: orden['nombre_repartidor_origen'] ?? 'Compañero',
                            direccion: 'Ubicación actual del compañero',
                            idOrden: orden['id'],
                            rastrearCompanero: true,
                          )));
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Ubicación del compañero no disponible. Esperando señal...'),
                            backgroundColor: Colors.orange,
                          ));
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            elevation: 4,
            color: isDarkMode ? Colors.grey[900] : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: huboFaltante ? Colors.redAccent : Colors.orangeAccent, width: 2.5)),
            clipBehavior: Clip.hardEdge,
            child: InkWell(
              onTap: () => _mostrarDetalleSinMapa(orden, masas, mercancia, tituloViaje, isDarkMode, cambio),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(tituloViaje, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange[700]))),
                      ],
                    ),
                    const SizedBox(height: 8),

                    Row(
                      children: [
                        Icon(Icons.receipt_long, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text('Estado: ${enTransferencia && !soyDestino ? 'Buscando Repartidor' : estado}', style: TextStyle(color: isDarkMode ? Colors.cyanAccent : Colors.blue[800], fontWeight: FontWeight.bold, fontSize: 14))),
                      ],
                    ),
                    const SizedBox(height: 6),

                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.person, color: isDarkMode ? Colors.grey[400] : Colors.grey[600], size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text('Para: ${orden['cliente'] ?? 'Cliente'}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87, fontWeight: FontWeight.bold, fontSize: 14))),
                                ],
                              ),
                              const SizedBox(height: 6),
                              
                              GestureDetector(
                                onTap: () => _mostrarDetalleConMapa(orden, masas, mercancia, tituloViaje, isDarkMode),
                                child: Container(
                                  color: Colors.transparent, 
                                  padding: const EdgeInsets.only(top: 2, bottom: 2, right: 8),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 16),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text('Local: ${orden['local'] ?? 'No especificado'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 13))),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (enTransferencia && !soyDestino)
                           Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: SizedBox(
                              width: 120, height: 40,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white, padding: EdgeInsets.zero), 
                                onPressed: () => _mostrarDialogoPIN(orden), 
                                child: const Text('Liberar Pedido', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))
                              ),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: _construirBotonAccionMini(orden, isDarkMode),
                          )
                      ],
                    ),

                    if (huboFaltante)
                      Container(
                        margin: const EdgeInsets.only(top: 16),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red)),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Colors.red),
                            const SizedBox(width: 8),
                            Expanded(child: Text('Faltante reportado: ${orden['detalles_faltante'] ?? 'Revisar.'}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13))),
                          ],
                        ),
                      ),

                    const SizedBox(height: 12),
                    Divider(height: 1, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black87),
                    const SizedBox(height: 12),

                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (masas.isNotEmpty)
                          Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: masas.map((m) => Text("${m['nombre_producto']}: ${m['cantidad']} Kl.", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black))).toList())),
                        if (masas.isNotEmpty && mercancia.isNotEmpty)
                          const Padding(padding: EdgeInsets.symmetric(horizontal: 12.0), child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold))),
                        if (mercancia.isNotEmpty)
                          Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: mercancia.map((m) => Text("${m['nombre_producto']}: ${m['cantidad']} U.", style: const TextStyle(fontSize: 12, color: Colors.grey))).toList())),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red[500], foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: EdgeInsets.zero),
                    icon: const Icon(Icons.phone, size: 22),
                    label: const Text('Llamar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    onPressed: tieneTelefono ? () => _llamarCliente(telefonoStr) : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF90A4AE), foregroundColor: Colors.black87, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: EdgeInsets.zero),
                    icon: const Icon(Icons.map, size: 22),
                    label: Text((enTransferencia && !soyDestino) ? 'Ruta al compañero' : '¿Cómo llegar?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: (enTransferencia && !soyDestino) ? 14 : 16), textAlign: TextAlign.center),
                    onPressed: () {
                      if (enTransferencia && !soyDestino) {
                        final LatLng? destinoCompanero = _ubicacionesCompaneros[orden['id']];
                        if (destinoCompanero != null) {
                          Navigator.push(context, MaterialPageRoute(builder: (context) => MapaRutaRepartidorScreen(
                            destino: destinoCompanero,
                            cliente: orden['nombre_repartidor_destino'] ?? 'Compañero',
                            direccion: 'Ubicación actual del compañero',
                            idOrden: orden['id'],
                            rastrearCompanero: true,
                          )));
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Ubicación del compañero no disponible. Esperando señal...'),
                            backgroundColor: Colors.orange,
                          ));
                        }
                      } else {
                        _abrirRutaGPS(orden);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: Colors.white24, thickness: 2),
        ],
      ),
    );
  }

  Widget _construirBotonAccionMini(Map<String, dynamic> orden, bool isDarkMode) {
    final estado = orden['estado'];
    final idOrden = orden['id'];

    if (estado == 'Asignado' || estado == 'Pendiente') {
      return SizedBox(
        width: 110, 
        height: 40,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            minimumSize: Size.zero, 
            backgroundColor: const Color(0xFF00C853), 
            foregroundColor: Colors.white, 
            padding: EdgeInsets.zero 
          ), 
          onPressed: () => _mostrarDialogoVerificacion(orden, isDarkMode), 
          child: const Text('RECOGER', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))
        ),
      );
    } else if (estado == 'En Camino') {
      final bool yaLlego = _ordenesEnLugar.contains(idOrden);

      return SizedBox(
        width: 110, 
        height: 40,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            minimumSize: Size.zero, 
            backgroundColor: yaLlego ? Colors.blueAccent : Colors.orange, 
            foregroundColor: Colors.white, 
            padding: EdgeInsets.zero 
          ), 
          onPressed: () {
            if (yaLlego) {
              _mostrarDialogoPINCliente(orden); 
            } else {
              _marcarYaLlegue(idOrden); 
            }
          }, 
          child: Text(yaLlego ? 'ENTREGAR' : 'YA LLEGUE', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))
        ),
      );
    }
    return const SizedBox();
  }
  
  void _mostrarDialogoPINCliente(Map<String, dynamic> orden) {
    showDialog(
      context: context,
      builder: (ctx) {
        final isDarkMode = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDarkMode ? Colors.grey[900] : const Color(0xFF0052CC),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          contentPadding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ingresa el NIP del Cliente', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
              const SizedBox(height: 20),
              CuatroBloquesNip(
                borderColor: isDarkMode ? Colors.orangeAccent : Colors.white,
                textColor: Colors.white,
                onCompleted: (pin) {
                  Navigator.pop(ctx);
                  _completarPedidoFinal(orden['id'], pin);
                },
              ),
            ],
          ),
        );
      }
    );
  }

  Future<void> _completarPedidoFinal(int idOrden, String codigoIngresado) async {
    setState(() => _isLoading = true);
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.apiHost}/ordenes/completar/$idOrden'), 
        headers: {'Content-Type': 'application/json'}, 
        body: jsonEncode({'codigo': codigoIngresado})
      );
      final d = jsonDecode(res.body);
      if (d['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Pedido entregado con éxito.', style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
        _ordenesEnLugar.remove(idOrden); 
        await _revisarOrdenAsignada(); 
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('❌ NIP incorrecto', style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.red));
      }
    } catch (e) {
      debugPrint("Error al completar: $e");
    } finally { 
      if (mounted) setState(() => _isLoading = false); 
    }
  }

  void _mostrarDetalleConMapa(Map<String, dynamic> orden, List<dynamic> masas, List<dynamic> mercancia, String tituloViaje, bool isDarkMode) {
    double lat = double.tryParse(orden['latitud']?.toString() ?? '19.4') ?? 19.4;
    double lng = double.tryParse(orden['longitud']?.toString() ?? '-99.1') ?? -99.1;
    LatLng destino = LatLng(lat, lng);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDarkMode ? Colors.grey[900] : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.85, 
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(child: Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10)))),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tituloViaje, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange[700])),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.person, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Para: ${orden['cliente'] ?? 'Sin nombre'}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 16))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.store, color: isDarkMode ? Colors.green[300] : Colors.green[700], size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Local: ${orden['local'] ?? 'No especificado'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black, fontSize: 15))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text('Ubicación: ${orden['direccion'] ?? 'No especificada'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black, fontSize: 15))),
                        ],
                      ),
                      Divider(height: 20, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black),
                      
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (masas.isNotEmpty)
                            Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: masas.map((m) => Text("${m['nombre_producto'] ?? 'Masa'}: ${m['cantidad']} Kl.", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black))).toList())),
                          if (masas.isNotEmpty && mercancia.isNotEmpty)
                            const Padding(padding: EdgeInsets.symmetric(horizontal: 12.0), child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold))),
                          if (mercancia.isNotEmpty)
                            Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: mercancia.map((m) => Text("${m['nombre_producto'] ?? 'Producto'}: ${m['cantidad']} U.", style: const TextStyle(fontSize: 14, color: Colors.grey))).toList())),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ]
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                    child: GoogleMap(
                      initialCameraPosition: CameraPosition(target: destino, zoom: 16),
                      markers: { Marker(markerId: const MarkerId('destino'), position: destino, icon: _iconoMoto ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),) },
                      myLocationEnabled: true,
                      myLocationButtonEnabled: true,
                      zoomControlsEnabled: false,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _mostrarDetalleSinMapa(Map<String, dynamic> orden, List<dynamic> masas, List<dynamic> mercancia, String tituloViaje, bool isDarkMode, double cambio) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDarkMode ? Colors.grey[900] : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 20, left: 20, right: 20, top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(child: Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10)))),
              const SizedBox(height: 20),
              
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(tituloViaje, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange[700]))),
                ],
              ),
              const SizedBox(height: 12),
              
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.receipt_long, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Estado: ${orden['estado']}', style: TextStyle(color: isDarkMode ? Colors.cyanAccent : Colors.blue[800], fontWeight: FontWeight.bold, fontSize: 15))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.person, color: isDarkMode ? Colors.grey[400] : Colors.grey[600], size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Para: ${orden['cliente'] ?? 'Sin nombre'}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 16))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Local: ${orden['local'] ?? orden['direccion'] ?? 'No especificado'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black, fontSize: 15))),
                ],
              ),
              Divider(height: 30, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black),
              
              if (masas.isNotEmpty) ...[
                const Text("Masas:", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange, fontSize: 16)),
                const SizedBox(height: 8),
                ...masas.map((m) => Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: Text("${m['nombre_producto']}", style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontSize: 16))),
                      Text("${m['cantidad']} Kl.", style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
                    ]
                  ),
                )).toList(),
                const SizedBox(height: 12),
              ],

              if (mercancia.isNotEmpty) ...[
                const Text("Productos:", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent, fontSize: 16)),
                const SizedBox(height: 8),
                ...mercancia.map((m) => Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(child: Text("${m['nombre_producto']}", style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontSize: 14))),
                      Text("${m['cantidad']} U.", style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 14)),
                    ]
                  ),
                )).toList(),
              ],

              Divider(height: 30, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('TOTAL A COBRAR:', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('\$${orden['total']} MXN', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.green)),
                ],
              ),
              if (cambio > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text('⚠️ Lleva cambio para: \$$cambio MXN', style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 14))
                ),
            ],
          ),
        );
      },
    );
  }
}

// =========================================================
// 🚀 MAPA RUTA REPARTIDOR (CON RASTREO EN TIEMPO REAL)
// =========================================================
class MapaRutaRepartidorScreen extends StatefulWidget {
  final LatLng destino;
  final String cliente;
  final String direccion;
  final int? idOrden; // 🚀 NUEVO: ID DE LA ORDEN
  final bool rastrearCompanero; // 🚀 NUEVO: MODO PERSECUCIÓN

  const MapaRutaRepartidorScreen({
    super.key,
    required this.destino,
    required this.cliente,
    required this.direccion,
    this.idOrden,
    this.rastrearCompanero = false,
  });

  @override
  State<MapaRutaRepartidorScreen> createState() => _MapaRutaRepartidorScreenState();
}

class _MapaRutaRepartidorScreenState extends State<MapaRutaRepartidorScreen> {
  GoogleMapController? _mapController;
  Set<Marker> _marcadores = {};
  Set<Polyline> _rutas = {};
  bool _isLoading = true;
  LatLngBounds? _boundsRuta; 

  StreamSubscription<Position>? _positionStream; 
  Timer? _timerRuta; 
  IO.Socket? _socket; // 🚀 SOCKET PARA ESCUCHAR A LA OTRA MOTO
  LatLng? _destinoActual; // 🚀 EL MARCADOR AHORA ES DINÁMICO

  @override
  void initState() {
    super.initState();
    _destinoActual = widget.destino;
    
    _marcadores = {
      Marker(
        markerId: const MarkerId('destino'),
        position: _destinoActual!,
        infoWindow: InfoWindow(title: widget.cliente, snippet: widget.direccion),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed), 
      )
    };
    
    _obtenerUbicacionYRuta(silencioso: false);

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5)
    ).listen((Position pos) {
      if (mounted) {
        setState(() {
          _marcadores.removeWhere((m) => m.markerId.value == 'origen');
          _marcadores.add(Marker(
            markerId: const MarkerId('origen'),
            position: LatLng(pos.latitude, pos.longitude),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue), 
          ));
        });
      }
    });

    _timerRuta = Timer.periodic(const Duration(seconds: 30), (timer) {
      _obtenerUbicacionYRuta(silencioso: true);
    });

    // 🚀 MAGIA: CONECTAMOS EL SOCKET PARA VER MOVERSE A LA OTRA MOTO
    if (widget.rastrearCompanero && widget.idOrden != null) {
      _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });
      
      _socket!.on('ubicacion_repartidor', (data) {
        final safeData = parseSocketData(data);
        if (safeData['id_orden'] != null && safeData['lat'] != null && safeData['lng'] != null) {
          int idO = int.tryParse(safeData['id_orden'].toString()) ?? 0;
          
          if (idO == widget.idOrden) {
            double lat = double.tryParse(safeData['lat'].toString()) ?? 0;
            double lng = double.tryParse(safeData['lng'].toString()) ?? 0;
            
            if (lat != 0 && lng != 0 && mounted) {
              setState(() {
                _destinoActual = LatLng(lat, lng);
                _marcadores.removeWhere((m) => m.markerId.value == 'destino');
                _marcadores.add(Marker(
                  markerId: const MarkerId('destino'),
                  position: _destinoActual!,
                  infoWindow: InfoWindow(title: widget.cliente, snippet: 'Ubicación en tiempo real'),
                  icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
                ));
              });
            }
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _positionStream?.cancel(); 
    _timerRuta?.cancel(); 
    _socket?.disconnect(); // 🚀 APAGAMOS EL SOCKET AL SALIR
    _mapController?.dispose();
    super.dispose();
  }

  List<LatLng> _decodificarRuta(String encoded) {
    List<LatLng> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do { b = encoded.codeUnitAt(index++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); lat += dlat;
      shift = 0; result = 0;
      do { b = encoded.codeUnitAt(index++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)); lng += dlng;
      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  Future<void> _obtenerUbicacionYRuta({bool silencioso = false}) async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) { if (mounted && !silencioso) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Activa el GPS por favor.'))); return; }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;
      }

      // 🚀 SALVAVIDAS: SI EL GPS TARDA MÁS DE 10 SEGUNDOS, USA EL ÚLTIMO CONOCIDO PARA NO TRABARSE
      Position posActual;
      try {
        posActual = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 10)
        );
      } catch (e) {
        Position? last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          posActual = last;
        } else {
          if (mounted && !silencioso) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo ubicar el GPS.')));
          if (mounted && !silencioso) setState(() => _isLoading = false);
          return;
        }
      }

      LatLng origen = LatLng(posActual.latitude, posActual.longitude);

      if (mounted) {
        setState(() {
          _marcadores.removeWhere((m) => m.markerId.value == 'origen');
          _marcadores.add(Marker(markerId: const MarkerId('origen'), position: origen, icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue)));
        });
      }

      final Map<String, dynamic> body = {
        "origin": {"location": {"latLng": {"latitude": origen.latitude, "longitude": origen.longitude}}},
        "destination": {"location": {"latLng": {"latitude": _destinoActual!.latitude, "longitude": _destinoActual!.longitude}}}, // 🚀 APUNTAMOS AL DESTINO DINÁMICO
        "travelMode": "DRIVE"
      };

      final response = await http.post(
        Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'), 
        headers: {'Content-Type': 'application/json', 'X-Goog-Api-Key': kGoogleApiKey, 'X-Goog-FieldMask': 'routes.polyline.encodedPolyline'}, 
        body: jsonEncode(body)
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          List<LatLng> puntosRuta = _decodificarRuta(data['routes'][0]['polyline']['encodedPolyline']);
          double minLat = origen.latitude, maxLat = origen.latitude, minLng = origen.longitude, maxLng = origen.longitude;
          for (LatLng p in puntosRuta) {
            if (p.latitude < minLat) minLat = p.latitude; if (p.latitude > maxLat) maxLat = p.latitude;
            if (p.longitude < minLng) minLng = p.longitude; if (p.longitude > maxLng) maxLng = p.longitude;
          }
          if (mounted) {
            setState(() {
              _rutas = {Polyline(polylineId: const PolylineId('ruta_companero'), color: Colors.blueAccent, width: 6, points: puntosRuta)};
              _boundsRuta = LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
            });
            if (silencioso && _mapController != null && _boundsRuta != null) {
              _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_boundsRuta!, 60.0));
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Error obteniendo ruta: $e");
    } finally {
      if (mounted && !silencioso) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.rastrearCompanero ? 'Ruta al Compañero' : 'Ruta al Destino', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), centerTitle: true, backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
      body: _isLoading
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(), SizedBox(height: 16), Text("Trazando ruta...")]))
          : Stack(
              children: [
                GoogleMap(
                  onMapCreated: (controller) {
                    _mapController = controller;
                    if (_boundsRuta != null) Future.delayed(const Duration(milliseconds: 300), () => _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_boundsRuta!, 60.0)));
                  },
                  initialCameraPosition: CameraPosition(target: _destinoActual!, zoom: 15),
                  markers: _marcadores, polylines: _rutas, myLocationEnabled: true, myLocationButtonEnabled: true,
                ),
                Positioned(bottom: 20, left: 16, right: 16, child: Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Dirígete hacia: ${widget.cliente}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black)), const SizedBox(height: 4), Text(widget.rastrearCompanero ? "Pídele el código cuando llegues." : "Ubicación del cliente", style: const TextStyle(color: Colors.black54, fontSize: 14))]))),
              ],
            ),
    );
  }
}