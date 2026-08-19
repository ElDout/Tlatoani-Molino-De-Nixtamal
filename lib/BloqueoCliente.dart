import 'dart:async';
import 'dart:convert';
import 'dart:typed_data'; // Añadido para manejar los bytes de la imagen
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';
import 'package:molino_app/Clientes.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// 🚀 CLAVE DE GOOGLE MAPS
const String kGoogleApiKey = "AIzaSyCY5cOcVAzNpNfR_uSoOpC245m6fAtqdoU";

class BloqueoClienteScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final Map<String, dynamic> ordenInicial; 
  
  const BloqueoClienteScreen({
    super.key, 
    required this.onThemeChanged,
    required this.ordenInicial,
  });

  @override
  State<BloqueoClienteScreen> createState() => _BloqueoClienteScreenState();
}

class _BloqueoClienteScreenState extends State<BloqueoClienteScreen> {
  Map<String, dynamic>? _ordenActual;
  IO.Socket? _socket;
  bool _isLoading = false; 

  GoogleMapController? _mapController;
  LatLng? _ubicacionRepartidor;
  LatLng? _destinoCliente;

  // 🚀 VARIABLES PARA LA RUTA, EL TIEMPO Y EL RECENTRADO
  Set<Polyline> _rutas = {};
  Set<Marker> _marcadores = {};
  String _tiempoEstimado = "";
  bool _trazandoRuta = false;
  DateTime? _ultimaVezRuta;
  LatLngBounds? _boundsActuales; // Guarda el encuadre perfecto del mapa
  BitmapDescriptor? _iconoMoto;

  // 🚀 VARIABLES PRE-DECODIFICADAS PARA OPTIMIZAR MEMORIA
  Uint8List? _fotoRepartidorBytes;
  List<dynamic> _masas = [];
  List<dynamic> _mercancia = [];

