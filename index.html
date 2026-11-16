<!DOCTYPE html>
<html lang="en">

<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <!-- Strict Content Security Policy: blocks unauthorized scripts and restricts network calls to Render & Metered -->
    <meta http-equiv="Content-Security-Policy" content="
    default-src 'self';
    script-src 'self' 'unsafe-inline';
    style-src 'self' 'unsafe-inline';
    connect-src 'self' wss://family-video-signaler.onrender.com https://family-video-signaler.onrender.com https://*.metered.live;
  " />
    <title>Bisnan Calling</title>
    <style>
        :root {
            --bg: #0f172a;
            --card: #1e293b;
            --accent: #3b82f6;
            --accent-hover: #2563eb;
            --danger: #ef4444;
            --success: #22c55e;
            --text: #f8fafc;
            --muted: #94a3b8;
        }

        * {
            box-sizing: border-box;
        }

        body {
            margin: 0;
            font-family: system-ui, -apple-system, sans-serif;
            background: var(--bg);
            color: var(--text);
            display: flex;
            flex-direction: column;
            align-items: center;
            min-height: 100vh;
            padding: 1.5rem;
        }

        .container {
            width: 100%;
            max-width: 900px;
            display: flex;
            flex-direction: column;
            gap: 1.25rem;
        }

        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 0.75rem;
        }

        h1 {
            margin: 0;
            font-size: 1.5rem;
        }

        .status-badge {
            padding: 0.35rem 0.75rem;
            border-radius: 999px;
            font-size: 0.85rem;
            background: var(--card);
            color: var(--muted);
        }

        .status-badge.connected {
            color: var(--success);
            border: 1px solid var(--success);
        }

        .status-badge.error {
            color: var(--danger);
            border: 1px solid var(--danger);
        }

        .card {
            background: var(--card);
            border-radius: 12px;
            padding: 1.25rem;
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.25);
        }

        .auth-row,
        .controls {
            display: flex;
            gap: 0.75rem;
            flex-wrap: wrap;
            align-items: center;
        }

        input {
            background: #0f172a;
            border: 1px solid #334155;
            color: var(--text);
            padding: 0.65rem 0.9rem;
            border-radius: 8px;
            font-size: 0.95rem;
            flex: 1;
            min-width: 180px;
        }

        button {
            background: var(--accent);
            color: white;
            border: none;
            padding: 0.65rem 1.1rem;
            border-radius: 8px;
            font-size: 0.95rem;
            font-weight: 600;
            cursor: pointer;
        }

        button:hover:not(:disabled) {
            background: var(--accent-hover);
        }

        button:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }

        button.danger {
            background: var(--danger);
        }

        button.secondary {
            background: #334155;
        }

        .videos {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 1rem;
        }

        .video-box {
            position: relative;
            background: #020617;
            border-radius: 12px;
            overflow: hidden;
            aspect-ratio: 16 / 9;
        }

        video {
            width: 100%;
            height: 100%;
            object-fit: cover;
        }

        .video-label {
            position: absolute;
            bottom: 0.5rem;
            left: 0.75rem;
            background: rgba(15, 23, 42, 0.75);
            padding: 0.25rem 0.6rem;
            border-radius: 6px;
            font-size: 0.8rem;
        }

        .peer-list {
            display: flex;
            flex-direction: column;
            gap: 0.6rem;
            margin-top: 0.75rem;
        }

        .peer-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            background: #0f172a;
            padding: 0.75rem 1rem;
            border-radius: 8px;
        }
    </style>
</head>

