import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';
import 'package:molino_app/Predeterminado.dart'; 

List<dynamic> parsearListaJson(String jsonStr) {
  final parsed = jsonDecode(jsonStr);
  return parsed is List ? parsed : [];
}

// =========================================================================
// 🚀 PANEL DE CONTROL DE LA TORTILLERÍA
// =========================================================================
class PanelTortilleriaScreen extends StatefulWidget {
  final Map<String, dynamic> tortilleria;
  final Function(ThemeMode) onThemeChanged;

  const PanelTortilleriaScreen({super.key, required this.tortilleria, required this.onThemeChanged});

  @override
  State<PanelTortilleriaScreen> createState() => _PanelTortilleriaScreenState();
}

class _PanelTortilleriaScreenState extends State<PanelTortilleriaScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        title: Text(widget.tortilleria['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          labelColor: isDarkMode ? Colors.black : Colors.white,
          unselectedLabelColor: isDarkMode ? Colors.white70 : Colors.black87,
          indicator: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: isDarkMode ? Colors.grey[300] : const Color(0xFF1565C0),
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          indicatorPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          tabs: const [
            Tab(text: "Tickets"),
            Tab(text: "Predeterminados"),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            TicketsTortilleriaTab(tortilleria: widget.tortilleria),
            PredeterminadosTab(tortilleria: widget.tortilleria),
          ],
        ),
      ),
    );
  }
}

// =========================================================================
// 🚀 TAB 1: TICKETS DE LA TORTILLERÍA
// =========================================================================
class TicketsTortilleriaTab extends StatefulWidget {
  final Map<String, dynamic> tortilleria;

  const TicketsTortilleriaTab({super.key, required this.tortilleria});

  @override
  State<TicketsTortilleriaTab> createState() => _TicketsTortilleriaTabState();
}

class _TicketsTortilleriaTabState extends State<TicketsTortilleriaTab> {
  bool isLoading = true;
  Map<String, List<dynamic>> ticketsPorFecha = {};

  @override
  void initState() {
    super.initState();
    fetchTickets();
  }

