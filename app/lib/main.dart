import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'package:call/username_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_handler.dart';
import 'video_call_screen.dart';

const String appReleaseTag = "v1.0.6";

String? savedUsername;
String? savedRoomSecret;
final StreamController<String> globalSignalStream =
    StreamController<String>.broadcast();

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final Map<String, List<Map<String, dynamic>>> globalPendingCandidates = {};

@pragma('vm:entry-point')
void ntp(NotificationResponse response) {
  // Handle background event execution
}

void minimizeAppToSystemTray() {
  const platform = MethodChannel('flutter/platform');
  platform.invokeMethod('SystemNavigator.pop');
}

@pragma('vm:entry-point')
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final SharedPreferences prefs = await SharedPreferences.getInstance();
  savedUsername = prefs.getString('saved_username');
  savedRoomSecret = prefs.getString('family_room_secret');

  FlutterCallkitIncoming.onEvent.listen((CallEvent? event) {
    if (event == null) return;
    if (event.event == Event.ACTION_CALL_DECLINE ||
        event.event == Event.ACTION_CALL_TIMEOUT) {
      final body = event.body is Map
          ? Map<String, dynamic>.from(event.body)
          : {};
      final callerId = body['id']?.toString();
      FlutterBackgroundService().invoke('notificationAction', {
        'action': 'decline',
        'targetId': callerId,
      });
    }
  });

  runApp(const MyApp());

  scheduleMicrotask(() async {
    await initializeBackgroundService(savedUsername);
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final bool needsSetup =
        savedUsername == null ||
        savedUsername!.isEmpty ||
        savedRoomSecret == null ||
        savedRoomSecret!.isEmpty;

    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Bisnan Calling',
      theme: ThemeData(brightness: Brightness.dark),
      initialRoute: needsSetup ? '/username' : '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/call': (context) => const VideoCallScreen(),
        '/username': (context) => const UsernameSetupScreen(),
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isOnline = false;
  bool _isReconnecting = false;
  StreamSubscription? _serviceSubscription;
  List<dynamic> _discoveredNetworkPeers = [];
  String? _myRegisteredId;
  bool _isProcessingNavigationLock = false;
  ReceivePort? _uiReceivePort;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _serviceSubscription?.cancel();
    _bindCommunicationChannel();
    _syncBackgroundStatus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncBackgroundStatus();
    }
  }

  Future<void> _syncBackgroundStatus() async {
    for (int i = 0; i < 4; i++) {
      if (!mounted || _isOnline) return;
      try {
        FlutterBackgroundService().invoke('checkStatus');
      } catch (e) {
        debugPrint("checkStatus invoke error: $e");
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // If UI engine was recreated by Android and the old channel detached, re-attach cleanly
    if (mounted && !_isOnline) {
      _serviceSubscription?.cancel();
      _bindCommunicationChannel();
      FlutterBackgroundService().invoke('reconnect');
    }
  }

  Future<void> _handleManualReconnect() async {
    if (_isReconnecting) return;

    setState(() {
      _isReconnecting = true;
      _isOnline = false;
    });

    try {
      FlutterBackgroundService().invoke('reconnect');
    } catch (e) {
      debugPrint("--> Reconnect failed to dispatch: $e");
    }

    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() {
        _isReconnecting = false;
      });
    }
  }

  void _bindCommunicationChannel() {
    // 1. Direct native Dart port (survives Activity destroy/recreate 100% of the time)
    IsolateNameServer.removePortNameMapping(BackgroundEngineState.uiPortName);
    _uiReceivePort = ReceivePort();
    IsolateNameServer.registerPortWithName(
      _uiReceivePort!.sendPort,
      BackgroundEngineState.uiPortName,
    );
    _uiReceivePort!.listen((message) {
      if (message is String) {
        _handleIncomingSignal(message);
      }
    });

    // 2. Standard flutter_background_service channel
    _serviceSubscription = FlutterBackgroundService()
        .on('onSignalReceived')
        .listen((event) {
          if (event == null || event['data'] == null) return;
          _handleIncomingSignal(event['data'] as String);
        });
  }

  void _handleIncomingSignal(String rawJson) {
    if (!globalSignalStream.isClosed) {
      globalSignalStream.add(rawJson);
    }
    if (!mounted) return;
    var data = jsonDecode(rawJson);

    if (data['type'] == 'ice-candidate' && data['senderId'] != null) {
      if (!VideoCallScreen.isActive) {
        globalPendingCandidates
            .putIfAbsent(data['senderId'].toString(), () => [])
            .add(Map<String, dynamic>.from(data));
      }
    }

    if (data['type'] == 'network-offline') {
      setState(() {
        _isOnline = false;
        _discoveredNetworkPeers = [];
        _isProcessingNavigationLock = false;
      });
      return;
    }

    if (!_isOnline || _isReconnecting) {
      setState(() {
        _isOnline = true;
        _isReconnecting = false;
      });
    }

    if (data['type'] == 'registered') {
      setState(() {
        _myRegisteredId = data['id'];
      });
      debugPrint(
        "--> UI Isolate successfully captured its own ID: $_myRegisteredId",
      );
    }

    if (data['type'] == 'hangup') {
      setState(() {
        _isProcessingNavigationLock = false;
      });
      return;
    }

    if (data['type'] == 'accept-from-notification') {
      debugPrint("--> UI Isolate captured notification answer tap.");

      if (!_isProcessingNavigationLock) {
        _isProcessingNavigationLock = true;

        final sdpPayload = data['sdp'];
        final senderIdPayload = data['senderId'] ?? 'browser_node';

        Navigator.pushNamed(
          context,
          '/call',
          arguments: {
            'sdp': sdpPayload,
            'senderId': senderIdPayload,
            'myRegisteredId':
                _myRegisteredId ?? data['targetId'] ?? 'unknown_tablet',
          },
        ).then((res) {
          if (mounted) {
            setState(() {
              _isProcessingNavigationLock = false;
            });
          }
        });
      }
      return;
    }

    if (data['type'] == 'mesh-peer-list') {
      setState(() {
        _discoveredNetworkPeers = data['peers'] ?? [];
      });
      debugPrint(
        "--> UI Rebuilt! Found ${_discoveredNetworkPeers.length} total raw nodes.",
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    IsolateNameServer.removePortNameMapping(BackgroundEngineState.uiPortName);
    _uiReceivePort?.close();
    _serviceSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seenNames = <String>{};
    final activeCallTargets = _discoveredNetworkPeers.where((peer) {
      final id = peer['id']?.toString();
      final name = peer['name']?.toString() ?? id ?? 'Unknown';
      if (_myRegisteredId != null && id == _myRegisteredId) return false;
      if (seenNames.contains(name)) return false;
      seenNames.add(name);
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Bisnan Video Call"),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Change Name or Secret',
            onPressed: () {
              Navigator.pushNamed(context, '/username');
            },
          ),
        ],
      ),
      bottomNavigationBar: const Padding(
        padding: EdgeInsets.only(bottom: 12.0),
        child: Text(
          appReleaseTag,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            activeCallTargets.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _isOnline ? "🟢" : "🔴",
                          style: const TextStyle(fontSize: 60),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _isOnline ? "Online" : "Offline",
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                          ),
                        ),
                        if (!_isOnline) ...[
                          const SizedBox(height: 24),
                          _isReconnecting
                              ? const CircularProgressIndicator()
                              : ElevatedButton.icon(
                                  onPressed: _handleManualReconnect,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text("Reconnect Service"),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                        ],
                      ],
                    ),
                  )
                : Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: activeCallTargets.length,
                      itemBuilder: (context, index) {
                        final peer = activeCallTargets[index];
                        final String peerId = peer['id'] ?? 'Unknown';
                        final String peerName = peer['name'] ?? 'Unknown';
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32.0,
                            vertical: 10.0,
                          ),
                          child: SizedBox(
                            width: double.infinity,
                            height: 76,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade600,
                                foregroundColor: Colors.white,
                                elevation: 6,
                                shadowColor: Colors.greenAccent.withValues(
                                  alpha: 0.4,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                              icon: const Icon(Icons.phone, size: 36),
                              label: Text(
                                "Call $peerName",
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              onPressed: () {
                                Navigator.pushNamed(
                                  context,
                                  '/call',
                                  arguments: {
                                    'isCaller': true,
                                    'targetId': peerId,
                                    'myRegisteredId': _myRegisteredId,
                                  },
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}
