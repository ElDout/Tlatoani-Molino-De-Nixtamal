import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';
import 'package:molino_app/BloqueoRepartidor.dart'; 
import 'package:molino_app/PerfilScreen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:molino_app/NotificacionesHelper.dart';
import 'package:geolocator/geolocator.dart'; 

class RepartidoresScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final int initialTab; 
  const RepartidoresScreen({super.key, required this.onThemeChanged, this.initialTab = 0});  

  @override
  State<RepartidoresScreen> createState() => _RepartidoresScreenState();
}

class _RepartidoresScreenState extends State<RepartidoresScreen> {
  String _nombreRepartidor = "Cargando...";
  String? _imagenBase64;
  
  int _tabIndex = 0; 
  
  List<dynamic> _ordenesPendientes = [];
  List<dynamic> _ordenesCompletadas = [];
  List<dynamic> _repartidoresEnProceso = [];
  
  bool _isLoading = true;
  bool _isNavigating = false;
  IO.Socket? _socket;
  
  Set<int> _pedidosSeleccionadosPendientes = {}; 
  Set<int> _pedidosSeleccionadosCompartir = {}; 
  int? _idRepartidorDestinoCompartir; 
  Set<int> _pedidosEnEspera = {}; 

  int _fetchCounter = 0;

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.initialTab;
    _cargarDatosUsuario();
    
    _revisarAsignacionAutomatica().then((_) {
      if (mounted && !_isNavigating) {
        _obtenerDatosDePestana();
      }
    });
    
