import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      print('--> NOTIFICATION RESPONSE: ${response.actionId}');
      if (response.actionId == 'accept_call') {
        FlutterBackgroundService().invoke("notificationAction", {
          "action": "accept",
        });
      } else if (response.actionId == 'decline_call') {
        FlutterBackgroundService().invoke("notificationAction", {
          "action": "decline",
        });
        flutterLocalNotificationsPlugin.cancel(100);

        // 3. CRITICAL: Gracefully exit the application process to dismiss the UI window instantly
        SystemNavigator.pop(); 
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
      debugShowCheckedModeBanner: false,
      title: 'Bisnan Calling',
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
  // dynamic _remoteSdpOffer;
  StreamSubscription? _serviceSubscription;
  // bool _isNavigatingToCall = false;
  List<dynamic> _discoveredNetworkPeers = [];
  String? _myRegisteredId;
  bool _isProcessingNavigationLock = false; // Add this class variable

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

  void _bindCommunicationChannel() {
    _serviceSubscription = FlutterBackgroundService().on('onSignalReceived').listen((
      event,
    ) {
      if (event == null || event['data'] == null) return;

      var data = jsonDecode(event['data']);

      // Ensure the online connection indicator switches to active
      if (!_isOnline) {
        setState(() => _isOnline = true);
      }

      if (data['type'] == 'registered') {
        if (mounted) {
          setState(() {
            _myRegisteredId = data['id'];
          });
          debugPrint(
            "--> UI Isolate successfully captured its own ID: $_myRegisteredId",
          );
        }
      }

      // if (data['type'] == 'offer') {
      //   if (mounted) {
      //     setState(() {
      //       // Capture the incoming browser call parameters right in the UI state
      //       _remoteSdpOffer = data;
      //     });
      //     debugPrint(
      //       "--> UI Isolate caught an incoming offer from: ${data['senderId']}",
      //     );
      //   }
      // }

      // if (data['type'] == 'hangup') {
      //   if (mounted) {
      //     setState(() {
      //       _remoteSdpOffer =
      //           null; // Clear the answer button if the browser hangs up
      //     });
      //   }
      // }
      // Inside your main App UI socket listener:

      // if (data['type'] == 'hangup') {
      //   // If the UI is already open, close it.
      //   // If it's closed/minimized, do NOT force open it.
      //   if (AppLifecycleState.resumed ==
      //       WidgetsBinding.instance.lifecycleState) {
      //     // Only perform navigation back if the app is actively being looked at
      //     Navigator.pop();
      //   }
      // }

      if (data['type'] == 'accept-from-notification') {
        if (mounted &&
            !VideoCallScreen.isActive &&
            !_isProcessingNavigationLock) {
          _isProcessingNavigationLock = true;
          final sdpPayload = data['sdp'];
          final senderIdPayload = data['senderId'] ?? 'browser_node';

          // setState(() {
          //   _remoteSdpOffer = null;
          // });

          Navigator.pushNamed(
            context,
            '/call',
            arguments: {
              'sdp': sdpPayload,
              'senderId': senderIdPayload,
              'myRegisteredId': _myRegisteredId,
            },
          ).then((_) {
            _isProcessingNavigationLock = false;
          });
        }
      }

      if (data['type'] == 'mesh-peer-list') {
        if (mounted) {
          // FIXED: Dynamically discover our own current tablet ID from the list itself!
          // Looks for the peer marked as 'tablet' (or our name 'Lito')
          final mySelfNode = (data['peers'] as List? ?? []).firstWhere(
            (peer) => peer['type'] == 'tablet',
            orElse: () => null,
          );

          setState(() {
            _discoveredNetworkPeers = data['peers'] ?? [];
            if (mySelfNode != null) {
              _myRegisteredId =
                  mySelfNode['id']; // Auto-heals stale ID states instantly!
              debugPrint(
                "--> Dynamically synced current Tablet ID: $_myRegisteredId",
              );
            }
          });
          debugPrint(
            "--> UI Rebuilt! Found ${_discoveredNetworkPeers.length} total raw nodes.",
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
    // Filters out your own tablet ID, leaving only the browser nodes visible
    final activeCallTargets = _discoveredNetworkPeers.where((peer) {
      if (_myRegisteredId != null) {
        return peer['id'] != _myRegisteredId;
      }
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Text("Bisnan Video Call"), centerTitle: true),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment
              .center, // Centers items vertically if they don't fill the screen
          crossAxisAlignment:
              CrossAxisAlignment.center, // Centers items horizontally
          mainAxisSize: MainAxisSize.min, // Forces the Column to only take up as much space as its children need
          children: [
            activeCallTargets.isEmpty
                ? Center(
                    child: Text(
                      _isOnline ? "🥱" : "🚫",
                      style: const TextStyle(fontSize: 60),
                    ),
                  )
                : Flexible(
                    // Replaced Expanded with Flexible so it can shrink-wrap
                    child: ListView.builder(
                      shrinkWrap: true, // Tells the ListView to only take up the space of its items
                      physics: const NeverScrollableScrollPhysics(), // Optional: prevents internal scrolling if you want it strictly fixed
                      itemCount: activeCallTargets.length,
                      itemBuilder: (context, index) {
                        final peer = activeCallTargets[index];
                        final String peerId = peer['id'] ?? 'Unknown';
                        final String peerName = peer['name'] ?? 'Unknown';

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Row(
                            children: [
                              // Left Half: Name aligned to the right edge of its container
                              Expanded(
                                child: Text(
                                  peerName,
                                  textAlign: TextAlign.end,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),

                              const SizedBox(
                                width: 24,
                              ), // Fixed gap between the name and the button
                              // Right Half: Phone icon aligned to the left edge of its container
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: IconButton(
                                    icon: const Icon(
                                      Icons.phone,
                                      color: Colors.green,
                                      size: 60,
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
                              ),
                            ],
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
