import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:molino_app/config.dart';

// =========================================================
// 1. PANTALLA PRINCIPAL: LISTA DE CLIENTES
// =========================================================
class TicketsAdminScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;

  const TicketsAdminScreen({super.key, required this.onThemeChanged});
  @override
  _TicketsAdminScreenState createState() => _TicketsAdminScreenState();
}

class _TicketsAdminScreenState extends State<TicketsAdminScreen> {
  List<dynamic> clientes = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    fetchUsuarios();
  }

  Future<void> fetchUsuarios() async {
    setState(() => isLoading = true);
    try {
      final resClientes = await http.get(Uri.parse('${AppConfig.apiHost}/panel/usuarios/clientes'));

      if (resClientes.statusCode == 200) {
        setState(() {
          clientes = json.decode(resClientes.body);
          isLoading = false;
        });
      }
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  Widget _buildList(List<dynamic> usuarios, String tipo, bool isDarkMode) {
    return usuarios.isEmpty
        ? Center(child: Text("No hay clientes registrados", style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.grey)))
        : ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: usuarios.length,
            itemBuilder: (context, index) {
              final user = usuarios[index];
              return GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => HistorialTicketsScreen(
                        idUsuario: user['id'],
                        nombreUsuario: user['nombre'] ?? 'Sin nombre',
                        tipoUsuario: tipo,
                      ),
                    ),
                  );
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 15),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isDarkMode ? const Color(0xFF9E9E9E) : const Color(0xFF1565C0),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 50, height: 50,
                        decoration: BoxDecoration(
                          color: isDarkMode ? Colors.blue[400] : Colors.blue[300],
                          borderRadius: BorderRadius.circular(10)
                        ),
                        clipBehavior: Clip.hardEdge,
                        
child: user['imagen'] != null && user['imagen'].toString().isNotEmpty
    ? Image.memory(
        base64Decode(user['imagen'].toString().replaceAll(RegExp(r'\s+'), '')),
        fit: BoxFit.cover,
        cacheWidth: 100, // 🚀 Salva la RAM al hacer scroll rápido en los clientes
        errorBuilder: (context, error, stackTrace) => const Icon(Icons.person, color: Colors.white, size: 30),
      )
    : const Icon(Icons.person, color: Colors.white, size: 30),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          user['nombre'] ?? 'Sin nombre',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
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

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        title: const Text("Tickets de Clientes", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildList(clientes, 'cliente', isDarkMode),
    );
  }
}

// =========================================================
// 2. PANTALLA: HISTORIAL DE TICKETS (FECHAS)
// =========================================================
class HistorialTicketsScreen extends StatefulWidget {
  final int idUsuario;
  final String nombreUsuario;
  final String tipoUsuario; 

  const HistorialTicketsScreen({super.key, required this.idUsuario, required this.nombreUsuario, required this.tipoUsuario});

  @override
  _HistorialTicketsScreenState createState() => _HistorialTicketsScreenState();
}

class _HistorialTicketsScreenState extends State<HistorialTicketsScreen> {
  bool isLoading = true;
  Map<String, List<dynamic>> ticketsPorFecha = {};
  IO.Socket? _socket;

  @override
  void initState() {
    super.initState();
    fetchHistorial();

    _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });

    _socket!.on('actualizacion_ordenes', (_) {
      if (mounted) fetchHistorial(); 
    });
  }

  @override
  void dispose() {
    _socket?.disconnect();
    super.dispose();
  }

  Future<void> fetchHistorial() async {
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/completadas/${widget.tipoUsuario}/${widget.idUsuario}'));
      
      if (response.statusCode == 200) {
        List<dynamic> ordenes = json.decode(response.body);
        
        Map<String, List<dynamic>> agrupadas = {};
        for (var orden in ordenes) {
          DateTime fechaParseada = DateTime.parse(orden['fecha_registro']).toLocal();
          String fechaStr = "${fechaParseada.day.toString().padLeft(2, '0')}/${fechaParseada.month.toString().padLeft(2, '0')}/${fechaParseada.year}";
          
          if (!agrupadas.containsKey(fechaStr)) agrupadas[fechaStr] = [];
          agrupadas[fechaStr]!.add(orden);
        }

        setState(() {
          ticketsPorFecha = agrupadas;
          isLoading = false;
        });
      }
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    List<String> fechasOrdenadas = ticketsPorFecha.keys.toList(); 

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Historial de", style: Theme.of(context).textTheme.bodySmall),
            Text(widget.nombreUsuario, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        centerTitle: true,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : fechasOrdenadas.isEmpty
              ? Center(child: Text("Este cliente no tiene compras completadas", style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.grey)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: fechasOrdenadas.length,
                  itemBuilder: (context, index) {
                    String fecha = fechasOrdenadas[index];
                    List<dynamic> ordenesDelDia = ticketsPorFecha[fecha]!;
                    
                    String idTicket = "TK-${fecha.replaceAll('/', '')}";

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Fecha: $fecha", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
                        const SizedBox(height: 5),
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => DetalleTicketScreen(
                                  nombreUsuario: widget.nombreUsuario,
                                  fecha: fecha,
                                  idTicket: idTicket,
                                  ordenes: ordenesDelDia,
                                  onUpdate: fetchHistorial,
                                ),
                              ),
                            );
                          },
                          child: Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 20),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                            decoration: BoxDecoration(
                              color: isDarkMode ? const Color(0xFF9E9E9E) : const Color(0xFF1565C0),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              "Ticket: $idTicket",
                              style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
    );
  }
}

