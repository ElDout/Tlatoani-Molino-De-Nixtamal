import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';

class NuevaOrdenTrabajadores extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  final Map<String, dynamic>? ordenAEditar; 

  const NuevaOrdenTrabajadores({super.key, required this.onThemeChanged, this.ordenAEditar});

  @override
  State<NuevaOrdenTrabajadores> createState() => _NuevaOrdenTrabajadoresState();
}

class _NuevaOrdenTrabajadoresState extends State<NuevaOrdenTrabajadores> {
  bool _fueraDeTiempo = false;
  bool _necesitasCambio = false; 
  bool _isLoading = false; 
  bool get _esEdicion => widget.ordenAEditar != null;
  
  final TextEditingController _cambioController = TextEditingController(); 

  DateTime? _fechaProgramada;
  String? _horaProgramada;
  String? _viajeSeleccionadoHoy;
  String? _viajeSeleccionadoTarde;

  List<Map<String, dynamic>> _carrito = [];
  List<dynamic> _mercanciaDB = [];
  List<String> _viajesUsadosHoy = [];

  final List<String> _todosLosViajes = const ['2:00 PM', '4:00 PM', '6:00 PM'];
  final List<String> _diasSemana = ['LUNES', 'MARTES', 'MIÉRCOLES', 'JUEVES', 'VIERNES', 'SÁBADO', 'DOMINGO'];
  
  List<String> _viajesHoyDisponibles = [];
  List<String> _viajesTardeDisponibles = [];

  @override
  void initState() {
    super.initState();
    _obtenerMercancia(); 
    
    _verificarViajesDeHoy().then((_) {
      if (_esEdicion) _cargarDatosDeEdicion();
    });
  }

  // 🚀 OPTIMIZACIÓN CLAVE: Destruimos el controlador de texto para liberar RAM
  @override
  void dispose() {
    _cambioController.dispose();
    super.dispose();
  }

  void _cargarDatosDeEdicion() {
    final orden = widget.ordenAEditar!;
    
    List<dynamic> prodsDB = orden['productos'] is String ? jsonDecode(orden['productos']) : List.from(orden['productos'] ?? []);
    setState(() {
      _carrito = prodsDB.map((p) => {
        'nombre': p['nombre_producto'],
        'detalle': p['detalle'],
        'cantidad': p['cantidad'],
        'precio': double.tryParse(p['precio'].toString()) ?? 0.0,
        'imagen': p['imagen'] ?? '' // 🚀 Rescatamos la imagen si ya la trae
      }).toList();
    });

    double cambio = double.tryParse(orden['cambio_efectivo']?.toString() ?? '0') ?? 0;
    if (cambio > 0) {
      _necesitasCambio = true;
      _cambioController.text = cambio.toString();
    }

    String viajeStr = orden['viaje_programado'];
    _fueraDeTiempo = orden['fuera_de_tiempo'] == true;

    if (viajeStr.startsWith('Prog:')) {
      final parts = viajeStr.split(' ');
      final dateParts = parts[1].split('/');
      _fechaProgramada = DateTime(int.parse(dateParts[2]), int.parse(dateParts[1]), int.parse(dateParts[0]));
      _horaProgramada = "${parts[4]} ${parts[5]}";
    } else {
      if (_fueraDeTiempo) {
        if (!_viajesTardeDisponibles.contains(viajeStr)) _viajesTardeDisponibles.add(viajeStr); 
        _viajeSeleccionadoTarde = viajeStr;
      } else {
        if (!_viajesHoyDisponibles.contains(viajeStr)) _viajesHoyDisponibles.add(viajeStr); 
        _viajeSeleccionadoHoy = viajeStr;
      }
    }
  }

  void _calcularHorariosDisponibles() {
    final ahora = DateTime.now();
    List<String> normales = [];
    List<String> tardes = [];

    final Map<String, int> horasInt = {
      '2:00 PM': 14, '4:00 PM': 16, '6:00 PM': 18 
    };

    for (String viaje in _todosLosViajes) {
      int horaStr = horasInt[viaje]!;
      int diff = (horaStr * 60) - (ahora.hour * 60 + ahora.minute);

      String viajeNormal = 'Viaje $viaje';
      String viajeTarde = 'Viaje ${viaje.replaceFirst(':00', ':20')}';

      if (_viajesUsadosHoy.contains(viajeNormal) && (!(_esEdicion && widget.ordenAEditar!['viaje_programado'] == viajeNormal))) continue;
      if (_viajesUsadosHoy.contains(viajeTarde) && (!(_esEdicion && widget.ordenAEditar!['viaje_programado'] == viajeTarde))) continue;

      if (diff >= 60) normales.add(viajeNormal);
      else if (diff >= 40 && diff <= 59) tardes.add(viajeTarde);
    }
    setState(() { _viajesHoyDisponibles = normales; _viajesTardeDisponibles = tardes; });
  }

