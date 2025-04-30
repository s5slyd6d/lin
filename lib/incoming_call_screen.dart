import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'call_screen.dart';

class IncomingCallScreen extends StatelessWidget {
  final String callerId;
  final String callerName;
  final String currentUserId;

  const IncomingCallScreen({
    required this.callerId,
    required this.callerName,
    required this.currentUserId,
    Key? key,
  }) : super(key: key);

  void _rejectCall(BuildContext context) async {
    final channelName = "${callerId}_$currentUserId";
    await FirebaseFirestore.instance
        .collection('calls')
        .doc(channelName)
        .update({'status': 'rejected'});
    Navigator.of(context).pop();
  }

  void _acceptCall(BuildContext context) async {
    try {
      // Получаем документ вызова
      final callDoc = await FirebaseFirestore.instance
          .collection('calls')
          .where('caller', isEqualTo: callerId)
          .where('receiver', isEqualTo: currentUserId)
          .where('status', isEqualTo: 'pending')
          .get();

      if (callDoc.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Вызов уже завершен или не существует')),
        );
        Navigator.pop(context);
        return;
      }

      final channelName = callDoc.docs.first.get('channelName');
      
      // Обновляем статус
      await FirebaseFirestore.instance
          .collection('calls')
          .doc(channelName)
          .update({'status': 'active'});

      // Переходим на экран звонка
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => CallScreen(
            channelName: channelName,
            currentUserId: currentUserId,
            otherUserId: callerId,
            otherUserName: callerName,
          ),
        ),
      );
    } catch (e) {
      print('Error accepting call: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка при принятии вызова: $e')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black87,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.call, color: Colors.greenAccent, size: 80),
            const SizedBox(height: 20),
            Text(
              '$callerName вам звонит',
              style: const TextStyle(color: Colors.white, fontSize: 24),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.call_end),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => _rejectCall(context),
                  label: const Text('Отклонить'),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.call),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () => _acceptCall(context),
                  label: const Text('Принять'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}
