import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'background_handler.dart';
import 'video_call_screen.dart';

@pragma('vm:entry-point')
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    WebRTC.initialize();
  } catch (e) {
    debugPrint("WebRTC native binding pass: $e");
  }

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  const AndroidNotificationChannel callChannel = AndroidNotificationChannel(
    'incoming_call_channel',
    'Incoming Video Calls',
    description: 'Displays full-screen incoming video call alerts.',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  final androidImplementation = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  if (androidImplementation != null) {
    await androidImplementation.createNotificationChannel(callChannel);
  }

  const initializationSettingsAndroid = AndroidInitializationSettings(
    '@mipmap/ic_launcher',
  );

  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(android: initializationSettingsAndroid),
    onDidReceiveNotificationResponse: (NotificationResponse response) {
      if (response.actionId == 'accept_call') {
        FlutterBackgroundService().invoke("notificationAction", {
          "action": "accept",
        });
      } else if (response.actionId == 'decline_call') {
        FlutterBackgroundService().invoke("notificationAction", {
          "action": "decline",
        });
      } else {
        FlutterBackgroundService().invoke("checkStatus");
      }
    },
    onDidReceiveBackgroundNotificationResponse:
        notificationTapBackgroundHandler,
  );

  runApp(const MyApp());

  scheduleMicrotask(() async {
    await initializeBackgroundService();
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Visual Call',
      theme: ThemeData(brightness: Brightness.dark),
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/call': (context) => const VideoCallScreen(),
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isOnline = false;
  dynamic _remoteSdpOffer;
  StreamSubscription? _serviceSubscription;
  // bool _isNavigatingToCall = false;
  List<dynamic> _discoveredNetworkPeers = [];

  @override
  void initState() {
    super.initState();

    // Wipes any stale stream registration before creating a clean hook
    _serviceSubscription?.cancel();
    _bindCommunicationChannel();

    Future.delayed(const Duration(milliseconds: 1000), () {
      FlutterBackgroundService().invoke('checkStatus');
    });
  }

  // main.dart -> Inside _HomeScreenState class
  bool _isProcessingNavigationLock = false; // Add this class variable

  void _bindCommunicationChannel() {
    _serviceSubscription = FlutterBackgroundService()
        .on('onSignalReceived')
        .listen((event) {
          if (event == null || event['data'] == null) return;

          var data = jsonDecode(event['data']);

          if (!_isOnline) {
            setState(() => _isOnline = true);
          }

          if (data['type'] == 'accept-from-notification') {
            // FIXED: Strict structural guard checking the active window status and tracking loop
            if (mounted &&
                !VideoCallScreen.isActive &&
                !_isProcessingNavigationLock) {
              _isProcessingNavigationLock =
                  true; // Lock execution track instantly

              final sdpPayload = data['sdp'];
              final senderIdPayload = data['senderId'] ?? 'browser_node';

              setState(() {
                _remoteSdpOffer = null;
              });

              Navigator.pushNamed(
                context,
                '/call',
                arguments: {'sdp': sdpPayload, 'senderId': senderIdPayload},
              ).then((_) {
                // Reset navigation lock when returning back to HomeScreen
                _isProcessingNavigationLock = false;
              });
            }
          }
          if (data['type'] == 'mesh-peer-list') {
            if (mounted) {
              setState(() {
                _discoveredNetworkPeers = data['peers'] ?? [];
              });
            }
          }
        });
  }

  @override
  void dispose() {
    _serviceSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.circle,
              color: _isOnline ? Colors.green : Colors.red,
              size: 24,
            ),
            const SizedBox(height: 10),
            Text(
              _isOnline
                  ? "Signaling Engine Connected"
                  : "Connecting to Engine...",
            ),
            if (_remoteSdpOffer != null) ...[
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                onPressed: () {
                  FlutterBackgroundService().invoke("notificationAction", {
                    "action": "accept",
                  });
                },
                child: const Text("Answer Call from UI"),
              ),
            ],
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              onPressed: () {
                // Find the first peer whose type profile equals 'browser'
                final browserNode = _discoveredNetworkPeers.firstWhere(
                  (peer) => peer['type'] == 'browser',
                  orElse: () => null,
                );

                if (browserNode != null && browserNode['id'] != null) {
                  String actualBrowserRuntimeId = browserNode['id'];
                  debugPrint(
                    "--> Routing outbound offer cleanly to actual target ID: $actualBrowserRuntimeId",
                  );

                  Navigator.pushNamed(
                    context,
                    '/call',
                    arguments: {
                      'isCaller': true,
                      'targetId': actualBrowserRuntimeId, // Pass the dynamic real ID here!
                    },
                  );
                } else {
                  // Show an error toast or snackbar if no browser is connected to the server yet
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Cannot initiate call: No active browser peer discovered online yet.",
                      ),
                    ),
                  );
                }
              },
              child: const Text("Call Browser"),
            ),
          ],
        ),
      ),
    );
  }
}
