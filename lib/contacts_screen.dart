import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:rxdart/rxdart.dart';
import 'chat_screen.dart';
import 'call_screen.dart';

class ContactsScreen extends StatelessWidget {
  final String currentUserId;
  final String currentUserRole;

  const ContactsScreen({
    required this.currentUserId,
    required this.currentUserRole,
    Key? key,
  }) : super(key: key);

  // Получаем коллекции для поиска контактов в зависимости от роли пользователя
  List<String> _getTargetCollections(String role) {
    switch (role) {
      case 'Водитель':
        return ['dispatchers']; // Водители видят только диспетчеров
      case 'Диспетчер':
        return ['drivers', 'otvetstveniy_za_ekspluataziu']; // Диспетчеры видят водителей и отв. за эксплуатацию
      case 'Ответственный за эксплуатацию':
        return ['dispatchers', 'rtvetstveniy_po_podrazdeleniu']; // Отв. за эксплуатацию видит диспетчеров и отв. по подразделению
      case 'Ответственный по подразделению':
        return ['otvetstveniy_za_ekspluataziu']; // Отв. по подразделению видит только отв. за эксплуатацию
      default:
        return [];
    }
  }

  Stream<List<QueryDocumentSnapshot>> _getContactsStream(List<String> collections) {
    if (collections.isEmpty) {
      return Stream.value([]);
    }
    
    // Создаем стримы для каждой коллекции
    final streams = collections.map((collection) {
      return FirebaseFirestore.instance
          .collection(collection)
          .snapshots()
          .map((snapshot) => snapshot.docs);
    }).toList();

    // Если только одна коллекция
    if (streams.length == 1) {
      return streams.first;
    }

    // Объединяем все стримы в один
    return Rx.combineLatestList(streams).map((lists) {
      return lists.expand((list) => list).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    print('Building ContactsScreen for user $currentUserId with role $currentUserRole');
    final targetCollections = _getTargetCollections(currentUserRole);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Контакты'),
      ),
      body: targetCollections.isEmpty
          ? const Center(child: Text('Нет доступных контактов для вашей роли'))
          : StreamBuilder<List<QueryDocumentSnapshot>>(
              stream: _getContactsStream(targetCollections),
              builder: (context, snapshot) {
                print('StreamBuilder update. HasError: ${snapshot.hasError}, HasData: ${snapshot.hasData}');

                if (snapshot.hasError) {
                  print('Error in StreamBuilder: ${snapshot.error}');
                  return Center(
                    child: Text('Ошибка загрузки контактов: ${snapshot.error}'),
                  );
                }

                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final contacts = snapshot.data!;

                if (contacts.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Нет доступных контактов'),
                        const SizedBox(height: 20),
                        Text('Ваш ID: $currentUserId'),
                        Text('Ваша роль: $currentUserRole'),
                      ],
                    ),
                  );
                }

                print('Found ${contacts.length} contacts');

                return ListView.builder(
                  itemCount: contacts.length,
                  itemBuilder: (context, index) {
                    final contact = contacts[index].data() as Map<String, dynamic>;
                    final contactId = contacts[index].id;
                    final contactName = contact['name'] as String;
                    final contactRole = contact['role'] as String;

                    print('Building contact item: $contactName ($contactId)');

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _getRoleColor(contactRole),
                        child: Text(contactName[0].toUpperCase()),
                      ),
                      title: Text(contactName),
                      subtitle: Text(_getRoleText(contactRole)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chat),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ChatScreen(
                                    currentUserId: currentUserId,
                                    otherUserId: contactId,
                                    otherUserName: contactName,
                                  ),
                                ),
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.phone),
                            onPressed: () {
                              final callId = [currentUserId, contactId]..sort();
                              final String channelName = callId.join('_');

                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => CallScreen(
                                    channelName: channelName,
                                    currentUserId: currentUserId,
                                    otherUserId: contactId,
                                    otherUserName: contactName,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  Color _getRoleColor(String role) {
    switch (role) {
      case 'Водитель':
        return Colors.blue;
      case 'Диспетчер':
        return Colors.green;
      case 'Ответственный за эксплуатацию':
        return Colors.orange;
      case 'Ответственный по подразделению':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  String _getRoleText(String role) {
    switch (role) {
      case 'Водитель':
        return 'Водитель';
      case 'Диспетчер':
        return 'Диспетчер';
      case 'Ответственный за эксплуатацию':
        return 'Отв. за эксплуатацию';
      case 'Ответственный по подразделению':
        return 'Отв. по подразделению';
      default:
        return role;
    }
  }
} 