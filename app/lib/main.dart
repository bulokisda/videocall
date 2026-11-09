import 'dart:async';
import 'dart:convert';

import 'package:call/username_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'background_handler.dart';
import 'video_call_screen.dart';

String? savedUsername;
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
void ntp(NotificationResponse response) {
  // Handle background event execution
}

void minimizeAppToSystemTray() {
  const platform = MethodChannel('flutter/platform');
  platform.invokeMethod('SystemNavigator.pop');
  // Note: Using SystemNavigator.pop within a custom async microtask block
  // AFTER updating state prevents cutting off the active isolate runtime loop.
}

// @pragma('vm:entry-point')
// void notificationTapBackground(NotificationResponse response) {
//   // Handle background event execution
//   print('XXX main Background notification response: $response');
//   if (response.actionId == 'decline_call') {
//     final localizedPlugin = FlutterLocalNotificationsPlugin();

//     localizedPlugin
//         .show(
//           100,
//           'Call Declined',
//           '',
//           const NotificationDetails(
//             android: AndroidNotificationDetails(
//               'incoming_call_channel',
//               'Incoming Video Calls',
//               importance: Importance.min,
//               priority: Priority.low,
//               ongoing: false,
//             ),
//           ),
//         )
//         .then((_) {
//           localizedPlugin.cancel(100);
//         });

//     FlutterBackgroundService().invoke('notificationAction', {
//       'action': 'decline',
//     });
//   } else if (response.actionId == 'accept_call') {
//     print('XXX main notificationTapBackgroundHandler: accept_call');
//     FlutterBackgroundService().invoke('notificationAction', {
//       'action': 'accept',
//     });
//   }
// }

@pragma('vm:entry-point')
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final SharedPreferences prefs = await SharedPreferences.getInstance();
  savedUsername = prefs.getString('saved_username');

  // 🟢 CallKit hooks its native event streams across background triggers natively.
  // We can start the application structure instantly.
  runApp(const MyApp());

  scheduleMicrotask(() async {
    await initializeBackgroundService(savedUsername);
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Bisnan Calling',
      theme: ThemeData(brightness: Brightness.dark),
      initialRoute: savedUsername == null ? '/username' : '/',
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

class _HomeScreenState extends State<HomeScreen> {
  bool _isOnline = false;
  bool _isReconnecting = false; // Tracks manual reconnect button spinning state
  StreamSubscription? _serviceSubscription;
  List<dynamic> _discoveredNetworkPeers = [];
  String? _myRegisteredId;
  bool _isProcessingNavigationLock = false;

  @override
  void initState() {
    super.initState();
    _serviceSubscription?.cancel();
    _bindCommunicationChannel();

    // 🟢 FIXED: Instead of a generic delayed status check, look up status safely
    FlutterBackgroundService().isRunning().then((running) {
      if (running) {
        FlutterBackgroundService().invoke('checkStatus');
      }
    });
  }

  // void _triggerStatusCheck() {
  //   Future.delayed(const Duration(milliseconds: 1000), () {
  //     FlutterBackgroundService().invoke('checkStatus');
  //   });
  // }

  //  CLEAN FIXED VERSION:
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

    // Give visual spinner effect time to resolve network loopback
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      setState(() {
        _isReconnecting = false;
      });
    }
  }

  void _bindCommunicationChannel() {
    _serviceSubscription = FlutterBackgroundService().on('onSignalReceived').listen((
      event,
    ) {
      // print('XXX event received: $event');
      if (event == null || event['data'] == null) return;
      var data = jsonDecode(event['data']);

      if (data['type'] == 'network-offline') {
        if (mounted) {
          setState(() {
            _isOnline = false;
            _discoveredNetworkPeers = []; // Purge peer views
            _isProcessingNavigationLock =
                false; // 🟢 Reset navigation flag block
          });
        }
        return;
      }

      // Any valid signal payload implies the socket service pipeline is running online
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

      // 🟢 Fix: Reset navigation filters immediately if a hangup/clear payload arrives
      if (data['type'] == 'hangup') {
        if (mounted) {
          setState(() {
            _isProcessingNavigationLock = false;
          });
        }
        return;
      }

      // 🚨 Change this specific block to check if an active call is already running
      if (data['type'] == 'accept-from-notification') {
        debugPrint("--> UI Isolate captured notification answer tap.");

        if (mounted && !_isProcessingNavigationLock) {
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
          ).then((_) {
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
        if (mounted) {
          final mySelfNode = (data['peers'] as List? ?? []).firstWhere(
            (peer) => peer['type'] == 'tablet',
            orElse: () => null,
          );
          setState(() {
            _discoveredNetworkPeers = data['peers'] ?? [];
            if (mySelfNode != null) {
              _myRegisteredId = mySelfNode['id'];
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
                          _isOnline ? "🥱" : "🚫",
                          style: const TextStyle(fontSize: 60),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _isOnline
                              ? "Online, but no available targets found."
                              : "Remote call service connection offline.",
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                          ),
                        ),
                        // Display the dynamic action button if connection is lost/offline
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
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Row(
                            children: [
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
                              const SizedBox(width: 24),
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
