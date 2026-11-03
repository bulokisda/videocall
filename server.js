const WebSocket = require('ws');
const wss = new WebSocket.Server({ port: 8080 });

const clients = new Map();
console.log("Manual Mesh Signaling Engine active on port 8080...");

function broadcastPeerList() {
    const peerList = Array.from(clients.entries()).map(([id, info]) => ({
        id: id,
        type: info.type
    }));
    
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
                    clients.set(clientId, { socket: ws, type: 'tablet' });
                    console.log(`Android 10 Node Registered: ${clientId}`);
                    ws.send(JSON.stringify({ type: 'registered', id: clientId }));
                    broadcastPeerList();
                    break;
            
                case 'register-browser':
                    // Clear out by matching socket wire reference
                    clients.forEach((info, id) => {
                        if (info.socket === ws) clients.delete(id);
                    });
                
                    // FIXED: If an ID was explicitly passed, purge any stale socket mapping tied to it first
                    if (data.id && clients.has(data.id)) {
                        console.log(`Purging stale socket reference for existing node session: ${data.id}`);
                        clients.delete(data.id);
                    }
                
                    clientId = data.id || 'browser_' + Math.random().toString(36).substr(2, 5);
                    clients.set(clientId, { socket: ws, type: 'browser' });
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
                        // Targeted point-to-point drop
                        const target = clients.get(data.targetId);
                        if (target && target.socket.readyState === WebSocket.OPEN) {
                            target.socket.send(JSON.stringify({ type: 'hangup', senderId: clientId }));
                        }
                    } else {
                        // Broad Room Teardown Notification (Client clicked Leave Room)
                        console.log(`Node explicitly requested global room teardown: ${clientId}`);
                        clients.delete(clientId); // Clean them out of registry memory instantly
                        
                        clients.forEach((info) => {
                            if (info.socket.readyState === WebSocket.OPEN) {
                                info.socket.send(JSON.stringify({ type: 'hangup', senderId: clientId }));
                            }
                        });
                        broadcastPeerList(); // Instantly update peer list across surviving nodes
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
            
            // Notify surviving nodes to instantly drop video feeds for this ID
            clients.forEach((info) => {
                if (info.socket.readyState === WebSocket.OPEN) {
                    info.socket.send(JSON.stringify({ type: 'hangup', senderId: clientId }));
                }
            });
            broadcastPeerList();
        }
    });
});
