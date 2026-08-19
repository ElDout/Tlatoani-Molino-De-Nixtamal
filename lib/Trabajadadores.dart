import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molino_app/Login.dart';
import 'package:molino_app/config.dart';
import 'package:molino_app/BloqueoTrabajo.dart';
import 'package:molino_app/PerfilScreen.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:molino_app/NotificacionesHelper.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:molino_app/BloqueoResenas.dart';

List<dynamic> parsearListaJson(String jsonStr) {
  final parsed = jsonDecode(jsonStr);
  return parsed is List ? parsed : [];
}

class TrabajadoresScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final int initialTab;
  const TrabajadoresScreen({super.key, required this.onThemeChanged, this.initialTab = 0});

  @override
  State<TrabajadoresScreen> createState() => _TrabajadoresScreenState();
}

class _TrabajadoresScreenState extends State<TrabajadoresScreen> {
  String _nombreTrabajador = "Cargando...";
  String? _imagenBase64;
  
  int _currentTab = 0; 
  bool _isLoading = false;

  Map<String, List<dynamic>> _ordenesAgrupadas = {};
  List<dynamic> _listaPendientes = [];
  
  // 🚀 PESTAÑA DE FALTANTES
  List<dynamic> _listaFaltantes = [];
  Set<int> _pedidosSeleccionadosFaltantes = {};
  List<dynamic> _mercanciaDB = [];

  IO.Socket? _socket;
  bool _pidiendoUbicacion = true; 
  GoogleMapController? _mapController;
  LatLng _posicionActual = const LatLng(19.432608, -99.133209); 
  Set<Marker> _marcadores = {};
  
  List<dynamic> _localesDB = [];
  String? _localSeleccionadoId;

  DateTime _obtenerHoraCDMX() {
    return DateTime.now().toUtc().subtract(const Duration(hours: 6));
  }

