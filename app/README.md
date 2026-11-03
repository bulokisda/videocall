Video Call Project Description

Code for project at: https://github.com/bulokisda/videocall.git

Browser web page hosted at: https://bulokisda.github.io/videocall/

Server hosted at:
wss://family-video-signaler.onrender.com

Stun servers:
stun:stun.l.google.com:19302
stun:stun1.l.google.com:19302

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

