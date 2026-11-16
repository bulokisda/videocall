import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String signalingServerUrl = "wss://family-video-signaler.onrender.com";
const String compileTimeRoomToken = String.fromEnvironment('ROOM_TOKEN');

class BackgroundEngineState {
  static WebSocketChannel? socket;
  static Timer? heartbeat;
  static Timer? pongTimeout;
  static Timer? reconnectTimer;

  static bool isConnecting = false;
  static bool isSocketReady = false;
  static String? registeredId;
  static String? username;
  static String? roomSecret;
  static Map<String, dynamic>? currentOffer;
  static Map<String, dynamic>? acceptedCallPayload;
  static List<String> pendingSignalsQueue = [];
  static String? cachedPeerListMessage;
  static String? cachedRegisteredMessage;
  static ServiceInstance? serviceInstance;
  static StreamSubscription? callKitEventSubscription;
  static const String uiPortName = 'bisnan_ui_signal_port';

  static void emitToUi(ServiceInstance service, String jsonMessage) {
    final SendPort? uiSendPort = IsolateNameServer.lookupPortByName(uiPortName);
    if (uiSendPort != null) {
      uiSendPort.send(jsonMessage);
    } else {
      service.invoke("onSignalReceived", {"data": jsonMessage});
    }
  }

  static void connect(ServiceInstance service) async {
    if (isConnecting || (socket != null && isSocketReady)) return;
    isConnecting = true;
    isSocketReady = false;
    reconnectTimer?.cancel();
    reconnectTimer = null;

    heartbeat?.cancel();
    heartbeat = null;
    pongTimeout?.cancel();
    pongTimeout = null;

    try {
      socket?.sink.close();
    } catch (e) {
      debugPrint("Previous socket close error: $e");
    }
    socket = null;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    username = prefs.getString('saved_username') ?? username;
    registeredId = prefs.getString('saved_device_id') ?? registeredId;
    final storedSecret = prefs.getString('family_room_secret');
    roomSecret = (storedSecret != null && storedSecret.isNotEmpty)
        ? storedSecret
        : compileTimeRoomToken;

    if (roomSecret == null || roomSecret!.isEmpty) {
      debugPrint("--> Missing Family Room Secret. Waiting for setup...");
      isConnecting = false;
      emitToUi(service, json.encode({'type': 'network-offline'}));
      return;
    }

    try {
      debugPrint("--> Background isolate establishing secured websocket...");
      final wsUri = Uri.parse(
        "$signalingServerUrl/?token=${Uri.encodeComponent(roomSecret!)}",
      );
      final currentSocket = WebSocketChannel.connect(wsUri);
      socket = currentSocket;

      await currentSocket.ready;

      // Abort if a newer connect() call superseded this socket while awaiting .ready
      if (socket != currentSocket) {
        try {
          currentSocket.sink.close();
        } catch (e) {
          debugPrint("Superseded socket close error: $e");
        }
        return;
      }

      isSocketReady = true;
      isConnecting = false;

      currentSocket.sink.add(
        json.encode({
          'type': 'register-tablet',
          'id': (registeredId != null && registeredId!.isNotEmpty)
              ? registeredId
              : null,
          'name': username,
        }),
      );

      heartbeat = Timer.periodic(const Duration(seconds: 20), (timer) {
        if (socket == currentSocket && isSocketReady) {
          try {
            currentSocket.sink.add(
              json.encode({
                'type': 'ping',
                'id': (registeredId != null && registeredId!.isNotEmpty)
                    ? registeredId
                    : null,
                'name': username,
              }),
            );

            pongTimeout?.cancel();
            pongTimeout = Timer(const Duration(seconds: 10), () {
              if (socket == currentSocket) {
                debugPrint(
                  "--> Pong timeout! Server unresponsive, reconnecting...",
                );
                _handleDisconnect(service);
              }
            });
          } catch (e) {
            if (socket == currentSocket) _handleDisconnect(service);
          }
        } else {
          timer.cancel();
        }
      });

      currentSocket.stream.listen(
        (message) {
          if (socket != currentSocket) return;
          isConnecting = false;
          var data = json.decode(message);

          if (data['type'] == 'pong') {
            pongTimeout?.cancel();
            pongTimeout = null;
            return;
          }

          if (data['type'] == 'registered') {
            registeredId = data['id'];
            cachedRegisteredMessage = message;
            SharedPreferences.getInstance().then((p) {
              if (registeredId != null) {
                p.setString('saved_device_id', registeredId!);
              }
            });
          }

          if (data['type'] == 'mesh-peer-list') {
            cachedPeerListMessage = message;
          }
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

          emitToUi(service, message);
        },
        onError: (err) {
          if (socket == currentSocket) _handleDisconnect(service);
        },
        onDone: () {
          if (socket != currentSocket) return;
          final code = currentSocket.closeCode;
          if (code == 4001) {
            debugPrint(
              "--> Session replaced by newer instance (4001). Halting duplicate loop.",
            );
            isSocketReady = false;
            isConnecting = false;
            heartbeat?.cancel();
            heartbeat = null;
            pongTimeout?.cancel();
            pongTimeout = null;
            socket = null;
            return;
          }
          _handleDisconnect(service);
        },
        cancelOnError: true,
      );
    } catch (e) {
      isConnecting = false;
      _handleDisconnect(service);
    }
  }

