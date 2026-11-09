Video Call Project Description

Code for project at: https://github.com/bulokisda/videocall.git

Browser web page hosted at: https://bulokisda.github.io/videocall/

Node Server hosted at render.com:
wss://family-video-signaler.onrender.com

Stun/TURN servers from metered.ca:
stun:stun.relay.metered.ca:80

https://raw.githubusercontent.com/bulokisda/videocall/refs/heads/main/app/lib/main.dart
https://raw.githubusercontent.com/bulokisda/videocall/refs/heads/main/app/lib/background_handler.dart
https://raw.githubusercontent.com/bulokisda/videocall/refs/heads/main/app/lib/video_call_screen.dart
https://raw.githubusercontent.com/bulokisda/videocall/refs/heads/main/server.js
https://raw.githubusercontent.com/bulokisda/videocall/refs/heads/main/index.html

Components:
1. Server Room - this is what the users connect to to discover who else is online and callable.
2. Browser calling page - this allows the user to connect to the server room and initiate or hangup a call.
3. Tablet calling app - this allows the user to connect to the server room and initiate or hangup a call.
4. Tablet background process - this allow the tablet to receive an incoming call request that the user can accept or decline.

General specifications:
The project allows browser to browser videocall, browser to tablet video call and tablet to browser.
Deployed using vscode.
Uses WebRTC via stun servers.
Users can call, hangup, connect to room, leave room.
Calls are one to one.

Tablet app specifications:
This is a flutter based app aimed at a lenovo tablet running Android 10.
The tablet app runs in the background until called, when the user accepts the call the video is displayed of both the local and remote users.
The tablet app when launched allows the tablet user to connect to the room and then call any user in the room.

Browser specifications:
In the browser the index.html allows the user to connect to the room before displaying the local video, then the user can call any other connected user in the room.

// Update this block inside your index.html file:
const rtcConfig = { 
  iceServers: [
      // 1. PRIMARY SHIELD: Force Secure TLS over Port 443 (TCP)
      {
        urls: "turns:standard.relay.metered.ca:443?transport=tcp",
        username: "801acfb381f1738ba4e9e792",
        credential: "xb8Y+/nANmaFf1Um",
      },
      
      // 2. Public Google STUN to gather fast local adapter targets
      { urls: "stun:://google.com" },

      // 3. Fallback: Standard TCP over Port 80
      {
        urls: "turn:standard.relay.metered.ca:80?transport=tcp",
        username: "801acfb381f1738ba4e9e792",
        credential: "xb8Y+/nANmaFf1Um",
      },

      // 4. Final Fallback: Standard UDP over Port 80
      {
        urls: "turn:standard.relay.metered.ca:80",
        username: "801acfb381f1738ba4e9e792",
        credential: "xb8Y+/nANmaFf1Um",
      },
  ],
};


Launch app in debug
Shows online
Background the app 
Call from browser
Decline notification (notification disappears ok)
Call again
Decline again (app displayed shows remote service connection offline)
Reconnect service
Still offline doesnt reconnect