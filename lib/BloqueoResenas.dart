import 'dart:convert';
import 'dart:typed_data'; // 🚀 Añadido para manejar la imagen en memoria
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';
import 'package:molino_app/Clientes.dart';
import 'package:molino_app/Trabajadadores.dart'; // Ajusta el nombre si tu archivo se llama distinto

class BloqueoResenasScreen extends StatefulWidget {
  final Map<String, dynamic> orden;
  final Function(ThemeMode) onThemeChanged;
  final String rol; // Puede ser 'cliente' o 'trabajador'

  const BloqueoResenasScreen({
    super.key,
    required this.orden,
    required this.onThemeChanged,
    required this.rol,
  });

  @override
  State<BloqueoResenasScreen> createState() => _BloqueoResenasScreenState();
}

class _BloqueoResenasScreenState extends State<BloqueoResenasScreen> {
  int _estrellasPedido = 0;
  int _estrellasRepartidor = 0;
  final TextEditingController _comentarioCtrl = TextEditingController();
  bool _isLoading = false;
  
  // 🚀 Variable para almacenar la imagen precargada
  Uint8List? _fotoRepartidorBytes;

  @override
  void initState() {
    super.initState();
    // 🚀 Decodificamos la foto UNA SOLA VEZ al abrir la pantalla
    if (widget.orden['foto_repartidor'] != null && widget.orden['foto_repartidor'].isNotEmpty) {
      try {
        _fotoRepartidorBytes = base64Decode(widget.orden['foto_repartidor'].replaceAll(RegExp(r'\s+'), ''));
      } catch (e) {
        _fotoRepartidorBytes = null;
      }
    }
  }

  @override
  void dispose() {
    // 🚀 IMPORTANTE: Destruimos el controlador de texto para liberar la RAM
    _comentarioCtrl.dispose();
    super.dispose();
  }

  Future<void> _enviarResena() async {
    if (_estrellasPedido == 0 || _estrellasRepartidor == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Por favor califica con estrellas ambas secciones.')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final res = await http.put(
        Uri.parse('${AppConfig.apiHost}/ordenes/resena/${widget.orden['id']}'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'calificacion_pedido': _estrellasPedido,
          'calificacion_repartidor': _estrellasRepartidor,
          'comentario_repartidor': _comentarioCtrl.text.trim()
        })
      );

      if (res.statusCode == 200) {
        if (!mounted) return;
        // 🚀 LIBERAMOS AL USUARIO Y LO REGRESAMOS A SU PANTALLA
        if (widget.rol == 'cliente') {
          Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => ClientesScreen(onThemeChanged: widget.onThemeChanged)), (route) => false);
        } else {
          Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => TrabajadoresScreen(onThemeChanged: widget.onThemeChanged)), (route) => false);
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al enviar la reseña')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildEstrellas(int valorActual, Function(int) onChanged) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (index) {
        return IconButton(
          iconSize: 40,
          icon: Icon(
            index < valorActual ? Icons.star : Icons.star_border,
            color: Colors.amber,
          ),
          onPressed: () => onChanged(index + 1),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    return WillPopScope(
      onWillPop: () async => false, // 🔒 BLOQUEO TOTAL: No pueden usar el botón de retroceso del celular
      child: Scaffold(
        body: SafeArea(
          child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 20),
                    const Icon(Icons.check_circle, color: Colors.green, size: 80),
                    const SizedBox(height: 16),
                    const Text('¡Tu pedido ha sido entregado!', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    const Text('Por favor, califica tu experiencia para continuar.', style: TextStyle(color: Colors.grey), textAlign: TextAlign.center),
                    const SizedBox(height: 32),
                    
                    // ⭐ CALIFICACIÓN DEL PRODUCTO
                    const Text('¿Qué te pareció el pedido / producto?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildEstrellas(_estrellasPedido, (val) => setState(() => _estrellasPedido = val)),
                    
                    const Divider(height: 40, thickness: 1),

                    // ⭐ CALIFICACIÓN DEL REPARTIDOR
                    Container(
                      width: 80, height: 80,
                      decoration: const BoxDecoration(color: Colors.blueAccent, shape: BoxShape.circle),
                      clipBehavior: Clip.hardEdge,
                      child: _fotoRepartidorBytes != null // 🚀 Usamos la variable optimizada
                          ? Image.memory(
                              _fotoRepartidorBytes!,
                              fit: BoxFit.cover, 
                              cacheWidth: 150, // 🚀 Ahorramos memoria RAM
                              errorBuilder: (c,e,s) => const Icon(Icons.person, color: Colors.white, size: 40)
                            )
                          : const Icon(Icons.person, color: Colors.white, size: 40),
                    ),
                    const SizedBox(height: 12),
                    Text('¿Cómo calificas a ${widget.orden['nombre_repartidor'] ?? 'tu repartidor'}?', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    _buildEstrellas(_estrellasRepartidor, (val) => setState(() => _estrellasRepartidor = val)),
                    const SizedBox(height: 16),

                    // 📝 CAJA DE COMENTARIOS
                    TextField(
                      controller: _comentarioCtrl,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: 'Escribe un comentario sobre el servicio del repartidor (Opcional)...',
                        filled: true,
                        fillColor: isDarkMode ? Colors.grey[800] : Colors.grey[200],
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)
                      ),
                    ),
                    const SizedBox(height: 40),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0052CC), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        onPressed: _enviarResena,
                        child: const Text('ENVIAR Y CONTINUAR', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    )
                  ],
                ),
              ),
        ),
      ),
    );
  }
}