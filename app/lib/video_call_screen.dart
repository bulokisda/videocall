import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:call/main.dart';
import 'package:call/preference_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const String _renderHttpBaseUrl = 'https://family-video-signaler.onrender.com';

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
  bool _isHandshakeComplete = false;
  bool _hasStartedBootstrap = false;
  String? _myNodeId;
  String? _myIdFromArgs;

  final Map<String, dynamic> _fallbackRtcConfig = {
    'iceServers': [
      {'urls': "stun:stun.relay.metered.ca:80"},
      {'urls': "stun:stun.l.google.com:19302"},
    ],
  };

  /// Fetches short-lived Metered TURN credentials from Render using the stored secret
  Future<Map<String, dynamic>> _fetchDynamicRtcConfig() async {
    final token = await PreferenceService.getRoomSecret();
    if (token == null || token.isEmpty) return _fallbackRtcConfig;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse(
        '$_renderHttpBaseUrl/ice-servers?token=${Uri.encodeComponent(token)}',
      );
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final servers = decoded['iceServers'];
        if (servers is List && servers.isNotEmpty) {
          debugPrint("--> Loaded ${servers.length} dynamic ICE/TURN servers.");
          return {'iceServers': servers};
        }
      }
    } catch (e) {
      debugPrint("--> Dynamic TURN fetch failed, using STUN fallback: $e");
    } finally {
      client.close();
    }
    return _fallbackRtcConfig;
  }

  @override
  void initState() {
    super.initState();
    VideoCallScreen.isActive = true;

    WidgetsBinding.instance.addPostFrameCallback((frame) {
      if (!_hasStartedBootstrap) {
        _hasStartedBootstrap = true;

        final remoteSdpArgs =
            ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

        if (remoteSdpArgs != null) {
          _myIdFromArgs = remoteSdpArgs['myRegisteredId'];
        }

        _bootstrapWebRTC(remoteSdpArgs);
      }
    });
  }

  void _bootstrapWebRTC(dynamic args) async {
    try {
      await _localRenderer.initialize();
      await _initializeLocalHardware();
      _bindMeshCallSignaling();

      if (args != null && args is Map) {
        bool isCaller = args['isCaller'] ?? false;
        String targetPeerId = args['targetId'] ?? "browser_node";

        if (isCaller) {
          debugPrint("--> App initiating outgoing call to $targetPeerId");
          await _createOutgoingMeshOffer(targetPeerId);
        } else {
          String actualSenderId = args['senderId'] ?? "browser_node";
          dynamic remoteSdp = args['sdp'];
          if (remoteSdp == null || remoteSdp.toString().isEmpty) {
            debugPrint(
              "❌ Missing SDP payload on incoming call answer. Exiting.",
            );
            _closeAllCallsAndExit();
            return;
          }
          await _handleIncomingMeshOffer(actualSenderId, remoteSdp);
        }
      } else {
        debugPrint("❌ VideoCallScreen launched with null arguments. Exiting.");
        _closeAllCallsAndExit();
      }
    } catch (e) {
      debugPrint("Initialization failure: $e");
    }
  }

  Future<void> _createOutgoingMeshOffer(String targetPeerId) async {
    if (_peerConnections.containsKey(targetPeerId)) return;

    try {
      _isHandshakeComplete = false;

      RTCPeerConnection pc = await _createNewPeerConnectionNode(targetPeerId);

      if (_localStream != null) {
        for (var track in _localStream!.getTracks()) {
          await pc.addTrack(track, _localStream!);
          debugPrint(
            "--> Attached outgoing track (${track.kind}) to $targetPeerId",
          );
        }
      }

      RTCSessionDescription offer = await pc.createOffer({
        'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      });

      await pc.setLocalDescription(offer);

      int checks = 0;
      while (pc.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete &&
          checks < 20) {
        await Future.delayed(const Duration(milliseconds: 50));
        checks++;
      }

      final stableOffer = await pc.getLocalDescription();

      FlutterBackgroundService().invoke('sendSignal', {
        'payload': json.encode({
          'type': 'offer',
          'targetId': targetPeerId,
          'senderId': _myIdFromArgs ?? 'unknown tablet',
          'senderName': savedUsername ?? 'Unknown User',
          'sdp': stableOffer?.sdp ?? offer.sdp,
        }),
      });
    } catch (e) {
      debugPrint("Failed to create outgoing call session: $e");
      _closeAllCallsAndExit();
    }
  }

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
    if (_isHardwareReady || _localStream != null) {
      debugPrint("--> Atomic Guard: Dropped parallel stream setup.");
      return;
    }
    _isHardwareReady = true;

    try {
      debugPrint(
        "--> Requesting hardware permissions and initializing combined media streams...",
      );

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
      _isHardwareReady = false;
      debugPrint("CRITICAL: Camera/Microphone access failed: $e");
    }
  }

  void _bindMeshCallSignaling() {
    _serviceSubscription?.cancel();
    _serviceSubscription = globalSignalStream.stream.listen((rawMessage) async {
      if (!mounted) return;
      var data = json.decode(rawMessage);
      String? peerId = data['senderId'];

      switch (data['type']) {
        case 'registered':
          _myNodeId = data['id'];
          break;

        case 'offer':
          if (peerId == null || peerId == _myNodeId) return;
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
          final rawAnswerSdp =
              (data['sdp'] is Map && data['sdp']['sdp'] != null)
              ? data['sdp']['sdp'].toString()
              : data['sdp'].toString();
          await _handleIncomingMeshAnswer(peerId, rawAnswerSdp);
          break;

        case 'ice-candidate':
          if (peerId == null) return;
          if (data['candidate'] != null) {
            var candidateMap = data['candidate'];
            String rawCandidateString = candidateMap['candidate'] ?? '';

            if (rawCandidateString.contains('fdf7:')) {
              debugPrint(
                "--> Dropping local IPv6 anchor link: $rawCandidateString",
              );
              return;
            }

            var candidateObject = RTCIceCandidate(
              candidateMap['candidate'],
              candidateMap['sdpMid'],
              candidateMap['sdpMLineIndex'],
            );

            if (_isHandshakeComplete && _peerConnections.containsKey(peerId)) {
              try {
                await _peerConnections[peerId]!.addCandidate(candidateObject);
              } catch (e) {
                debugPrint("Failed to add candidate: $e");
              }
            } else {
              _bufferedRemoteIceCandidates
                  .putIfAbsent(peerId, () => [])
                  .add(candidateObject);
            }
          }
          break;

        case 'call-decline':
          if (peerId == null) return;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Call declined'),
                duration: Duration(seconds: 3),
              ),
            );
          }
          _removePeer(peerId);
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

    final rtcConfig = await _fetchDynamicRtcConfig();
    RTCPeerConnection pc = await createPeerConnection(rtcConfig, const {});

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

  Future _handleIncomingMeshOffer(String peerId, dynamic remoteSdp) async {
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
      debugPrint(
        "--> Preparing native WebRTC engine workspace for incoming handshake...",
      );
      await Future.delayed(const Duration(milliseconds: 400));
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
      debugPrint(
        "--> Applying browser remote offer description mapping string...",
      );
      await pc.setRemoteDescription(RTCSessionDescription(sdpString, 'offer'));
      debugPrint("--> Remote description applied successfully.");
      if (globalPendingCandidates.containsKey(peerId)) {
        final earlyList = List<Map<String, dynamic>>.from(
          globalPendingCandidates.remove(peerId)!,
        );
        for (final item in earlyList) {
          final candMap = item['candidate'];
          if (candMap != null) {
            try {
              await pc.addCandidate(
                RTCIceCandidate(
                  candMap['candidate'],
                  candMap['sdpMid'],
                  candMap['sdpMLineIndex'],
                ),
              );
            } catch (e) {
              debugPrint("Early global candidate error: $e");
            }
          }
        }
      }

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
      RTCSessionDescription answer = await pc.createAnswer({
        'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      });
      await pc.setLocalDescription(answer);
      int checks = 0;
      while (pc.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete &&
          checks < 20) {
        await Future.delayed(const Duration(milliseconds: 50));
        checks++;
      }
      final stableAnswer = await pc.getLocalDescription();
      FlutterBackgroundService().invoke('sendSignal', {
        'payload': json.encode({
          'type': 'answer',
          'targetId': peerId,
          'sdp': stableAnswer?.sdp ?? answer.sdp,
        }),
      });
      debugPrint("--> Answer successfully dispatched to signaling hub.");
      if (mounted) {
        setState(() {
          _isHandshakeComplete = true;
        });
      }
      if (_bufferedRemoteIceCandidates.containsKey(peerId)) {
        final List candidates = List.from(
          _bufferedRemoteIceCandidates[peerId]!,
        );
        _bufferedRemoteIceCandidates.remove(peerId);
        debugPrint(
          "--> Draining ${candidates.length} early buffered candidates...",
        );
        for (var cand in candidates) {
          try {
            await pc.addCandidate(cand);
          } catch (e) {
            debugPrint("Failed to add drained candidate: $e");
          }
        }
      }
    } catch (error) {
      debugPrint(
        "❌ CRITICAL: Handshake crashed inside video_call_screen: $error",
      );
      WidgetsBinding.instance.addPostFrameCallback((frame) {
        if (mounted) _removePeer(peerId);
      });
    } finally {
      _activeHandshakesInFlight.remove(peerId);
    }
  }

  Future _handleIncomingMeshAnswer(String peerId, String sdpString) async {
    if (_peerConnections.containsKey(peerId)) {
      try {
        await _peerConnections[peerId]!.setRemoteDescription(
          RTCSessionDescription(sdpString, 'answer'),
        );
        if (mounted) {
          setState(() {
            _isHandshakeComplete = true;
          });
        }
        debugPrint("--> WebRTC Handshake completed successfully with $peerId");
        if (_bufferedRemoteIceCandidates.containsKey(peerId)) {
          final List candidates = List.from(
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
      } catch (e) {
        debugPrint("Error closing peer connection: $e");
      }
    }
    final renderer = _remoteRenderers.remove(peerId);
    if (renderer != null) {
      try {
        renderer.dispose();
      } catch (e) {
        debugPrint("Error disposing renderer: $e");
      }
    }
    if (mounted) {
      setState(() {});
    }
    if (_peerConnections.isEmpty) {
      _closeAllCallsAndExit();
    }
  }

  void _closeAllCallsAndExit() async {
    VideoCallScreen.isActive = false;
    _isHardwareReady = false;
    String? activePeerId = _peerConnections.keys.isNotEmpty
        ? _peerConnections.keys.first
        : null;
    try {
      if (activePeerId != null) {
        FlutterBackgroundService().invoke('sendSignal', {
          'payload': json.encode({'type': 'hangup', 'targetId': activePeerId}),
        });
      }
      FlutterBackgroundService().invoke('endCall');
    } catch (e) {
      debugPrint("Error sending clean hangup signal: $e");
    }
    if (_localStream != null) {
      _localStream!.getTracks().forEach((track) => track.stop());
      await _localStream!.dispose();
      _localStream = null;
    }
    final activePeers = List.from(_peerConnections.keys);
    for (var peerId in activePeers) {
      final pc = _peerConnections.remove(peerId);
      try {
        await pc?.close();
        await pc?.dispose();
      } catch (e) {
        debugPrint("Error disposing peer on exit: $e");
      }
    }
    final activeRenderers = List.from(_remoteRenderers.keys);
    for (var peerId in activeRenderers) {
      final r = _remoteRenderers.remove(peerId);
      try {
        r?.dispose();
      } catch (e) {
        debugPrint("Error disposing renderer on exit: $e");
      }
    }
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
    final remoteEntriesSnapshot = _remoteRenderers.entries.toList();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: OrientationBuilder(
          builder: (context, orientation) {
            final isLandscape = orientation == Orientation.landscape;
            Widget localControlPanel = Flex(
              direction: isLandscape ? Axis.vertical : Axis.horizontal,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  key: const ValueKey('local_window_bucket'),
                  height: isLandscape ? 120 : 180,
                  width: isLandscape ? 140 : 200,
                  child: _buildVideoViewFrame("", _localRenderer, true),
                ),
                if (isLandscape)
                  const SizedBox(height: 16)
                else
                  const SizedBox(width: 8),
                FloatingActionButton(
                  backgroundColor: Colors.red,
                  onPressed: _closeAllCallsAndExit,
                  child: const Icon(Icons.call_end, color: Colors.white),
                ),
              ],
            );
            Widget remoteStreamsPanel = remoteEntriesSnapshot.isEmpty
                ? Container(
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Text(
                        "Connecting...",
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  )
                : Flex(
                    direction: isLandscape ? Axis.vertical : Axis.horizontal,
                    children: remoteEntriesSnapshot.map((entry) {
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: isLandscape ? 0.0 : 4.0,
                            vertical: isLandscape ? 4.0 : 0.0,
                          ),
                          child: _buildVideoViewFrame(
                            "",
                            entry.value,
                            false,
                            key: ValueKey('remote_renderer_frame${entry.key}'),
                          ),
                        ),
                      );
                    }).toList(),
                  );
            return Padding(
              padding: const EdgeInsets.all(8.0),
              child: Flex(
                direction: isLandscape ? Axis.horizontal : Axis.vertical,
                children: [
                  if (isLandscape) ...[
                    localControlPanel,
                    const SizedBox(width: 12),
                    Expanded(
                      key: const ValueKey('remote_windows_bucket'),
                      child: remoteStreamsPanel,
                    ),
                  ] else ...[
                    localControlPanel,
                    const SizedBox(height: 8),
                    Expanded(
                      key: const ValueKey('remote_windows_bucket'),
                      child: remoteStreamsPanel,
                    ),
                  ],
                ],
              ),
            );
          },
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
        color: Colors.black,
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
