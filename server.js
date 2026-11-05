const WebSocket = require('ws');
const wss = new WebSocket.Server({ port: 8080 });

const clients = new Map();
console.log("Manual Mesh Signaling Engine active on port 8080...");

function broadcastPeerList() {
    const peerList = Array.from(clients.entries()).map(([id, info]) => {
        // Safe dynamic fallback name if info.name is missing (e.g. "Tablet (zn40n)" or "Browser (khzti)")
        const fallbackId = id.includes('_') ? id.split('_')[1] : id.substring(0, 5);
        const fallbackName = `${info.type.charAt(0).toUpperCase() + info.type.slice(1)} (${fallbackId})`;

        return {
            id: id,
            type: info.type,
            name: info.name || fallbackName
        };
    });
    
    clients.forEach((info) => {
        if (info.socket.readyState === WebSocket.OPEN) {
            info.socket.send(JSON.stringify({
                type: 'mesh-peer-list',
                peers: peerList
            }));
        }
    });
}


// PERIODIC CLEANUP INTERVAL (Pings clients every 5 seconds to wipe dead tabs instantly)
setInterval(() => {
    clients.forEach((info, id) => {
        if (info.socket.readyState !== WebSocket.OPEN) {
            console.log(`Sweeping dead socket from memory registry: ${id}`);
            clients.delete(id);
            broadcastPeerList();
        }
    });
}, 5000);

wss.on('connection', (ws) => {
    let clientId = null;

    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);

            switch (data.type) {
                case 'register-tablet':
                    // Clean out any old registrations using this exact socket first
                    clients.forEach((info, id) => {
                        if (info.socket === ws) clients.delete(id);
                    });
            
                    clientId = data.id || 'tablet_' + Math.random().toString(36).substr(2, 5);
                    
                    clients.set(clientId, { 
                        socket: ws, 
                        type: 'tablet',
                        name: data.name // Strictly rely on what the tablet sends!
                    });
                    
                    console.log(`Android Node Registered: ${clientId} - Name: ${data.name || 'None'}`);
                    ws.send(JSON.stringify({ type: 'registered', id: clientId }));
                    broadcastPeerList();
                    break;

            
                case 'register-browser':
                    clients.forEach((info, id) => {
                        if (info.socket === ws) clients.delete(id);
                    });
                
                    if (data.id && clients.has(data.id)) {
                        console.log(`Purging stale socket reference for existing node session: ${data.id}`);
                        clients.delete(data.id);
                    }
                
                    clientId = data.id || 'browser_' + Math.random().toString(36).substr(2, 5);
                    
                    // 3. DYNAMICALLY CAPTURE BROWSER NAME (If provided)
                    clients.set(clientId, { 
                        socket: ws, 
                        type: 'browser',
                        name: data.name
                    });
                    
                    console.log(`Web Browser Node Registered: ${clientId}`);
                    ws.send(JSON.stringify({ type: 'registered', id: clientId }));
                    broadcastPeerList();
                    break;

                case 'offer':
                case 'answer':
                case 'ice-candidate':
                case 'call-decline':
                    data.senderId = clientId;
                    const targetId = data.targetId;
                    if (!targetId) break;

                    const targetClient = clients.get(targetId);
                    if (targetClient && targetClient.socket.readyState === WebSocket.OPEN) {
                        targetClient.socket.send(JSON.stringify(data));
                    }
                    break;

                case 'hangup':
                    if (data.targetId) {
                        const target = clients.get(data.targetId);
                        if (target && target.socket.readyState === WebSocket.OPEN) {
                            target.socket.send(JSON.stringify({ type: 'hangup', senderId: clientId }));
                        }
                    } else {
                        console.log(`Node explicitly requested global room teardown: ${clientId}`);
                        clients.delete(clientId);
                        
                        clients.forEach((info) => {
                            if (info.socket.readyState === WebSocket.OPEN) {
                                info.socket.send(JSON.stringify({ type: 'hangup', senderId: clientId }));
                            }
                        });
                        broadcastPeerList();
                    }
                    break;
            }
        } catch (e) {
            console.error("Signaling error:", e);
        }
    });

    ws.on('close', () => {
        if (clientId) {
            console.log(`Connection dropped by client layout layer: ${clientId}`);
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