  static void _handleDisconnect(ServiceInstance service) {
    isSocketReady = false;
    isConnecting = false;
    heartbeat?.cancel();
    heartbeat = null;
    pongTimeout?.cancel();
    pongTimeout = null;

    try {
      socket?.sink.close();
    } catch (e) {
      debugPrint("Disconnect close error: $e");
    }
    socket = null;

    emitToUi(service, json.encode({'type': 'network-offline'}));

    reconnectTimer?.cancel();
    reconnectTimer = Timer(const Duration(seconds: 5), () {
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
    CallKitParams params = CallKitParams(
      id: uuid,
      nameCaller: senderName,
      appName: 'Bisnan Calling',
      avatar: 'assets/icon/call.png',
      type: 1,
      duration: 30000,
      textAccept: 'Answer',
      textDecline: 'Decline',
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: true,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#075E54',
        backgroundUrl: 'assets/icon/call.png',
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
        case Event.ACTION_CALL_ACCEPT:
          if (serviceInstance != null && acceptedCallPayload != null) {
            final payloadToSend = Map<String, dynamic>.from(
              acceptedCallPayload!,
            );
            final uiSendPort = IsolateNameServer.lookupPortByName(uiPortName);
            if (uiSendPort != null) {
              acceptedCallPayload = null;
              uiSendPort.send(json.encode(payloadToSend));
            } else {
              // UI is still launching; keep acceptedCallPayload so checkStatus delivers it
              serviceInstance!.invoke("onSignalReceived", {
                "data": json.encode(payloadToSend),
              });
            }
          }
          break;

        case Event.ACTION_CALL_DECLINE:
          final targetId = currentOffer?['senderId'];
          final senderId =
              currentOffer?['targetId'] ?? registeredId ?? 'unknown_tablet';

          if (socket != null && targetId != null) {
            try {
              socket!.sink.add(
                json.encode({
                  'type': 'call-decline',
                  'targetId': targetId,
                  'senderId': senderId,
                  'name': username,
                }),
              );
            } catch (e) {
              debugPrint("Decline signal error: $e");
            }
          }

          Future.delayed(Duration.zero, () async {
            currentOffer = null;
            acceptedCallPayload = null;
            try {
              await FlutterCallkitIncoming.endAllCalls();
            } catch (e) {
              debugPrint("EndAllCalls error: $e");
            }
          });
          break;

        default:
          break;
      }
    });
  }
}

