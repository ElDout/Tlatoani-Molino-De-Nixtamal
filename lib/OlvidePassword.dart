import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:molino_app/config.dart';

class OlvidePasswordScreen extends StatefulWidget {
  final Function(ThemeMode) onThemeChanged;
  const OlvidePasswordScreen({super.key, required this.onThemeChanged});

  @override
  State<OlvidePasswordScreen> createState() => _OlvidePasswordScreenState();
}

class _OlvidePasswordScreenState extends State<OlvidePasswordScreen> {
  final TextEditingController _correoController = TextEditingController();
  bool _isLoading = false;

  // 🚀 OPTIMIZACIÓN CLAVE: Destruimos el controlador para liberar RAM
  @override
  void dispose() {
    _correoController.dispose();
    super.dispose();
  }

  Future<void> _enviarRecuperacion() async {
    if (_correoController.text.isEmpty) return;
    setState(() => _isLoading = true);

    try {
      final response = await http.post(
        Uri.parse('${AppConfig.apiHost}/recuperar-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'correo': _correoController.text.trim()}),
      );

      if (response.statusCode == 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Se ha enviado un enlace a tu correo.')));
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('El correo no existe o hubo un error.')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error de conexión.')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recuperar Contraseña'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Ingresa tu correo electrónico registrado. Te enviaremos tu contraseña o un enlace para restablecerla.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _correoController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(hintText: 'ejemplo@correo.com'),
            ),
            const SizedBox(height: 32),
            _isLoading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: _enviarRecuperacion,
                    child: const Text('Enviar'),
                  ),
          ],
        ),
      ),
    );
  }
}