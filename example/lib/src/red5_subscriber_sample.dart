import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

class Red5SubscriberSample extends StatefulWidget {
  static String tag = 'data_channel_sample';

  @override
  _Red5SubscriberSampleState createState() => _Red5SubscriberSampleState();
}

class _Red5SubscriberSampleState extends State<Red5SubscriberSample> {
  RTCPeerConnection? _pc2;
  RTCDataChannel? _dc2;
  String _dc2Status = '';
  final List<String> logs = [];
  WebSocket? _signalingSocket;
  String? streamToken;
  String selfId = '1234567';
  bool _inCalling = false;
  String streamName = 'f9ce13e5-1224-493b-a1a2-051cd1a443fc';

  @override
  void initState() {
    super.initState();
    // _signalingSocket =
    //TODO Get StreamToken
  }

  void _makeCall() async {
    if (_pc2 != null) return;
    logs.add('MakeCall()');
    try {
      _pc2 = await createPeerConnection({'iceServers': []});

      _pc2!.onIceCandidate = (candidate) {
        logs.add('pc2: onIceCandidate: ${candidate.candidate}');
        print('pc2: onIceCandidate: ${candidate.candidate}');
        _sendCandidate(candidate);
      };

      _pc2!.onDataChannel = (channel) {
        _dc2 = channel;
        _dc2!.onDataChannelState = (state) {
          setState(() {
            _dc2Status += '\ndc2: state: ${state.toString()}';
            logs.add('dc2: state: ${state.toString()}');
          });
        };
        _dc2!.onMessage = (data) {
          setState(() {
            _dc2Status += '\ndc2: Received message: ${data.text}';
            logs.add('dc2: Received message: ${data.text}');
          });
          _dc2!.send(
              RTCDataChannelMessage('(dc2 ==> dc1) Hello from dc2 echo !!!'));
        };
      };
    } catch (e) {
      print(e.toString());
      logs.add('MakeCall() Error: $e');
    }
    if (!mounted) return;

    setState(() {
      _inCalling = true;
    });
  }