  @override
  void initState() {
    super.initState();
    _currentTab = widget.initialTab;
    _verificarUbicacionTurno(); 

    _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
      'forceNew': true,
    });

    _socket!.on('actualizacion_ordenes', (_) {
      if (mounted && !_pidiendoUbicacion) {
        _obtenerTodasLasPendientes();
        _obtenerOrdenesCompletadas();
        _verificarResenasPendientes();
      }
    });

    _socket!.on('notify_faltante_disponible', (_) {
      if (mounted && !_pidiendoUbicacion) {
        _obtenerFaltantes();
      }
    });

    _socket!.on('notify_pedido_asignado', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      if ((data['id_cliente'] == miId || data['id_trabajador'] == miId) && mounted) {
        NotificacionesHelper.mostrarNotificacion(titulo: 'Pedido Tomado ✅', cuerpo: '${data['nombre_repartidor']} se dirige a recoger tu pedido.', payload: {'tipo': 'cliente_aviso'});
      }
    });

    _socket!.on('notify_pedido_recogido', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      if ((data['id_cliente'] == miId || data['id_trabajador'] == miId) && mounted) {
        NotificacionesHelper.mostrarNotificacion(titulo: '¡Tu pedido va en camino! 🛵', cuerpo: '${data['nombre_repartidor']} ya recogió tus cosas.', payload: {'tipo': 'cliente_aviso'});
      }
    });

    _socket!.on('notify_repartidor_llegado', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      if ((data['id_cliente'] == miId || data['id_trabajador'] == miId) && mounted) {
        NotificacionesHelper.mostrarNotificacion(titulo: '¡El repartidor ha llegado! 📍', cuerpo: 'Sal a recibir a ${data['nombre_repartidor']}.', payload: {'tipo': 'llegada_repartidor'});
      }
    });

    _socket!.on('notify_cambio_repartidor', (data) async {
      final prefs = await SharedPreferences.getInstance();
      final miId = prefs.getInt('userId');
      if ((data['id_cliente'] == miId || data['id_trabajador'] == miId) && mounted) {
        NotificacionesHelper.mostrarNotificacion(
          titulo: '🔄 Cambio de Repartidor', 
          cuerpo: 'Tu pedido ha sido transferido. Tu nuevo repartidor designado es ${data['nombre_repartidor']}.', 
          payload: {'tipo': 'cambio_repartidor'}
        );
      }
    });
  }

  @override
  void dispose() { 
    _socket?.disconnect(); 
    _mapController?.dispose();
    super.dispose(); 
  }

  Future<void> _verificarResenasPendientes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? miId = prefs.getInt('userId');
      if (miId == null) return;
      
      final res = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/pendientes-resena/trabajador/$miId'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['success'] == true && data['requiere_resena'] == true) {
          if (mounted) {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => BloqueoResenasScreen(
                orden: data['orden'], 
                onThemeChanged: widget.onThemeChanged,
                rol: 'trabajador', 
              )),
              (route) => false
            );
          }
        }
      }
    } catch (e) {}
  }

  Future<void> _verificarUbicacionTurno() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    final prefs = await SharedPreferences.getInstance();
    final int? miId = prefs.getInt('userId');
    final ahora = DateTime.now();

    final int? expiracionMillis = prefs.getInt('ubicacion_trabajador_expiracion');
    if (expiracionMillis != null) {
      final expiracion = DateTime.fromMillisecondsSinceEpoch(expiracionMillis);
      if (ahora.isBefore(expiracion)) {
        _localSeleccionadoId = prefs.getString('id_tortilleria_guardada');
        setState(() { _pidiendoUbicacion = false; _isLoading = false; });
        _cargarDatosIniciales(); 
        return;
      }
    }
    
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/tortillerias'));
      if (response.statusCode == 200) {
        final List<dynamic> locales = jsonDecode(response.body);
        if (mounted) setState(() { _localesDB = locales; });

        if (miId != null) {
          final localAsignado = locales.cast<Map<String, dynamic>?>().firstWhere((l) {
            if (l == null || l['id_trabajador_actual'].toString() != miId.toString()) return false;
            if (l['fecha_asignacion'] == null) return false;
            
            DateTime fechaAsignacion = DateTime.parse(l['fecha_asignacion']).toLocal();
            return fechaAsignacion.year == ahora.year && fechaAsignacion.month == ahora.month && fechaAsignacion.day == ahora.day;
          }, orElse: () => null);

          if (localAsignado != null) {
            _localSeleccionadoId = localAsignado['id'].toString();
            final medianoche = DateTime(ahora.year, ahora.month, ahora.day + 1);
            
            await prefs.setString('id_tortilleria_guardada', _localSeleccionadoId!); 
            await prefs.setString('local_trabajador_guardado', localAsignado['nombre']);
            await prefs.setString('direccion_trabajador_guardada', localAsignado['nombre']); 
            await prefs.setDouble('lat_trabajador_guardada', double.tryParse(localAsignado['latitud'].toString()) ?? 19.432608);
            await prefs.setDouble('lng_trabajador_guardada', double.tryParse(localAsignado['longitud'].toString()) ?? -99.133209);
            await prefs.setInt('ubicacion_trabajador_expiracion', medianoche.millisecondsSinceEpoch);

            if (mounted) {
              setState(() { _pidiendoUbicacion = false; _isLoading = false; });
              _cargarDatosIniciales();
            }
            return;
          }
        }
      }
    } catch (e) { }

    if (mounted) setState(() { _pidiendoUbicacion = true; _isLoading = false; });
  }

  Future<void> _obtenerLocalesDisponibles() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/tortillerias'));
      if (response.statusCode == 200) {
        if (mounted) setState(() { _localesDB = jsonDecode(response.body); });
      }
    } catch (e) { } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _guardarUbicacionTurno() async {
    if (_localSeleccionadoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Por favor selecciona un Local')));
      return;
    }

    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final miId = prefs.getInt('userId');

    try {
      await http.put(
        Uri.parse('${AppConfig.apiHost}/tortillerias/turno/$_localSeleccionadoId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_trabajador': miId})
      );
    } catch (e) { }

    final localInfo = _localesDB.firstWhere((l) => l['id'].toString() == _localSeleccionadoId);
    final ahora = DateTime.now();
    final medianoche = DateTime(ahora.year, ahora.month, ahora.day + 1);

    await prefs.setString('id_tortilleria_guardada', _localSeleccionadoId!); 
    await prefs.setString('local_trabajador_guardado', localInfo['nombre']);
    await prefs.setString('direccion_trabajador_guardada', localInfo['nombre']); 
    await prefs.setDouble('lat_trabajador_guardada', _posicionActual.latitude);
    await prefs.setDouble('lng_trabajador_guardada', _posicionActual.longitude);
    await prefs.setInt('ubicacion_trabajador_expiracion', medianoche.millisecondsSinceEpoch);

    setState(() {
      _pidiendoUbicacion = false;
      _isLoading = false;
    });
    _cargarDatosIniciales();
  }

  Future<void> _cargarDatosIniciales() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    
    await _cargarDatosUsuario();
    
    await Future.wait([
      _verificarResenasPendientes(),
      _obtenerCatalogoMercancia(),
      _obtenerTodasLasPendientes(),
      _obtenerOrdenesCompletadas(),
      _obtenerFaltantes(),
    ]);

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _cargarDatosUsuario() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _nombreTrabajador = prefs.getString('userUser') ?? prefs.getString('userName') ?? 'Trabajador';
      _imagenBase64 = prefs.getString('userImage');
    });
  }

  Future<void> _obtenerCatalogoMercancia() async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/mercancia'));
      if (response.statusCode == 200) {
        final List<dynamic> datos = await compute(parsearListaJson, response.body);
        if (mounted) setState(() => _mercanciaDB = datos);
      }
    } catch(e) { }
  }

  Future<void> _obtenerFaltantes() async {
    if (_localSeleccionadoId == null) return;
    try {
      final url = '${AppConfig.apiHost}/mercancia-faltante/local/$_localSeleccionadoId';
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        final List<dynamic> datos = await compute(parsearListaJson, response.body);
        if (mounted) {
          setState(() { 
            _listaFaltantes = datos; 
            _pedidosSeleccionadosFaltantes.removeWhere((idOrden) => !_listaFaltantes.any((f) => f['id_orden'] == idOrden));
          });
        }
      }
    } catch (e) { }
  }

  // 🚀 FUSIÓN DE PEDIDOS PENDIENTES Y PREDETERMINADOS
  Future<void> _obtenerTodasLasPendientes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idTrabajador = prefs.getInt('userId');
      if (idTrabajador == null || _localSeleccionadoId == null) return;

      final resTrabajador = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/pendientes/trabajador/$idTrabajador'));
      final resLocal = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/predeterminadas/local/$_localSeleccionadoId'));

      List<dynamic> ordenesHoy = [];
      List<dynamic> ordenesFuturo = [];

      if (resTrabajador.statusCode == 200) {
        final List<dynamic> datos = jsonDecode(resTrabajador.body);
        for (var orden in datos) {
          if (orden['id_tortilleria'] != null) continue; // Ignoramos los de tortilleria aquí para evitar duplicados si los jalara
          String viajeStr = orden['viaje_programado'] ?? '';
          if (viajeStr.startsWith('Prog:')) ordenesFuturo.add(orden);
          else ordenesHoy.add(orden);
        }
      }

      if (resLocal.statusCode == 200) {
        final List<dynamic> datosLocal = jsonDecode(resLocal.body);
        for (var orden in datosLocal) {
          String viajeStr = orden['viaje_programado'] ?? '';
          if (viajeStr.startsWith('Prog:')) ordenesFuturo.add(orden);
          else ordenesHoy.add(orden);
        }
      }

      ordenesFuturo.sort((a, b) {
         try { return _parsearFecha(a['viaje_programado']).compareTo(_parsearFecha(b['viaje_programado'])); } 
         catch(e) { return 0; }
      });
      ordenesHoy.sort((a, b) {
         try { return _parsearFecha(a['viaje_programado']).compareTo(_parsearFecha(b['viaje_programado'])); } 
         catch(e) { return 0; }
      });

      if (mounted) setState(() { _listaPendientes = [...ordenesHoy, ...ordenesFuturo]; });
    } catch (e) { }
  }

  // 🚀 HISTORIAL: SÓLO DONDE EL TRABAJADOR ACTUAL FUE RESPONSABLE
  Future<void> _obtenerOrdenesCompletadas() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idTrabajador = prefs.getInt('userId');
      if (idTrabajador == null) return;

      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/completadas/trabajador/$idTrabajador'));
      if (response.statusCode == 200) {
        final List<dynamic> ordenes = jsonDecode(response.body);
        Map<String, List<dynamic>> agrupadas = {};
        
        for (var orden in ordenes) {
          DateTime dt = DateTime.parse(orden['fecha_registro']).toLocal();
          String fechaStr = "${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}";
          if (!agrupadas.containsKey(fechaStr)) agrupadas[fechaStr] = [];
          agrupadas[fechaStr]!.add(orden);
        }
        if (mounted) setState(() { _ordenesAgrupadas = agrupadas; });
      }
    } catch (e) { }
  }

  DateTime _parsearFecha(String? viajeStr) {
    if (viajeStr == null || viajeStr.isEmpty) return DateTime(2099);
    try {
      if (viajeStr.startsWith('Prog:')) {
        final parts = viajeStr.split(' ');
        if (parts.length < 6) return DateTime(2099);
        final d = parts[1].split('/');
        final t = parts[4].split(':');
        if (d.length < 3 || t.length < 2) return DateTime(2099);
        int h = int.parse(t[0]);
        if (parts[5] == 'PM' && h < 12) h += 12; if (parts[5] == 'AM' && h == 12) h = 0;
        return DateTime(int.parse(d[2]), int.parse(d[1]), int.parse(d[0]), h, int.parse(t[1]));
      } else if (viajeStr.startsWith('Viaje ')) {
        final parts = viajeStr.split(' ');
        if (parts.length < 3) return DateTime(2099);
        final t = parts[1].split(':');
        if (t.length < 2) return DateTime(2099);
        int h = int.parse(t[0]);
        if (parts[2] == 'PM' && h < 12) h += 12; if (parts[2] == 'AM' && h == 12) h = 0;
        final now = _obtenerHoraCDMX();
        DateTime target = DateTime(now.year, now.month, now.day, h, int.parse(t[1]));
        if (now.hour >= 19) target = target.add(const Duration(days: 1));
        return target;
      }
    } catch (e) { return DateTime(2099); }
    return DateTime(2099);
  }

  // 🚀 REGLA DE BLOQUEO DE 80 MINUTOS
  bool _estaBloqueadoPorTiempo(String? viaje) {
    DateTime target = _parsearFecha(viaje);
    int diffMins = target.difference(_obtenerHoraCDMX()).inMinutes;
    return diffMins < 80;
  }

  Future<void> _eliminarFaltanteViaje(int idOrden) async {
    bool confirmar = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Descartar Viaje Completo?'),
        content: const Text('Se eliminarán todos los productos faltantes de este viaje y ya no podrás pedirlos.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Conservar')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Descartar', style: TextStyle(color: Colors.red))),
        ],
      )
    ) ?? false;

    if (!confirmar) return;
    try {
      await http.delete(Uri.parse('${AppConfig.apiHost}/mercancia-faltante/viaje/$idOrden'));
      _obtenerFaltantes();
    } catch (e) { }
  }

  Future<void> _enviarRescateAlServidor(List<Map<String, dynamic>> carrito, double total) async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final miId = prefs.getInt('userId');
    
    try {
      List<int> todosLosIds = [];
      for (var c in carrito) {
        todosLosIds.addAll(List<int>.from(c['ids_faltantes']));
      }

      final payload = {
        'id_trabajador': miId,
        'id_tortilleria': int.parse(_localSeleccionadoId!),
        'total': total,
        'productos': carrito.map((c) => {
          'nombre': c['nombre'],
          'detalle': c['detalle'],
          'cantidad': c['cantidad'],
          'precio': c['precio']
        }).toList(),
        'ids_faltantes': todosLosIds
      };

      final res = await http.post(
        Uri.parse('${AppConfig.apiHost}/ordenes/rescate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload)
      );

      final data = jsonDecode(res.body);

      if (res.statusCode == 200 && data['success'] == true) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Rescate solicitado. En breve un repartidor lo tomará.', style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
        _pedidosSeleccionadosFaltantes.clear();
        setState(() => _currentTab = 0); 
        _cargarDatosIniciales();
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error al procesar el rescate.', style: const TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.red, duration: const Duration(seconds: 4)));
      }
    } catch(e) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _mostrarResumenRescate() {
    List<Map<String, dynamic>> carritoFusionado = [];
    
    for (int idOrden in _pedidosSeleccionadosFaltantes) {
      final viaje = _listaFaltantes.firstWhere((e) => e['id_orden'] == idOrden);
      final List<dynamic> faltantes = viaje['faltantes'];

      for (var f in faltantes) {
        double precio = 0.0;
        String unidad = 'UNIDAD';
        try {
          final m = _mercanciaDB.firstWhere((e) => e['nombre'] == f['nombre_producto']);
          precio = double.tryParse(m['precio'].toString()) ?? 0.0;
          unidad = m['unidad']?.toString().toUpperCase() ?? 'UNIDAD';
        } catch(e) {}

        double cantidadFaltante = double.tryParse(f['cantidad_faltante'].toString()) ?? 0.0;

        int index = carritoFusionado.indexWhere((c) => c['nombre'] == f['nombre_producto']);
        if (index != -1) {
          carritoFusionado[index]['cantidad'] += cantidadFaltante;
          carritoFusionado[index]['cantidad_maxima'] += cantidadFaltante;
          carritoFusionado[index]['ids_faltantes'].add(f['id']);
        } else {
          carritoFusionado.add({
            'ids_faltantes': [f['id']],
            'nombre': f['nombre_producto'],
            'cantidad': cantidadFaltante,
            'cantidad_maxima': cantidadFaltante,
            'precio': precio,
            'detalle': '\$$precio MXN POR $unidad'
          });
        }
      }
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateModal) {
            double total = 0;
            for(var p in carritoFusionado) { total += (p['cantidad'] * p['precio']); }

            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom, left: 16, right: 16, top: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Rescatar Mercancía', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Ajusta la cantidad que deseas pedir. Lo que elimines se descartará.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 16),
                  
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: carritoFusionado.length,
                      itemBuilder: (c, i) {
                        final item = carritoFusionado[i];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(item['nombre'] ?? 'Producto', style: const TextStyle(fontWeight: FontWeight.bold)),
                                      Text(item['detalle'] ?? '', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                    ],
                                  ),
                                ),
                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                                      onPressed: () { setStateModal(() { if (item['cantidad'] > 1) item['cantidad']--; }); }
                                    ),
                                    Text(item['cantidad'] == item['cantidad'].toInt() ? '${item['cantidad'].toInt()}' : '${item['cantidad']}'),
                                    IconButton(
                                      icon: const Icon(Icons.add_circle_outline, color: Colors.green),
                                      onPressed: () { setStateModal(() { if (item['cantidad'] < item['cantidad_maxima']) item['cantidad']++; }); }
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red),
                                      onPressed: () { setStateModal(() { carritoFusionado.removeAt(i); }); }
                                    )
                                  ],
                                )
                              ],
                            ),
                          )
                        );
                      }
                    )
                  ),
                  const SizedBox(height: 16),
                  Text('Total a cobrar: \$${total.toStringAsFixed(2)} MXN', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50)),
                    onPressed: carritoFusionado.isEmpty ? null : () { Navigator.pop(ctx); _enviarRescateAlServidor(carritoFusionado, total); },
                    child: const Text('CONFIRMAR RESCATE', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 16),
                ]
              )
            );
          }
        );
      }
    );
  }

  // 🚀 SOLICITUD DE CANCELACIÓN POR HOY
  Future<void> _confirmarCancelacionDia(Map<String, dynamic> orden) async {
    bool confirmar = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Cancelar pedido de hoy?'),
        content: const Text('Se enviará una solicitud al Administrador para cancelar la entrega de este viaje ÚNICAMENTE por el día de hoy.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Regresar', style: TextStyle(color: Colors.grey))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sí, solicitar', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))),
        ],
      )
    ) ?? false;

    if (!confirmar) return;

    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final miId = prefs.getInt('userId');

    try {
      final payload = {
        'id_orden': orden['id'],
        'id_trabajador': miId,
        // 🚀 TRUCO: Mandamos un producto falso para que el Admin lo vea claro
        'productos_nuevos': [{
          'nombre': '❌ CANCELACIÓN DEL DÍA',
          'detalle': 'El trabajador solicita NO recibir este viaje hoy.',
          'cantidad': 0,
          'precio': 0
        }],
        'total_nuevo': 0,
        'tipo_edicion': 'Cancelación'
      };
      
      final res = await http.post(Uri.parse('${AppConfig.apiHost}/solicitudes-edicion'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));

      if (!mounted) return;
      if (res.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("✅ Solicitud de cancelación enviada al administrador", style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
        _cargarDatosIniciales();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error al enviar solicitud", style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.red));
      }
    } catch (e) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 🚀 MENÚ DE OPCIONES DE EDICIÓN
  void _mostrarOpcionesEdicion(Map<String, dynamic> orden) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("¿Qué tipo de edición deseas hacer?", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.today, color: Colors.orange, size: 30),
              title: const Text("Edición Temporal", style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text("El cambio sólo aplicará para el viaje de hoy."),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (context) => SolicitarEdicionPredeterminadoScreen(ordenAEditar: orden, tipoEdicion: 'Temporal'))).then((_) => _cargarDatosIniciales());
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.all_inclusive, color: Colors.blueAccent, size: 30),
              title: const Text("Edición Permanente", style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text("El cambio se guardará para todos los días futuros."),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (context) => SolicitarEdicionPredeterminadoScreen(ordenAEditar: orden, tipoEdicion: 'Permanente'))).then((_) => _cargarDatosIniciales());
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return WillPopScope(
      onWillPop: () async => false, 
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent, elevation: 0, centerTitle: true,
          automaticallyImplyLeading: false, 
          title: Column(children: [Text('Trabajos', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)), Text(_nombreTrabajador, style: const TextStyle(fontSize: 14, color: Colors.grey))]),
          leading: GestureDetector(
            onTap: () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => PerfilScreen(onThemeChanged: widget.onThemeChanged))).then((_) => _cargarDatosUsuario());
            },
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Container(
                decoration: BoxDecoration(color: const Color(0xFF0052CC), borderRadius: BorderRadius.circular(8.0)),
                clipBehavior: Clip.hardEdge,
                // ✅ CÓDIGO OPTIMIZADO
child: _imagenBase64 != null && _imagenBase64!.isNotEmpty
    ? Image.memory(
        base64Decode(_imagenBase64!), 
        fit: BoxFit.cover, 
        cacheWidth: 100, // 🚀 Protege la RAM en el App Bar
        errorBuilder: (c, e, s) => const Icon(Icons.person, color: Colors.white)
      )
    : const Icon(Icons.person, color: Colors.white),
              ),
            ),
          ),
        ),
        body: _pidiendoUbicacion 
            ? _buildPantallaBloqueoUbicacion(isDarkMode)
            : _buildPantallaNormal(isDarkMode),
        
        // 🚀 YA NO HAY BOTÓN DE NUEVA ORDEN PARA EL TRABAJADOR
        floatingActionButton: _pidiendoUbicacion 
          ? null 
          : (_currentTab == 2 && _pedidosSeleccionadosFaltantes.isNotEmpty)
            ? FloatingActionButton.extended(
                onPressed: _mostrarResumenRescate,
                backgroundColor: const Color(0xFF00C853),
                foregroundColor: Colors.white,
                icon: const Icon(Icons.check),
                label: Text('Rescatar (${_pedidosSeleccionadosFaltantes.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
              )
            : null,
      ),
    );
  }

  Widget _buildPantallaBloqueoUbicacion(bool isDarkMode) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_localesDB.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.storefront_outlined, size: 80, color: Colors.blueAccent),
              const SizedBox(height: 16),
              const Text('Aún no hay tortillerías', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const Text('El administrador debe registrar los locales en su panel antes de que puedas comenzar tu turno.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.grey)),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                icon: const Icon(Icons.refresh),
                label: const Text('Refrescar Locales', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                onPressed: _obtenerLocalesDisponibles,
              )
            ],
          ),
        ),
      );
    }

    if (_localSeleccionadoId != null && !_localesDB.any((l) => l['id'].toString() == _localSeleccionadoId)) {
      _localSeleccionadoId = null;
    }

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.storefront, size: 60, color: Colors.blueAccent),
          const SizedBox(height: 16),
          Text('Configurar Turno', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
          const SizedBox(height: 8),
          const Text('Selecciona el Local donde vas a trabajar hoy. Serás el Encargado registrado de este local hasta la medianoche.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.grey)),
          const SizedBox(height: 24),
          
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text("Local Asignado", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    height: 55, margin: const EdgeInsets.only(bottom: 20), padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(border: Border.all(color: Colors.blueAccent, width: 2), borderRadius: BorderRadius.circular(8)),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true, 
                        value: _localSeleccionadoId, 
                        hint: const Text("Seleccionar tortillería..."),
                        icon: const Icon(Icons.arrow_drop_down, color: Colors.blueAccent),
                        items: _localesDB.map((l) => DropdownMenuItem<String>(value: l['id'].toString(), child: Text(l['nombre']))).toList(),
                        onChanged: (newValue) { 
                          if (newValue != null) {
                            final localSeleccionado = _localesDB.firstWhere((l) => l['id'].toString() == newValue);
                            final double lat = double.tryParse(localSeleccionado['latitud'].toString()) ?? 19.432608;
                            final double lng = double.tryParse(localSeleccionado['longitud'].toString()) ?? -99.133209;
                            final LatLng pos = LatLng(lat, lng);

                            setState(() { 
                              _localSeleccionadoId = newValue; 
                              _posicionActual = pos;
                              _marcadores = {Marker(markerId: const MarkerId('loc'), position: pos)};
                            });
                            _mapController?.animateCamera(CameraUpdate.newLatLngZoom(pos, 16));
                          }
                        },
                      ),
                    ),
                  ),

                  const Text("Confirmar Mapa", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Container(
                    height: 250, decoration: BoxDecoration(border: Border.all(color: Colors.blueAccent, width: 2), borderRadius: BorderRadius.circular(8)),
                    clipBehavior: Clip.hardEdge,
                    child: AbsorbPointer( 
                      child: GoogleMap(
                        initialCameraPosition: CameraPosition(target: _posicionActual, zoom: 15),
                        markers: _marcadores, mapType: MapType.normal, zoomControlsEnabled: false, myLocationButtonEnabled: false,
                        onMapCreated: (GoogleMapController controller) { _mapController = controller; },
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
          
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 55), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: _guardarUbicacionTurno,
            child: const Text('CONFIRMAR Y EMPEZAR TURNO', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
    );
  }

  Widget _buildPantallaNormal(bool isDarkMode) {
    return Padding(
      padding: const EdgeInsets.only(top: 16.0, left: 16.0, right: 16.0, bottom: 0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildTabButton('Pendientes', 0, isDarkMode),
              _buildTabButton('Completadas', 1, isDarkMode),
              _buildTabButton('Faltantes', 2, isDarkMode),
            ],
          ),
          const SizedBox(height: 24),
          
          Expanded(
            child: _isLoading 
              ? const Center(child: CircularProgressIndicator())
              : _currentTab == 0
                ? _buildPestanaPendientes(isDarkMode)
                : _currentTab == 1
                  ? _buildPestanaCompletadas(isDarkMode)
                  : _buildPestanaFaltantes(isDarkMode)
          ),
        ],
      ),
    );
  }

  Widget _buildPestanaPendientes(bool isDarkMode) {
    if (_listaPendientes.isEmpty) {
      return Center(child: Text('No hay trabajos pendientes.', style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.black54)));
    }
    return ListView.builder(itemCount: _listaPendientes.length, itemBuilder: (context, index) => _buildTarjetaPendiente(_listaPendientes[index], isDarkMode));
  }

  Widget _buildPestanaCompletadas(bool isDarkMode) {
    if (_ordenesAgrupadas.isEmpty) {
      return Center(child: Text('No se ha completado ningún trabajo.', style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.black54)));
    }
    return ListView.builder(
      itemCount: _ordenesAgrupadas.keys.length,
      itemBuilder: (context, index) {
        String fecha = _ordenesAgrupadas.keys.elementAt(index);
        String idTicket = "TK-${fecha.replaceAll('/', '')}";
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Fecha: $fecha", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
            const SizedBox(height: 5),
            GestureDetector(
              onTap: () => _abrirTicketCompletado(fecha, idTicket, _ordenesAgrupadas[fecha]!, isDarkMode),
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 20),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                decoration: BoxDecoration(
                  color: isDarkMode ? const Color(0xFF9E9E9E) : const Color(0xFF1565C0),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text("Ticket: $idTicket", style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        );
      },
    );
  }

 Widget _buildPestanaFaltantes(bool isDarkMode) {
    if (_listaFaltantes.isEmpty) {
      return Center(child: Text("No hay mercancía por rescatar.", style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.grey)));
    }
    
    // 🚀 MAGIA: Si ya pasaron las 7 PM (19:00), muestra el aviso.
    final bool deNoche = _obtenerHoraCDMX().hour >= 19;

    return Column(
      children: [
        // 🚀 EL AVISO VISUAL QUE PIDISTE PARA LA NOCHE
        if (deNoche)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withOpacity(0.1), 
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blueAccent)
            ),
            child: const Text('🌙 Los pedidos no entregados hoy volverán a estar disponibles mañana a primera hora.', textAlign: TextAlign.center, style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _obtenerFaltantes,
            child: ListView.builder(
              itemCount: _listaFaltantes.length,
              itemBuilder: (context, index) {
                final viaje = _listaFaltantes[index];
                final bool todosDisponibles = viaje['todos_disponibles'] == true; 
                final bool isSelected = _pedidosSeleccionadosFaltantes.contains(viaje['id_orden']);
                final List<dynamic> faltantes = viaje['faltantes'];
                
                // 🚀 BLINDAJE CONTRA FECHAS NULAS O BORRADAS
                String fechaStr = "Fecha desconocida";
                if (viaje['fecha_orden'] != null) {
                  try {
                    DateTime fechaFormat = DateTime.parse(viaje['fecha_orden'].toString()).toLocal();
                    fechaStr = "${fechaFormat.day}/${fechaFormat.month}/${fechaFormat.year}";
                  } catch(e) {}
                }
                
                return Card(
                  color: isDarkMode ? const Color(0xFF424242) : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: isSelected ? Colors.green : Colors.transparent, width: 2)
                  ),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Checkbox(
                              value: isSelected,
                              activeColor: Colors.green,
                              onChanged: todosDisponibles ? (val) {
                                setState(() {
                                  if (val == true) _pedidosSeleccionadosFaltantes.add(viaje['id_orden']);
                                  else _pedidosSeleccionadosFaltantes.remove(viaje['id_orden']);
                                });
                              } : null,
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(viaje['viaje_programado'] ?? 'Viaje', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                  Text("Fecha: $fechaStr", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                ],
                              )
                            ),
                            if (!todosDisponibles)
                              const Padding(
                                padding: EdgeInsets.only(right: 8.0),
                                child: Icon(Icons.timer, color: Colors.orange),
                              ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _eliminarFaltanteViaje(viaje['id_orden']),
                            ),
                          ],
                        ),
                        if (!todosDisponibles)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(4),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                            child: const Text('⏳ Esperando autorización del Administrador', textAlign: TextAlign.center, style: TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        const Divider(),
                        ...faltantes.map((f) {
                          bool prodAgotado = f['estado'] == 'Agotado'; 

                          // 🚀 FIX VISUAL: Cantidades limpias sin .0
                          double cant = double.tryParse(f['cantidad_faltante'].toString()) ?? 0;
                          String cantStr = cant == cant.toInt() ? cant.toInt().toString() : cant.toString();

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 12.0),
                            child: Row(
                              children: [
                                Icon(prodAgotado ? Icons.error_outline : Icons.inventory, size: 16, color: prodAgotado ? Colors.red : Colors.orange),
                                const SizedBox(width: 8),
                                Text("${cantStr}x ${f['nombre_producto']}", style: TextStyle(
                                    color: prodAgotado ? Colors.red : (isDarkMode ? Colors.white70 : Colors.black87),
                                )),
                                if (prodAgotado)
                                   const Text(" (Agotado)", style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold))
                              ],
                            ),
                          );
                        }).toList(),
                      ],
                    ),
                  )
                );
              }
            ),
          )
        )
      ],
    );
  }

  Widget _buildTarjetaPendiente(Map<String, dynamic> orden, bool isDarkMode) {
    final String? viaje = orden['viaje_programado'];
    final String estado = orden['estado'];
    final bool esFuturo = viaje?.startsWith('Prog:') ?? false;
    final bool yaEstaEnCamino = estado == 'En Camino';
    final bool bloqueado = _estaBloqueadoPorTiempo(viaje) || yaEstaEnCamino; 
    
    final bool huboFaltante = orden['hubo_faltante'] == true;
    final String estadoSolicitud = orden['estado_solicitud'] ?? '';
    final bool haySolicitudPendiente = estadoSolicitud == 'Pendiente';

    final Color colorBorde = huboFaltante ? Colors.redAccent : (haySolicitudPendiente ? Colors.orange : (esFuturo ? Colors.grey : Colors.orangeAccent));
    final String tituloViaje = esFuturo ? (viaje?.replaceAll('Prog: ', 'Programado:\n') ?? 'Programado') : 'Entrega Hoy:\n$viaje';

    final String nombreRepartidor = orden['nombre_repartidor']?.toString() ?? '';
    final bool tieneRepartidor = nombreRepartidor.isNotEmpty;

    List<dynamic> prods = orden['productos'] is String ? jsonDecode(orden['productos']) : List.from(orden['productos'] ?? []);
    List<dynamic> masas = [];
    List<dynamic> mercancia = [];
    
    for(var p in prods) {
      bool esMasa = p['detalle'].toString().toLowerCase().contains('kilo') || p['detalle'].toString().toLowerCase().contains('gramo');
      if (esMasa) {
        masas.add(p);
      } else {
        mercancia.add(p);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: InkWell(
        onTap: () { Navigator.push(context, MaterialPageRoute(builder: (context) => BloqueoTrabajoScreen(onThemeChanged: widget.onThemeChanged, ordenInicial: orden))).then((_) => _cargarDatosIniciales()); },
        child: Card(
          elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: colorBorde, width: huboFaltante ? 3 : 2)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(tituloViaje, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: esFuturo ? Theme.of(context).colorScheme.onSurface : Colors.orange[700])), Icon(Icons.touch_app, color: isDarkMode ? Colors.white54 : Colors.black38)]),
                const Divider(height: 24),
                
                if (haySolicitudPendiente)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange)),
                    child: const Row(
                      children: [
                        Icon(Icons.hourglass_empty, color: Colors.orange),
                        SizedBox(width: 8),
                        Expanded(child: Text('Solicitud de edición enviada al administrador. Esperando respuesta...', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 12))),
                      ],
                    ),
                  )
                else if (huboFaltante)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red)),
                    child: const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.red),
                        SizedBox(width: 8),
                        Expanded(child: Text('¡OJO! El repartidor reportó un faltante. Se ha ajustado el pedido.', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12))),
                      ],
                    ),
                  ),

                Row(children: [Icon(tieneRepartidor ? Icons.motorcycle : Icons.receipt_long, color: isDarkMode ? Colors.blue[300] : Colors.blue[700], size: 20), const SizedBox(width: 8), Expanded(child: Text(tieneRepartidor ? 'Repartidor: $nombreRepartidor' : 'Estado: $estado', style: TextStyle(color: isDarkMode ? Colors.cyanAccent : Colors.blue[800], fontWeight: FontWeight.bold, fontSize: 14)))]),
                const SizedBox(height: 16),
                
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (masas.isNotEmpty)
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: masas.map((m) => Text("${m['nombre_producto']}: ${m['cantidad']} Kl.", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDarkMode ? Colors.white : Colors.black))).toList(),
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
                          children: mercancia.map((m) => Text("${m['nombre_producto']}: ${m['cantidad']} U.", style: const TextStyle(fontSize: 12, color: Colors.grey))).toList(),
                        ),
                      ),
                  ],
                ),
                
                const SizedBox(height: 12),
                const Divider(height: 1, thickness: 1, color: Colors.black12),
                const SizedBox(height: 12),

                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Total:', style: TextStyle(fontWeight: FontWeight.bold)), Text('\$${orden['total']} MXN', style: const TextStyle(fontWeight: FontWeight.bold))]),
                const SizedBox(height: 12),
                
                // 🚀 AQUÍ ABRIMOS EL MENÚ DE OPCIONES DE EDICIÓN
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red[600], foregroundColor: Colors.white, minimumSize: const Size(0, 45), padding: const EdgeInsets.symmetric(horizontal: 4)), 
                        icon: const Icon(Icons.cancel, size: 16), 
                        label: const Text("Cancelar por hoy", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)), 
                        onPressed: (bloqueado || haySolicitudPendiente) ? null : () {
                          _confirmarCancelacionDia(orden);
                        }
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey, foregroundColor: Colors.white, minimumSize: const Size(0, 45), padding: const EdgeInsets.symmetric(horizontal: 4)), 
                        icon: const Icon(Icons.edit, size: 16), 
                        label: const Text("Editar Pedido", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)), 
                        onPressed: (bloqueado || haySolicitudPendiente) ? null : () {
                          _mostrarOpcionesEdicion(orden);
                        }
                      ),
                    ),
                  ],
                ),
                if (bloqueado && !huboFaltante) Padding(padding: const EdgeInsets.only(top: 8.0), child: Center(child: Text(yaEstaEnCamino ? "🔒 Orden en camino. El repartidor ya la recogió." : "🔒 Orden protegida. Faltan menos de 80 min.", style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold))))
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _abrirTicketCompletado(String fecha, String idTicket, List<dynamic> ordenesDelDia, bool isDarkMode) {
    double granTotal = 0;
    for (var o in ordenesDelDia) { granTotal += double.tryParse(o['total'].toString()) ?? 0; }
    
    Navigator.push(context, MaterialPageRoute(builder: (context) => Scaffold(
      backgroundColor: isDarkMode ? const Color(0xFF383838) : Colors.white, 
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, leading: IconButton(icon: Icon(Icons.arrow_back, color: Theme.of(context).colorScheme.onSurface), onPressed: () => Navigator.pop(context)), title: Text("Historial", style: TextStyle(color: Theme.of(context).colorScheme.onSurface)), centerTitle: true), 
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16), 
              children: [
                Text("Fecha: $fecha", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)), 
                Text("Ticket: $idTicket", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)), 
                const SizedBox(height: 20), 
                ...ordenesDelDia.map((orden) { 
                  List<dynamic> productos = orden['productos'] is String ? json.decode(orden['productos']) : List.from(orden['productos'] ?? []); 
                  
                  // 🚀 AQUÍ CONTROLAMOS EL ESTADO VISUAL
                  String estadoTicket = orden['estado'] == 'Cobrado' ? 'Cobrado' : 'Pendiente a Cobro';
                  Color colorEstado = orden['estado'] == 'Cobrado' ? Colors.green : Colors.orange;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start, 
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(orden['viaje_programado'] ?? "Viaje", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14, fontWeight: FontWeight.bold)), 
                          Text(estadoTicket, style: TextStyle(color: colorEstado, fontSize: 12, fontWeight: FontWeight.bold)),
                        ]
                      ),
                      const SizedBox(height: 5), 
                      Container(
                        width: double.infinity, 
                        margin: const EdgeInsets.only(bottom: 12), 
                        padding: const EdgeInsets.all(12), 
                        decoration: BoxDecoration(color: isDarkMode ? const Color(0xFF9E9E9E) : const Color(0xFF1565C0), borderRadius: BorderRadius.circular(10)), 
                        child: Column(
                          children: productos.map<Widget>((prod) {
                            bool tieneDescuento = prod['descuento'] != null;

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8.0), 
                              child: Row(
                                children: [
                                  Container(
                                    width: 40, height: 40, 
                                    decoration: BoxDecoration(color: Colors.blueAccent, borderRadius: BorderRadius.circular(8)), 
                                    clipBehavior: Clip.hardEdge, 
                                    // ✅ CÓDIGO OPTIMIZADO
child: (prod['imagen'] != null && prod['imagen'].toString().isNotEmpty) 
  ? Image.memory(
      base64Decode(prod['imagen'].toString().replaceAll(RegExp(r'\s+'), '')), 
      fit: BoxFit.cover, 
      cacheWidth: 100, // 🚀 Protege la RAM al hacer scroll en el historial
      errorBuilder: (c,e,s) => const Icon(Icons.image, color: Colors.white)
    ) 
  : const Icon(Icons.image, color: Colors.white)
                                  ), 
                                  const SizedBox(width: 10), 
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start, 
                                      children: [
                                        Text(prod['nombre_producto'], style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontWeight: FontWeight.bold)), 
                                        
                                        // 🚀 RENDERIZAMOS EL DESCUENTO PARA EL TRABAJADOR
                                        if (tieneDescuento)
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: 2.0, top: 2.0),
                                            child: Row(
                                              children: [
                                                Text("\$${prod['precio_original']} MXN", style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                  decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(4)),
                                                  child: Text("-${prod['descuento']}%", style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                                                ),
                                              ],
                                            ),
                                          ),
                                        
                                        Text("\$${double.parse(prod['precio'].toString()).toStringAsFixed(2)} MXN POR UNIDAD", style: TextStyle(color: tieneDescuento ? Colors.greenAccent : (isDarkMode ? Colors.black54 : Colors.white70), fontSize: 10, fontWeight: tieneDescuento ? FontWeight.bold : FontWeight.normal))
                                      ]
                                    )
                                  ), 
                                  Text("${prod['cantidad']} u.", style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontSize: 12)), 
                                  const SizedBox(width: 10), 
                                  Text("Total: \$${((double.tryParse(prod['precio'].toString()) ?? 0) * (double.tryParse(prod['cantidad'].toString()) ?? 0)).toStringAsFixed(2)}", style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontSize: 12, fontWeight: FontWeight.bold))
                                ]
                              )
                            );
                          }).toList()
                        )
                      ), 
                      Align(alignment: Alignment.centerLeft, child: Text("Total del viaje: \$${double.parse(orden['total'].toString()).toStringAsFixed(2)}", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold))), 
                      const SizedBox(height: 20)
                    ]
                  ); 
                }).toList()
              ]
            )
          ), 
          Container(
            width: double.infinity, 
            padding: const EdgeInsets.all(20), 
            decoration: BoxDecoration(color: isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF0052CC), borderRadius: const BorderRadius.vertical(top: Radius.circular(20))), 
            child: Center(
              child: Text("TOTAL GENERAL: \$${granTotal.toStringAsFixed(2)} MXN", style: TextStyle(color: isDarkMode ? Colors.black : Colors.white, fontSize: 18, fontWeight: FontWeight.bold))
            )
          )
        ]
      )
    )));
  }

  Widget _buildTabButton(String titulo, int tabIndex, bool isDarkMode) {
    final bool isSelected = _currentTab == tabIndex;
    return GestureDetector(
      onTap: () { 
        if (_currentTab != tabIndex) {
          setState(() { _currentTab = tabIndex; }); 
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        decoration: BoxDecoration(color: isSelected ? (isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF0052CC)) : Colors.transparent, borderRadius: BorderRadius.circular(8.0)),
        child: Text(titulo, style: TextStyle(color: isSelected ? (isDarkMode ? Colors.black : Colors.white) : (isDarkMode ? Colors.white70 : Colors.black87), fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, decoration: isSelected ? TextDecoration.none : TextDecoration.underline)),
      ),
    );
  }
}

