import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'dart:convert';
import 'package:flutter/services.dart';
import 'call_screen.dart';

class ChatScreen extends StatefulWidget {
  final String currentUserId;
  final String otherUserId;
  final String otherUserName;

  const ChatScreen({
    required this.currentUserId,
    required this.otherUserId,
    required this.otherUserName,
    Key? key,
  }) : super(key: key);

  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late String _chatRoomId;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    var users = [widget.currentUserId, widget.otherUserId];
    users.sort();
    _chatRoomId = users.join('_');
    print('Chat room ID: $_chatRoomId');
  }

  void _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final message = {
        'senderId': widget.currentUserId,
        'receiverId': widget.otherUserId,
        'message': _messageController.text.trim(),
        'timestamp': FieldValue.serverTimestamp(),
      };

      print('Sending message: $message');

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatRoomId)
          .collection('messages')
          .add(message);

      _messageController.clear();
      _scrollToBottom();
    } catch (e) {
      print('Error sending message: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка отправки сообщения: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<String?> _getFcmToken(String userId, CollectionReference receiverCollection) async {
    try {
      final doc = await receiverCollection.doc(userId).get();
      if (doc.exists) {
        return doc['fcmToken'] as String?;
      }
    } catch (e) {
      print("Ошибка при получении FCM токена: $e");
    }
    return null;
  }

  Future<CollectionReference> _getReceiverCollection(String userId) async {
    return FirebaseFirestore.instance.collection('users');
  }

  Future<String> _getSenderName(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      if (doc.exists) {
        return doc['name'] as String;
      }
    } catch (e) {
      print("Ошибка при получении имени отправителя: $e");
    }
    return "Неизвестный";
  }

  void _sendCallNotification() async {
    final receiverCollection = await _getReceiverCollection(widget.otherUserId);
    final fcmToken = await _getFcmToken(widget.otherUserId, receiverCollection);

    if (fcmToken != null) {
      try {
        // Загрузка учетных данных сервисного аккаунта
        final serviceAccount = jsonDecode(await rootBundle.loadString('assets/google-services.json'));
        final credentials = auth.ServiceAccountCredentials.fromJson(serviceAccount);
        final client = await auth.clientViaServiceAccount(credentials, ['https://www.googleapis.com/auth/firebase.messaging']);
        final accessToken = client.credentials.accessToken;

        // Получение имени вызывающего пользователя
        final callerName = await _getSenderName(widget.currentUserId);

        // Формирование полезной нагрузки уведомления
        final body = {
          "message": {
            "token": fcmToken,
            "notification": {
              "title": "Входящий звонок📞",
              "body": "$callerName звонит вам!☎️",
            },
            "data": {
              "callStatus": "incoming",
              "callerId": widget.currentUserId,
              "callerName": callerName,
            },
          },
        };

        // Отправка уведомления
        final response = await http.post(
          Uri.parse("https://fcm.googleapis.com/v1/projects/pril123/messages:send"),
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer ${accessToken.data}",
          },
          body: jsonEncode(body),
        );

        if (response.statusCode == 200) {
          print("Push notification for call sent successfully!");
        } else {
          print("Error sending call push notification: ${response.body}");
        }
      } catch (e) {
        print("Ошибка при отправке уведомления о звонке: $e");
      }
    } else {
      print("FCM token не найден для пользователя ${widget.otherUserId}");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.otherUserName),
                  Text(
                    'ID: ${widget.otherUserId}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.phone),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => CallScreen(
                      channelName: _chatRoomId,
                      currentUserId: widget.currentUserId,
                      otherUserId: widget.otherUserId,
                      otherUserName: widget.otherUserName,
                    ),
                  ),
                );
                _sendCallNotification();
              },
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(_chatRoomId)
                  .collection('messages')
                  .orderBy('timestamp', descending: false)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  print('Error in chat stream: ${snapshot.error}');
                  return Center(
                    child: Text('Ошибка загрузки сообщений: ${snapshot.error}'),
                  );
                }

                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final messages = snapshot.data!.docs;

                if (messages.isEmpty) {
                  return const Center(
                    child: Text('Нет сообщений. Начните общение!'),
                  );
                }

                WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

                return ListView.builder(
                  controller: _scrollController,
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index].data() as Map<String, dynamic>;
                    final isMe = message['senderId'] == widget.currentUserId;
                    final timestamp = message['timestamp'] as Timestamp?;

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 10),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isMe ? Colors.blue : Colors.grey[300],
                          borderRadius: BorderRadius.circular(15),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              spreadRadius: 1,
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.7,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              message['message'] as String,
                              style: TextStyle(
                                color: isMe ? Colors.white : Colors.black,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              timestamp != null
                                  ? DateFormat('HH:mm').format(timestamp.toDate())
                                  : 'Отправляется...',
                              style: TextStyle(
                                fontSize: 12,
                                color: isMe ? Colors.white70 : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  spreadRadius: 1,
                  blurRadius: 3,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Введите сообщение...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  onPressed: _isLoading ? null : _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}