Future initializeBackgroundService(String? name) async {
  BackgroundEngineState.username = name;
  await [
    Permission.notification,
    Permission.camera,
    Permission.microphone,
  ].request();
  if (await Permission.ignoreBatteryOptimizations.isDenied) {
    await Permission.ignoreBatteryOptimizations.request();
  }
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'incoming_call_channel',
    'Background Call Service',
    description: 'Keeps connection active for incoming video calls',
    importance: Importance.low,
  );
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);
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
      initialNotificationTitle: 'Bisnan Calling',
      initialNotificationContent: 'Waiting for call...',
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStartBackgroundEngine,
    ),
  );
}

@pragma('vm:entry-point')
Future onStartBackgroundEngine(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundEngineState.serviceInstance = service;
  BackgroundEngineState.bindCallKitNativeEvents();
  service.on('checkStatus').listen((event) {
    if (BackgroundEngineState.acceptedCallPayload != null) {
      BackgroundEngineState.emitToUi(
        service,
        json.encode(BackgroundEngineState.acceptedCallPayload!),
      );
      BackgroundEngineState.acceptedCallPayload = null;
    }

    if (BackgroundEngineState.isSocketReady) {
      BackgroundEngineState.emitToUi(
        service,
        json.encode({
          'type': 'registered',
          'id': BackgroundEngineState.registeredId ?? 'tablet_active',
        }),
      );
    }
    if (BackgroundEngineState.cachedPeerListMessage != null) {
      BackgroundEngineState.emitToUi(
        service,
        BackgroundEngineState.cachedPeerListMessage!,
      );
    }

    if (!BackgroundEngineState.isSocketReady &&
        !BackgroundEngineState.isConnecting) {
      BackgroundEngineState.connect(service);
    }
  });

  service.on('notificationAction').listen((event) {
    if (event == null) return;
    if (event['action'] == 'decline') {
      final targetId =
          BackgroundEngineState.currentOffer?['senderId'] ?? event['targetId'];
      if (BackgroundEngineState.socket != null && targetId != null) {
        try {
          BackgroundEngineState.socket!.sink.add(
            json.encode({
              'type': 'call-decline',
              'targetId': targetId,
              'senderId': BackgroundEngineState.registeredId,
              'name': BackgroundEngineState.username,
            }),
          );
        } catch (e) {
          debugPrint("Notification decline signal error: $e");
        }
      }
      BackgroundEngineState._clearActiveCallData();
    }
  });

  service.on('reconnect').listen((event) {
    debugPrint("--> Manual reconnect triggered by UI.");
    BackgroundEngineState.reconnectTimer?.cancel();
    BackgroundEngineState.reconnectTimer = null;
    BackgroundEngineState.heartbeat?.cancel();
    BackgroundEngineState.heartbeat = null;
    BackgroundEngineState.pongTimeout?.cancel();
    BackgroundEngineState.pongTimeout = null;
    try {
      BackgroundEngineState.socket?.sink.close();
    } catch (e) {
      debugPrint("Reconnect close error: $e");
    }
    BackgroundEngineState.socket = null;
    BackgroundEngineState.isSocketReady = false;
    BackgroundEngineState.isConnecting = false;
    BackgroundEngineState.connect(service);
  });

  service.on('stopService').listen((event) {
    BackgroundEngineState.reconnectTimer?.cancel();
    BackgroundEngineState.reconnectTimer = null;
    BackgroundEngineState.heartbeat?.cancel();
    BackgroundEngineState.heartbeat = null;
    BackgroundEngineState.pongTimeout?.cancel();
    BackgroundEngineState.pongTimeout = null;
    try {
      BackgroundEngineState.socket?.sink.close();
    } catch (e) {
      debugPrint("StopService close error: $e");
    }
    BackgroundEngineState.socket = null;
    service.stopSelf();
  });
  service.on('sendSignal').listen((event) {
    if (BackgroundEngineState.socket != null && event != null) {
      BackgroundEngineState.socket!.sink.add(event['payload']);
    }
  });
  service.on('endCall').listen((event) {
    BackgroundEngineState._clearActiveCallData();
  });
  BackgroundEngineState.connect(service);
}