    _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'forceNew': true,
    });

    _socket!.on('actualizacion_ordenes', (data) async {
      debugPrint("🚀 SOCKET: actualizacion_ordenes");
      if (_isNavigating || !mounted) return; 
      await _revisarAsignacionAutomatica();
      if (mounted && !_isNavigating) {
        await _obtenerDatosDePestana(silencioso: true);
      }
    });

    _socket!.on('compartir_aceptado', (data) async {
      if (data == null || _isNavigating) return;
      try {
        Map<String, dynamic> safeData;
        if (data is String) {
          safeData = jsonDecode(data);
        } else if (data is List) {
          if (data.isEmpty) return;
          safeData = Map<String, dynamic>.from(data[0]);
        } else {
          safeData = Map<String, dynamic>.from(data);
        }

        final prefs = await SharedPreferences.getInstance();
        final miId = _obtenerIdSeguro(prefs);

        if (miId != null && safeData['id_repartidor_destino']?.toString() == miId.toString()) {
          if (mounted && !_isNavigating) {
            _isNavigating = true;
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => BloqueoRepartidorScreen(onThemeChanged: widget.onThemeChanged),
              ),
            );
          }
        }
      } catch (e) {
        debugPrint("❌ Error procesando compartir_aceptado: $e");
      }
    });

    _socket!.on('compartir_rechazado', (data) async {
      if (data == null) return;
      try {
        Map<String, dynamic> safeData;
        if (data is String) {
          safeData = jsonDecode(data);
        } else if (data is List) {
          if (data.isEmpty) return;
          safeData = Map<String, dynamic>.from(data[0]);
        } else {
          safeData = Map<String, dynamic>.from(data);
        }

        final prefs = await SharedPreferences.getInstance();
        final miId = _obtenerIdSeguro(prefs);

        if (miId != null && safeData['id_repartidor_destino']?.toString() == miId.toString() && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('❌ El compañero denegó tu solicitud de transferencia.', style: TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: Colors.red
          ));
          setState(() {
            List<dynamic> rechazadas = safeData['ids_ordenes'] ?? safeData['ordenes'] ?? [];
            for(var oId in rechazadas) {
              _pedidosEnEspera.remove(int.tryParse(oId.toString()) ?? 0); 
            }
          });
        }
      } catch (e) {
        debugPrint("❌ Error procesando compartir_rechazado: $e");
      }
    });

    _socket!.on('notify_nuevo_pedido', (data) {
      if (mounted) {
        NotificacionesHelper.mostrarNotificacion(
          titulo: 'Nuevo Pedido 📦',
          cuerpo: 'El usuario ${data['cliente']} acaba de hacer un pedido.',
          payload: {'tipo': 'admin_pedido', 'id_orden': data['id_orden']}
        );
        _obtenerDatosDePestana(silencioso: true);
      }
    });

    _socket!.on('notify_pedido_asignado', (data) async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt('userId') == data['id_repartidor'] && mounted) {
        NotificacionesHelper.mostrarNotificacion(
          titulo: '¡Nuevo Encargo! 🛵',
          cuerpo: 'Se te ha asignado un nuevo pedido para recoger.',
          payload: {'tipo': 'repartidor_asignado'}
        );
      }
    });
  }

  @override
  void dispose() {
    _socket?.disconnect();
    super.dispose();
  }

  Future<void> _cargarDatosUsuario() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _nombreRepartidor = prefs.getString('userUser') ?? prefs.getString('userName') ?? 'Repartidor';
      _imagenBase64 = prefs.getString('userImage'); 
    });
  }

  int _obtenerMinutos(String? viaje) {
    if (viaje == null || viaje.isEmpty) return 0; 
    if (viaje.startsWith('Prog:')) return 9999; 

    RegExp regExp = RegExp(r'(\d{1,2}):(\d{2})\s*(AM|PM)', caseSensitive: false);
    Match? match = regExp.firstMatch(viaje);

    if (match != null) {
      int hour = int.parse(match.group(1)!);
      int minute = int.parse(match.group(2)!);
      String ampm = match.group(3)!.toUpperCase();

      if (ampm == 'PM' && hour < 12) hour += 12;
      if (ampm == 'AM' && hour == 12) hour = 0;

      return hour * 60 + minute;
    }

    return 0; 
  }

  int? _obtenerIdSeguro(SharedPreferences prefs) {
    int? id = prefs.getInt('userId');
    if (id == null) {
      String? idStr = prefs.getString('userId');
      if (idStr != null) id = int.tryParse(idStr);
    }
    return id;
  }

  Future<void> _revisarAsignacionAutomatica() async {
    if (_isNavigating) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? myId = _obtenerIdSeguro(prefs);
      if (myId == null) return;
      
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/activa/repartidor/$myId')).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['ordenes'] != null) { 
          _isNavigating = true;
          if (!mounted) return;
          Navigator.pushReplacement(
            context, 
            MaterialPageRoute(builder: (context) => BloqueoRepartidorScreen(onThemeChanged: widget.onThemeChanged))
          );
        }
      }
    } catch (e) { debugPrint('Error: $e'); }
  }

  Future<void> _obtenerDatosDePestana({bool silencioso = false}) async {
    if (!silencioso && mounted) setState(() => _isLoading = true);
    final int currentFetch = ++_fetchCounter; 
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? myId = _obtenerIdSeguro(prefs);
      
      if (_tabIndex == 0) {
        final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/pendientes'));
        if (res.statusCode == 200 && mounted && currentFetch == _fetchCounter) {
          List<dynamic> ordenesData = jsonDecode(res.body);
          
          ordenesData.sort((a, b) {
            int timeA = _obtenerMinutos(a['viaje_programado']?.toString());
            int timeB = _obtenerMinutos(b['viaje_programado']?.toString());
            return timeA.compareTo(timeB);
          });

          setState(() { 
            _ordenesPendientes = ordenesData; 
            _pedidosSeleccionadosPendientes.removeWhere((id) => !_ordenesPendientes.any((o) => o['id'] == id));
          });
        }
      } else if (_tabIndex == 1) {
        final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/en-proceso/repartidores'));
        if (res.statusCode == 200 && mounted && currentFetch == _fetchCounter) {
          List<dynamic> rows = jsonDecode(res.body);
          Map<int, Map<String, dynamic>> agrupados = {};
          
          for (var row in rows) {
            int idRep = row['id_repartidor'];
            if (idRep == myId) continue; 
            
            if (!agrupados.containsKey(idRep)) {
              agrupados[idRep] = {
                'id_repartidor': idRep,
                'nombre': row['nombre_repartidor'],
                'foto': row['foto_repartidor'],
                'ordenes': []
              };
            }
            agrupados[idRep]!['ordenes'].add(row);
          }

          for (var rep in agrupados.values) {
            (rep['ordenes'] as List).sort((a, b) {
              int timeA = _obtenerMinutos(a['viaje_programado']?.toString());
              int timeB = _obtenerMinutos(b['viaje_programado']?.toString());
              return timeA.compareTo(timeB);
            });
          }

          setState(() { 
            _repartidoresEnProceso = agrupados.values.toList(); 
            if (_idRepartidorDestinoCompartir != null) {
              final rep = agrupados[_idRepartidorDestinoCompartir];
              if (rep == null) {
                _pedidosSeleccionadosCompartir.clear();
                _idRepartidorDestinoCompartir = null;
              } else {
                List<dynamic> ords = rep['ordenes'];
                _pedidosSeleccionadosCompartir.removeWhere((id) => !ords.any((o) => o['id_orden'] == id));
                if (_pedidosSeleccionadosCompartir.isEmpty) _idRepartidorDestinoCompartir = null;
              }
            }
          });
        }
      } else if (_tabIndex == 2) {
        final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/completadas/repartidor/$myId'));
        if (res.statusCode == 200 && mounted && currentFetch == _fetchCounter) {
          setState(() => _ordenesCompletadas = jsonDecode(res.body));
        }
      }
    } catch (e) {
      debugPrint('Error obteniendo órdenes: $e');
    } finally {
      if (mounted && !silencioso && currentFetch == _fetchCounter) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _solicitarCompartir() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? miId = _obtenerIdSeguro(prefs);
      
      List<Map<String, dynamic>> productosLimpios = []; // 🚀 AQUÍ SALVAMOS LA MEMORIA
      List<String> nombresClientes = [];
      
      final rep = _repartidoresEnProceso.firstWhere(
        (r) => r['id_repartidor'] == _idRepartidorDestinoCompartir, 
        orElse: () => null
      );

      if (rep != null) {
        List<dynamic> ords = rep['ordenes'];
        for (var o in ords) {
          int idOrdenActual = o['id_orden'] ?? o['id'];
          if (_pedidosSeleccionadosCompartir.contains(idOrdenActual)) {
            if (o['cliente'] != null) nombresClientes.add(o['cliente'].toString());
            if (o['productos'] != null) {
              List<dynamic> prods = o['productos'] is String ? jsonDecode(o['productos']) : List.from(o['productos']);
              // 🚀 LIMPIAMOS LAS IMÁGENES BASE64 PARA EVITAR QUE COLAPSE FIREBASE Y EL SOCKET
              for (var p in prods) {
                productosLimpios.add({
                  'nombre_producto': p['nombre_producto'] ?? p['nombre'],
                  'cantidad': p['cantidad'],
                  'detalle': p['detalle']
                });
              }
            }
          }
        }
      }

      final payload = {
        'id_repartidor_origen': _idRepartidorDestinoCompartir, 
        'id_repartidor_destino': miId, 
        'nombre_destino': _nombreRepartidor,
        'ordenes': _pedidosSeleccionadosCompartir.toList(),
        'cliente_nombre': nombresClientes.isNotEmpty ? nombresClientes.join(', ') : 'Varios clientes',
        'productos': productosLimpios // 🚀 AHORA SÍ, UNA LISTA LIGERITA
      };

      await http.post(
        Uri.parse('${AppConfig.apiHost}/ordenes/solicitar-compartir'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload)
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('⏳ Solicitud enviada. Esperando a que el compañero acepte...'),
          backgroundColor: Colors.blueAccent,
        ));
      }
    } catch (e) {
      debugPrint("Error al solicitar: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _mostrarDialogoConfirmacion() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Confirmar Selección', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text('¿Estás seguro de aceptar ${_pedidosSeleccionadosPendientes.length} pedido(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _aceptarPedidosEnLote();
            },
            child: const Text('Sí, Aceptar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _aceptarPedidosEnLote() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idRepartidor = _obtenerIdSeguro(prefs);
      
      final response = await http.put(
        Uri.parse('${AppConfig.apiHost}/ordenes/aceptar-multiples'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'id_repartidor': idRepartidor,
          'ids_ordenes': _pedidosSeleccionadosPendientes.toList()
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          _isNavigating = true;
          if (!mounted) return;
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => BloqueoRepartidorScreen(onThemeChanged: widget.onThemeChanged)));
        } else {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error al aceptar pedidos', style: const TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.red));
          _obtenerDatosDePestana(); 
        }
      }
    } catch (e) { 
      debugPrint('Error al aceptar: $e'); 
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _toggleSeleccion(int ordenId, dynamic idRepartidor) {
    if (_tabIndex == 0) {
      setState(() {
        _pedidosSeleccionadosPendientes.contains(ordenId)
            ? _pedidosSeleccionadosPendientes.remove(ordenId)
            : _pedidosSeleccionadosPendientes.add(ordenId);
      });
    } else if (_tabIndex == 1) {
      int idDueno = idRepartidor;
      setState(() {
        if (_pedidosSeleccionadosCompartir.isEmpty) _idRepartidorDestinoCompartir = idDueno;
        
        if (_idRepartidorDestinoCompartir == idDueno) {
          _pedidosSeleccionadosCompartir.contains(ordenId)
              ? _pedidosSeleccionadosCompartir.remove(ordenId)
              : _pedidosSeleccionadosCompartir.add(ordenId);
          if (_pedidosSeleccionadosCompartir.isEmpty) _idRepartidorDestinoCompartir = null;
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Solo puedes seleccionar pedidos de un mismo repartidor a la vez.')));
        }
      });
    }
  }

  void _mostrarDetalleConMapa(Map<String, dynamic> orden, List<dynamic> masas, List<dynamic> mercancia, String tituloViaje, bool isDarkMode) {
    double lat = double.tryParse(orden['latitud']?.toString() ?? '0') ?? 0;
    double lng = double.tryParse(orden['longitud']?.toString() ?? '0') ?? 0;
    bool hasLocation = lat != 0 && lng != 0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return FractionallySizedBox(
          heightFactor: 0.85,
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10))),
                ),
                const SizedBox(height: 20),
                Text(tituloViaje, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange[700])),
                const SizedBox(height: 12),
                
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.person, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Para: ${orden['cliente'] ?? 'Sin nombre'}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.store, color: isDarkMode ? Colors.green[300] : Colors.green[700], size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Local: ${orden['local'] ?? 'No especificado'}', style: const TextStyle(fontSize: 15))),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Ubicación: ${orden['direccion'] ?? 'No especificada'}', style: const TextStyle(fontSize: 14))),
                  ],
                ),
                const Divider(height: 30),
                
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (masas.isNotEmpty)
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: masas.map((m) => Text(
                            "${m['nombre_producto']}: ${m['cantidad']} Kl.", 
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black)
                          )).toList(),
                        ),
                      ),
                    if (masas.isNotEmpty && mercancia.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12.0),
                        child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold)),
                      ),
                    if (mercancia.isNotEmpty)
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: mercancia.map((m) => Text(
                            "${m['nombre_producto']}: ${m['cantidad']} U.", 
                            style: const TextStyle(fontSize: 14, color: Colors.grey)
                          )).toList(),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: hasLocation 
                      ? GoogleMap(
                          initialCameraPosition: CameraPosition(target: LatLng(lat, lng), zoom: 16),
                          markers: {
                            Marker(
                              markerId: const MarkerId('entrega'),
                              position: LatLng(lat, lng),
                              infoWindow: InfoWindow(title: orden['cliente'], snippet: orden['local']),
                            )
                          },
                          myLocationEnabled: true,
                        )
                      : Container(
                          color: isDarkMode ? Colors.grey[800] : Colors.grey[200],
                          child: const Center(child: Text("Ubicación en mapa no disponible", style: TextStyle(color: Colors.grey))),
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

  Widget _construirTarjetaCompanero(Map<String, dynamic> orden, int idDueno, bool isDarkMode) {
    final List<dynamic> productos = orden['productos'] is String ? jsonDecode(orden['productos']) : List.from(orden['productos'] ?? []);
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _mostrarDetalleConMapa(orden, masas, mercancia, tituloViaje, isDarkMode),
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
                ],
              ),
            ),
          ),
          Divider(height: 1, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black87),
          Padding(
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
                        onPressed: () => _solicitarCompartirUna(orden['id_orden'] ?? orden['id'], idDueno, orden['cliente'], productos), 
                        child: const Text('Solicitar Compartir', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12), textAlign: TextAlign.center)
                      ),
                    ),
                  )
              ],
            ),
          ),
        ],
      ),
    );
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
        'nombre_destino': _nombreRepartidor, 
        'ordenes': [idOrden], 
        'cliente_nombre': cliente ?? 'Sin nombre', 
        'productos': prodsLimpios // 🚀 EVITAMOS EL CRASHEO DE FIREBASE Y EL SOCKET
      };

      await http.post(Uri.parse('${AppConfig.apiHost}/ordenes/solicitar-compartir'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));
      
      if (mounted) {
        setState(() { _pedidosEnEspera.add(idOrden); });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⏳ Solicitud enviada. Esperando a que el compañero acepte...'), backgroundColor: Colors.blueAccent));
      }
    } catch (e) { 
      debugPrint("Error: $e"); 
    } finally { 
      if (mounted) setState(() => _isLoading = false); 
    }
  }

  Widget _buildEstrellasReadOnly(String label, int rating, bool isDarkMode) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: isDarkMode ? Colors.white70 : Colors.black54)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(5, (index) {
            return Icon(
              index < rating ? Icons.star : Icons.star_border,
              color: Colors.amber,
              size: 20,
            );
          }),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: GestureDetector(
          onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (context) => PerfilScreen(onThemeChanged: widget.onThemeChanged))).then((_) => _cargarDatosUsuario());
          },
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Container(
              decoration: BoxDecoration(color: const Color(0xFF0052CC), borderRadius: BorderRadius.circular(8.0)),
              clipBehavior: Clip.hardEdge,
              child: _imagenBase64 != null && _imagenBase64!.isNotEmpty
    ? Image.memory(
        base64Decode(_imagenBase64!), 
        fit: BoxFit.cover,
        cacheWidth: 100, 
      )
    : const Icon(Icons.person, color: Colors.white),
            ),
          ),
        ),
        title: Column(
          children: [
            Text('Ordenes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
            Text(_nombreRepartidor, style: const TextStyle(fontSize: 14, color: Colors.grey)),
          ],
        ),
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildTabButton('Pendientes', 0, isDarkMode),
                      const SizedBox(width: 8),
                      _buildTabButton('Compañeros', 1, isDarkMode),
                      const SizedBox(width: 8),
                      _buildTabButton('Completadas', 2, isDarkMode),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: _isLoading 
                    ? const Center(child: CircularProgressIndicator())
                    : _construirContenidoPestana(isDarkMode)
                ),
              ],
            ),
          ),

          if (_tabIndex == 0 && _pedidosSeleccionadosPendientes.isNotEmpty)
            Positioned(
              bottom: 20, left: 20, right: 20,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), elevation: 5),
                onPressed: _mostrarDialogoConfirmacion,
                child: Text('Aceptar ${_pedidosSeleccionadosPendientes.length} pedido(s)', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _construirContenidoPestana(bool isDarkMode) {
    if (_tabIndex == 0) {
      if (_ordenesPendientes.isEmpty) return const Center(child: Text('No hay encargos pendientes'));
      return ListView.builder(
        padding: EdgeInsets.only(bottom: _pedidosSeleccionadosPendientes.isNotEmpty ? 80 : 10),
        itemCount: _ordenesPendientes.length,
        itemBuilder: (ctx, i) => _construirTarjetaOrden(_ordenesPendientes[i], isDarkMode, false),
      );
    } else if (_tabIndex == 1) {
      if (_repartidoresEnProceso.isEmpty) return const Center(child: Text('No hay compañeros activos en este momento'));
      return ListView.builder(
        padding: EdgeInsets.only(bottom: _pedidosSeleccionadosCompartir.isNotEmpty ? 80 : 10),
        itemCount: _repartidoresEnProceso.length,
        itemBuilder: (ctx, i) {
          final rep = _repartidoresEnProceso[i];
          final List<dynamic> ordenes = rep['ordenes'];
          
          return Card(
            color: isDarkMode ? Colors.grey[900] : Colors.blue[50],
            margin: const EdgeInsets.only(bottom: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ExpansionTile(
leading: CircleAvatar(
  backgroundColor: Colors.blueAccent,
  backgroundImage: rep['foto'] != null 
      ? ResizeImage(MemoryImage(base64Decode(rep['foto'])), width: 150) 
      : null,
  child: rep['foto'] == null ? const Icon(Icons.motorcycle, color: Colors.white) : null,
),
              title: Text(rep['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${ordenes.length} pedidos activos en su ruta'),
              children: ordenes.map((o) => _construirTarjetaCompanero(o, rep['id_repartidor'], isDarkMode)).toList(),
            ),
          );
        },
      );
    } else {
      if (_ordenesCompletadas.isEmpty) return const Center(child: Text('No hay encargos completados'));
      return ListView.builder(
        itemCount: _ordenesCompletadas.length,
        itemBuilder: (ctx, i) => _construirTarjetaOrden(_ordenesCompletadas[i], isDarkMode, false),
      );
    }
  }

  void _mostrarDetalleCompletada(Map<String, dynamic> orden, List<dynamic> masas, List<dynamic> mercancia, String tituloViaje, bool isDarkMode) {
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
              Center(
                child: Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(10))),
              ),
              const SizedBox(height: 20),
              Text(tituloViaje, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.orange[700])),
              const SizedBox(height: 12),
              
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.person, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Entregado a: ${orden['cliente'] ?? 'Sin nombre'}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.location_on, color: isDarkMode ? Colors.red[300] : Colors.red[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Lugar: ${orden['local'] ?? orden['direccion'] ?? 'No especificado'}', style: const TextStyle(fontSize: 15))),
                ],
              ),
              const Divider(height: 30),
              
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (masas.isNotEmpty)
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: masas.map((m) => Text(
                          "${m['nombre_producto']}: ${m['cantidad']} Kl.", 
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black)
                        )).toList(),
                      ),
                    ),
                  if (masas.isNotEmpty && mercancia.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12.0),
                      child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold)),
                    ),
                  if (mercancia.isNotEmpty)
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: mercancia.map((m) => Text(
                          "${m['nombre_producto']}: ${m['cantidad']} U.", 
                          style: const TextStyle(fontSize: 14, color: Colors.grey)
                        )).toList(),
                      ),
                    ),
                ],
              ),
              const Divider(height: 30),

              if (orden['calificacion_repartidor'] != null || orden['calificacion_pedido'] != null) ...[
                const Text("Comentarios y Calificaciones", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                if (orden['calificacion_repartidor'] != null)
                  _buildEstrellasReadOnly('Tu Calificación', orden['calificacion_repartidor'] ?? 0, isDarkMode),
                if (orden['calificacion_pedido'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4.0),
                    child: _buildEstrellasReadOnly('Calificación del Pedido', orden['calificacion_pedido'] ?? 0, isDarkMode),
                  ),
                if (orden['comentario_repartidor'] != null && orden['comentario_repartidor'].toString().trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12.0),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: isDarkMode ? Colors.grey[800] : Colors.grey[100], borderRadius: BorderRadius.circular(8)),
                      child: Text('"${orden['comentario_repartidor']}"', style: const TextStyle(fontStyle: FontStyle.italic)),
                    ),
                  ),
                const SizedBox(height: 20),
              ] else ...[
                const Center(child: Text("Aún no hay reseñas de este viaje.", style: TextStyle(color: Colors.grey))),
                const SizedBox(height: 20),
              ],
              
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cerrar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              )
            ],
          ),
        );
      },
    );
  }
  
  Widget _construirTarjetaOrden(Map<String, dynamic> orden, bool isDarkMode, bool esParaCompartir) {
    final int ordenId = esParaCompartir ? orden['id_orden'] : orden['id'];
    
    bool estaSeleccionado = false;
    if (_tabIndex == 0) estaSeleccionado = _pedidosSeleccionadosPendientes.contains(ordenId);
    if (_tabIndex == 1) estaSeleccionado = _pedidosSeleccionadosCompartir.contains(ordenId);

    final String? viaje = orden['viaje_programado'];
    final bool esFuturo = viaje?.startsWith('Prog:') ?? false;
    final bool huboFaltante = orden['hubo_faltante'] == true;
    final String estado = orden['estado'];

    final Color colorBorde = estaSeleccionado 
        ? (esParaCompartir ? Colors.orange : const Color(0xFF00C853)) 
        : (huboFaltante ? Colors.redAccent : (esFuturo ? Colors.grey : Colors.orangeAccent));

    final String tituloViaje = esFuturo ? 'Programado: ${viaje?.replaceAll('Prog: ', '')}' : 'Entrega: $viaje';

    List<dynamic> prods = orden['productos'] is String ? jsonDecode(orden['productos']) : List.from(orden['productos'] ?? []);
    List<dynamic> masas = [];
    List<dynamic> mercancia = [];
    for(var p in prods) {
      bool esMasa = p['detalle'].toString().toLowerCase().contains('kilo') || p['detalle'].toString().toLowerCase().contains('gramo');
      if (esMasa) masas.add(p);
      else mercancia.add(p);
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorBorde, width: estaSeleccionado || huboFaltante ? 3 : 1.5)
      ),
      margin: const EdgeInsets.only(bottom: 12, left: 8, right: 8),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () {
              if (_tabIndex == 2) {
                _mostrarDetalleCompletada(orden, masas, mercancia, tituloViaje, isDarkMode);
              } else {
                _mostrarDetalleConMapa(orden, masas, mercancia, tituloViaje, isDarkMode);
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(tituloViaje, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: esFuturo ? Theme.of(context).colorScheme.onSurface : Colors.orange[700])),
                      ),
                      Icon(Icons.touch_app, color: isDarkMode ? Colors.white54 : Colors.black38), 
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.receipt_long, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 16),
                      const SizedBox(width: 6),
                      Expanded(child: Text('Estado: $estado', style: TextStyle(color: isDarkMode ? Colors.cyanAccent : Colors.blue[800], fontWeight: FontWeight.bold, fontSize: 14))),
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
                      Expanded(child: Text('Local: ${orden['local'] ?? orden['direccion'] ?? 'No especificado'}', style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black87, fontSize: 13))),
                    ],
                  ),

                  if (orden['ultima_entrega'] == true) 
                    const Padding(padding: EdgeInsets.only(top: 8.0), child: Text('🚨 ÚLTIMO ENCARGO 🚨', style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold, fontSize: 11))),
                ],
              ),
            ),
          ),
          
          Divider(height: 1, thickness: 1.5, color: isDarkMode ? Colors.white24 : Colors.black87),

          if (_tabIndex == 2 && (orden['calificacion_repartidor'] != null || orden['calificacion_pedido'] != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (orden['calificacion_repartidor'] != null)
                    _buildEstrellasReadOnly('Tu Calificación', orden['calificacion_repartidor'] ?? 0, isDarkMode),
                  if (orden['calificacion_pedido'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: _buildEstrellasReadOnly('Calificación del Pedido', orden['calificacion_pedido'] ?? 0, isDarkMode),
                    ),
                  const SizedBox(height: 8),
                  Divider(color: isDarkMode ? Colors.white12 : Colors.black12),
                ],
              ),
            ),

          if (huboFaltante)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red)),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Faltante reportado: ${orden['detalles_faltante'] ?? 'Revisar.'}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12))),
                ],
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (masas.isNotEmpty)
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: masas.map((m) => Text(
                        "${m['nombre_producto']}: ${m['cantidad']} Kl.", 
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black)
                      )).toList(),
                    ),
                  ),
                  
                if (masas.isNotEmpty && mercancia.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text("!", style: TextStyle(fontSize: 22, color: Colors.orange, fontWeight: FontWeight.bold)),
                  ),
                  
                if (mercancia.isNotEmpty)
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: mercancia.map((m) => Text(
                        "${m['nombre_producto']}: ${m['cantidad']} U.", 
                        style: const TextStyle(fontSize: 12, color: Colors.grey)
                      )).toList(),
                    ),
                  ),

                if (_tabIndex == 0 || _tabIndex == 1)
                  GestureDetector(
                    onTap: () => _toggleSeleccion(ordenId, orden['id_repartidor']),
                    child: Container(
                      margin: const EdgeInsets.only(left: 8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle, 
                        color: estaSeleccionado ? (esParaCompartir ? Colors.orange : const Color(0xFF00C853)) : (isDarkMode ? Colors.grey[800] : Colors.grey[200]),
                        border: Border.all(color: estaSeleccionado ? Colors.transparent : Colors.grey.withOpacity(0.5), width: 1.5)
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Icon(estaSeleccionado ? Icons.check : Icons.circle_outlined, color: estaSeleccionado ? Colors.white : Colors.transparent, size: 24),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildTabButton(String titulo, int index, bool isDarkMode) {
    final bool isSelected = _tabIndex == index;
    return GestureDetector(
      onTap: () { 
        setState(() { 
          _tabIndex = index; 
          _pedidosSeleccionadosPendientes.clear();
          _pedidosSeleccionadosCompartir.clear();
          _idRepartidorDestinoCompartir = null;
        }); 
        _obtenerDatosDePestana();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        decoration: BoxDecoration(
          color: isSelected ? (isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF0052CC)) : Colors.transparent,
          borderRadius: BorderRadius.circular(8.0),
        ),
        child: Text(
          titulo,
          style: TextStyle(
            color: isSelected ? (isDarkMode ? Colors.black : Colors.white) : (isDarkMode ? Colors.white70 : Colors.black87),
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            decoration: isSelected ? TextDecoration.none : TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}

class MapaRutaCompaneroScreen extends StatefulWidget {
  final LatLng destino;
  final String nombreCompanero;

  const MapaRutaCompaneroScreen({super.key, required this.destino, required this.nombreCompanero});

  @override
  State<MapaRutaCompaneroScreen> createState() => _MapaRutaCompaneroScreenState();
}

class _MapaRutaCompaneroScreenState extends State<MapaRutaCompaneroScreen> {
  GoogleMapController? _mapController;
  Set<Marker> _marcadores = {};
  Set<Polyline> _rutas = {};
  bool _isLoading = true;
  LatLngBounds? _boundsRuta; 

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _marcadores = {
      Marker(
        markerId: const MarkerId('destino'),
        position: widget.destino,
        infoWindow: InfoWindow(title: widget.nombreCompanero, snippet: "Ubicación actual"),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange), 
      )
    };
    _obtenerUbicacionYRuta();
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

  Future<void> _obtenerUbicacionYRuta() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Activa el GPS por favor.'))); return; }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;
      }

      Position posActual = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      LatLng origen = LatLng(posActual.latitude, posActual.longitude);

      setState(() {
        _marcadores.add(Marker(markerId: const MarkerId('origen'), position: origen, icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue)));
      });

      final Map<String, dynamic> body = {
        "origin": {"location": {"latLng": {"latitude": origen.latitude, "longitude": origen.longitude}}},
        "destination": {"location": {"latLng": {"latitude": widget.destino.latitude, "longitude": widget.destino.longitude}}},
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
          setState(() {
            _rutas = {Polyline(polylineId: const PolylineId('ruta_companero'), color: Colors.blueAccent, width: 6, points: puntosRuta)};
            _boundsRuta = LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
          });
        }
      }
    } catch (e) {
      debugPrint("Error obteniendo ruta: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ruta al Compañero', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)), centerTitle: true, backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white),
      body: _isLoading
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(), SizedBox(height: 16), Text("Trazando ruta...")]))
          : Stack(
              children: [
                GoogleMap(
                  onMapCreated: (controller) {
                    _mapController = controller;
                    if (_boundsRuta != null) Future.delayed(const Duration(milliseconds: 300), () => _mapController?.animateCamera(CameraUpdate.newLatLngBounds(_boundsRuta!, 60.0)));
                  },
                  initialCameraPosition: CameraPosition(target: widget.destino, zoom: 15),
                  markers: _marcadores, polylines: _rutas, myLocationEnabled: true, myLocationButtonEnabled: true,
                ),
                Positioned(bottom: 20, left: 16, right: 16, child: Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 10)]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Dirígete hacia: ${widget.nombreCompanero}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black)), const SizedBox(height: 4), const Text("Pídele el código cuando llegues.", style: TextStyle(color: Colors.black54, fontSize: 14))]))),
              ],
            ),
    );
  }
}