// =========================================================
// 3. PANTALLA: DETALLE COMPLETO DEL TICKET (FASE 4)
// =========================================================
class DetalleTicketScreen extends StatefulWidget {
  final String nombreUsuario;
  final String fecha;
  final String idTicket;
  final List<dynamic> ordenes;
  final VoidCallback onUpdate;

  const DetalleTicketScreen({super.key, required this.nombreUsuario, required this.fecha, required this.idTicket, required this.ordenes, required this.onUpdate});

  @override
  _DetalleTicketScreenState createState() => _DetalleTicketScreenState();
}

class _DetalleTicketScreenState extends State<DetalleTicketScreen> {
  bool _isLoading = false;
  bool _modoDescuento = false; 
  List<dynamic> _ordenesModificadas = []; 

  @override
  void initState() {
    super.initState();
    // 🚀 Copia profunda para editar los precios localmente
    // ✅ CÓDIGO OPTIMIZADO
_ordenesModificadas = jsonDecode(jsonEncode(widget.ordenes));
for (var orden in _ordenesModificadas) {
  if (orden['productos'] is String) {
    orden['productos'] = jsonDecode(orden['productos']);
  }
  // 🚀 Decodificamos las imágenes 1 sola vez en la RAM
  if (orden['productos'] is List) {
    for (var p in orden['productos']) {
      if (p['imagen'] != null && p['imagen'].toString().isNotEmpty) {
        try { p['imagenBytes'] = base64Decode(p['imagen'].toString().replaceAll(RegExp(r'\s+'), '')); } catch(_) {}
      }
    }
  }
}
  }