  @override
  void initState() {
    super.initState();
    _ordenActual = widget.ordenInicial;
    _prepararDatosOrden(); // 🔥 Decodificamos todo antes de dibujar la pantalla
    _cargarIconoMoto();
    
    // Extraemos la ubicación del cliente para el mapa
    _prepararMapa();
    _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'forceNew': true, 
    });

    _socket!.onConnect((_) {
      debugPrint("🟢 SOCKET CLIENTE CONECTADO AL SERVER");
    });

    _socket!.on('actualizacion_ordenes', (_) {
      if (mounted) {
        _revisarEstadoOrdenSilencioso();
      }
    });

    // 🚀 AQUI ESCUCHAMOS EL GPS DEL REPARTIDOR EN TIEMPO REAL
    _socket!.on('ubicacion_repartidor', (data) {
      if (!mounted) return;

      if (data != null && data['id_orden'] != null && data['lat'] != null && data['lng'] != null) {
        if (data['id_orden'].toString() == _ordenActual!['id'].toString()) {
          
          final double? lat = double.tryParse(data['lat'].toString());
          final double? lng = double.tryParse(data['lng'].toString());

          if (lat == null || lng == null) return;
          LatLng nuevaPos = LatLng(lat, lng);

          // 🚀 ACTUALIZAMOS LA VARIABLE Y EL MARCADOR DE GOLPE
          setState(() {
            _ubicacionRepartidor = nuevaPos;
            _marcadores.removeWhere((m) => m.markerId.value == 'repartidor');
            _marcadores.add(Marker(
              markerId: const MarkerId('repartidor'),
              position: nuevaPos,
              icon: _iconoMoto ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
              infoWindow: const InfoWindow(title: "Repartidor"),
            ));
          });
          
          if (_ultimaVezRuta == null || DateTime.now().difference(_ultimaVezRuta!).inSeconds >= 15) { // 🚀 Bajado a 15 seg para que sea rápido como en admin
            _trazarRutaYCalcularTiempo();
            _ultimaVezRuta = DateTime.now();
          } else {
            if (_boundsActuales == null && _ubicacionRepartidor != null) {
              _mapController?.animateCamera(CameraUpdate.newLatLng(_ubicacionRepartidor!));
            }
          }
        }
      }
    });

    _socket!.on('notify_mercancia_modificada', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      
      if (data['id_cliente'] == miId && data['id_orden'].toString() == _ordenActual!['id'].toString() && mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('⚠️ Pedido Modificado', style: TextStyle(fontWeight: FontWeight.bold)),
            content: Text('El repartidor reportó mercancía faltante en el local. Se han ajustado los productos de tu orden.\n\nNuevo total: \$${data['nuevo_total']} MXN.'),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853)),
                onPressed: () => Navigator.pop(ctx), 
                child: const Text('Entendido', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))
              )
            ],
          )
        );
      }
    });
  }
  // 🚀 NUEVA FUNCIÓN PARA CENTRALIZAR EL MAPA COMO EN ADMIN
  void _prepararMapa() {
    if (_ordenActual == null) return;

    double lat = double.tryParse(_ordenActual!['lat_custom']?.toString() ?? _ordenActual!['latitud']?.toString() ?? '19.4') ?? 19.4;
    double lng = double.tryParse(_ordenActual!['lng_custom']?.toString() ?? _ordenActual!['longitud']?.toString() ?? '-99.1') ?? -99.1;
    _destinoCliente = LatLng(lat, lng);

    _marcadores.removeWhere((m) => m.markerId.value == 'destino');
    _marcadores.add(Marker(
      markerId: const MarkerId('destino'),
      position: _destinoCliente!,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      infoWindow: const InfoWindow(title: "Destino"),
    ));

    // Si ya tenemos la ubicación del repartidor, lo pintamos también
    if (_ubicacionRepartidor != null) {
      _marcadores.removeWhere((m) => m.markerId.value == 'repartidor');
      _marcadores.add(Marker(
        markerId: const MarkerId('repartidor'),
        position: _ubicacionRepartidor!,
        icon: _iconoMoto ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        infoWindow: const InfoWindow(title: "Repartidor"),
      ));
    }
  }

  Future<void> _cargarIconoMoto() async {
    _iconoMoto = await BitmapDescriptor.fromAssetImage(
      const ImageConfiguration(size: Size(48, 48)),
      'assets/moto_icon.png', 
    );
    if (mounted) {
      setState(() {
        _prepararMapa(); // 🚀 ACTUALIZA EL MARCADOR PARA PONER LA MOTO
      });
    }
  }

  // 🚀 FUNCIÓN CLAVE PARA EVITAR DECODIFICAR EN BUCLE
  void _prepararDatosOrden() {
    if (_ordenActual == null) return;

    // 1. Decodificar la imagen del repartidor una sola vez
    final String? fotoBase64 = _ordenActual!['foto_repartidor'];
    if (fotoBase64 != null && fotoBase64.isNotEmpty) {
      try {
        _fotoRepartidorBytes = base64Decode(fotoBase64.replaceAll(RegExp(r'\s+'), ''));
      } catch (e) {
        _fotoRepartidorBytes = null;
      }
    }

    // 2. Decodificar productos y separar masas/mercancía una sola vez
    final dynamic prodsRaw = _ordenActual!['productos'];
    final List<dynamic> productos = prodsRaw is String ? jsonDecode(prodsRaw) : List.from(prodsRaw ?? []);
    
    _masas.clear();
    _mercancia.clear();
    
    for (var p in productos) {
      bool esMasa = p['detalle']?.toString().toLowerCase().contains('kilo') == true || p['detalle']?.toString().toLowerCase().contains('gramo') == true;
      if (esMasa) _masas.add(p);
      else _mercancia.add(p);
    }
  }

  @override
  void dispose() { 
    _socket?.disconnect();
    _mapController?.dispose(); // 🔥 Matamos el mapa de memoria
    super.dispose(); 
  }

  // 🚀 FUNCIÓN PARA DECODIFICAR LA LÍNEA AZUL DE GOOGLE MAPS
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

  // 🚀 FUNCIÓN QUE PIDE LA RUTA Y EL TIEMPO AL SERVIDOR DE GOOGLE
  Future<void> _trazarRutaYCalcularTiempo() async {
    if (_ubicacionRepartidor == null || _destinoCliente == null || _trazandoRuta) return;
    _trazandoRuta = true;
    
    try {
      final Map<String, dynamic> body = {
        "origin": {"location": {"latLng": {"latitude": _ubicacionRepartidor!.latitude, "longitude": _ubicacionRepartidor!.longitude}}},
        "destination": {"location": {"latLng": {"latitude": _destinoCliente!.latitude, "longitude": _destinoCliente!.longitude}}},
        "travelMode": "DRIVE"
      };

      final response = await http.post(
        Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
        headers: {'Content-Type': 'application/json', 'X-Goog-Api-Key': kGoogleApiKey, 'X-Goog-FieldMask': 'routes.polyline.encodedPolyline,routes.duration'},
        body: jsonEncode(body)
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          List<LatLng> puntosRuta = _decodificarRuta(route['polyline']['encodedPolyline']);
          
          String duracionStr = route['duration'] ?? ""; 
          int segundos = int.tryParse(duracionStr.replaceAll('s', '')) ?? 0;
          int minutos = (segundos / 60).ceil();

          double minLat = _ubicacionRepartidor!.latitude;
          double maxLat = _ubicacionRepartidor!.latitude;
          double minLng = _ubicacionRepartidor!.longitude;
          double maxLng = _ubicacionRepartidor!.longitude;
          for (LatLng p in puntosRuta) {
            if (p.latitude < minLat) minLat = p.latitude; if (p.latitude > maxLat) maxLat = p.latitude;
            if (p.longitude < minLng) minLng = p.longitude; if (p.longitude > maxLng) maxLng = p.longitude;
          }

          if (mounted) {
            setState(() {
              _rutas = {Polyline(polylineId: const PolylineId('ruta_moto'), color: Colors.blueAccent, width: 6, points: puntosRuta)};
              _tiempoEstimado = minutos > 0 ? "$minutos min" : "Llegando...";
              _boundsActuales = LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
            });
            
            // Hacemos el zoom perfecto
            _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_boundsActuales!, 60.0));
          }
        }
      }
    } catch (e) {
      debugPrint("❌ Error trazando ruta de Google Maps: $e");
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error Google Maps: $e'), backgroundColor: Colors.red));
      }
    } finally {
      _trazandoRuta = false;
    }
  }

  // 🚀 FUNCIÓN PARA EL BOTÓN DE RECENTRAR MAPA
  void _centrarMapa() {
    if (_mapController == null) return;
    if (_boundsActuales != null) {
      // Si ya trazó la ruta, ajustamos el encuadre para ver a la moto y la casa
      _mapController!.animateCamera(CameraUpdate.newLatLngBounds(_boundsActuales!, 60.0));
    } else if (_ubicacionRepartidor != null) {
      // Si solo tenemos a la moto, lo seguimos a él
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_ubicacionRepartidor!, 15));
    } else if (_destinoCliente != null) {
      // Si nada más tenemos la casa, vamos a la casa
      _mapController!.animateCamera(CameraUpdate.newLatLngZoom(_destinoCliente!, 15));
    }
  }

  Future<void> _revisarEstadoOrdenSilencioso() async {
    try {
      final int idOrden = _ordenActual!['id'];

      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/$idOrden'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final ordenServer = data['orden'];
          
          if (ordenServer['estado'] == 'Completada') {
            _socket?.disconnect();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('✅ ¡Tu pedido ha sido completado!', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)), backgroundColor: Colors.green)
              );
              Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => ClientesScreen(onThemeChanged: widget.onThemeChanged)), (route) => false);
            }
          } else {
            if (mounted) {
              setState(() { 
                _ordenActual = ordenServer; 
                _prepararDatosOrden(); // 🔥 Si cambia la orden, volvemos a preparar variables limpias
                _prepararMapa();

                // 🚀 AQUÍ FORZAMOS A QUE EL MAPA AGARRE LAS COORDENADAS FRESCAS Y SE VAYA A PACHUCA
                double lat = double.tryParse(_ordenActual!['lat_custom']?.toString() ?? _ordenActual!['latitud']?.toString() ?? '0') ?? 0;
                double lng = double.tryParse(_ordenActual!['lng_custom']?.toString() ?? _ordenActual!['longitud']?.toString() ?? '0') ?? 0;
                if (lat != 0 && lng != 0) {
                  _destinoCliente = LatLng(lat, lng);
                }
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error revisando orden: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDarkMode ? const Color(0xFF2A2A2A) : const Color(0xFF003B99);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => ClientesScreen(onThemeChanged: widget.onThemeChanged)),
              (route) => false,
            );
          },
        ),
        actions: [
          PopupMenuButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Modo Oscuro'),
                    Switch(value: isDarkMode, onChanged: (value) {
                      widget.onThemeChanged(value ? ThemeMode.dark : ThemeMode.light);
                      Navigator.pop(context);
                    }),
                  ],
                ),
              ),
            ],
          )
        ],
      ),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _construirPantallaEstadoNormal(), 
    );
  }

  Widget _construirPantallaEstadoNormal() {
    final String estado = _ordenActual!['estado'];
    final bool repartidorAsignado = (estado == 'Asignado' || estado == 'En Camino' || estado == 'Pendiente' && _ordenActual!['id_repartidor'] != null);
    
    // 🚀 OBTENEMOS LAS COORDENADAS DIRECTO DE LA ORDEN ACTUALIZADA
    double lat = double.tryParse(_ordenActual!['lat_custom']?.toString() ?? _ordenActual!['latitud']?.toString() ?? '19.4') ?? 19.4;
    double lng = double.tryParse(_ordenActual!['lng_custom']?.toString() ?? _ordenActual!['longitud']?.toString() ?? '-99.1') ?? -99.1;
    LatLng destinoCliente = LatLng(lat, lng);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!repartidorAsignado) ...[
            const SizedBox(height: 20),
            const Text('Esperando asignar repartidor...', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
          ] else ...[
            Row(
              children: [
                Container(
                  width: 60, height: 60, 
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)), 
                  clipBehavior: Clip.hardEdge, 
                  child: _fotoRepartidorBytes != null // 🔥 Usamos la variable optimizada
                    ? Image.memory(
                        _fotoRepartidorBytes!, 
                        fit: BoxFit.cover,
                        cacheWidth: 150, // 🔥 Ahorra RAM
                        errorBuilder: (c,e,s) => const Icon(Icons.motorcycle, color: Colors.white, size: 40)
                      ) 
                    : const Icon(Icons.motorcycle, color: Colors.white, size: 40)
                ),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Repartidor:\n${_ordenActual!['nombre_repartidor'] ?? 'No disponible'}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)), 
                  const SizedBox(height: 4), 
                  Text('Teléfono:\n${_ordenActual!['tel_repartidor'] ?? 'No disponible'}', style: const TextStyle(color: Colors.white70, fontSize: 12))
                ])),
                if (estado == 'En Camino')
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: Colors.orangeAccent, borderRadius: BorderRadius.circular(20)),
                        child: const Text('En Camino', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                      // 🚀 PINTAMOS EL TIEMPO ESTIMADO SI YA SE CALCULÓ
                      if (_tiempoEstimado.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6.0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(12)),
                            child: Text('⏱ $_tiempoEstimado', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                          ),
                        ),
                    ],
                  )
              ],
            ),
            const SizedBox(height: 24),
          ],
          
          Text(_ordenActual!['viaje_programado'] ?? 'Viaje', textAlign: TextAlign.center, style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 16),
          
          // 🚀 RENDERIZADO DE MASAS (Usando la lista optimizada)
          if (_masas.isNotEmpty) ...[
            const Text("Masas:", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            ..._masas.map((prod) => Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  const Icon(Icons.circle, color: Colors.orangeAccent, size: 10),
                  const SizedBox(width: 8),
                  Expanded(child: Text(prod['nombre_producto'], style: const TextStyle(color: Colors.white, fontSize: 14))),
                  Text('${prod['cantidad']} Kl.', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
            )).toList(),
            const SizedBox(height: 12),
          ],

          // 🚀 RENDERIZADO DE PRODUCTOS (Usando la lista optimizada)
          if (_mercancia.isNotEmpty) ...[
            const Text("Productos:", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            ..._mercancia.map((prod) => Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  const Icon(Icons.circle, color: Colors.blueAccent, size: 10),
                  const SizedBox(width: 8),
                  Expanded(child: Text(prod['nombre_producto'], style: const TextStyle(color: Colors.white70, fontSize: 14))),
                  Text('${prod['cantidad']} U.', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
            )).toList(),
            const SizedBox(height: 16),
          ],

          // 🚀 MAPA DE UBICACIÓN EN TIEMPO REAL CON BOTÓN DE RECENTRAR
          if (repartidorAsignado)
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24, width: 2),
                ),
                clipBehavior: Clip.hardEdge,
                child: Stack(
                  children: [
                    GoogleMap(
                      onMapCreated: (controller) => _mapController = controller,
                      initialCameraPosition: CameraPosition(
                        target: _ubicacionRepartidor ?? destinoCliente,
                        zoom: 15,
                      ),
                      myLocationEnabled: false,
                      zoomControlsEnabled: false,
                      polylines: _rutas, // 🚀 AQUI PINTAMOS LA RUTA AZUL DE GOOGLE
                      markers: _marcadores, // 🚀 AHORA EL MAPA ESCUCHA A LA VARIABLE DE ESTADO DIRECTAMENTE
                    ),
                    
                    // 🚀 BOTÓN DE RECENTRAR FLOTANDO SOBRE EL MAPA
                    Positioned(
                      bottom: 16,
                      right: 16,
                      child: FloatingActionButton(
                        mini: true,
                        backgroundColor: Colors.white,
                        onPressed: _centrarMapa,
                        child: const Icon(Icons.my_location, color: Colors.blueAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
          if (repartidorAsignado) ...[
            const SizedBox(height: 16),
            const Text('CÓDIGO DE ENTREGA', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
            Text('${_ordenActual!['codigo_entrega']}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 36, letterSpacing: 4, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}