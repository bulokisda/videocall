import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String signalingServerUrl = "wss://family-video-signaler.onrender.com";

class BackgroundEngineState {
  static WebSocketChannel? socket;
  static Timer? heartbeat;
  static bool isConnecting = false;
  static bool isSocketReady = false;
  static String? registeredId;
  static String? username;
  static Map<String, dynamic>? currentOffer;
  static Map<String, dynamic>? acceptedCallPayload;
  static List<String> pendingSignalsQueue = [];
  static String? cachedPeerListMessage; // 🟢 FIXED: Explicitly declared field
  static ServiceInstance? serviceInstance;
  static StreamSubscription? callKitEventSubscription;

  static void connect(ServiceInstance service) async {
    if (isConnecting || (socket != null && isSocketReady)) return;
    isConnecting = true;
    isSocketReady = false;

    heartbeat?.cancel();
    heartbeat = null;

    try {
      socket?.sink.close();
    } catch (_) {}
    socket = null;

    if (username == null) {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      username = prefs.getString('saved_username');
    }

    try {
      debugPrint("--> Background isolate establishing stable websocket...");
      socket = WebSocketChannel.connect(Uri.parse(signalingServerUrl));
      isSocketReady = true;

      socket!.sink.add(
        json.encode({
          'type': 'register-tablet',
          'id': (registeredId != null && registeredId!.isNotEmpty)
              ? registeredId
              : null,
          'name': username,
        }),
      );

      heartbeat = Timer.periodic(const Duration(seconds: 20), (timer) {
        if (socket != null && isSocketReady) {
          try {
            socket!.sink.add(
              json.encode({
                'type': 'ping',
                'id': (registeredId != null && registeredId!.isNotEmpty)
                    ? registeredId
                    : null,
                'name': username,
              }),
            );
          } catch (e) {
            _handleDisconnect(service);
          }
        } else {
          _handleDisconnect(service);
        }
      });

      socket!.stream.listen(
        (message) {
          isConnecting = false;
          var data = json.decode(message);

          if (data['type'] == 'registered') registeredId = data['id'];
          if (data['type'] == 'mesh-peer-list') cachedPeerListMessage = message;
          if (data['type'] == 'offer') {
            currentOffer = data;
            acceptedCallPayload = {
              'type': 'accept-from-notification',
              'sdp': data['sdp'],
              'senderId': data['senderId'] ?? 'browser_node',
            };

            String displaySender =
                data['senderName'] ?? data['senderId'] ?? 'Someone';
            _showNativeCallKitInterface(
              data['senderId'] ?? 'uuid_node',
              displaySender,
            );
          }
          if (data['type'] == 'hangup') {
            _clearActiveCallData();
          }

          service.invoke("onSignalReceived", {"data": message});
        },
        onError: (err) => _handleDisconnect(service),
        onDone: () => _handleDisconnect(service),
        cancelOnError: true,
      );
    } catch (e) {
      isConnecting = false;
      _handleDisconnect(service);
    }
  }

  // static void _forceFullConnectionReset() {
  //   currentOffer = null;
  //   acceptedCallPayload = null;
  //   registeredId = null;
  //   isSocketReady = false;
  //   isConnecting = false;
  //   heartbeat?.cancel();
  //   heartbeat = null;
  //   try {
  //     socket?.sink.close();
  //   } catch (_) {}
  //   socket = null;

  //   if (serviceInstance != null) {
  //     connect(serviceInstance!);
  //   }
  // }

  static void _handleDisconnect(ServiceInstance service) {
    isSocketReady = false;
    isConnecting = false;
    heartbeat?.cancel();
    heartbeat = null;
    try {
      socket?.sink.close();
    } catch (_) {}
    socket = null;

    service.invoke("onSignalReceived", {
      "data": json.encode({'type': 'network-offline'}),
    });

    Future.delayed(const Duration(seconds: 5), () {
      if (!isSocketReady && !isConnecting) connect(service);
    });
  }

  static void _clearActiveCallData() async {
    currentOffer = null;
    acceptedCallPayload = null;
    await FlutterCallkitIncoming.endAllCalls();
  }