  Future<void> _cobrarTicketCompleto() async {
    setState(() => _isLoading = true);
    try {
      for (var orden in _ordenesModificadas) {
        if (orden['estado'] != 'Cobrado') {
          List<Map<String, dynamic>> productosLimpios = (orden['productos'] as List).map((p) => {
            'nombre_producto': p['nombre_producto'] ?? p['nombre'],
            'detalle': p['detalle'],
            'cantidad': p['cantidad'],
            'precio': p['precio']
          }).toList();

          await http.put(
            Uri.parse('${AppConfig.apiHost}/ordenes/cobrar/${orden['id']}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'total': orden['total'],
              'productos': productosLimpios
            })
          );
        }
      }
      widget.onUpdate(); 
      Navigator.pop(context); 
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _guardarDescuentos() async {
    setState(() => _isLoading = true);
    try {
      for (var orden in _ordenesModificadas) {
        if (orden['estado'] != 'Cobrado') {
          List<Map<String, dynamic>> productosLimpios = (orden['productos'] as List).map((p) => {
            'nombre_producto': p['nombre_producto'] ?? p['nombre'],
            'detalle': p['detalle'],
            'cantidad': p['cantidad'],
            'precio': p['precio'],
            'precio_original': p['precio_original'],
            'descuento': p['descuento']
          }).toList();

          await http.put(
            Uri.parse('${AppConfig.apiHost}/ordenes/guardar-descuentos/${orden['id']}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'total': orden['total'],
              'productos': productosLimpios
            })
          );
        }
      }
      setState(() {
        _modoDescuento = false;
      });
      widget.onUpdate();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Descuentos guardados con éxito.', style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
      }
    } catch (e) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 🚀 DIÁLOGO DE DESCUENTO AL TOTAL DEL PRODUCTO
  void _mostrarDialogoDescuento(Map<String, dynamic> orden, int indexProducto) {
    var prod = orden['productos'][indexProducto]; 
    TextEditingController precioController = TextEditingController();
    
    double cantidad = double.tryParse(prod['cantidad'].toString()) ?? 1.0;
    double precioOriginalUnitario = double.tryParse(prod['precio_original']?.toString() ?? prod['precio'].toString()) ?? 0.0;
    double totalOriginalProducto = precioOriginalUnitario * cantidad;

    showDialog(
      context: context,
      builder: (ctx) {
        final isDarkMode = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDarkMode ? Colors.grey[900] : Colors.white,
          title: Text('Descuento al total de ${prod['nombre_producto'] ?? prod['nombre']}', style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Total actual: \$${totalOriginalProducto.toStringAsFixed(2)}', style: const TextStyle(color: Colors.grey, fontSize: 14)),
              const SizedBox(height: 12),
              TextField(
                controller: precioController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  labelText: 'Nuevo Total (\$)',
                  labelStyle: TextStyle(color: Colors.orange),
                  prefixText: '\$ ',
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.orange)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
              onPressed: () {
                double? nuevoTotalProducto = double.tryParse(precioController.text);

                if (nuevoTotalProducto != null && nuevoTotalProducto >= 0 && nuevoTotalProducto < totalOriginalProducto) {
                  setState(() {
                    if (prod['precio_original'] == null) {
                      prod['precio_original'] = precioOriginalUnitario;
                    }
                    
                    double porcentaje = ((totalOriginalProducto - nuevoTotalProducto) / totalOriginalProducto) * 100;
                    prod['descuento'] = porcentaje.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
                    prod['precio'] = nuevoTotalProducto / cantidad;

                    double nuevoTotal = 0;
                    for (var p in orden['productos']) {
                      nuevoTotal += (double.tryParse(p['precio'].toString()) ?? 0) * (double.tryParse(p['cantidad'].toString()) ?? 0);
                    }
                    orden['total'] = nuevoTotal;
                  });
                }
                Navigator.pop(ctx);
              },
              child: const Text('Aplicar', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      }
    );
  }

  List<Widget> _construirListaOrdenes(List<dynamic> ordenesLista, bool isDarkMode, BuildContext context) {
    return ordenesLista.map((orden) {
      List<dynamic> productos = orden['productos'] ?? [];

      // 🚀 ESTADO DEL TICKET
      String estadoTicket = orden['estado'] == 'Cobrado' ? 'Cobrado' : 'Pendiente a Cobro';
      Color colorEstado = orden['estado'] == 'Cobrado' ? Colors.green : Colors.orange;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(orden['viaje_programado'] ?? "Viaje Inmediato", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14, fontWeight: FontWeight.bold)),
              Text(estadoTicket, style: TextStyle(color: colorEstado, fontSize: 12, fontWeight: FontWeight.bold)),
            ]
          ),
          if (orden['nombre_repartidor'] != null)
              Text("Repartidor: ${orden['nombre_repartidor']}", style: const TextStyle(fontSize: 12, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDarkMode ? const Color(0xFF9E9E9E) : const Color(0xFF1565C0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: List.generate(productos.length, (indexProd) {
                var prod = productos[indexProd];
                bool tieneDescuento = prod['descuento'] != null;

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _modoDescuento ? () => _mostrarDialogoDescuento(orden, indexProd) : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: EdgeInsets.all(_modoDescuento ? 6.0 : 0),
                      margin: const EdgeInsets.only(bottom: 8.0),
                      decoration: BoxDecoration(
                        border: _modoDescuento ? Border.all(color: Colors.orangeAccent, width: 2) : Border.all(color: Colors.transparent, width: 2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(
                              color: isDarkMode ? Colors.blue[400] : Colors.blue[300],
                              borderRadius: BorderRadius.circular(8)
                            ),
                            
clipBehavior: Clip.hardEdge,
child: prod['imagenBytes'] != null
    ? Image.memory(
        prod['imagenBytes'], 
        fit: BoxFit.cover, 
        cacheWidth: 80, // 🚀 Súper ligero para que la lista del ticket no se trabe
        errorBuilder: (context, error, stackTrace) => const Icon(Icons.image, color: Colors.white, size: 20)
      )
    : const Icon(Icons.image, color: Colors.white, size: 20),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(prod['nombre_producto'] ?? prod['nombre'], style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontWeight: FontWeight.bold)),
                                
                                if (tieneDescuento)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 2.0),
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

                                Text("\$${double.parse(prod['precio'].toString()).toStringAsFixed(2)} MXN POR UNIDAD", style: TextStyle(color: tieneDescuento ? Colors.greenAccent : (isDarkMode ? Colors.black54 : Colors.white70), fontSize: 10, fontWeight: tieneDescuento ? FontWeight.bold : FontWeight.normal)),
                              ],
                            ),
                          ),
                          Text("${prod['cantidad']} u.", style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontSize: 12)),
                          const SizedBox(width: 10),
                          Text("Total: \$${((double.tryParse(prod['precio'].toString()) ?? 0) * (double.tryParse(prod['cantidad'].toString()) ?? 0)).toStringAsFixed(2)}", 
                            style: TextStyle(color: isDarkMode ? Colors.black87 : Colors.white, fontSize: 12, fontWeight: FontWeight.bold)
                          ),
                          
                          // 🚀 BOTÓN DE REVERTIR
                          if (tieneDescuento && _modoDescuento)
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  prod['precio'] = prod['precio_original'];
                                  prod.remove('precio_original');
                                  prod.remove('descuento');
                                  
                                  double nuevoTotal = 0;
                                  for (var p in orden['productos']) {
                                    nuevoTotal += (double.tryParse(p['precio'].toString()) ?? 0) * (double.tryParse(p['cantidad'].toString()) ?? 0);
                                  }
                                  orden['total'] = nuevoTotal;
                                });
                              },
                              child: const Padding(
                                padding: EdgeInsets.only(left: 8.0),
                                child: Icon(Icons.replay, color: Colors.redAccent, size: 24),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          
          Align(
            alignment: Alignment.centerLeft,
            child: Text("Total del viaje: \$${double.parse(orden['total'].toString()).toStringAsFixed(2)}", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold)),
          ),
          
