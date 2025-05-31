// packages/flutter_blue_plus/example/lib/screens/login_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus_example/screens/scan_screen.dart';
import 'package:flutter_blue_plus_example/utils/snackbar.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  void _login() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    // Simple validation for demonstration
    if (username.isEmpty || password.isEmpty) {
      Snackbar.show(ABC.a, "Please enter username and password", success: false);
      return;
    }

    // You would typically validate credentials with a backend here
    // For this example, we'll just proceed if fields are not empty
    Snackbar.show(ABC.a, "Login Successful! Scanning for devices...", success: true);

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => ScanScreen(
          initialDeviceNameToConnect: username, // Pass username as device name to connect
          username: username, // Truyền username
          password: password, // Truyền password
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: Snackbar.snackBarKeyA, // Use a specific key for this screen
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Login'),
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Thêm Image.asset vào đây
                Image.asset(
                  'assets/images/logo_xhx_full.png', // Thay 'your_logo.png' bằng tên file ảnh của bạn
                  height: 120, // Điều chỉnh chiều cao theo ý muốn
                  width: 120, // Điều chỉnh chiều rộng theo ý muốn
                ),
                const SizedBox(height: 30), // Khoảng cách giữa logo và trường nhập liệu đầu tiên
                // Kết thúc phần thêm logo
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username (BLE Device Name)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16.0),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24.0),
                ElevatedButton(
                  onPressed: _login,
                  child: const Text('Login'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
