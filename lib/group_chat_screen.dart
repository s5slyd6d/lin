
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:intl/intl.dart';
import 'call_screen.dart';

class GroupChatScreen extends StatefulWidget {
  final String currentUserId;
  final String chatType;
  final String title;

  const GroupChatScreen({
    required this.currentUserId,
    required this.chatType,
    required this.title,
    Key? key,
  }) : super(key: key);

  @override
  _GroupChatScreenState createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final TextEditingController _controller = TextEditingController();

  void _sendMessage() async {
    if (_controller.text.trim().isEmpty) return;

    final collections = [
      'drivers',
      'dispatchers',
      'otvetstveniy_za_ekspluataziu',
      'rtvetstveniy_po_podrazdeleniu'
    ];
    String? userName;

    for (final col in collections) {
      final doc = await FirebaseFirestore.instance
          .collection(col)
          .doc(widget.currentUserId)
          .get();
      if (doc.exists) {
        userName = doc['name'];
        break;
      }
    }

    userName ??= 'Аноним';
    final messageText = _controller.text.trim();

    await FirebaseFirestore.instance
        .collection('group_chats')
        .doc(widget.chatType)
        .collection('messages')
        .add({
      'senderId': widget.currentUserId,
      'senderName': userName,
      'text': messageText,
      'timestamp': FieldValue.serverTimestamp(),
      'readBy': [widget.currentUserId],
    });

    await _sendGroupChatPushNotification(
        messageText, widget.chatType, userName);
    _controller.clear();
  }