  Future<void> _verificarViajesDeHoy() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idTrabajador = prefs.getInt('userId');
      if (idTrabajador == null) return;

      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/hoy/trabajador/$idTrabajador'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final List<dynamic> ordenesHoy = data['ordenes'];
          List<String> usados = [];
          for (var o in ordenesHoy) { if (o['viaje_programado'] != null) usados.add(o['viaje_programado']); }
          _viajesUsadosHoy = usados;
          _calcularHorariosDisponibles();
        }
      }
    } catch (e) { debugPrint('Error: $e'); }
  }

  Future<void> _obtenerMercancia() async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/mercancia'));
      if (response.statusCode == 200) { if (mounted) setState(() { _mercanciaDB = jsonDecode(response.body); }); }
    } catch (e) {}
  }

  double _calcularTotal() {
    double total = 0;
    for (var prod in _carrito) { total += (prod['cantidad'] * prod['precio']); }
    return total;
  }

  Future<void> _seleccionarFechaYHora() async {
    DateTime ahora = DateTime.now();
    DateTime manana = DateTime(ahora.year, ahora.month, ahora.day + 1);

    final DateTime? fecha = await showDatePicker(
      context: context, initialDate: manana, firstDate: manana, lastDate: DateTime(ahora.year + 1),
      builder: (context, child) => Theme(data: Theme.of(context).copyWith(colorScheme: const ColorScheme.light(primary: Color(0xFF003399))), child: child!),
    );

    if (fecha != null) {
      if (!mounted) return;
      final String? hora = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Elige la hora de entrega'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true, itemCount: _todosLosViajes.length,
              itemBuilder: (context, i) => ListTile(title: Text(_todosLosViajes[i]), onTap: () => Navigator.pop(context, _todosLosViajes[i])),
            ),
          ),
        ),
      );

      if (hora != null) {
        setState(() {
          _fechaProgramada = fecha; _horaProgramada = hora;
          _viajeSeleccionadoHoy = null; _viajeSeleccionadoTarde = null; _fueraDeTiempo = false;
        });
      }
    }
  }

  void _abrirCatalogoProductos() {
    showModalBottomSheet(
      context: context, backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        return Column(
          children: [
            Padding(padding: const EdgeInsets.all(16.0), child: Text('Selecciona un Producto', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface))),
            Expanded(
              child: _mercanciaDB.isEmpty
                  ? const Center(child: Text('No hay mercancía disponible'))
                  : ListView.builder(
                      itemCount: _mercanciaDB.length,
                      itemBuilder: (context, i) {
                        final item = _mercanciaDB[i];
                        return ListTile(
                          leading: Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(color: Colors.blueAccent, borderRadius: BorderRadius.circular(8)),
                            clipBehavior: Clip.hardEdge,
                            child: item['imagen'] != null && item['imagen'].toString().isNotEmpty
                                ? Image.memory(
                                    base64Decode(item['imagen']), 
                                    fit: BoxFit.cover,
                                    cacheWidth: 80, // 🚀 PROTEGE LA RAM AL ABRIR EL CATÁLOGO
                                  )
                                : const Icon(Icons.image, color: Colors.white),
                          ),
                          title: Text(item['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('${item['precio']} MXN por ${item['unidad']}'),
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
          title: Text(indexEditar != null ? 'Editar cantidad' : '¿Cuántas unidades?', style: const TextStyle(fontSize: 16)),
          content: TextField(controller: qtyController, keyboardType: TextInputType.number, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C853), foregroundColor: Colors.white),
              onPressed: () {
                int qty = int.tryParse(qtyController.text) ?? 1;
                if (qty <= 0) return;
                setState(() {
                  if (indexEditar != null) { _carrito[indexEditar]['cantidad'] = qty; } 
                  else {
                    _carrito.add({
                      'nombre': productoInfo['nombre'],
                      'detalle': '${productoInfo['precio']} MXN POR ${productoInfo['unidad'].toString().toUpperCase()}',
                      'cantidad': qty,
                      'precio': double.tryParse(productoInfo['precio'].toString()) ?? 0.0,
                      'imagen': productoInfo['imagen'] 
                    });
                  }
                });
                Navigator.pop(context);
              },
              child: const Text('Confirmar'),
            )
          ],
        );
      },
    );
  }

  Future<void> _enviarOActualizarPedido() async {
    if (_carrito.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Agrega productos al carrito'))); return; }

    String viajeFinal = '';
    if (_fechaProgramada != null && _horaProgramada != null) {
      String diaStr = "${_fechaProgramada!.day.toString().padLeft(2,'0')}/${_fechaProgramada!.month.toString().padLeft(2,'0')}/${_fechaProgramada!.year}";
      viajeFinal = 'Prog: $diaStr a las $_horaProgramada';
    } else if (_fueraDeTiempo && _viajeSeleccionadoTarde != null) {
      viajeFinal = _viajeSeleccionadoTarde!;
    } else if (!_fueraDeTiempo && _viajeSeleccionadoHoy != null) {
      viajeFinal = _viajeSeleccionadoHoy!;
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Elige una hora de entrega válida')));
      return;
    }

    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final int? idTrabajador = prefs.getInt('userId'); 
      
      // 📍 JALAMOS LOS DATOS SECRETOS GUARDADOS EN LA OTRA PANTALLA
      final String dirGuardada = prefs.getString('direccion_trabajador_guardada') ?? '';
      final double latGuardada = prefs.getDouble('lat_trabajador_guardada') ?? 19.432608;
      final double lngGuardada = prefs.getDouble('lng_trabajador_guardada') ?? -99.133209;

      final payload = {
        'id_trabajador': idTrabajador, 
        'viaje_programado': viajeFinal,
        'fuera_de_tiempo': _fueraDeTiempo,
        'ultima_entrega': false, 
        'total': _calcularTotal(),
        'cambio_efectivo': _necesitasCambio ? (double.tryParse(_cambioController.text) ?? 0.0) : 0.0,
        'productos': _carrito,
        'direccion_custom': dirGuardada, // 👈 Se envía automáticamente
        'lat_custom': latGuardada.toString(), // 👈 Se envía automáticamente
        'lng_custom': lngGuardada.toString(), // 👈 Se envía automáticamente
      };

      http.Response response;
      if (_esEdicion) {
        response = await http.put(Uri.parse('${AppConfig.apiHost}/ordenes/actualizar/${widget.ordenAEditar!['id']}'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));
      } else {
        response = await http.post(Uri.parse('${AppConfig.apiHost}/ordenes'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));
      }

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        if (!mounted) return;
        Navigator.pop(context); 
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error al procesar el pedido')));
      }
    } catch (e) {
      debugPrint('Error enviando/actualizando pedido: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
        backgroundColor: Colors.transparent, elevation: 0, centerTitle: true,
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onSurface),
        title: Text(_esEdicion ? 'Editar Orden' : 'Nueva Orden', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
      ),
      body: Column(
        children: [
          // --- MITAD SUPERIOR: PRODUCTOS ---
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Productos', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: _abrirCatalogoProductos,
                    child: Row(
                      children: [
                        Container(
                          width: 50, height: 50, 
                          decoration: BoxDecoration(color: isDarkMode ? Colors.grey[400] : colorAzulMockup, borderRadius: BorderRadius.circular(8)), 
                          child: Icon(Icons.add, color: isDarkMode ? Colors.black : Colors.white)
                        ),
                        const SizedBox(width: 16),
                        Text('Agregar Producto', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _carrito.length,
                      itemBuilder: (context, index) {
                        final item = _carrito[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12.0),
                          child: Row(
                            children: [
                              Container(
                                width: 50, height: 50, 
                                decoration: BoxDecoration(color: isDarkMode ? Colors.grey[400] : colorAzulMockup, borderRadius: BorderRadius.circular(8)),
                                clipBehavior: Clip.hardEdge,
                                child: (item['imagen'] != null && item['imagen'].toString().isNotEmpty)
                                    ? Image.memory(
                                        base64Decode(item['imagen']), 
                                        fit: BoxFit.cover,
                                        cacheWidth: 100, // 🚀 PROTEGE LA RAM AL HACER SCROLL EN EL CARRITO
                                      )
                                    : Icon(Icons.image, color: isDarkMode ? Colors.black : Colors.white),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(item['nombre'], style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold)),
                                    Text(item['detalle'], style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 12)),
                                  ],
                                ),
                              ),
                              Row(
                                children: [
                                  IconButton(icon: const Icon(Icons.edit, color: Colors.orange, size: 20), onPressed: () => _pedirCantidad(item, indexEditar: index)),
                                  IconButton(icon: const Icon(Icons.delete, color: Colors.red, size: 20), onPressed: () => setState(() => _carrito.removeAt(index))),
                                  Text('${item['cantidad']} U.', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold)),
                                ],
                              )
                            ],
                          ),
                        );
                      },
                    ),
                  )
                ],
              ),
            ),
          ),
          
          // --- MITAD INFERIOR: CONTROLES ---
          Expanded(
            flex: 4, 
            child: Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(color: colorGrisInferior, border: Border(top: BorderSide(color: isDarkMode ? Colors.white24 : Colors.black12, width: 2))),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Entrega Programada', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        InkWell(
                          onTap: _seleccionarFechaYHora,
                          child: Container(width: 80, height: 80, decoration: BoxDecoration(color: colorAzulMockup, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.calendar_month, color: Colors.white, size: 40)),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Elige una opción', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                              Text(_fechaProgramada != null ? 'Dia: ${_fechaProgramada!.day.toString().padLeft(2,'0')}/${_fechaProgramada!.month.toString().padLeft(2,'0')}/${_fechaProgramada!.year}' : 'Dia: XX/XX/XXXX', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                              Text(_fechaProgramada != null ? _diasSemana[_fechaProgramada!.weekday - 1] : 'SABADO', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                              Text(_horaProgramada != null ? 'Entrega: $_horaProgramada' : 'Entrega: XX:XX XX', style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
                            ],
                          ),
                        )
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('Entrega Hoy', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16, fontWeight: FontWeight.bold)),
                    const Text('Despues de las 5:30 no se pueden hacer mas pedidos Hasta las 12:00AM del dia siguiente', style: TextStyle(fontSize: 10, color: Colors.grey)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(color: colorAzulMockup, borderRadius: BorderRadius.circular(24)),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          dropdownColor: colorAzulMockup,
                          value: _viajeSeleccionadoHoy, hint: const Text('Elige una opción', style: TextStyle(color: Colors.white)), icon: const Icon(Icons.arrow_drop_down, color: Colors.white), isExpanded: true,
                          items: _viajesHoyDisponibles.map((String value) => DropdownMenuItem<String>(value: value, child: Text(value, style: const TextStyle(color: Colors.white)))).toList(),
                          onChanged: _viajesHoyDisponibles.isEmpty ? null : (newValue) { setState(() { _viajeSeleccionadoHoy = newValue; _fechaProgramada = null; _horaProgramada = null; _fueraDeTiempo = false; _viajeSeleccionadoTarde = null; }); },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text('Fuera de tiempo', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16, fontWeight: FontWeight.bold)),
                        Switch(value: _fueraDeTiempo, activeColor: Colors.white, activeTrackColor: Colors.black, onChanged: _viajesTardeDisponibles.isEmpty ? null : (val) { setState(() { _fueraDeTiempo = val; if(val) { _fechaProgramada = null; _horaProgramada = null; _viajeSeleccionadoHoy = null; } else { _viajeSeleccionadoTarde = null; }}); }),
                      ],
                    ),
                    const Text('Esta opcion esta disponible 40 minutos antes de las entregas de hoy*', style: TextStyle(fontSize: 10, color: Colors.grey)),
                    const SizedBox(height: 8),
                    if (_fueraDeTiempo)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12), decoration: BoxDecoration(color: colorAzulMockup, borderRadius: BorderRadius.circular(24)),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            dropdownColor: colorAzulMockup, value: _viajeSeleccionadoTarde, hint: const Text('Elige una opción', style: TextStyle(color: Colors.white)), icon: const Icon(Icons.arrow_drop_down, color: Colors.white), isExpanded: true,
                            items: _viajesTardeDisponibles.map((String value) => DropdownMenuItem<String>(value: value, child: Text(value, style: const TextStyle(color: Colors.white)))).toList(),
                            onChanged: (newValue) { setState(() { _viajeSeleccionadoTarde = newValue; }); },
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text('Necesitas cambio?', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16, fontWeight: FontWeight.bold)),
                        Switch(value: _necesitasCambio, onChanged: (val) { setState(() { _necesitasCambio = val; }); }, activeColor: Colors.white, activeTrackColor: Colors.black),
                      ],
                    ),
                    if (_necesitasCambio)
                      Row(
                        children: [
                          Expanded(child: TextField(controller: _cambioController, keyboardType: TextInputType.number, decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: colorAzulMockup, width: 2)), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: colorAzulMockup, width: 2))))),
                          const SizedBox(width: 8),
                          const Expanded(child: Text('Escribe la cantidad que daras en efectivo', style: TextStyle(fontSize: 10, color: Colors.grey))),
                        ],
                      ),
                    const SizedBox(height: 30),
                    
                    Center(child: Text('TOTAL: ${_calcularTotal()} MXN', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold, fontSize: 16))),
                    const SizedBox(height: 12),
                    
                    _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: _esEdicion ? Colors.orange : colorAzulMockup,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(double.infinity, 50),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                          onPressed: _enviarOActualizarPedido,
                          child: Text(_esEdicion ? 'ACTUALIZAR PEDIDO' : 'ENVIAR PEDIDO', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}