<body>
    <div class="container">
        <header>
            <h1>Bisnan Calling Secure</h1>
            <span id="statusBadge" class="status-badge">Disconnected</span>
        </header>

        <!-- Family Access Setup (Stored locally in browser, never hardcoded in GitHub) -->
        <div class="card">
            <div class="auth-row">
                <input id="callerNameInput" type="text" placeholder="Your Name (e.g. Mom, Dad)" maxlength="30" />
                <input id="roomSecretInput" type="password" placeholder="Family Room Secret" />
                <button id="connectBtn">Save &amp; Connect</button>
                <button id="clearAuthBtn" class="secondary" title="Clear saved secret">Reset</button>
            </div>
        </div>

        <!-- Camera & Call Controls -->
        <div class="card">
            <div class="controls">
                <button id="startCamBtn">Start Camera</button>
                <button id="toggleMicBtn" class="secondary" disabled>Mute Mic</button>
                <button id="toggleCamBtn" class="secondary" disabled>Turn Off Video</button>
                <button id="hangupBtn" class="danger" disabled>Hang Up</button>
            </div>
        </div>

        <!-- Video Streams -->
        <div class="videos">
            <div class="video-box">
                <video id="localVideo" autoplay playsinline muted></video>
                <span class="video-label">You</span>
            </div>
            <div class="video-box">
                <video id="remoteVideo" autoplay playsinline></video>
                <span id="remoteLabel" class="video-label">Remote Caller</span>
            </div>
        </div>

        <!-- Online Family Devices -->
        <div class="card">
            <strong>Online Family Devices</strong>
            <div id="peerList" class="peer-list">
                <span style="color: var(--muted); font-size: 0.9rem;">Enter your name and Family Room Secret to see
                    online devices.</span>
            </div>
        </div>
    </div>

    <script>
        const RENDER_HTTP_BASE = 'https://family-video-signaler.onrender.com';
        const RENDER_WS_BASE = 'wss://family-video-signaler.onrender.com';

        let ws = null;
        let pc = null;
        let localStream = null;
        let myId = null;
        let activeTargetId = null;
        let cachedIceServers = [{ urls: 'stun:stun.l.google.com:19302' }];
        let reconnectTimer = null;

        const statusBadge = document.getElementById('statusBadge');
        const callerNameInput = document.getElementById('callerNameInput');
        const roomSecretInput = document.getElementById('roomSecretInput');
        const connectBtn = document.getElementById('connectBtn');
        const clearAuthBtn = document.getElementById('clearAuthBtn');
        const startCamBtn = document.getElementById('startCamBtn');
        const toggleMicBtn = document.getElementById('toggleMicBtn');
        const toggleCamBtn = document.getElementById('toggleCamBtn');
        const hangupBtn = document.getElementById('hangupBtn');
        const localVideo = document.getElementById('localVideo');
        const remoteVideo = document.getElementById('remoteVideo');
        const remoteLabel = document.getElementById('remoteLabel');
        const peerListEl = document.getElementById('peerList');

        // Load saved credentials from localStorage
        callerNameInput.value = localStorage.getItem('bisnan_caller_name') || '';
        roomSecretInput.value = localStorage.getItem('bisnan_room_secret') || '';

        function setStatus(text, state = '') {
            statusBadge.textContent = text;
            statusBadge.className = 'status-badge ' + state;
        }

        // Fetch temporary TURN servers dynamically from Render (keeps Metered API key hidden)
        async function refreshIceServers(token) {
            try {
                const res = await fetch(`${RENDER_HTTP_BASE}/ice-servers?token=${encodeURIComponent(token)}`);
                if (!res.ok) throw new Error(`HTTP ${res.status}`);
                const data = await res.json();
                if (Array.isArray(data.iceServers) && data.iceServers.length > 0) {
                    cachedIceServers = data.iceServers;
                }
            } catch (err) {
                console.warn('Could not fetch TURN servers, falling back to STUN:', err.message);
            }
        }

        async function startCamera() {
            if (localStream) return localStream;
            try {
                localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
                localVideo.srcObject = localStream;
                startCamBtn.textContent = 'Camera Active';
                startCamBtn.disabled = true;
                toggleMicBtn.disabled = false;
                toggleCamBtn.disabled = false;
                return localStream;
            } catch (err) {
                alert('Camera/Microphone permission is required: ' + err.message);
                throw err;
            }
        }

        function createPeerConnection(targetId) {
            if (pc) pc.close();
            activeTargetId = targetId;
            pc = new RTCPeerConnection({ iceServers: cachedIceServers });

            if (localStream) {
                localStream.getTracks().forEach(track => pc.addTrack(track, localStream));
            }

            pc.ontrack = (event) => {
                if (remoteVideo.srcObject !== event.streams[0]) {
                    remoteVideo.srcObject = event.streams[0];
                }
            };

            pc.onicecandidate = (event) => {
                if (event.candidate && ws && ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({
                        type: 'ice-candidate',
                        targetId: activeTargetId,
                        candidate: event.candidate
                    }));
                }
            };

            pc.onconnectionstatechange = () => {
                if (pc.connectionState === 'connected') {
                    setStatus('In Call', 'connected');
                    hangupBtn.disabled = false;
                } else if (['disconnected', 'failed', 'closed'].includes(pc.connectionState)) {
                    endCallLocally();
                }
            };

            return pc;
        }

        async function callPeer(targetId, targetName) {
            await startCamera();
            const token = roomSecretInput.value.trim();
            if (token) await refreshIceServers(token);

            remoteLabel.textContent = targetName || targetId;
            setStatus(`Calling ${targetName || targetId}...`);
            hangupBtn.disabled = false;

            const peerConn = createPeerConnection(targetId);
            const offer = await peerConn.createOffer();
            await peerConn.setLocalDescription(offer);

            ws.send(JSON.stringify({
                type: 'offer',
                targetId: targetId,
                callerName: callerNameInput.value.trim() || 'Web Browser',
                sdp: offer
            }));
        }

        function endCallLocally() {
            if (pc) {
                pc.close();
                pc = null;
            }
            activeTargetId = null;
            remoteVideo.srcObject = null;
            remoteLabel.textContent = 'Remote Caller';
            hangupBtn.disabled = true;
            if (ws && ws.readyState === WebSocket.OPEN) {
                setStatus('Connected', 'connected');
            }
        }
        function renderPeerList(peers) {
            peerListEl.innerHTML = '';
            const others = peers.filter(p => p.id !== myId);
            if (others.length === 0) {
                const empty = document.createElement('span');
                empty.style.color = 'var(--muted)';
                empty.style.fontSize = '0.9rem';
                empty.textContent = 'No other family devices online right now.';
                peerListEl.appendChild(empty);
                return;
            }
            others.forEach(peer => {
                const row = document.createElement('div');
                row.className = 'peer-item';
                // Use textContent (never innerHTML) to prevent XSS from device names
                const label = document.createElement('span');
                label.textContent = '${ peer.name } (${ peer.type })';
            const btn = document.createElement('button');
            btn.textContent = 'Call';
            btn.onclick = () => callPeer(peer.id, peer.name);
            row.appendChild(label);
            row.appendChild(btn);
            peerListEl.appendChild(row);
        });
}
        async function connectSignaling() {
            const name = callerNameInput.value.trim() || 'Family Web';
            const token = roomSecretInput.value.trim();
            if (!token) {
                setStatus('Secret Required', 'error');
                return;
            }
            localStorage.setItem('bisnan_caller_name', name);
            localStorage.setItem('bisnan_room_secret', token);
            if (reconnectTimer) clearTimeout(reconnectTimer);
            if (ws) ws.close();
            setStatus('Connecting...');
            await refreshIceServers(token);
            ws = new WebSocket('${ RENDER_WS_BASE } /? token = ${ encodeURIComponent(token) }');
            ws.onopen = () => {
                setStatus('Connected', 'connected');
                ws.send(JSON.stringify({
                    type: 'register-browser',
                    name: name
                }));
            };
            ws.onmessage = async (event) => {
                const data = JSON.parse(event.data);
                switch (data.type) {
                    case 'registered':
                        myId = data.id;
                        break;
                    case 'mesh-peer-list':
                        renderPeerList(data.peers || []);
                        break;
                    case 'offer': {
                        const accept = confirm('Incoming call from ' + (data.callerName || data.senderId) + '. Answer?');
                        if (!accept) {
                            ws.send(JSON.stringify({ type: 'call-decline', targetId: data.senderId }));
                            return;
                        }
                        await startCamera();
                        remoteLabel.textContent = data.callerName || data.senderId;
                        hangupBtn.disabled = false;
                        const peerConn = createPeerConnection(data.senderId);
                        await peerConn.setRemoteDescription(new RTCSessionDescription(data.sdp));
                        const answer = await peerConn.createAnswer();
                        await peerConn.setLocalDescription(answer);
                        ws.send(JSON.stringify({
                            type: 'answer',
                            targetId: data.senderId,
                            sdp: answer
                        }));
                        break;
                    }
                    case 'answer':
                        if (pc && data.sdp) {
                            await pc.setRemoteDescription(new RTCSessionDescription(data.sdp));
                        }
                        break;
                    case 'ice-candidate':
                        if (pc && data.candidate) {
                            await pc.addIceCandidate(new RTCIceCandidate(data.candidate));
                        }
                        break;
                    case 'call-decline':
                        alert('Call was declined.');
                        endCallLocally();
                        break;
                    case 'hangup':
                        endCallLocally();
                        break;
                }
            };
            ws.onclose = (event) => {
                endCallLocally();
                if (event.code === 1006 || event.code === 4001) {
                    setStatus('Disconnected (Check Secret or Session)', 'error');
                } else {
                    setStatus('Disconnected - Retrying...', 'error');
                    reconnectTimer = setTimeout(connectSignaling, 4000);
                }
            };
            ws.onerror = () => {
                setStatus('Connection Error', 'error');
            };
        }
        connectBtn.onclick = connectSignaling;
        clearAuthBtn.onclick = () => {
            localStorage.removeItem('bisnan_room_secret');
            roomSecretInput.value = '';
            if (ws) ws.close();
            setStatus('Disconnected');
        };
        startCamBtn.onclick = startCamera;
        toggleMicBtn.onclick = () => {
            if (!localStream) return;
            const audioTrack = localStream.getAudioTracks()[0];
            if (audioTrack) {
                audioTrack.enabled = !audioTrack.enabled;
                toggleMicBtn.textContent = audioTrack.enabled ? 'Mute Mic' : 'Unmute Mic';
            }
        };
        toggleCamBtn.onclick = () => {
            if (!localStream) return;
            const videoTrack = localStream.getVideoTracks()[0];
            if (videoTrack) {
                videoTrack.enabled = !videoTrack.enabled;
                toggleCamBtn.textContent = videoTrack.enabled ? 'Turn Off Video' : 'Turn On Video';
            }
        };
        hangupBtn.onclick = () => {
            if (ws && ws.readyState === WebSocket.OPEN && activeTargetId) {
                ws.send(JSON.stringify({ type: 'hangup', targetId: activeTargetId }));
            }
            endCallLocally();
        };
        // Auto-connect on page load if secret was already saved
        if (roomSecretInput.value.trim()) {
            connectSignaling();
        }
