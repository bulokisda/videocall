const http = require('http');
const https = require('https');
const url = require('url');
const crypto = require('crypto');
const WebSocket = require('ws');

const PORT = process.env.PORT || 8080;
const FAMILY_SECRET = process.env.FAMILY_ROOM_SECRET;
const METERED_DOMAIN = process.env.METERED_DOMAIN; // e.g., "bisnan.metered.live"
const METERED_API_KEY = process.env.METERED_API_KEY;
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || 'https://bulokisda.github.io';

if (!FAMILY_SECRET) {
    console.warn('WARNING: FAMILY_ROOM_SECRET is not set! All connections will be rejected until configured in Render Environment Variables.');
}

// Constant-time string comparison to prevent timing attacks on the secret token
function isValidToken(providedToken) {
    if (!FAMILY_SECRET || typeof providedToken !== 'string') return false;
    const expectedBuf = Buffer.from(FAMILY_SECRET, 'utf8');
    const providedBuf = Buffer.from(providedToken, 'utf8');
    if (expectedBuf.length !== providedBuf.length) return false;
    return crypto.timingSafeEqual(expectedBuf, providedBuf);
}

// Helper to fetch short-lived TURN credentials from Metered REST API
function fetchMeteredIceServers() {
    return new Promise((resolve, reject) => {
        if (!METERED_DOMAIN || !METERED_API_KEY) {
            return resolve([
                { urls: 'stun:stun.l.google.com:19302' },
                { urls: 'stun:stun.relay.metered.ca:80' }
            ]);
        }

        const apiUrl = `https://${METERED_DOMAIN}/api/v1/turn/credentials?apiKey=${encodeURIComponent(METERED_API_KEY)}`;
        https.get(apiUrl, (res) => {
            let rawData = '';
            res.on('data', (chunk) => { rawData += chunk; });
            res.on('end', () => {
                try {
                    const parsed = JSON.parse(rawData);
                    if (Array.isArray(parsed)) {
                        resolve(parsed);
                    } else {
                        reject(new Error('Unexpected Metered API response format'));
                    }
                } catch (err) {
                    reject(err);
                }
            });
        }).on('error', reject);
    });
}

// HTTP Server handles health checks and authenticated /ice-servers requests
const server = http.createServer(async (req, res) => {
    const origin = req.headers.origin;

    // Strict CORS headers
    if (!origin || origin === ALLOWED_ORIGIN) {
        res.setHeader('Access-Control-Allow-Origin', origin || ALLOWED_ORIGIN);
        res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
        res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    }

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        return res.end();
    }

    const parsedUrl = url.parse(req.url, true);

    // Health check endpoint for Render
    if (req.method === 'GET' && parsedUrl.pathname === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ status: 'ok' }));
    }

    // Authenticated endpoint to fetch temporary TURN credentials
    if (req.method === 'GET' && parsedUrl.pathname === '/ice-servers') {
        if (origin && origin !== ALLOWED_ORIGIN) {
            res.writeHead(403, { 'Content-Type': 'application/json' });
            return res.end(JSON.stringify({ error: 'Forbidden Origin' }));
        }

        if (!isValidToken(parsedUrl.query.token)) {
            res.writeHead(401, { 'Content-Type': 'application/json' });
            return res.end(JSON.stringify({ error: 'Unauthorized' }));
        }

        try {
            const iceServers = await fetchMeteredIceServers();
            res.writeHead(200, { 'Content-Type': 'application/json' });
            return res.end(JSON.stringify({ iceServers }));
        } catch (err) {
            console.error('Failed to fetch Metered TURN credentials:', err.message);
            res.writeHead(502, { 'Content-Type': 'application/json' });
            return res.end(JSON.stringify({ error: 'Failed to retrieve ICE servers' }));
        }
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not Found' }));
});

