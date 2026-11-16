import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'main.dart';
import 'preference_service.dart';

class UsernameSetupScreen extends StatefulWidget {
  const UsernameSetupScreen({super.key});

  @override
  State<UsernameSetupScreen> createState() => _UsernameSetupScreenState();
}

class _UsernameSetupScreenState extends State<UsernameSetupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
  bool _obscureSecret = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final name = await PreferenceService.getUsername();
    final secret = await PreferenceService.getRoomSecret();
    if (mounted) {
      setState(() {
        _nameController.text = name ?? '';
        _secretController.text = secret ?? '';
      });
    }
  }

  Future<void> _saveAndContinue() async {
    final name = _nameController.text.trim();
    final secret = _secretController.text.trim();

    if (name.isEmpty || secret.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter both a Tablet Name and the Family Room Secret.'),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    await PreferenceService.saveSettings(
      username: name,
      roomSecret: secret,
    );
    savedUsername = name;

    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('reconnect');
    } else {
      await service.startService();
    }

    if (!mounted) return;
    setState(() => _isSaving = false);

    Navigator.of(context).pushReplacementNamed('/');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bisnan Calling Setup')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Connect Family Tablet',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Tablet Name (e.g. Living Room Tablet)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.tablet_android),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _secretController,
                  obscureText: _obscureSecret,
                  decoration: InputDecoration(
                    labelText: 'Family Room Secret',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureSecret ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () {
                        setState(() => _obscureSecret = !_obscureSecret);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _isSaving ? null : _saveAndContinue,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: _isSaving
                      ? const CircularProgressIndicator()
                      : const Text('Save & Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
