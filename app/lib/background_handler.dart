import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String signalingServerUrl = "wss://family-video-signaler.onrender.com";

Map<String, dynamic>? currentOffer;
String? registeredId;
List<String> pendingWebRtcSignalsQueue = [];
// FIXED: Cache the accepted call payload to survive app launch boot cycles
Map<String, dynamic>? acceptedCallPayload;
String? cachedPeerListMessage;

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartBackgroundEngine,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'incoming_call_channel',
      initialNotificationTitle: 'System Engine Active',
      initialNotificationContent: 'Awaiting incoming visual requests...',
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStartBackgroundEngine,
    ),
  );
}

@pragma('vm:entry-point')
void notificationTapBackgroundHandler(NotificationResponse response) {
  final backgroundService = FlutterBackgroundService();

  if (response.actionId == 'decline_call') {
    backgroundService.invoke('notificationAction', {'action': 'decline'});
  } else if (response.actionId == 'accept_call') {
    backgroundService.invoke('notificationAction', {'action': 'accept'});
  }
}

@pragma('vm:entry-point')
void onStartBackgroundEngine(ServiceInstance service) {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(android: initializationSettingsAndroid),
    onDidReceiveNotificationResponse: (response) {
      if (response.actionId == 'decline_call') {
        service.invoke('notificationAction', {'action': 'decline'});
      } else if (response.actionId == 'accept_call') {
        service.invoke('notificationAction', {'action': 'accept'});
      }
    },
    onDidReceiveBackgroundNotificationResponse:
        notificationTapBackgroundHandler,
  );

  WebSocketChannel? backgroundSocket;
  Timer? backgroundHeartbeat;

  void connectSocket() {
    backgroundHeartbeat?.cancel();
    try {
      backgroundSocket = WebSocketChannel.connect(
        Uri.parse(signalingServerUrl),
      );

      backgroundSocket!.sink.add(
        json.encode({
          'type': 'register-tablet',
          'id': registeredId,
          'name': 'Lito', // <-- Pass the custom device name right here
        }),
      );

      backgroundHeartbeat = Timer.periodic(const Duration(seconds: 20), (
        timer,
      ) {
        backgroundSocket?.sink.add(json.encode({'type': 'ping'}));
      });

      backgroundSocket!.stream.listen(
        (message) {
          debugPrint(
            "!! BACKGROUND ISOLATE RECEIVED SIGNALLING ENVELOPE: $message",
          );
          var data = json.decode(message);

          if (data['type'] == 'registered') {
            registeredId = data['id'];
          }

          if (data['type'] == 'mesh-peer-list') {
            cachedPeerListMessage = message; // Cache the exact JSON string
          }

          if (data['type'] == 'offer') {
            currentOffer = data;
            acceptedCallPayload = null; // Clear any old stale accepted pass
            String displaySender = data['senderName'] ?? data['senderId'] ?? 'Someone';
            pendingWebRtcSignalsQueue.add(message);

            flutterLocalNotificationsPlugin.show(
              100,
              'Incoming Call',
              '$displaySender is calling...',
              const NotificationDetails(
                android: AndroidNotificationDetails(
                  'incoming_call_channel',
                  'Incoming Video Calls',
                  importance: Importance.max,
                  priority: Priority.high,
                  fullScreenIntent: true,
                  color: Colors.green,
                  category: AndroidNotificationCategory.call,
                  ongoing: true,
                  actions: [
                    AndroidNotificationAction(
                      'accept_call',
                      'Answer',
                      cancelNotification: true,
                      showsUserInterface: true,
                    ),
                    AndroidNotificationAction(
                      'decline_call',
                      'Decline',
                      cancelNotification: true,
                      showsUserInterface: true,
                    ),
                  ],
                ),
              ),
            );
          }

          if (data['type'] == 'ice-candidate') {
            pendingWebRtcSignalsQueue.add(message);
          }

          if (data['type'] == 'hangup') {
            currentOffer = null;
            acceptedCallPayload = null;
            pendingWebRtcSignalsQueue.clear();
            flutterLocalNotificationsPlugin.cancel(100);
          }

          service.invoke("onSignalReceived", {"data": message});
        },
        onError: (err) {
          backgroundSocket?.sink.close();
          Future.delayed(const Duration(seconds: 5), connectSocket);
        },
        onDone: () {
          Future.delayed(const Duration(seconds: 5), connectSocket);
        },
        cancelOnError: true,
      );
    } catch (e) {
      Future.delayed(const Duration(seconds: 5), connectSocket);
    }
  }

  service.on('notificationAction').listen((event) {
    if (event == null) return;

    if (event['action'] == 'accept' && currentOffer != null) {
      pendingWebRtcSignalsQueue.clear();
      flutterLocalNotificationsPlugin.cancel(100);

      // FIXED: Build and cache the exact payload structure right here
      acceptedCallPayload = {
        'type': 'accept-from-notification',
        'sdp': currentOffer!['sdp'],
        'senderId': currentOffer!['senderId'] ?? 'browser_node',
      };

      service.invoke("onSignalReceived", {
        "data": json.encode(acceptedCallPayload),
      });
    } else if (event['action'] == 'decline') {
      pendingWebRtcSignalsQueue.clear();
      currentOffer = null;
      acceptedCallPayload = null;

      flutterLocalNotificationsPlugin.cancel(100);

      if (backgroundSocket != null) {
        backgroundSocket?.sink.add(json.encode({'type': 'hangup'}));
      }
      service.invoke("onSignalReceived", {
        "data": json.encode({'type': 'hangup'}),
      });
    }
  });

  service.on('checkStatus').listen((event) {
    debugPrint("--> UI Isolate requested a clean queue flush.");

    // FIXED: If the app just opened because of an "Answer" tap, deliver it cleanly now!
    if (acceptedCallPayload != null) {
      service.invoke("onSignalReceived", {
        "data": json.encode(acceptedCallPayload),
      });
      acceptedCallPayload = null; // Clear it out instantly once delivered
    }

    // FIXED: If we have an existing peer list, push it immediately to the newly opened UI
    if (cachedPeerListMessage != null) {
      service.invoke("onSignalReceived", {"data": cachedPeerListMessage});
    }

    for (var queuedMessage in pendingWebRtcSignalsQueue) {
      service.invoke("onSignalReceived", {"data": queuedMessage});
    }

    pendingWebRtcSignalsQueue.clear();

    if (registeredId != null) {
      service.invoke("onSignalReceived", {
        "data": json.encode({'type': 'registered', 'id': registeredId}),
      });
    }
  });

  service.on('stopService').listen((event) {
    backgroundHeartbeat?.cancel();
    backgroundSocket?.sink.close();
    service.stopSelf();
  });

  service.on('sendSignal').listen((event) {
    if (backgroundSocket != null && event != null) {
      backgroundSocket!.sink.add(event['payload']);
    }
  });

  Timer.run(() {
    connectSocket();
  });
}