  Future<void> _sendGroupChatPushNotification(
      String messageText, String chatType, String senderName) async {
    try {
      final List<String> collections = chatType == 'dispatcher_chat'
          ? ['drivers', 'dispatchers']
          : ['drivers', 'otvetstveniy_za_ekspluataziu'];

      List<String> tokens = [];

      for (final collection in collections) {
        final snapshot =
            await FirebaseFirestore.instance.collection(collection).get();
        for (var doc in snapshot.docs) {
          final data = doc.data();
          final token = data['fcmToken'];
          final userId = doc.id;

          if (token != null &&
              token.toString().isNotEmpty &&
              userId != widget.currentUserId) {
            tokens.add(token);
          }
        }
      }

      if (tokens.isEmpty) return;

      final serviceAccount =
          jsonDecode(await rootBundle.loadString('assets/google-services.json'));
      final credentials =
          auth.ServiceAccountCredentials.fromJson(serviceAccount);
      final client = await auth.clientViaServiceAccount(
        credentials,
        ['https://www.googleapis.com/auth/firebase.messaging'],
      );
      final accessToken = client.credentials.accessToken;

      for (final token in tokens) {
        final body = {
          "message": {
            "token": token,
            "notification": {
              "title": "Новое сообщение в общем чате",
              "body": "$senderName: $messageText"
            },
            "data": {
              "click_action": "FLUTTER_NOTIFICATION_CLICK",
              "type": "group_chat",
              "chatType": chatType,
              "senderName": senderName,
              "userId": widget.currentUserId
            }
          }
        };

        await http.post(
          Uri.parse(
              "https://fcm.googleapis.com/v1/projects/pril123/messages:send"),
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer ${accessToken.data}",
          },
          body: jsonEncode(body),
        );
      }

      client.close();
    } catch (e) {
      print("Ошибка при отправке уведомлений: $e");
    }
  }

  
  void _showChatMembers() async {
    List<String> collections = [];

    switch (widget.chatType) {
      case 'dispatcher_chat':
        collections = ['drivers', 'dispatchers'];
        break;
      case 'responsible_chat':
      case 'driver_responsible_chat':
        collections = ['drivers', 'otvetstveniy_za_ekspluataziu'];
        break;
      case 'dispatcher_responsible_chat':
        collections = ['dispatchers', 'otvetstveniy_za_ekspluataziu'];
        break;
    }

    List<Map<String, dynamic>> allUsers = [];

    for (final collection in collections) {
      final snapshot = await FirebaseFirestore.instance.collection(collection).get();
      for (var doc in snapshot.docs) {
        final data = doc.data();
        data['id'] = doc.id;
        data['collection'] = collection;
        allUsers.add(data);
      }
    }

    TextEditingController searchController = TextEditingController();
    List<Map<String, dynamic>> filteredUsers = List.from(allUsers);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(builder: (context, setModalState) {
          return AnimatedPadding(
            duration: const Duration(milliseconds: 300),
            padding: MediaQuery.of(context).viewInsets,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const Text(
                    'Участники чата',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      shadows: [
                        Shadow(offset: Offset(1, 1), blurRadius: 2, color: Colors.black26),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: searchController,
                    decoration: const InputDecoration(
                      hintText: 'Поиск по имени...',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                    ),
                    onChanged: (value) {
                      setModalState(() {
                        filteredUsers = allUsers
                            .where((user) => (user['name'] ?? '')
                                .toString()
                                .toLowerCase()
                                .contains(value.toLowerCase()))
                            .toList();
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: ListView(
                      children: filteredUsers.map((user) {
                        String roleLabel = '';
                        Color roleColor = Colors.grey;

                        switch (user['collection']) {
                          case 'drivers':
                            roleLabel = 'Водитель';
                            roleColor = Colors.blue;
                            break;
                          case 'dispatchers':
                            roleLabel = 'Диспетчер';
                            roleColor = Colors.orange;
                            break;
                          case 'otvetstveniy_za_ekspluataziu':
                            roleLabel = 'Ответственный';
                            roleColor = Colors.purple;
                            break;
                        }

                        final userName = user['name'] ?? 'Без имени';
                        final phone = user['phoneNumber'] ?? 'нет номера';
                        final isDispatcher = user['collection'] == 'dispatchers';
                        final isOnline = user['isOnline'] == true;

                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            border: Border.all(color: roleColor, width: 1.5),
                            borderRadius: BorderRadius.circular(12),
                            color: Colors.white,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black12,
                                blurRadius: 4,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: roleColor.withOpacity(0.8),
                              child: Text(
                                userName.isNotEmpty ? userName[0].toUpperCase() : '?',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                            title: Text(
                              userName,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('$roleLabel · $phone'),
                                if (isDispatcher)
                                  Text(
                                    isOnline ? 'в сети' : 'не активен',
                                    style: TextStyle(
                                      color: isOnline ? Colors.green : Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.phone, color: Colors.green),
                              onPressed: () {
                                Navigator.of(context).pop();
                                _initiateCallToUser(user['id'], userName);
                              },
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  Future<String> _getCurrentUserName(String userId) async {
    final collections = [
      'drivers',
      'dispatchers',
      'otvetstveniy_za_ekspluataziu',
      'rtvetstveniy_po_podrazdeleniu'
    ];
    String? userName;

    for (final col in collections) {
      final doc = await FirebaseFirestore.instance.collection(col).doc(userId).get();
      if (doc.exists) {
        userName = doc['name'];
        break;
      }
    }

    return userName ?? 'Аноним';
  }

  void _initiateCallToUser(String receiverId, String receiverName) async {
    String callerName = await _getCurrentUserName(widget.currentUserId);
    String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    String channelName = '${widget.currentUserId}_${receiverId}_$timestamp';

    try {
      await FirebaseFirestore.instance.collection('calls').doc(channelName).set({
        'status': 'pending',
        'caller': widget.currentUserId,
        'receiver': receiverId,
        'callerName': callerName,
        'receiverName': receiverName,
        'timestamp': FieldValue.serverTimestamp(),
      'readBy': [widget.currentUserId],
        'channelName': channelName,
      });

      await _sendIncomingCallNotification(receiverId, widget.currentUserId, callerName);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CallScreen(
            channelName: channelName,
            currentUserId: widget.currentUserId,
            otherUserId: receiverId,
            otherUserName: receiverName,
          ),
        ),
      );
    } catch (e) {
      print('Error initiating call: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка при инициализации звонка: $e')),
      );
    }
  }

  Future<void> _sendIncomingCallNotification(
      String receiverId, String callerId, String callerName) async {
    try {
      final List<String> collections = [
        'drivers',
        'dispatchers',
        'otvetstveniy_za_ekspluataziu',
        'rtvetstveniy_po_podrazdeleniu'
      ];
      String? token;

      for (final col in collections) {
        final doc = await FirebaseFirestore.instance.collection(col).doc(receiverId).get();
        if (doc.exists && doc['fcmToken'] != null) {
          token = doc['fcmToken'];
          break;
        }
      }

      if (token == null) return;

      final serviceAccount =
          jsonDecode(await rootBundle.loadString('assets/google-services.json'));
      final credentials = auth.ServiceAccountCredentials.fromJson(serviceAccount);
      final client = await auth.clientViaServiceAccount(
        credentials,
        ['https://www.googleapis.com/auth/firebase.messaging'],
      );
      final accessToken = client.credentials.accessToken;

      final body = {
        "message": {
          "token": token,
          "notification": {
            "title": "Входящий вызов",
            "body": "Вам звонит $callerName",
          },
          "data": {
            "type": "incoming_call",
            "callerId": callerId,
            "callerName": callerName,
            "receiverId": receiverId,
            "click_action": "FLUTTER_NOTIFICATION_CLICK",
          }
        }
      };

      await http.post(
        Uri.parse("https://fcm.googleapis.com/v1/projects/pril123/messages:send"),
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer ${accessToken.data}",
        },
        body: jsonEncode(body),
      );

      client.close();
    } catch (e) {
      print("Ошибка при отправке уведомления о звонке: $e");
    }
  }


  void _markMessagesAsRead(List<QueryDocumentSnapshot> messages) async {
    for (var doc in messages) {
      final data = doc.data() as Map<String, dynamic>;
      final List readBy = data['readBy'] ?? [];

      if (data['senderId'] != widget.currentUserId && !readBy.contains(widget.currentUserId)) {
        await doc.reference.update({
          'readBy': FieldValue.arrayUnion([widget.currentUserId])
        });
      }
    }
  }


  void _showReadByDialog(List readBy) async {
    if (readBy == null || readBy.isEmpty) return;

    List<String> userNames = [];

    for (final userId in readBy) {
      for (final col in ['drivers', 'dispatchers', 'otvetstveniy_za_ekspluataziu']) {
        final doc = await FirebaseFirestore.instance.collection(col).doc(userId).get();
        if (doc.exists) {
          userNames.add(doc['name'] ?? 'Неизвестный');
          break;
        }
      }
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Прочитали сообщение'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: userNames.map((name) => ListTile(title: Text(name))).toList(),
        ),
        actions: [
          TextButton(
            child: const Text('ОК'),
            onPressed: () => Navigator.of(context).pop(),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _showChatMembers,
          child: Text(widget.title),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF3A7BD5), Color(0xFF00d2ff)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('group_chats')
                  .doc(widget.chatType)
                  .collection('messages')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

                final messages = snapshot.data!.docs;
                _markMessagesAsRead(messages);

                return ListView(
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  children: messages.map((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final isMe = data['senderId'] == widget.currentUserId;
                    final timestamp = data['timestamp'] != null
                        ? (data['timestamp'] as Timestamp).toDate()
                        : null;

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: GestureDetector(onTap: isMe ? () => _showReadByDialog(data['readBy']) : null, child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        padding: const EdgeInsets.all(12),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.75,
                        ),
                        decoration: BoxDecoration(
                          color: isMe ? Colors.blue[100] : Colors.grey[200],
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            )
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment:
                              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            if (!isMe)
                              Text(
                                data['senderName'] ?? 'Неизвестный',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black54,
                                ),
                              ),
                            const SizedBox(height: 4),
                            Text(
                              data['text'] ?? '',
                              style: const TextStyle(fontSize: 15),
                            ),
                            if (timestamp != null) ...[
                              const SizedBox(height: 6),
                              
Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Text(
      DateFormat('HH:mm').format(timestamp),
      style: TextStyle(
        fontSize: 11,
        color: Colors.grey[600],
      ),
    ),
    const SizedBox(width: 6),
    if (isMe)
      Icon(
        Icons.done_all,
        size: 16,
        color: (data['readBy'] != null && (data['readBy'] as List).any((id) => id != widget.currentUserId))
            ? Colors.blue
            : Colors.grey,
      ),
  ],
),

                            ]
                          ],
                        ),
                      ),
                    ));
                  }).toList(),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(color: Colors.black12, blurRadius: 4),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'Введите сообщение...',
                      filled: true,
                      fillColor: Colors.grey[100],
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                onTap: _sendMessage,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    color: Colors.blueAccent,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.send, color: Colors.white),
                ),
              ),
            ],
            ),
          ),
        ],
      ),
    );
  }
}