  void _hangUp() async {
    logs.add('HangUp()');
    try {
      await _dc2?.close();
      await _pc2?.close();
      _pc2 = null;
    } catch (e) {
      logs.add('HangUp() Error');
      print(e.toString());
    }
    setState(() {
      _inCalling = false;
    });

    Timer(const Duration(seconds: 1), () {
      setState(() {
        _dc2Status = '';
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Data Channel Test'),
        actions: [
          IconButton(
            onPressed: () {
              showAboutDialog(
                  context: context, children: [Text(logs.join('\n'))]);
            },
            icon: Icon(Icons.analytics),
          ),
        ],
      ),
      body: OrientationBuilder(
        builder: (context, orientation) {
          return Center(
              child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('\n\n(callee)DataChannel:\n'),
              Container(
                child: Text(_dc2Status),
              ),
            ],
          ));
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: onFabPressed,
        tooltip: tooltip,
        child: Icon(iconData),
      ),
    );
  }

  onFabPressed() async {
    if (streamToken == null) {
      await getStreamToken();
    }
    await grabSocketUrl();
  }

  String get tooltip {
    if (streamToken == null) return 'Token';
    return _inCalling ? 'Hangup' : 'Call';
  }

  IconData get iconData {
    if (streamToken == null) return Icons.abc;
    return _inCalling ? Icons.call_end : Icons.phone;
  }

  grabSocketUrl() async {
    logs.clear();
    const host = 'test-nm.daleapp.com.br';
    const streamManagerVersion = '4.0';
    const red5ContextName = 'live';
    String url =
        'https://$host/streammanager/api/$streamManagerVersion/event/$red5ContextName/$streamName?action=subscribe';
    final response = await http.get(Uri.parse(url));
    final rawResponse = jsonDecode(response.body);
    print(rawResponse);

    final serverAddress = rawResponse['serverAddress'];
    final scope = rawResponse['scope'];
    String wss =
        'wss://$host/streammanager/?id=subscriber-$selfId&host=$serverAddress&app=$scope&token=$streamToken';

    connectToSignalingSocket(wss);
  }

  connectToSignalingSocket(String wssUrl) async {
    _signalingSocket = await WebSocket.connect(wssUrl);
    _signalingSocket?.listen(
      _onSocketMessage,
      onDone: _onSocketDone,
    );
  }

  _send(Map<String, dynamic> rawMessage) {
    print('SocketMessage Sent: $rawMessage');
    _signalingSocket?.add(jsonEncode(rawMessage));
  }

  _onSocketMessage(dynamic rawMessage) {
    final Map message = jsonDecode(rawMessage);
    print('SocketMessage Received: $rawMessage');
    logs.add('SocketMessage: $rawMessage');
    Map? messageData = message['data'];
    final String? rawMessageType = messageData?['type'];
    final Red5SignalingMessageType? messageDataType;
    switch (rawMessageType) {
      case 'status':
        messageDataType = Red5SignalingMessageType.status;
        break;
      case 'candidate':
        messageDataType = Red5SignalingMessageType.candidate;
        break;
      case 'error':
        messageDataType = Red5SignalingMessageType.error;
        break;
      default:
        if (message?["isAvailable"] == true) {
          messageDataType = Red5SignalingMessageType.streamAvailable;
        } else if (message['sdp']?['type'] == 'offer') {
          messageDataType = Red5SignalingMessageType.sdpOffer;
        } else if (message['type'] == 'metadata') {
          messageDataType = Red5SignalingMessageType.metadata;
        } else if (messageData?['status'] == "NetStream.Play.UnpublishNotify") {
          messageDataType = Red5SignalingMessageType.unpublishNotify;
        } else {
          messageDataType = null;
        }
    }
    switch (messageDataType) {
      case Red5SignalingMessageType.status:
        if (messageData!["code"] == "NetConnection.Connect.Success") {
          _requestStreamAvailability();
        }
        if (messageData["code"] == "NetConnection.Connect.Failed") {}
        break;
      case Red5SignalingMessageType.candidate:
        // TODO: Handle this case.
        break;
      case Red5SignalingMessageType.error:
        // TODO: Handle this case.
        break;
      case Red5SignalingMessageType.streamAvailable:
        _requestOffer();
        break;
      case Red5SignalingMessageType.metadata:
        break;
      case Red5SignalingMessageType.unpublishNotify:
        break;
      case Red5SignalingMessageType.sdpOffer:
      // TODO: Handle this case.
      case null:
      // TODO: Handle this case.
    }
  }

  void _requestOffer() {
    _send({
      "requestOffer": streamName,
      "requestId": 'subscriber-$selfId',
      "transport": "udp",
      "datachannel": true,
      "doNotSwitch": false
    });
  }

  _onSocketDone() {
    debugPrint(
        'Closed by server [${_signalingSocket!.closeCode} => ${_signalingSocket!.closeReason}]!');
    //DATACHANNEL: Instance of 'RTCDataChannelNative' message: {"data":{"status":"NetStream.Play.UnpublishNotify"}}
  }

  _sendCandidate(RTCIceCandidate candidate) {
    _send({
      'handleCandidate': streamName,
      'requestId': 'subscriber-$selfId',
      'data': {
        'candidate': {
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'sdpMid': candidate.sdpMid,
          'candidate': candidate.candidate,
        }
      }
    });
  }

  onOffer() {
    // print('pc1 offer: ${offer.sdp}');
    // logs.add('pc1 offer: ${offer.sdp}');
    //
    // await _pc2
    // !.setRemoteDescription(offer);
    // var answer = await _pc2!.createAnswer();
    // print('pc2 answer: ${answer.sdp}');
    // logs.add('pc2 answer: ${answer.sdp}');
    //
    // await _pc2!.setLocalDescription(answer);
  }

  subscribe() {
    // _sendRaw({
    //   "subscribe": r5configuration.streamName,
    //   "requestId": 'subscriber-$selfId'
    // });
  }

  getStreamToken() async {
    const ppvServerUrl = 'https://ppv-dev.daleapp.com.br/dev';
    print('Fetching StreamToken');
    logs.add('Fetching StreamToken');
    http.Response response = await http.get(
      Uri.parse('$ppvServerUrl/stream/$streamName/token'),
    );
    Map rawToken = json.decode(response.body);
    setState(() {
      streamToken = rawToken['streamToken'];
    });
    print('StreamToken: $streamToken');
    logs.add('StreamToken: $streamToken');
  }

  void _requestStreamAvailability() {
    _send({"isAvailable": streamName});
  }
}

enum Red5SignalingMessageType {
  status,
  candidate,
  error,
  streamAvailable,
  metadata,
  unpublishNotify,
  sdpOffer,
}

enum StatusMessage {
  connectFailed,
  connectSuccess,
  trickleCompleted,
  dataChannelAvailable,
}
