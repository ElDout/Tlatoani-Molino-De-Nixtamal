import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';
import 'package:molino_app/NuevaTortilleria.dart'; 
import 'package:molino_app/PanelTortilleria.dart'; 

class TortillasScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  const TortillasScreen({super.key, required this.onThemeChanged});

  @override
  State<TortillasScreen> createState() => _TortillasScreenState();
}

class _TortillasScreenState extends State<TortillasScreen> {
  List<dynamic> _tortillerias = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _obtenerTortillerias();
  }

  Future<void> _obtenerTortillerias() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('${AppConfig.apiHost}/tortillerias')).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        if (mounted) setState(() { _tortillerias = jsonDecode(response.body); });
      }
    } catch (e) {
      debugPrint('Error obteniendo tortillerías: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _eliminarTortilleria(int id) async {
    bool confirmar = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar Local'),
        content: const Text('¿Estás seguro de que quieres eliminar esta tortillería?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar', style: TextStyle(color: Colors.white))),
        ],
      ),
    ) ?? false;

    // 🚀 OPTIMIZACIÓN CLAVE: Evita crash si el admin cierra la pantalla mientras el diálogo está abierto
    if (!mounted) return; 

    if (!confirmar) return;

    setState(() => _isLoading = true);
    try {
      await http.delete(Uri.parse('${AppConfig.apiHost}/tortillerias/$id'));
      _obtenerTortillerias();
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _irANuevaTortilleria() async {
    final bool? seGuardo = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => NuevaTortilleriaScreen(onThemeChanged: widget.onThemeChanged)),
    );
    
    // 🚀 OPTIMIZACIÓN CLAVE: Protege la RAM y el ciclo de vida al volver
    if (!mounted) return; 
    
    if (seGuardo == true) {
      _obtenerTortillerias();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0, centerTitle: true,
        title: Text('Tortillerias', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
        iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onSurface),
      ),
      body: RefreshIndicator(
        onRefresh: _obtenerTortillerias, 
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDarkMode ? const Color(0xFFCFD8DC) : Colors.white,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 60),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                ),
                onPressed: _irANuevaTortilleria,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('Añadir Tortillería', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    SizedBox(width: 12),
                    Icon(Icons.add, size: 24),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _tortillerias.isEmpty
                    ? ListView(
                        children: [
                          SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                          Center(child: Text('No hay tortillerías registradas.', style: TextStyle(color: isDarkMode ? Colors.white54 : Colors.black54))),
                        ],
                      )
                    : ListView.builder(
                        itemCount: _tortillerias.length,
                        itemBuilder: (context, index) {
                          final tortilleria = _tortillerias[index];
                          return Card(
                            color: isDarkMode ? Colors.grey[800] : Colors.grey[300],
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: Container(
                                width: 50, height: 50,
                                decoration: BoxDecoration(color: Colors.blueGrey, borderRadius: BorderRadius.circular(8)),
                                child: const Icon(Icons.storefront, color: Colors.white),
                              ),
                              title: Text(tortilleria['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => PanelTortilleriaScreen(
                                      tortilleria: tortilleria,
                                      onThemeChanged: widget.onThemeChanged,
                                    ),
                                  ),
                                );
                              },
                              trailing: IconButton(
                                icon: const Icon(Icons.delete, color: Colors.redAccent),
                                onPressed: () => _eliminarTortilleria(tortilleria['id']),
                              ),
                            ),
                          );
                        }
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}