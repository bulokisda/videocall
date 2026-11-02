import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String signalingServerUrl = "wss://family-video-signaler.onrender.com";

// 1. Declare a message queue container near your other top-level isolate state maps:
Map<String, dynamic>? currentOffer;
String? registeredId;
// ADD THIS CONTAINER HERE:
List<String> pendingWebRtcSignalsQueue = [];

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartBackgroundEngine,
      autoStart: true,
      isForegroundMode: true,
      // FIXED: Points exactly to the channel string registered in main.dart
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
  if (response.actionId == 'accept_call') {
    FlutterBackgroundService().invoke("notificationAction", {
      "action": "accept",
    });
  } else if (response.actionId == 'decline_call') {
    FlutterBackgroundService().invoke("notificationAction", {
      "action": "decline",
    });
  }
}

@pragma('vm:entry-point')
void onStartBackgroundEngine(ServiceInstance service) {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  WebSocketChannel? backgroundSocket;
  Timer? backgroundHeartbeat;
  Map<String, dynamic>? currentOffer;
  String? registeredId;

  void connectSocket() {
    backgroundHeartbeat?.cancel();
    try {
      backgroundSocket = WebSocketChannel.connect(
        Uri.parse(signalingServerUrl),
      );

      backgroundSocket!.sink.add(json.encode({'type': 'register-tablet'}));

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
            debugPrint(
              "Background engine assigned mesh identity node: $registeredId",
            );
          }

          if (data['type'] == 'offer') {
            currentOffer = data;
            String displaySender = data['senderId'] ?? 'browser_node';
            pendingWebRtcSignalsQueue.add(message);

            // Update the Notification Details block inside your WebSocket offer event listener:

            flutterLocalNotificationsPlugin.show(
              100,
              'Incoming Visual Request',
              'User ($displaySender) is calling...',
              const NotificationDetails(
                android: AndroidNotificationDetails(
                  'incoming_call_channel',
                  'Incoming Video Calls',
                  importance: Importance.max,
                  priority: Priority.high,
                  fullScreenIntent: true, // Forces Android to treat this like a real phone call
                  category: AndroidNotificationCategory.call,
                  ongoing: true, // Prevents accidental swipe-away closures
                  styleInformation: BigTextStyleInformation(''),
                  actions: [
                    AndroidNotificationAction(
                      'accept_call',
                      'Answer',
                      cancelNotification: true,
                      showsUserInterface:
                          true, // Wakes screen and launches application frame
                    ),
                    AndroidNotificationAction(
                      'decline_call',
                      'Decline',
                      cancelNotification: true,
                    ),
                  ],
                ),
              ),
            );
          }

          // Capture early candidate payloads sent by the browser before the UI can even load
          if (data['type'] == 'ice-candidate') {
            pendingWebRtcSignalsQueue.add(message);
          }

          if (data['type'] == 'hangup') {
            if (data['senderId'] == null ||
                data['senderId'] == currentOffer?['senderId']) {
              currentOffer = null;
              pendingWebRtcSignalsQueue
                  .clear(); // FIXED: Wipes out old handshake tokens completely
            }
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
      service.invoke("onSignalReceived", {
        "data": json.encode({
          'type': 'accept-from-notification',
          'sdp': currentOffer!['sdp'],
          'senderId': currentOffer!['senderId'] ?? 'browser_node',
        }),
      });
    } else if (event['action'] == 'decline') {
      if (currentOffer != null) {
        pendingWebRtcSignalsQueue.clear(); // Add this line to clear the queue
        if (currentOffer != null) {
          backgroundSocket?.sink.add(
            json.encode({
              'type': 'hangup',
              'targetId': currentOffer!['senderId'],
            }),
          );
          currentOffer = null;
        }
      } else {
        backgroundSocket?.sink.add(json.encode({'type': 'hangup'}));
      }
      service.invoke("onSignalReceived", {
        "data": json.encode({'type': 'hangup'}),
      });
    }
  });

  // 3. Update the 'checkStatus' or a new 'flushQueue' listener to empty the cache cleanly:
  service.on('checkStatus').listen((event) {
    debugPrint(
      "--> UI Isolate requested a flush. Current Queue Size: ${pendingWebRtcSignalsQueue.length}",
    );

    // Re-broadcast anything the frozen UI isolate missed while booting up
    for (var queuedMessage in pendingWebRtcSignalsQueue) {
      service.invoke("onSignalReceived", {"data": queuedMessage});
    }

    if (registeredId != null && pendingWebRtcSignalsQueue.isEmpty) {
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