  static void _showNativeCallKitInterface(
    String uuid,
    String senderName,
  ) async {
    // 🟢 FIXED Parameters: Removed undefined attributes and fixed naming structures
    CallKitParams params = CallKitParams(
      id: uuid,
      nameCaller: senderName,
      appName: 'Bisnan Calling',
      // avatar: 'https://pravatar.cc',
      type: 1,
      duration: 30000,
      textAccept: 'Answer',
      textDecline: 'Decline',
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#075E54',
        // backgroundUrl: 'https://pravatar.cc',
        actionColor: '#4CAF50',
        incomingCallNotificationChannelName: 'Incoming Video Calls',
      ),
    );

    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  static void bindCallKitNativeEvents() {
    callKitEventSubscription?.cancel();
    callKitEventSubscription = FlutterCallkitIncoming.onEvent.listen((
      CallEvent? event,
    ) {
      if (event == null) return;

      switch (event.event) {
        // 🟢 FIXED: Updated enum maps to use matching upper-case constants
        case Event.ACTION_CALL_ACCEPT:
          if (serviceInstance != null && acceptedCallPayload != null) {
            serviceInstance!.invoke("onSignalReceived", {
              "data": json.encode(acceptedCallPayload),
            });
          }
          break;

        case Event.ACTION_CALL_DECLINE:
          final targetId = currentOffer?['senderId'] ?? 'browser_node';
          final senderId =
              currentOffer?['targetId'] ?? registeredId ?? 'unknown_tablet';

          // 🟢 STEP 1: ULTRA-PRIORITY NETWORK PIPE DISPATCH
          // Fire outbound signaling payloads down the TCP line instantly, completely uncoupled from WebRTC
          if (socket != null && isSocketReady) {
            try {
              // 1. Tell browser immediately to clear its calling screen
              socket!.sink.add(
                json.encode({
                  'type': 'hangup',
                  'targetId': targetId,
                  'senderId': senderId,
                  'name': username,
                }),
              );

              // 2. Instantly update tablet online presence baseline on the server
              socket!.sink.add(
                json.encode({
                  'type': 'register-tablet',
                  'id': registeredId,
                  'name': username,
                }),
              );

            } catch (e) {
              // print("XXX CallKit Wire: Network fast-path push failed: $e");
            }
          }

          // 🟢 STEP 2: DEFER NATIVE WEBRTC HARDWARE DE-ALLOCATION
          // Schedule heavy camera/audio hardware teardown tasks to run asynchronously
          // in a separate macro-task loop execution frame.
          Future.delayed(Duration.zero, () async {

            // Clean local offer states
            currentOffer = null;
            acceptedCallPayload = null;

            // Trigger the internal native plugin endpoints
            try {
              await FlutterCallkitIncoming.endAllCalls();
            } catch (e) {
              // print("--> CallKit native call termination failed: $e");
            }
          });
          break;

        default:
          break;
      }
    });
  }
}

Future<void> initializeBackgroundService(String? name) async {
  BackgroundEngineState.username = name;
  final service = FlutterBackgroundService();

  if (await service.isRunning()) {
    service.invoke('checkStatus');
    return;
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartBackgroundEngine,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'incoming_call_channel',
      initialNotificationTitle: 'Waiting for call...',
      initialNotificationContent: '',
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStartBackgroundEngine,
    ),
  );
}

@pragma('vm:entry-point')
Future<void> onStartBackgroundEngine(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundEngineState.serviceInstance = service;

  BackgroundEngineState.bindCallKitNativeEvents();

  service.on('checkStatus').listen((event) {
    if (BackgroundEngineState.acceptedCallPayload != null) {
      service.invoke("onSignalReceived", {
        "data": json.encode(BackgroundEngineState.acceptedCallPayload),
      });
      BackgroundEngineState.acceptedCallPayload = null;
    }
    if (BackgroundEngineState.cachedPeerListMessage != null) {
      service.invoke("onSignalReceived", {
        "data": BackgroundEngineState.cachedPeerListMessage,
      });
    }
    if (BackgroundEngineState.registeredId != null) {
      service.invoke("onSignalReceived", {
        "data": json.encode({
          'type': 'registered',
          'id': BackgroundEngineState.registeredId,
        }),
      });
    }
    if (!BackgroundEngineState.isSocketReady &&
        !BackgroundEngineState.isConnecting) {
      BackgroundEngineState.connect(service);
    }
  });

  service.on('notificationAction').listen((event) {
    if (event == null) return;
    if (event['action'] == 'decline') {
      BackgroundEngineState._clearActiveCallData();
      BackgroundEngineState.registeredId = null;
      BackgroundEngineState._handleDisconnect(service);
    }
  });

  service.on('reconnect').listen((event) {
    BackgroundEngineState.isSocketReady = false;
    BackgroundEngineState.isConnecting = false;
    BackgroundEngineState.connect(service);
  });

  service.on('stopService').listen((event) {
    BackgroundEngineState.heartbeat?.cancel();
    BackgroundEngineState.socket?.sink.close();
    service.stopSelf();
  });

  service.on('sendSignal').listen((event) {
    if (BackgroundEngineState.socket != null && event != null) {
      BackgroundEngineState.socket!.sink.add(event['payload']);
    }
  });

  BackgroundEngineState.connect(service);
}
