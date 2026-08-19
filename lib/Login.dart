import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/Registrarse.dart';
import 'package:molino_app/Admin.dart';
import 'package:molino_app/Clientes.dart'; 
import 'package:molino_app/Repartidores.dart'; 
import 'package:molino_app/Trabajadadores.dart';
import 'package:molino_app/config.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:molino_app/RegistroMolino.dart'; 
import 'package:molino_app/OlvidePassword.dart';

// 👇 IMPORTAMOS FIREBASE MESSAGING
import 'package:firebase_messaging/firebase_messaging.dart';

class LoginScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;

  const LoginScreen({super.key, required this.onThemeChanged});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isPasswordVisible = false;
  bool _isLoading = false;

  final TextEditingController _usuarioController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  // 🚀 OPTIMIZACIÓN CLAVE: Destruimos los controladores para liberar RAM
  @override
  void dispose() {
    _usuarioController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _iniciarSesion() async {
    final String usuario = _usuarioController.text.trim();
    final String password = _passwordController.text.trim();

    if (usuario.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor llena todos los campos')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final url = Uri.parse('${AppConfig.apiHost}/login');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'usuario': usuario, 'password': password}),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode == 200 && data['success'] == true) {
        final user = data['user'];
        
        final prefs = await SharedPreferences.getInstance();

        await prefs.setBool('isLoggedIn', true);
        await prefs.setInt('userId', user['id']);
        await prefs.setString('userRole', user['rol'] ?? 'cliente');

        // Guardar toda la info al iniciar sesión
        String nombreReal = user['nombre_propietario'] ?? user['nombres'] ?? user['nombre'] ?? 'Usuario';
        await prefs.setString('userName', nombreReal);
        await prefs.setString('userUser', user['usuario'] ?? '');
        await prefs.setString('userPhone', user['telefono'] ?? '');
        await prefs.setString('userEmail', user['correo'] ?? '');
        await prefs.setString('userImage', user['imagen'] ?? '');
        
        // 🚀🚀🚀 MAGIA: PEDIR TOKEN Y GUARDAR EN POSTGRES 🚀🚀🚀
        try {
          String? token = await FirebaseMessaging.instance.getToken();
          if (token != null) {
            await http.put(
              Uri.parse('${AppConfig.apiHost}/perfil/fcm-token'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'id': user['id'],
                'rol': user['rol'] ?? 'cliente',
                'fcm_token': token
              }),
            );
            debugPrint("Token FCM registrado en BD: $token");
          }
        } catch (e) {
          debugPrint("Error guardando token: $e");
        }
        // 🚀🚀🚀 FIN DE MAGIA 🚀🚀🚀

        if (!mounted) return;
        
        // 👈 EL DETECTOR: Si no es cliente y no tiene correo, lo mandamos a completar su perfil
        if (user['rol'] != 'cliente' && (user['correo'] == null || user['correo'].toString().isEmpty)) {
          Navigator.pushReplacement(
            context, 
            MaterialPageRoute(builder: (context) => RegistroMolinoScreen(
              onThemeChanged: widget.onThemeChanged, 
              userData: user, // Le pasamos los datos que ya tenemos (id, rol, nombre)
            ))
          );
          return;
        }

        // Si todo está bien, sigue el flujo normal...
        if (user['rol'] == 'admin') {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => AdminScreen(onThemeChanged: widget.onThemeChanged)));
        } else if (user['rol'] == 'repartidor') {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => RepartidoresScreen(onThemeChanged: widget.onThemeChanged)));
        } else if (user['rol'] == 'trabajador') {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => TrabajadoresScreen(onThemeChanged: widget.onThemeChanged)));
        } else {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => ClientesScreen(onThemeChanged: widget.onThemeChanged)));
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message'] ?? 'Error al iniciar sesión')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error de conexión con el servidor')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: PopupMenuButton(
          icon: Icon(Icons.settings, color: Theme.of(context).colorScheme.onSurface),
          itemBuilder: (context) => [
            PopupMenuItem(
              enabled: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Modo Oscuro'),
                  Switch(
                    value: isDarkMode,
                    onChanged: (value) {
                      widget.onThemeChanged(value ? ThemeMode.dark : ThemeMode.light);
                      Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(height: MediaQuery.of(context).size.height * 0.02),
              
              // 🚀 LOGO OPTIMIZADO PARA NO SATURAR LA RAM
              Center(
                child: Image.asset(
                  'assets/fulllogo_transparent_nobuffer.png',
                  height: 140, 
                  cacheHeight: 300, // 👈 Evita tirones al abrir el teclado
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 24),
              
              const Center(child: Text('Bienvenido', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold))),
              const SizedBox(height: 8),
              const Center(child: Text('Iniciar Sesión', style: TextStyle(fontSize: 18, color: Colors.grey))),
              const SizedBox(height: 48),
              
              const Text('Usuario', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextField(controller: _usuarioController, decoration: const InputDecoration(hintText: 'Ingrese su usuario')),
              const SizedBox(height: 24),
              
              const Text('Contraseña', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: !_isPasswordVisible,
                decoration: InputDecoration(
                  hintText: 'Ingrese su contraseña',
                  suffixIcon: IconButton(
                    icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off),
                    onPressed: () { setState(() { _isPasswordVisible = !_isPasswordVisible; }); },
                  ),
                ),
              ),
              const SizedBox(height: 48),
              
              _isLoading 
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _iniciarSesion, 
                    child: const Text('Iniciar Sesión', style: TextStyle(fontSize: 16)),
                  ),
                  
              const SizedBox(height: 24),
              Center(
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (context) => RegistrarseScreen(onThemeChanged: widget.onThemeChanged)));
                  },
                  child: Text('¿No tienes cuenta? Regístrate', style: TextStyle(color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline)),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (context) => OlvidePasswordScreen(onThemeChanged: widget.onThemeChanged)));
                  },
                  child: Text(
                    '¿Olvidaste tu contraseña?', 
                    style: TextStyle(color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline)
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}