// WebSocket Server attached to the HTTP server with strict handshake verification
const wss = new WebSocket.Server({
    server,
    maxPayload: 64 * 1024, // 64 KB max message size
    verifyClient: (info, done) => {
        const origin = info.origin;

        // Browser clients send an Origin header; native Flutter clients do not
        if (origin && origin !== ALLOWED_ORIGIN) {
            console.warn(`Blocked unauthorized origin: ${origin}`);
            return done(false, 403, 'Forbidden Origin');
        }

        const query = url.parse(info.req.url, true).query;
        if (!isValidToken(query.token)) {
            console.warn('Blocked unauthorized WebSocket handshake attempt');
            return done(false, 401, 'Unauthorized');
        }

        done(true);
    }
});

const clients = new Map();

function sanitizeString(value, maxLen = 40) {
    if (typeof value !== 'string') return null;
    return value.trim().slice(0, maxLen).replace(/[<>]/g, '');
}

function broadcastPeerList() {
    const peerList = Array.from(clients.entries()).map(([id, info]) => {
        const fallbackId = id.includes('_') ? id.split('_')[1] : id.substring(0, 5);
        const fallbackName = `${info.type.charAt(0).toUpperCase() + info.type.slice(1)} (${fallbackId})`;

        return {
            id: id,
            type: info.type,
            name: info.name || fallbackName
        };
    });

    const payload = JSON.stringify({
        type: 'mesh-peer-list',
        peers: peerList
    });

    clients.forEach((info) => {
        if (info.socket.readyState === WebSocket.OPEN) {
            info.socket.send(payload);
        }
    });
}

// Periodic cleanup of dead sockets every 5 seconds
setInterval(() => {
    let changed = false;
    clients.forEach((info, id) => {
        if (info.socket.readyState !== WebSocket.OPEN) {
            console.log(`Sweeping dead socket from memory registry: ${id}`);
            clients.delete(id);
            changed = true;
        }
    });
    if (changed) broadcastPeerList();
}, 5000);

