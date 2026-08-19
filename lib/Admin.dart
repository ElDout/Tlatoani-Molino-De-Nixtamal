import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:molino_app/Login.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molino_app/RegistroAdmin.dart';
import 'package:molino_app/Mercancia.dart';
import 'package:molino_app/Usuarios.dart';
import 'package:molino_app/AdminOrdenes.dart';
import 'package:molino_app/config.dart';
import 'package:molino_app/TicketsAdmin.dart';
import 'package:molino_app/PerfilScreen.dart';
import 'package:molino_app/Tortillas.dart'; 
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:molino_app/NotificacionesHelper.dart';
import 'package:molino_app/config.dart';

class AdminScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;

  const AdminScreen({super.key, required this.onThemeChanged});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  Uint8List? _imagenBytes;
  String _nombreAdmin = "Administrador";
  IO.Socket? _socket;

  @override
void initState() {
  super.initState();
  _cargarDatosUsuario();
  _conectarSocketGlobal();
}

void _conectarSocketGlobal() {
  _socket = IO.io(AppConfig.apiHost, <String, dynamic>{
    'transports': ['websocket'],
    'autoConnect': true,
  });

  // Notificación 1: Nuevo Pedido
  _socket!.on('notify_nuevo_pedido', (data) {
    if (mounted) {
      NotificacionesHelper.mostrarNotificacion(
        titulo: 'Nuevo Pedido 📦',
        cuerpo: 'El usuario ${data['cliente']} acaba de hacer un pedido.',
        payload: {'tipo': 'admin_nuevo', 'id_orden': data['id_orden'].toString()}
      );
    }
  });

  // Notificación 2: Recogido
  _socket!.on('notify_pedido_recogido', (data) {
    if (mounted) {
      NotificacionesHelper.mostrarNotificacion(
        titulo: 'Pedido Recogido 🛵',
        cuerpo: '${data['nombre_repartidor']} recogió un pedido.',
        payload: {'tipo': 'admin_recogido', 'id_orden': data['id_orden'].toString()}
      );
    }
  });

  // Notificación 3: Faltantes
  _socket!.on('notify_mercancia_modificada', (data) {
    if (mounted) {
      NotificacionesHelper.mostrarNotificacion(
        titulo: 'Faltantes Reportados ⚠️',
        cuerpo: 'Un repartidor marcó que hay faltantes.',
        payload: {'tipo': 'admin_faltante', 'id_orden': data['id_orden'].toString()}
      );
    }
  });

  // Notificación 4: Completado
  _socket!.on('notify_pedido_completado', (data) {
    if (mounted) {
      NotificacionesHelper.mostrarNotificacion(
        titulo: 'Pedido Completado ✅',
        cuerpo: '${data['repartidor']} completó el pedido.',
        payload: {'tipo': 'admin_completado', 'id_orden': data['id_orden'].toString()}
      );
    }
  });

  // Notificación 5: Edición Predeterminado
  _socket!.on('notify_solicitud_edicion', (data) {
    if (mounted) {
      NotificacionesHelper.mostrarNotificacion(
        titulo: 'Edición de Predeterminado 📝',
        cuerpo: '${data['tortilleria']} solicita editar su pedido.',
        payload: {'tipo': 'admin_solicitud_edicion', 'id_orden': data['id_orden'].toString()}
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
    
    // Obtenemos los datos primero
    final nombre = prefs.getString('userUser') ?? prefs.getString('userName') ?? 'Administrador';
    final base64Str = prefs.getString('userImage');
    
    Uint8List? bytesDecodificados;
    
    if (base64Str != null && base64Str.isNotEmpty) {
      bytesDecodificados = base64Decode(base64Str); 
    }

    // Actualizamos el estado solo una vez con los datos ya procesados
    setState(() {
      _nombreAdmin = nombre;
      _imagenBytes = bytesDecodificados;
    });
  }

  Future<void> _cerrarSesion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => LoginScreen(onThemeChanged: widget.onThemeChanged)),
      (Route<dynamic> route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        // Agregué el botón de cerrar sesión en el lado derecho (actions)
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            onPressed: _cerrarSesion,
            tooltip: 'Cerrar Sesión',
          )
        ],
        leading: GestureDetector(
          onTap: () {
            Navigator.push(
              context, 
              MaterialPageRoute(builder: (context) => PerfilScreen(onThemeChanged: widget.onThemeChanged))
            ).then((_) => _cargarDatosUsuario());
          },
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0052CC), 
                borderRadius: BorderRadius.circular(8.0)
              ),
              clipBehavior: Clip.hardEdge,
              child: _imagenBytes != null 
                  // Optimización clave: cacheWidth reduce el tamaño de la imagen en RAM
                  ? Image.memory(
                      _imagenBytes!, 
                      fit: BoxFit.cover,
                      cacheWidth: 150, // Ajusta este valor al tamaño aproximado del contenedor
                    ) 
                  : const Icon(Icons.person, color: Colors.white),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 56.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Bienvenido $_nombreAdmin', 
                textAlign: TextAlign.center, 
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w400)
              ),
              const SizedBox(height: 32), 
              
              _crearBotonMenu('Ordenes', pantallaDestino: OrdenesAdmin(onThemeChanged: widget.onThemeChanged)),
              const SizedBox(height: 16),
              
              _crearBotonMenu('Tickets', pantallaDestino: TicketsAdminScreen(onThemeChanged: widget.onThemeChanged)),
              const SizedBox(height: 16),
              
              _crearBotonMenu('Mercancia', pantallaDestino: MercanciaScreen(onThemeChanged: widget.onThemeChanged)),
              const SizedBox(height: 16),

              _crearBotonMenu('Tortillerias', pantallaDestino: TortillasScreen(onThemeChanged: widget.onThemeChanged)),
              const SizedBox(height: 16),
              
              _crearBotonMenu('Usuarios', pantallaDestino: UsuariosScreen(onThemeChanged: widget.onThemeChanged)),
              const SizedBox(height: 16),
              
              _crearBotonMenu('Registro Clientes', pantallaDestino: const RegistroClientesScreen()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _crearBotonMenu(String titulo, {Widget? pantallaDestino}) {
    return ElevatedButton(
      onPressed: pantallaDestino != null ? () {
        Navigator.push(context, MaterialPageRoute(builder: (context) => pantallaDestino));
      } : null,
      child: Text(titulo, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
    );
  }
}