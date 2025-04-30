import 'dart:async';
import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// Замените на ваш App ID из консоли Agora
const String appId = "cb24f1b314174d0e922611fcdc89180d";

class CallScreen extends StatefulWidget {
  final String channelName;
  final String currentUserId;
  final String otherUserId;
  final String otherUserName;

  const CallScreen({
    required this.channelName,
    required this.currentUserId,
    required this.otherUserId,
    required this.otherUserName,
    Key? key,
  }) : super(key: key);

  @override
  _CallScreenState createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  int? _remoteUid;
  bool _localUserJoined = false;
  bool _muted = false;
  RtcEngine? _engine;
  StreamSubscription? _callStatusSubscription;

  @override
  void initState() {
    super.initState();
    _initializeCall();
  }

  Future<void> _initializeCall() async {
    try {
      print('========== CALL INITIALIZATION ==========');
      print('Channel Name: ${widget.channelName}');
      print('Current User ID: ${widget.currentUserId}');
      print('Other User ID: ${widget.otherUserId}');

      // Проверяем существующий вызов
      final callDoc = await FirebaseFirestore.instance
          .collection('calls')
          .doc(widget.channelName)
          .get();

      if (!callDoc.exists) {
        print('Creating new call document...');
        await FirebaseFirestore.instance
            .collection('calls')
            .doc(widget.channelName)
            .set({
          'status': 'pending',
          'caller': widget.currentUserId,
          'receiver': widget.otherUserId,
          'timestamp': FieldValue.serverTimestamp(),
          'channelName': widget.channelName,
        });
      }

      // Добавьте задержку перед инициализацией Agora
      await Future.delayed(const Duration(seconds: 1));

      // Запрашиваем разрешения только если не веб
      if (!kIsWeb) {
        final status = await Permission.microphone.request();
        if (status != PermissionStatus.granted) {
          throw Exception('Разрешение на использование микрофона не получено');
        }
      }

      // Инициализируем Agora
      _engine = createAgoraRtcEngine();
      await _engine!.initialize(const RtcEngineContext(
        appId: appId,
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
      ));

      // Включаем аудио
      await _engine!.enableAudio();
      
      // Устанавливаем роль клиента
      await _engine!.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

      // Регистрируем обработчики событий
      _engine!.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (connection, elapsed) {
            print('Successfully joined channel: ${widget.channelName}');
            setState(() {
              _localUserJoined = true;
            });
          },
          onUserJoined: (connection, remoteUid, elapsed) {
            print('Remote user joined: $remoteUid');
            setState(() {
              _remoteUid = remoteUid;
            });
          },
          onUserOffline: (connection, remoteUid, reason) {
            print('Remote user left: $remoteUid');
            setState(() {
              _remoteUid = null;
            });
            _onCallEnd(context);
          },
          onError: (err, msg) {
            print("Agora error: $err, $msg");
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Ошибка звонка: $msg")),
            );
            _onCallEnd(context);
          },
        ),
      );

      // Добавьте лог перед присоединением к каналу
      print('Attempting to join channel: ${widget.channelName}');
      await _engine!.joinChannel(
        token: '',
        channelId: widget.channelName,
        uid: 0,
        options: const ChannelMediaOptions(
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
          channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
        ),
      );

      // Слушаем изменения статуса вызова
      _callStatusSubscription = FirebaseFirestore.instance
          .collection('calls')
          .doc(widget.channelName)
          .snapshots()
          .listen((snapshot) {
        if (snapshot.exists) {
          final status = snapshot.data()?['status'];
          if (status == 'rejected') {
            _onCallEnd(context);
          }
        }
      });
    } catch (e) {
      print('Error in _initializeCall: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка инициализации звонка: $e")),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _updateCallStatus(String status) async {
    try {
      await FirebaseFirestore.instance
          .collection('calls')
          .doc(widget.channelName)
          .update({'status': status});
    } catch (e) {
      print("Error updating call status: $e");
    }
  }

  void _onToggleMute() {
    setState(() {
      _muted = !_muted;
    });
    _engine?.muteLocalAudioStream(_muted);
  }

  void _onCallEnd(BuildContext context) async {
    await _updateCallStatus('ended');
    await _engine?.leaveChannel();
    await _callStatusSubscription?.cancel();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _engine?.release();
    _callStatusSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Звонок с ${widget.otherUserName}'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 50,
              child: Text(
                widget.otherUserName[0].toUpperCase(),
                style: const TextStyle(fontSize: 40),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _remoteUid != null
                  ? 'Разговор'
                  : _localUserJoined
                      ? 'Вызов...'
                      : 'Подключение...',
              style: const TextStyle(fontSize: 24),
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                  onPressed: _onToggleMute,
                  iconSize: 40,
                ),
                IconButton(
                  icon: const Icon(Icons.call_end, color: Colors.red),
                  onPressed: () => _onCallEnd(context),
                  iconSize: 40,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}