wss.on('connection', (ws) => {
    let clientId = null;
    let messageCount = 0;
    let rateWindowStart = Date.now();

    ws.on('message', (message) => {
        // Basic rate limiter: max 120 messages per 10 seconds per socket (accommodates ICE candidate bursts)
        const now = Date.now();
        if (now - rateWindowStart > 10000) {
            rateWindowStart = now;
            messageCount = 0;
        }
        messageCount++;
        if (messageCount > 120) {
            console.warn(`Rate limit exceeded by ${clientId || 'unregistered socket'}, closing.`);
            ws.close(1008, 'Rate limit exceeded');
            return;
        }

        try {
            const data = JSON.parse(message);
            if (!data || typeof data.type !== 'string') return;

            if (data.type !== 'ping') {
                // Avoid logging full SDP/ICE payloads in production logs
                console.log(`Signal [${data.type}] from ${clientId || 'unregistered'}`);
            }

            switch (data.type) {
                case 'register-tablet': {
                    const cleanName = sanitizeString(data.name);
                    const cleanId = sanitizeString(data.id, 64);

                    let existingDeviceName = cleanName;
                    clients.forEach((info, id) => {
                        if (info.socket === ws && info.name) {
                            existingDeviceName = info.name;
                        }
                        if (info.socket === ws) {
                            clients.delete(id);
                        }
                    });

                    clientId = cleanId || 'tablet_' + crypto.randomBytes(3).toString('hex');
                    const dynamicPersistedName = cleanName || existingDeviceName;

                    if (dynamicPersistedName) {
                        clients.forEach((info, id) => {
                            if (info.type === 'tablet' && info.name === dynamicPersistedName) {
                                console.log(`Purging stale network session for ${dynamicPersistedName}: ${id}`);
                                if (info.socket.readyState === WebSocket.OPEN) {
                                    info.socket.close(4001, 'Replaced by newer session');
                                }
                                clients.delete(id);
                            }
                        });
                    }

                    clients.set(clientId, {
                        socket: ws,
                        type: 'tablet',
                        name: dynamicPersistedName
                    });

                    console.log(`Android Node Registered: ${clientId} - Name: ${dynamicPersistedName || 'None'}`);
                    ws.send(JSON.stringify({ type: 'registered', id: clientId }));
                    broadcastPeerList();
                    break;
                }

                case 'register-browser': {
                    const cleanName = sanitizeString(data.name);
                    const cleanId = sanitizeString(data.id, 64);

                    clients.forEach((info, id) => {
                        if (info.socket === ws) clients.delete(id);
                    });

                    if (cleanId && clients.has(cleanId)) {
                        console.log(`Purging stale socket reference for existing node session: ${cleanId}`);
                        const old = clients.get(cleanId);
                        if (old && old.socket.readyState === WebSocket.OPEN) {
                            old.socket.close(4001, 'Replaced by newer session');
                        }

                        clients.delete(cleanId);
                    }
                    clientId = cleanId || 'browser_' + crypto.randomBytes(3).toString('hex');
                    clients.set(clientId, {
                        socket: ws,
                        type: 'browser',
                        name: cleanName
                    });
                    console.log('Web Browser Node Registered: ${ clientId }');
                    ws.send(JSON.stringify({ type: 'registered', id: clientId }));
                    broadcastPeerList();
                    break;
                }
                case 'offer':
                case 'answer':
                case 'ice-candidate':
                case 'call-decline': {
                    // Reject signaling messages from sockets that haven't registered yet
                    if (!clientId) return;
                    data.senderId = clientId;
                    const targetId = sanitizeString(data.targetId, 64);
                    if (!targetId) break;
                    const targetClient = clients.get(targetId);
                    if (targetClient && targetClient.socket.readyState === WebSocket.OPEN) {
                        targetClient.socket.send(JSON.stringify(data));
                    }
                    break;
                }
                case 'hangup': {
                    if (!clientId) return;
                    if (data.targetId) {
                        const targetId = sanitizeString(data.targetId, 64);
                        const target = clients.get(targetId);
                        if (target && target.socket.readyState === WebSocket.OPEN) {
                            target.socket.send(JSON.stringify({ type: 'hangup', senderId: clientId }));
                        }
                    } else {
                        console.log(`Node explicitly requested global room teardown: ${ clientId }`);
                        clients.delete(clientId);
                        clients.forEach((info) => {
                            if (info.socket.readyState === WebSocket.OPEN) {
                                info.socket.send(JSON.stringify({ type: 'hangup', senderId: clientId }));
                            }
                        });
                    }
                    broadcastPeerList();
                    break;
                }
                case 'ping': {
                    const cleanId = sanitizeString(data.id, 64);
                    const cleanName = sanitizeString(data.name);
                    if (cleanId && !clients.has(cleanId)) {
                        clientId = cleanId;
                        clients.set(clientId, {
                            socket: ws,
                            type: 'tablet',
                            name: cleanName
                        });
                        console.log(`Self - healed node registration from ping: ${ clientId } - Name: ${ cleanName || 'None' }`);
    ws.send(JSON.stringify({ type: 'registered', id: clientId }));
    broadcastPeerList();
}
if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'pong' }));
}
break;
}
}
} catch (e) {
    console.error('Signaling error:', e.message);
}
});
ws.on('close', () => {
    if (clientId && clients.get(clientId)?.socket === ws) {
        console.log(`Connection dropped by client layout layer: ${ clientId }`);
        clients.delete(clientId);
        clients.forEach((info) => {
            if (info.socket.readyState === WebSocket.OPEN) {
                info.socket.send(JSON.stringify({ type: 'hangup', senderId: clientId }));
            }
        });
        broadcastPeerList();
    }
});
});
server.listen(PORT, () => {
    console.log(`Secured Manual Mesh Signaling Engine active on port ${ PORT }...`);
});
