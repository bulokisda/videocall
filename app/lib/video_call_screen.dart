import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class VideoCallScreen extends StatefulWidget {
  const VideoCallScreen({super.key});
  static bool isActive = false;

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, List<RTCIceCandidate>> _bufferedRemoteIceCandidates = {};
  final Set<String> _activeHandshakesInFlight = {};

  MediaStream? _localStream;
  StreamSubscription? _serviceSubscription;
  // bool _isInitialized = false;
  bool _isHandshakeComplete = false;
  bool _hasStartedBootstrap = false;
  String? _myNodeId;
  String? _myIdFromArgs;

  // final Map<String, dynamic> _rtcConfig = {
  //   'iceServers': [
  //     {
  //       'urls': [
  //         'stun:stun.l.google.com:19302',
  //         'stun:stun1.l.google.com:19302',
  //       ],
  //     },
  //     {
  //       'urls': [
  //         'turn:openrelay.metered.ca:80',
  //         'turn:openrelay.metered.ca:443',
  //         'turn:openrelay.metered.ca:443?transport=tcp',
  //       ],
  //       'username': 'openrelayproject',
  //       'credential': 'openrelayprojectsecret',
  //     }
  //   ],
  //   'sdpSemantics': 'unified-plan',
  // };

  final Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {'urls': "stun:stun.relay.metered.ca:80"},
      {
        'urls': "turn:standard.relay.metered.ca:80",
        'username': "801acfb381f1738ba4e9e792",
        'credential': "xb8Y+/nANmaFf1Um",
      },
      {
        'urls': "turn:standard.relay.metered.ca:80?transport=tcp",
        'username': "801acfb381f1738ba4e9e792",
        'credential': "xb8Y+/nANmaFf1Um",
      },
      {
        'urls': "turn:standard.relay.metered.ca:443",
        'username': "801acfb381f1738ba4e9e792",
        'credential': "xb8Y+/nANmaFf1Um",
      },
      {
        'urls': "turns:standard.relay.metered.ca:443?transport=tcp",
        'username': "801acfb381f1738ba4e9e792",
        'credential': "xb8Y+/nANmaFf1Um",
      },
    ],
  };

  @override
  void initState() {
    super.initState();
    VideoCallScreen.isActive = true;

    // FIXED: Executing directly out of initState ensures that no matter how
    // many layout frame updates occur, the loop triggers exactly once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hasStartedBootstrap) {
        _hasStartedBootstrap = true;

        // Safely extract the arguments from the modal context inside post-frame layout bounds
        final remoteSdpArgs =
            ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

        if (remoteSdpArgs != null) {
          // FIXED: Map the dynamic argument variable securely to your class instance property scope
          _myIdFromArgs = remoteSdpArgs['myRegisteredId'];
        }

        _bootstrapWebRTC(remoteSdpArgs);
      }
    });
  }

  // Inside video_call_screen.dart -> Add this tracking variable to your State class
  // bool _isHardwareConfiguredDone = false;

  void _bootstrapWebRTC(dynamic args) async {
    try {
      await _localRenderer.initialize();
      await _initializeLocalHardware();
      _bindMeshCallSignaling();

      if (args != null && args is Map) {
        // Check if we are initiating the call or answering
        bool isCaller = args['isCaller'] ?? false;
        String targetPeerId = args['targetId'] ?? "browser_node";

        if (isCaller) {
          debugPrint("--> App initiating outgoing call to $targetPeerId");
          await _createOutgoingMeshOffer(targetPeerId);
        } else {
          // Existing incoming call answer workflow
          String actualSenderId = args['senderId'] ?? "browser_node";
          dynamic remoteSdp = args['sdp'];
          await _handleIncomingMeshOffer(actualSenderId, remoteSdp);
        }
      }
    } catch (e) {
      debugPrint("Initialization failure: $e");
    }
  }

  Future<void> _createOutgoingMeshOffer(String targetPeerId) async {
    if (_peerConnections.containsKey(targetPeerId)) return;

    try {
      _isHandshakeComplete = false;

      // 1. Create a fresh peer node connection mapping
      RTCPeerConnection pc = await _createNewPeerConnectionNode(targetPeerId);

      // 2. Attach our camera/microphone tracks BEFORE creating the offer
      if (_localStream != null) {
        for (var track in _localStream!.getTracks()) {
          await pc.addTrack(track, _localStream!);
          debugPrint(
            "--> Attached outgoing track (${track.kind}) to $targetPeerId",
          );
        }
      }

      // 3. Generate the WebRTC offer SDP
      RTCSessionDescription offer = await pc.createOffer({
        'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      });

      // 4. Save locally to start generating our ICE candidates
      await pc.setLocalDescription(offer);

      // FIXED: Allow WebRTC a brief window to gather local connection candidates
      // into the SDP profile string before broadcasting it to the network hub.
      int checks = 0;
      while (pc.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete &&
          checks < 20) {
        await Future.delayed(const Duration(milliseconds: 50));
        checks++;
      }

      // Fetch the updated local description containing bundled network routes
      final stableOffer = await pc.getLocalDescription();

      // 5. Send it to the background isolate to deliver to the target peer node
      FlutterBackgroundService().invoke('sendSignal', {
        'payload': json.encode({
          'type': 'offer',
          'targetId': targetPeerId,
          'senderId':
              _myIdFromArgs ??
              'unknown tablet', // Use the registered ID from args if available
          'senderName': 'Lito', // Properly configured custom identity anchor
          'sdp':
              stableOffer?.sdp ?? offer.sdp, // Fallback if gathering timed out
        }),
      });
    } catch (e) {
      debugPrint("Failed to create outgoing call session: $e");
      _closeAllCallsAndExit();
    }
  }

  // video_call_screen.dart

  @override
  void dispose() {
    VideoCallScreen.isActive = false;

    if (_serviceSubscription != null) {
      _serviceSubscription!.cancel();
      _serviceSubscription = null;
      debugPrint("--> Cleaned up zombie signaling stream listener.");
    }

    _localRenderer.dispose();
    super.dispose();
  }

  bool _isHardwareReady = false;

  Future<void> _initializeLocalHardware() async {
    // 1. FIXED: Synchronous block check. No await before this line!
    if (_isHardwareReady || _localStream != null) {
      debugPrint("--> Atomic Guard: Dropped parallel stream setup.");
      return;
    }
    _isHardwareReady = true; // Lock the execution track instantly

    try {
      debugPrint(
        "--> Requesting hardware permissions and initializing combined media streams...",
      );

      // Captures both camera and microphone safely in ONE single hardware request
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {'echoCancellation': true, 'noiseSuppression': true},
        'video': {'width': 640, 'height': 480, 'facingMode': 'user'},
      });

      if (mounted && _localStream != null) {
        setState(() {
          _localRenderer.srcObject = _localStream;
        });
        debugPrint(
          "--> Audio and Video hardware tracks successfully mapped in a single pass.",
        );
      }
    } catch (e) {
      _isHardwareReady = false; // Reset only on a genuine failure
      debugPrint("CRITICAL: Camera/Microphone access failed: $e");
    }
  }

  void _bindMeshCallSignaling() {
    _serviceSubscription = FlutterBackgroundService()
        .on('onSignalReceived')
        .listen((event) async {
          if (event == null || event['data'] == null || !mounted) return;
          var data = json.decode(event['data']);
          String? peerId = data['senderId'];

          switch (data['type']) {
            case 'registered':
              _myNodeId = data['id'];
              break;

            case 'offer':
              if (peerId == null || peerId == _myNodeId) return;
              // If we are already handling a connection with this peer, drop duplication
              if (_peerConnections.containsKey(peerId)) {
                debugPrint(
                  "--> Ignored duplicate offer packet for active peer: $peerId",
                );
                return;
              }
              await _handleIncomingMeshOffer(peerId, data['sdp']);
              break;

            case 'answer':
              if (peerId == null) return;
              // remoteSdp is already the string payload here
              await _handleIncomingMeshAnswer(peerId, data['sdp'].toString());
              break;

            case 'ice-candidate':
              if (peerId == null) return;
              if (data['candidate'] != null) {
                var candidateMap = data['candidate'];
                String rawCandidateString = candidateMap['candidate'] ?? '';

                if (rawCandidateString.contains(' tcp ') ||
                    rawCandidateString.contains('tcptype') ||
                    rawCandidateString.contains('fdf7:')) {
                  return;
                }

                var candidateObject = RTCIceCandidate(
                  candidateMap['candidate'],
                  candidateMap['sdpMid'],
                  candidateMap['sdpMLineIndex'],
                );

                if (_isHandshakeComplete &&
                    _peerConnections.containsKey(peerId)) {
                  try {
                    await _peerConnections[peerId]!.addCandidate(
                      candidateObject,
                    );
                  } catch (_) {}
                } else {
                  _bufferedRemoteIceCandidates
                      .putIfAbsent(peerId, () => [])
                      .add(candidateObject);
                }
              }
              break;

            case 'hangup':
              if (peerId == null) return;
              _removePeer(peerId);
              break;
          }
        });
  }

  Future<RTCPeerConnection> _createNewPeerConnectionNode(String peerId) async {
    if (!_remoteRenderers.containsKey(peerId)) {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      _remoteRenderers[peerId] = renderer;
    }

    RTCPeerConnection pc = await createPeerConnection(_rtcConfig, const {});

    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        if (_remoteRenderers[peerId]?.srcObject == null) {
          if (mounted) {
            setState(() {
              _remoteRenderers[peerId]!.srcObject = event.streams.first;
            });
          }
        }
      }
    };

    pc.onIceCandidate = (RTCIceCandidate candidate) {
      FlutterBackgroundService().invoke('sendSignal', {
        'payload': json.encode({
          'type': 'ice-candidate',
          'targetId': peerId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        }),
      });
    };

    _peerConnections[peerId] = pc;
    return pc;
  }

  Future<void> _handleIncomingMeshOffer(
    String peerId,
    dynamic remoteSdp,
  ) async {
    if (_peerConnections.containsKey(peerId) ||
        _activeHandshakesInFlight.contains(peerId)) {
      debugPrint(
        "--> Dropping overlapping parallel offer execution for $peerId",
      );
      return;
    }

    try {
      _activeHandshakesInFlight.add(peerId);
      _isHandshakeComplete = false;

      RTCPeerConnection pc;
      if (!_peerConnections.containsKey(peerId)) {
        pc = await _createNewPeerConnectionNode(peerId);
      } else {
        pc = _peerConnections[peerId]!;
      }

      String sdpString = (remoteSdp is Map && remoteSdp.containsKey('sdp'))
          ? remoteSdp['sdp']
          : remoteSdp.toString();

      if (sdpString.endsWith('a=rt')) {
        sdpString = sdpString.replaceAll('a=rt', 'a=rtcp-mux\r\n');
      }
      if (!sdpString.endsWith('\r\n')) {
        sdpString += '\r\n';
      }

      // 1. First set the remote description from the browser
      await pc.setRemoteDescription(RTCSessionDescription(sdpString, 'offer'));

      // 2. FIXED: Attach local tracks BEFORE creating the Answer SDP
      // This forces WebRTC to write the tablet's camera streams into the answer payload.
      if (_localStream != null) {
        for (var track in _localStream!.getTracks()) {
          try {
            await pc.addTrack(track, _localStream!);
            debugPrint(
              "--> Attached local track (${track.kind}) to peer $peerId before generating SDP.",
            );
          } catch (e) {
            debugPrint("Track attach error: $e");
          }
        }
      }

      // 3. Now generate the Answer containing the attached media blocks
      RTCSessionDescription answer = await pc.createAnswer({
        'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      });
      await pc.setLocalDescription(answer);

      // 4. Ship the complete, track-aware Answer to the signaling server
      FlutterBackgroundService().invoke('sendSignal', {
        'payload': json.encode({
          'type': 'answer',
          'targetId': peerId,
          'sdp': answer.sdp,
        }),
      });

      if (mounted) {
        setState(() {
          _isHandshakeComplete = true;
        });
      }

      if (_bufferedRemoteIceCandidates.containsKey(peerId)) {
        final List<RTCIceCandidate> candidates = List.from(
          _bufferedRemoteIceCandidates[peerId]!,
        );
        _bufferedRemoteIceCandidates.remove(peerId);

        for (var cand in candidates) {
          try {
            await pc.addCandidate(cand);
          } catch (_) {}
        }
      }
    } catch (error) {
      debugPrint("Handshake crashed safely: $error");
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _removePeer(peerId);
      });
    } finally {
      _activeHandshakesInFlight.remove(peerId);
    }
  }

  Future<void> _handleIncomingMeshAnswer(
    String peerId,
    String sdpString,
  ) async {
    if (_peerConnections.containsKey(peerId)) {
      try {
        // 1. Set the remote description sent by the browser
        await _peerConnections[peerId]!.setRemoteDescription(
          RTCSessionDescription(sdpString, 'answer'),
        );

        if (mounted) {
          setState(() {
            _isHandshakeComplete = true;
          });
        }
        debugPrint("--> WebRTC Handshake completed successfully with $peerId");

        // 2. FIXED: Immediately drain early buffered ICE candidates for outbound calls
        if (_bufferedRemoteIceCandidates.containsKey(peerId)) {
          final List<RTCIceCandidate> candidates = List.from(
            _bufferedRemoteIceCandidates[peerId]!,
          );
          _bufferedRemoteIceCandidates.remove(peerId);

          for (var cand in candidates) {
            try {
              await _peerConnections[peerId]!.addCandidate(cand);
              debugPrint(
                "--> Drained early candidate for outbound peer: $peerId",
              );
            } catch (e) {
              debugPrint("Failed to apply drained candidate: $e");
            }
          }
        }
      } catch (e) {
        debugPrint("CRITICAL: Failed to apply remote answer description: $e");
      }
    }
  }

  void _removePeer(String peerId) async {
    _activeHandshakesInFlight.remove(peerId);
    _bufferedRemoteIceCandidates.remove(peerId);

    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      try {
        await pc.close();
        await pc.dispose();
      } catch (_) {}
    }

    final renderer = _remoteRenderers.remove(peerId);
    if (renderer != null) {
      try {
        renderer.dispose();
      } catch (_) {}
    }

    if (mounted) {
      setState(() {});
    }

    if (_peerConnections.isEmpty) {
      _closeAllCallsAndExit();
    }
  }

  // video_call_screen.dart -> Inside _closeAllCallsAndExit()
  void _closeAllCallsAndExit() async {
    VideoCallScreen.isActive = false;
    _isHardwareReady = false;
    // _isHardwareConfiguredDone = false;

    String? activePeerId = _peerConnections.keys.isNotEmpty
        ? _peerConnections.keys.first
        : null;

    try {
      if (activePeerId != null) {
        FlutterBackgroundService().invoke('sendSignal', {
          'payload': json.encode({'type': 'hangup', 'targetId': activePeerId}),
        });
      }

      // This triggers the 'decline' action block we fixed above, emptying the queues
      FlutterBackgroundService().invoke("notificationAction", {
        "action": "decline",
      });

      FlutterBackgroundService().invoke('sendSignal', {
        'payload': json.encode({
          'type': 'register-tablet',
          'id': _myNodeId,
          'name': 'Lito',
        }),
      });
    } catch (e) {
      debugPrint("Error sending clean hangup signal: $e");
    }

    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) => track.stop());
      await _localStream!.dispose();
      _localStream = null;
    }

    // Wiping connections completely
    final activePeers = List<String>.from(_peerConnections.keys);
    for (var peerId in activePeers) {
      final pc = _peerConnections.remove(peerId);
      try {
        await pc?.close();
        await pc?.dispose();
      } catch (_) {}
    }

    final activeRenderers = List<String>.from(_remoteRenderers.keys);
    for (var peerId in activeRenderers) {
      final r = _remoteRenderers.remove(peerId);
      try {
        r?.dispose();
      } catch (_) {}
    }

    // FIXED: Explicitly reset structural control flags to initial states
    _bufferedRemoteIceCandidates.clear();
    _activeHandshakesInFlight.clear();
    _hasStartedBootstrap = false;
    _isHandshakeComplete = false;

    if (_serviceSubscription != null) {
      await _serviceSubscription!.cancel();
      _serviceSubscription = null;
      debugPrint("--> Terminated subscription on explicit call exit.");
    }

    if (mounted) {
      Navigator.popUntil(context, ModalRoute.withName('/'));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Take an isolated map snapshot entry list copy BEFORE running layout generation.
    // If an error drops or modifies a renderer map mid-build, the UI loops over this
    // snapshot copy safely, preventing ConcurrentModificationErrors.
    final remoteEntriesSnapshot = _remoteRenderers.entries.toList();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  children: [
                    Expanded(
                      key: const ValueKey('local_window_bucket'),
                      child: _buildVideoViewFrame(
                        "You (Local)",
                        _localRenderer,
                        true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      key: const ValueKey('remote_windows_bucket'),
                      child: remoteEntriesSnapshot.isEmpty
                          ? Container(
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Center(
                                child: Text(
                                  "Connecting stream...",
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ),
                            )
                          : Row(
                              children: remoteEntriesSnapshot.map((entry) {
                                return Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4.0,
                                    ),
                                    child: _buildVideoViewFrame(
                                      "User: ${entry.key}",
                                      entry.value,
                                      false,
                                      key: ValueKey(
                                        'remote_renderer_frame_${entry.key}',
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: FloatingActionButton(
                  backgroundColor: Colors.red,
                  onPressed: _closeAllCallsAndExit,
                  child: const Icon(Icons.call_end, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoViewFrame(
    String label,
    RTCVideoRenderer renderer,
    bool mirror, {
    Key? key,
  }) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: Colors.grey,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(child: RTCVideoView(renderer, mirror: mirror)),
          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: const TextStyle(fontSize: 12, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
