import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'background_handler.dart';
import 'video_call_screen.dart';

// REPLACE your existing notification initialization in main() with this structured routing logic:

@pragma('vm:entry-point')
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // FIXED: Explicitly pre-initialize WebRTC hardware bindings on the main UI isolate thread
  // before any background services spin up or notifications route traffic.
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
      // Directs the UI tap event cleanly into the communication bus
      if (response.actionId == 'accept_call') {
        FlutterBackgroundService().invoke("notificationAction", {
          "action": "accept",
        });
      } else if (response.actionId == 'decline_call') {
        FlutterBackgroundService().invoke("notificationAction", {
          "action": "decline",
        });
      } else {
        // Tapping the body of the notification opens the app to inspect the current state
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

  @override
  void initState() {
    super.initState();
    _bindCommunicationChannel();
    Future.delayed(const Duration(milliseconds: 1000), () {
      FlutterBackgroundService().invoke('checkStatus');
    });
  }

    void _bindCommunicationChannel() {
    _serviceSubscription = FlutterBackgroundService()
        .on('onSignalReceived')
        .listen((event) {
          if (event == null || event['data'] == null) return;

          print("!! FOREGROUND UI ISOLATE RECEIVED PACKET: ${event['data']}");
          var data = jsonDecode(event['data']);

          if (!_isOnline) {
            setState(() => _isOnline = true);
          }

          if (data['type'] == 'offer' || data['type'] == 'accept-from-notification') {
            // FIXED: Guard against duplicate concurrent routing attempts if a call screen is already live
            if (mounted && !VideoCallScreen.isActive) {
              
              // 1. Capture payload data structures cleanly
              final sdpPayload = data['sdp'];
              final senderIdPayload = data['senderId'] ?? 'browser_node';

              // 2. Clear out local state immediately to break the multi-fire loop
              setState(() {
                _remoteSdpOffer = null; 
              });

              // 3. Route to the call interface safely
              Navigator.pushNamed(
                context,
                '/call',
                arguments: {
                  'sdp': sdpPayload,
                  'senderId': senderIdPayload,
                },
              );
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
          ],
        ),
      ),
    );
  }
}
