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
  bool _isHardwareAllocationLocked = false;
  String? _myNodeId;

  final Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {
        'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'],
      },
    ],
    'sdpSemantics': 'unified-plan',
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
        final remoteSdpArgs = ModalRoute.of(context)?.settings.arguments;
        _bootstrapWebRTC(remoteSdpArgs);
      }
    });
  }

  // FIXED: Simplified bootstrap setup with absolute execution isolation
  void _bootstrapWebRTC(dynamic args) async {
    try {
      await _localRenderer.initialize();
      _bindMeshCallSignaling();
      
      await _initializeLocalHardware();

      if (args != null && args is Map) {
        String actualSenderId = args['senderId'] ?? "browser_node";
        dynamic remoteSdp = args['sdp'];
        await _handleIncomingMeshOffer(actualSenderId, remoteSdp);
      }
    } catch (e) {
      debugPrint("Initialization failure: $e");
    }
  }

  @override
  void dispose() {
    VideoCallScreen.isActive = false;
    _serviceSubscription?.cancel();
    _localRenderer.dispose();
    super.dispose();
  }


  // 2. Replace your existing _initializeLocalHardware method with this implementation:
  Future<void> _initializeLocalHardware() async {
    // FIXED: An atomic guard gate. If this method is called a second time 
    // while the first one is running or completed, it drops out instantly.
    if (_isHardwareAllocationLocked) {
      debugPrint("--> Blocked duplicate parallel hardware track allocation attempt.");
      return;
    }
    
    try {
      _isHardwareAllocationLocked = true; // Lock the gate immediately
      
      debugPrint("--> Requesting hardware permissions and initializing media streams...");
      
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'width': 640,
          'height': 480,
          'facingMode': 'user',
        },
      });
      
      if (mounted && _localStream != null) {
        setState(() {
          _localRenderer.srcObject = _localStream;
        });
        debugPrint("--> Video hardware track successfully mapped and rendered.");
      }

      // Safe, delayed separation for the audio channel track allocation
      await Future.delayed(const Duration(milliseconds: 500));

      if (mounted && VideoCallScreen.isActive) {
        try {
          MediaStream audioStream = await navigator.mediaDevices.getUserMedia({
            'audio': {
              'echoCancellation': true,
              'noiseSuppression': true,
            },
            'video': false,
          });

          if (audioStream.getAudioTracks().isNotEmpty) {
            final audioTrack = audioStream.getAudioTracks().first;
            await _localStream?.addTrack(audioTrack);
            debugPrint("--> Audio hardware track successfully mapped into stream pool.");
          }
        } catch (audioError) {
          debugPrint("Bypassed non-fatal Audio initialization variance: $audioError");
        }
      }

    } catch (e) {
      _isHardwareAllocationLocked = false; // Release the gate only on a true fatal exception
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
              await _handleIncomingMeshOffer(peerId, data['sdp']);
              break;

            case 'answer':
              if (peerId == null) return;
              await _handleIncomingMeshAnswer(peerId, data['sdp']);
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

      // FIXED: Safely verify if a node is currently under construction.
      // If it isn't, create it. If it is under construction, wait for it to complete.
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

      // Ensure the native C++ handle exists before executing native methods
      await pc.setRemoteDescription(RTCSessionDescription(sdpString, 'offer'));

      RTCSessionDescription answer = await pc.createAnswer({
        'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      });
      await pc.setLocalDescription(answer);

      if (_localStream != null) {
        for (var track in _localStream!.getTracks()) {
          try {
            await pc.addTrack(track, _localStream!);
          } catch (_) {}
        }
      }

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
    dynamic remoteSdp,
  ) async {
    if (_peerConnections.containsKey(peerId)) {
      try {
        String sdpString = (remoteSdp is Map && remoteSdp.containsKey('sdp'))
            ? remoteSdp['sdp']
            : remoteSdp.toString();
        await _peerConnections[peerId]!.setRemoteDescription(
          RTCSessionDescription(sdpString, 'answer'),
        );
      } catch (_) {}
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

  void _closeAllCallsAndExit() async {
    VideoCallScreen.isActive = false;

    _localStream?.getTracks().forEach((track) => track.stop());
    await _localStream?.dispose();
    _localStream = null;

    // Use a snapshot list to clear connections safely without modifying the collection during iteration
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

    if (mounted) {
      Navigator.pushReplacementNamed(context, '/');
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