/// =========================================================================
// 🚀 PANTALLA DE EDICIÓN PARA EL TRABAJADOR (MANDA SOLICITUD AL ADMIN)
// =========================================================================
class SolicitarEdicionPredeterminadoScreen extends StatefulWidget {
  final Map<String, dynamic> ordenAEditar; 
  final String tipoEdicion; // 🚀 AQUÍ RECIBE SI ES TEMPORAL O PERMANENTE

  const SolicitarEdicionPredeterminadoScreen({super.key, required this.ordenAEditar, required this.tipoEdicion});

  @override
  State<SolicitarEdicionPredeterminadoScreen> createState() => _SolicitarEdicionPredeterminadoScreenState();
}

class _SolicitarEdicionPredeterminadoScreenState extends State<SolicitarEdicionPredeterminadoScreen> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _carrito = [];
  List<dynamic> _mercanciaDB = [];

  @override
  void initState() {
    super.initState();
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    setState(() => _isLoading = true);
    try {
      final resMerc = await http.get(Uri.parse('${AppConfig.apiHost}/mercancia'));
      if (resMerc.statusCode == 200) {
        final datosMercancia = await compute(parsearListaJson, resMerc.body);
        if (mounted) setState(() => _mercanciaDB = datosMercancia);
      }

      List<dynamic> prodsDB = widget.ordenAEditar['productos'] is String ? jsonDecode(widget.ordenAEditar['productos']) : List.from(widget.ordenAEditar['productos'] ?? []);
      
      if (mounted) {
        setState(() {
          _carrito = prodsDB.map((p) => {
            'nombre': p['nombre_producto'] ?? p['nombre'],
            'detalle': p['detalle'] ?? '\$${p['precio']} MXN POR UNIDAD',
            'cantidad': int.tryParse(p['cantidad'].toString()) ?? 1,
            'precio': double.tryParse(p['precio'].toString()) ?? 0.0,
          }).toList();
        });
      }

    } catch (e) { } finally { if (mounted) setState(() => _isLoading = false); }
  }

  double _calcularTotal() {
    double total = 0;
    for (var prod in _carrito) { total += ((int.tryParse(prod['cantidad'].toString()) ?? 0) * (double.tryParse(prod['precio'].toString()) ?? 0.0)); }
    return total;
  }

 void _abrirCatalogo() {
    // 🚀 MAGIA: Filtramos para que sólo salgan los que NO están en el carrito
    final catalogoActivo = _mercanciaDB.where((item) {
      return !_carrito.any((c) => c['nombre'] == item['nombre']);
    }).toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        return Column(
          children: [
            Padding(padding: const EdgeInsets.all(16.0), child: Text('Selecciona un Producto', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface))),
            Expanded(
              child: catalogoActivo.isEmpty
                  ? const Center(child: Text('Todos los productos ya están en el carrito', style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      itemCount: catalogoActivo.length,
                      itemBuilder: (context, i) {
                        final item = catalogoActivo[i];
                        return ListTile(
                          leading: Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(color: Colors.blueAccent, borderRadius: BorderRadius.circular(8)),
                            clipBehavior: Clip.hardEdge,
                            // ✅ CÓDIGO OPTIMIZADO
                            child: item['imagen'] != null && item['imagen'].toString().isNotEmpty
                                ? Image.memory(
                                    base64Decode(item['imagen'].toString().replaceAll(RegExp(r'\s+'), '')), 
                                    fit: BoxFit.cover, 
                                    cacheWidth: 80, // 🚀 Súper ligero para que el catálogo de abajo no dé tirones
                                    errorBuilder: (c, e, s) => const Icon(Icons.image, color: Colors.white)
                                  )
                                : const Icon(Icons.image, color: Colors.white),
                          ),
                          title: Text(item['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('\$${item['precio']} MXN por ${item['unidad'] ?? 'unidad'}'),
                          onTap: () { Navigator.pop(context); _pedirCantidad(item); },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  void _pedirCantidad(Map<String, dynamic> productoInfo, {int? indexEditar}) {
    final TextEditingController qtyController = TextEditingController(text: indexEditar != null ? _carrito[indexEditar]['cantidad'].toString() : '1');
    showDialog(
      context: context,
      builder: (context) {
        final isDarkMode = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDarkMode ? const Color(0xFF2A2A2A) : Colors.white,
          title: Text(indexEditar != null ? 'Editar cantidad' : '¿Cuántas unidades?'),
          content: TextField(controller: qtyController, keyboardType: TextInputType.number, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white),
              onPressed: () {
                int qty = int.tryParse(qtyController.text) ?? 1;
                if (qty > 0) {
                  setState(() {
                    if (indexEditar != null) { _carrito[indexEditar]['cantidad'] = qty; } 
                    else {
                      _carrito.add({
                        'nombre': productoInfo['nombre'],
                        'detalle': '\$${productoInfo['precio']} MXN POR ${(productoInfo['unidad'] ?? 'UNIDAD').toString().toUpperCase()}',
                        'cantidad': qty,
                        'precio': double.tryParse(productoInfo['precio'].toString()) ?? 0.0,
                      });
                    }
                  });
                }
                Navigator.pop(context);
              },
              child: const Text('Confirmar'),
            )
          ],
        );
      }
    );
  }

  Future<void> _enviarSolicitud() async {
    if (_carrito.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Añade al menos un producto.")));
      return;
    }

    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final miId = prefs.getInt('userId');

    try {
      final productosLimpios = _carrito.map((p) => {
        'nombre': p['nombre'],
        'detalle': p['detalle'],
        'cantidad': p['cantidad'],
        'precio': p['precio']
      }).toList();

      final payload = {
        'id_orden': widget.ordenAEditar['id'],
        'id_trabajador': miId,
        'productos_nuevos': productosLimpios,
        'total_nuevo': _calcularTotal(),
        'tipo_edicion': widget.tipoEdicion // 🚀 MANDAMOS EL TIPO DE EDICIÓN AL SERVIDOR
      };
      
      await http.post(Uri.parse('${AppConfig.apiHost}/solicitudes-edicion'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("✅ Solicitud ${widget.tipoEdicion} enviada al administrador", style: const TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
      Navigator.pop(context);
      
    } catch (e) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _construirImagenDesdeCatalogo(String nombreProducto, bool isDarkMode) {
    final Map<String, dynamic>? mercancia = _mercanciaDB.firstWhere((m) => m['nombre'] == nombreProducto, orElse: () => null);
    
    // ✅ CÓDIGO OPTIMIZADO
if (mercancia != null && mercancia['imagen'] != null && mercancia['imagen'].toString().isNotEmpty) {
  try {
    String cleanStr = mercancia['imagen'].toString().replaceAll('\n', '').replaceAll('\r', '').replaceAll(' ', '');
    return Image.memory(
      base64Decode(cleanStr), 
      fit: BoxFit.cover, 
      cacheWidth: 100, // 🚀 Salva la RAM al renderizar el carrito principal
      errorBuilder: (_,__,___) => Icon(Icons.image, color: isDarkMode ? Colors.black : Colors.white)
    );
  } catch(e) {
        return Icon(Icons.image, color: isDarkMode ? Colors.black : Colors.white);
      }
    }
    return Icon(Icons.image, color: isDarkMode ? Colors.black : Colors.white);
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final colorGrisFondo = isDarkMode ? const Color(0xFF383838) : Colors.white;
    final colorGrisInferior = isDarkMode ? const Color(0xFF424242) : Colors.white;
    final colorAzulMockup = const Color(0xFF003399);
    
    return Scaffold(
      backgroundColor: colorGrisFondo,
      appBar: AppBar(
        title: Text("Modificar Viaje (${widget.tipoEdicion})", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0, 
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onSurface),
      ),
      body: SafeArea(
        child: _isLoading 
          ? const Center(child: CircularProgressIndicator())
          : Column(
          children: [
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("📍 Local: ${widget.ordenAEditar['cliente'] ?? 'Tortillería'}", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                          const SizedBox(height: 4),
                          Text("⏰ Viaje: ${widget.ordenAEditar['viaje_programado']}", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    
                    Text("Mercancía Necesaria", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    
                    InkWell(
                      onTap: _abrirCatalogo,
                      child: Row(
                        children: [
                          Container(
                            width: 50, height: 50,
                            decoration: BoxDecoration(color: isDarkMode ? Colors.grey[400] : colorAzulMockup, borderRadius: BorderRadius.circular(8)),
                            child: Icon(Icons.add, color: isDarkMode ? Colors.black : Colors.white),
                          ),
                          const SizedBox(width: 16),
                          Text('Agregar Producto', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
              
                    Expanded(
                      child: _carrito.isEmpty 
                          ? Center(child: Text("No has añadido productos", style: TextStyle(color: Colors.grey[500])))
                          : ListView.builder(
                              itemCount: _carrito.length,
                              itemBuilder: (context, index) {
                                final p = _carrito[index];
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12.0),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 50, height: 50, 
                                        decoration: BoxDecoration(color: isDarkMode ? Colors.grey[400] : colorAzulMockup, borderRadius: BorderRadius.circular(8)),
                                        clipBehavior: Clip.hardEdge,
                                        child: _construirImagenDesdeCatalogo(p['nombre'], isDarkMode),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(p['nombre'], style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold)),
                                            Text(p['detalle'], style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 12)),
                                          ],
                                        ),
                                      ),
                                      Row(
                                        children: [
                                          IconButton(icon: const Icon(Icons.edit, color: Colors.orange, size: 20), onPressed: () => _pedirCantidad(p, indexEditar: index)),
                                          IconButton(icon: const Icon(Icons.delete, color: Colors.red, size: 20), onPressed: () => setState(() => _carrito.removeAt(index))),
                                          Text('${p['cantidad']} U.', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold)),
                                        ],
                                      )
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: colorGrisInferior, 
                  border: Border(top: BorderSide(color: isDarkMode ? Colors.white24 : Colors.black12, width: 2))
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                           const Text('TOTAL ANTERIOR:', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 14)),
                           Text('\$${widget.ordenAEditar['total']} MXN', style: const TextStyle(color: Colors.grey, decoration: TextDecoration.lineThrough, fontWeight: FontWeight.bold, fontSize: 14)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                           Text('NUEVO TOTAL:', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold, fontSize: 18)),
                           Text('\$${_calcularTotal().toStringAsFixed(2)} MXN', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 18)),
                        ],
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _enviarSolicitud,
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                        child: const Text("ENVIAR SOLICITUD AL ADMIN", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      )
                    ],
                  ),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}