  Future<void> fetchTickets() async {
    setState(() => isLoading = true);
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/ordenes/tortilleria/${widget.tortilleria['id']}'));
      
      if (response.statusCode == 200) {
        List<dynamic> ordenes = await compute(parsearListaJson, response.body);
        Map<String, List<dynamic>> agrupadas = {};
        
        for (var orden in ordenes) {
          DateTime fechaParseada = DateTime.parse(orden['fecha_registro']).toLocal();
          String fechaStr = "${fechaParseada.day.toString().padLeft(2, '0')}/${fechaParseada.month.toString().padLeft(2, '0')}/${fechaParseada.year}";
          
          if (!agrupadas.containsKey(fechaStr)) agrupadas[fechaStr] = [];
          agrupadas[fechaStr]!.add(orden);
        }

        if (mounted) {
          setState(() {
            ticketsPorFecha = agrupadas;
            isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    List<String> fechasOrdenadas = ticketsPorFecha.keys.toList();

    if (isLoading) return const Center(child: CircularProgressIndicator());

    if (fechasOrdenadas.isEmpty) {
      return Center(child: Text("No hay tickets aún.", style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.grey)));
    }

    return RefreshIndicator(
      onRefresh: fetchTickets,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
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
                      builder: (context) => DetalleTicketTortilleriaScreen(
                        nombreLocal: widget.tortilleria['nombre'],
                        fecha: fecha,
                        idTicket: idTicket,
                        ordenes: ordenesDelDia,
                        onUpdate: fetchTickets, 
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

// =========================================================================
// 🚀 PANTALLA DE DETALLE DE TORTILLERÍA CON COBRO EN BLOQUE
// =========================================================================
class DetalleTicketTortilleriaScreen extends StatefulWidget {
  final String nombreLocal;
  final String fecha;
  final String idTicket;
  final List<dynamic> ordenes;
  final VoidCallback onUpdate;

  const DetalleTicketTortilleriaScreen({super.key, required this.nombreLocal, required this.fecha, required this.idTicket, required this.ordenes, required this.onUpdate});

  @override
  State<DetalleTicketTortilleriaScreen> createState() => _DetalleTicketTortilleriaScreenState();
}

class _DetalleTicketTortilleriaScreenState extends State<DetalleTicketTortilleriaScreen> {
  bool _isLoading = false;
  bool _modoDescuento = false; // 🚀 Controla si estamos en modo descuento
  List<dynamic> _ordenesModificadas = []; // 🚀 Copia local para editar precios

  @override
  void initState() {
    super.initState();
    // 🚀 Hacemos una copia profunda para poder editar los precios localmente
    _ordenesModificadas = jsonDecode(jsonEncode(widget.ordenes));
    // ✅ CÓDIGO OPTIMIZADO
for (var orden in _ordenesModificadas) {
  if (orden['productos'] is String) {
    orden['productos'] = jsonDecode(orden['productos']);
  }
  // Decodificamos las imágenes 1 sola vez en RAM
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
          // 🚀 Extraemos los productos ya con los precios modificados
          List<Map<String, dynamic>> productosLimpios = (orden['productos'] as List).map((p) => {
            'nombre_producto': p['nombre_producto'] ?? p['nombre'],
            'detalle': p['detalle'],
            'cantidad': p['cantidad'],
            'precio': p['precio']
          }).toList();

          await http.put(
            Uri.parse('${AppConfig.apiHost}/ordenes/cobrar/${orden['id']}'),
            headers: {'Content-Type': 'application/json'},
            // 🚀 Mandamos el nuevo total y los productos descontados al backend
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

  // 🚀 DIÁLOGO PARA APLICAR EL DESCUENTO (Y REVERTIR)
  // 🚀 DIÁLOGO PARA APLICAR EL DESCUENTO (AL TOTAL DEL PRODUCTO)
  void _mostrarDialogoDescuento(Map<String, dynamic> orden, int indexProducto) {
    var prod = orden['productos'][indexProducto]; 
    TextEditingController precioController = TextEditingController();
    
    // 🚀 Calculamos el Total original de este producto (precio x cantidad)
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

                // 🚀 Verificamos que el nuevo total sea válido y menor al anterior
                if (nuevoTotalProducto != null && nuevoTotalProducto >= 0 && nuevoTotalProducto < totalOriginalProducto) {
                  setState(() {
                    if (prod['precio_original'] == null) {
                      prod['precio_original'] = precioOriginalUnitario;
                    }
                    
                    // 🚀 El porcentaje se saca del total
                    double porcentaje = ((totalOriginalProducto - nuevoTotalProducto) / totalOriginalProducto) * 100;
                    prod['descuento'] = porcentaje.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
                    
                    // 🚀 Modificamos el precio unitario para que al multiplicar por la cantidad nos dé tu nuevo total
                    prod['precio'] = nuevoTotalProducto / cantidad;

                    // 🚀 Recalcular el total general de todo el viaje
                    double nuevoTotal = 0;
                    for (var p in orden['productos']) {
                      nuevoTotal += (double.tryParse(p['precio'].toString()) ?? 0) * (double.tryParse(p['cantidad'].toString()) ?? 0);
                    }
                    orden['total'] = nuevoTotal;
                  });
                }
                Navigator.pop(ctx);
              },
              child: const Text('Descontar', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      }
    );
  }

  List<Widget> _construirListaOrdenes(List<dynamic> ordenesLista, bool isDarkMode, BuildContext context) {
    return ordenesLista.map((orden) {
      List<dynamic> productos = orden['productos'] ?? [];

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(orden['viaje_programado'] ?? "Viaje Inmediato", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 14, fontWeight: FontWeight.bold)),
          if (orden['nombre_repartidor'] != null)
            Text("Repartidor: ${orden['nombre_repartidor']}", style: const TextStyle(fontSize: 12, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDarkMode ? Colors.grey[800] : const Color(0xFFBDBDBD), 
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: List.generate(productos.length, (indexProd) {
                var prod = productos[indexProd];
                bool tieneDescuento = prod['descuento'] != null;

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _modoDescuento ? () => _mostrarDialogoDescuento(orden, indexProd) : null,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: EdgeInsets.all(_modoDescuento ? 6.0 : 0),
                      margin: const EdgeInsets.only(bottom: 8.0),
                      decoration: BoxDecoration(
                        border: _modoDescuento ? Border.all(color: Colors.orangeAccent, width: 2) : Border.all(color: Colors.transparent, width: 2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 50, height: 50,
                            decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(12)),
                            clipBehavior: Clip.hardEdge,
                            // ✅ CÓDIGO OPTIMIZADO
child: (prod['imagenBytes'] != null)
  ? Image.memory(
      prod['imagenBytes'], 
      fit: BoxFit.cover, 
      cacheWidth: 100, 
      errorBuilder: (c,e,s) => const Icon(Icons.image, color: Colors.white)
    )
  : const Icon(Icons.image, color: Colors.white),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(prod['nombre_producto'] ?? prod['nombre'], style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 14)),
                                const SizedBox(height: 2),
                                
                                if (tieneDescuento)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 2.0),
                                    child: Row(
                                      children: [
                                        Text("\$${prod['precio_original']} MXN", style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                          decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(4)),
                                          child: Text("-${prod['descuento']}%", style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                  ),
                                
                                Text("\$${double.parse(prod['precio'].toString()).toStringAsFixed(2)} MXN POR UNIDAD", style: TextStyle(color: tieneDescuento ? Colors.green : (isDarkMode ? Colors.white70 : Colors.black54), fontSize: 10, fontWeight: tieneDescuento ? FontWeight.bold : FontWeight.normal)),
                              ],
                            ),
                          ),
                          Text("${prod['cantidad']} u.", style: TextStyle(color: isDarkMode ? Colors.white : Colors.black87, fontSize: 12)),
                          const SizedBox(width: 12),
                          Text("Total: \$${((double.tryParse(prod['precio'].toString()) ?? 0) * (double.tryParse(prod['cantidad'].toString()) ?? 0)).toStringAsFixed(2)}", 
                            style: TextStyle(color: isDarkMode ? Colors.white : Colors.black, fontSize: 14, fontWeight: FontWeight.bold)
                          ),
                          
                          // 🚀 BOTÓN DE REVERTIR AL LADO DEL TOTAL (Solo sale en Modo Descuento)
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
            child: Text("Total del viaje: \$${double.parse(orden['total'].toString()).toStringAsFixed(2)}", style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          
          const SizedBox(height: 24),
          const Divider(),
        ],
      );
    }).toList();
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Descuentos guardados. El trabajador ya puede verlos.', style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green));
      }
    } catch (e) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    double granTotal = 0;
    bool todoCobrado = true;

    List<dynamic> ordenesNormales = [];
    List<dynamic> ordenesRescate = [];
    String? responsableDelDia;

    // 🚀 AHORA ITERAMOS SOBRE LA LISTA MODIFICADA LOCALMENTE
    for (var orden in _ordenesModificadas) {
      granTotal += double.tryParse(orden['total'].toString()) ?? 0;
      if (orden['estado'] != 'Cobrado') {
        todoCobrado = false;
      }
      
      if (responsableDelDia == null && orden['responsable'] != null) {
        responsableDelDia = orden['responsable'];
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
    
    bool mostrarBotonesCobro = true; 

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor, 
        elevation: 0, 
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.idTicket, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text(widget.nombreLocal, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
      ),
      body: SafeArea(
        child: _isLoading 
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
                color: isDarkMode ? const Color(0xFFCFD8DC) : const Color(0xFFE0E0E0), 
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "TOTAL DEL DÍA: \$${granTotal.toStringAsFixed(2)} MXN", 
                    style: const TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.bold)
                  ),
                  
                  if (responsableDelDia != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        "Responsable: $responsableDelDia", 
                        style: const TextStyle(color: Colors.green, fontSize: 16, fontWeight: FontWeight.bold)
                      ),
                    ),
                  
                  const SizedBox(height: 16),

                  if (todoCobrado)
                    const Text("✅ TICKET COBRADO", style: TextStyle(color: Colors.green, fontSize: 16, fontWeight: FontWeight.bold))
                  else if (mostrarBotonesCobro) 
                    Row(
                      children: [
                        // 🚀 BOTÓN DE DESCUENTO / DESCONTAR
                        Expanded(
                          flex: 1, 
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _modoDescuento ? Colors.redAccent : Colors.orange, 
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12)
                            ),
                            icon: Icon(_modoDescuento ? Icons.save : Icons.percent, size: 20),
                            label: Text(_modoDescuento ? "Descontar" : "Descuento", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            onPressed: () {
                              if (_modoDescuento) {
                                _guardarDescuentos(); // 🚀 Guarda en la BD
                              } else {
                                setState(() { _modoDescuento = true; }); // 🚀 Entra en modo edición
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2, 
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              // 🚀 Se pone gris y se deshabilita si estás en medio de un descuento
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
                    const Text("⏳ El corte de hoy se habilitará a las 7:00 PM", 
                      style: TextStyle(color: Colors.black54, fontStyle: FontStyle.italic, fontWeight: FontWeight.bold)
                    ),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }
}