          const SizedBox(height: 20),
        ],
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    double granTotal = 0;
    bool todoCobrado = true;

    List<dynamic> ordenesNormales = [];
    List<dynamic> ordenesRescate = [];

    for (var orden in _ordenesModificadas) {
      granTotal += double.tryParse(orden['total'].toString()) ?? 0;
      if (orden['estado'] != 'Cobrado') {
        todoCobrado = false;
      }

      if (orden['viaje_programado'] == 'Entrega de pedido pendiente' || orden['viaje_programado'] == 'Prog: Rescate (Mañana)') {
        ordenesRescate.add(orden);
      } else {
        ordenesNormales.add(orden);
      }
    }

    DateTime ahora = DateTime.now();
    String hoyStr = "${ahora.day.toString().padLeft(2, '0')}/${ahora.month.toString().padLeft(2, '0')}/${ahora.year}";
    bool esTicketDeHoy = (widget.fecha == hoyStr);
    bool esDespuesDeLas7 = ahora.hour >= 19;
    bool mostrarBotonesCobro = !esTicketDeHoy || esDespuesDeLas7;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.idTicket, style: Theme.of(context).textTheme.bodySmall),
            Text(widget.nombreUsuario, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        centerTitle: true,
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text("Fecha: ${widget.fecha}", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
                Text("Ticket: ${widget.idTicket}", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14)),
                const SizedBox(height: 20),

                if (ordenesNormales.isNotEmpty) ...[
                  ..._construirListaOrdenes(ordenesNormales, isDarkMode, context),
                ],

                if (ordenesRescate.isNotEmpty) ...[
                  if (ordenesNormales.isNotEmpty) const Divider(color: Colors.grey, thickness: 2, height: 40),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    decoration: BoxDecoration(color: Colors.purple.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
                    child: const Row(
                      children: [
                        Icon(Icons.inventory, color: Colors.purpleAccent),
                        SizedBox(width: 8),
                        Expanded(child: Text("📦 PEDIDOS FALTANTES ENTREGADOS", style: TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.bold, fontSize: 14))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  ..._construirListaOrdenes(ordenesRescate, isDarkMode, context),
                ],
              ],
            ),
          ),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFF0052CC), 
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "TOTAL DEL DÍA: \$${granTotal.toStringAsFixed(2)} MXN", 
                  style: TextStyle(
                    color: isDarkMode ? Colors.black : Colors.white, 
                    fontSize: 18, 
                    fontWeight: FontWeight.bold
                  )
                ),
                
                const SizedBox(height: 16),

                if (todoCobrado)
                  const Text("✅ TICKET COBRADO", style: TextStyle(color: Colors.greenAccent, fontSize: 16, fontWeight: FontWeight.bold))
                else if (mostrarBotonesCobro) 
                  Row(
                    children: [
                      Expanded(
                        flex: 1, 
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _modoDescuento ? Colors.green : Colors.orange, 
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12)
                          ),
                          icon: Icon(_modoDescuento ? Icons.save : Icons.percent, size: 20),
                          // 🚀 BOTÓN DE DESCONTAR PARA GUARDAR
                          label: Text(_modoDescuento ? "Descontar" : "Descuento", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          onPressed: () {
                            if (_modoDescuento) {
                              _guardarDescuentos(); 
                            } else {
                              setState(() { _modoDescuento = true; }); 
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2, 
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _modoDescuento ? Colors.grey : Colors.green, 
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12)
                          ),
                          icon: const Icon(Icons.attach_money, size: 20),
                          label: const Text("Cobrar Todo", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                          onPressed: _modoDescuento ? null : _cobrarTicketCompleto,
                        ),
                      ),
                    ],
                  )
                else
                  Text("⏳ El corte de hoy se habilitará a las 7:00 PM", 
                    style: TextStyle(color: isDarkMode ? Colors.black54 : Colors.white70, fontStyle: FontStyle.italic, fontWeight: FontWeight.bold)
                  ),
              ],
            ),
          )
        ],
      ),
    );
  }
}