import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:url_launcher/url_launcher.dart';
import 'contacts_screen.dart';
import 'package:intl/intl.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'group_chat_screen.dart';
import 'incoming_call_screen.dart';
import 'package:overlay_support/overlay_support.dart';
import 'package:shared_preferences/shared_preferences.dart';



final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Обязательно!
  await Firebase.initializeApp(); // Инициализация Firebase
  final prefs = await SharedPreferences.getInstance();
  final savedUserId = prefs.getString('userId');
  final savedUserRole = prefs.getString('userRole');

  Widget initialScreen = const WelcomeScreen();

  if (savedUserId != null && savedUserRole != null) {
    switch (savedUserRole) {
      case 'drivers':
        initialScreen = DriverDashboard(driverId: savedUserId);
        break;
      case 'dispatchers':
        initialScreen = DispatcherDashboard(dispatcherId: savedUserId);
        break;
      case 'otvetstveniy_za_ekspluataziu':
        initialScreen = OtvetstveniyZaEkspluataziuScreen(userId: savedUserId);
        break;
      case 'rtvetstveniy_po_podrazdeleniu':
        initialScreen = OtvetstveniyPoPodrazdeleniuScreen(userId: savedUserId);
        break;
    }
  }
  // 🔄 Обработка нажатий на пуши
  FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);
  RemoteMessage? initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    _handleMessage(initialMessage);
  }
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
  final data = message.data;
  final type = data['type'];

  if (type == 'incoming_call') {
    final callerName = data['callerName'];
    final callerId = data['callerId'];
    final currentUserId = data['receiverId'];

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => IncomingCallScreen(
          callerId: callerId,
          callerName: callerName,
          currentUserId: currentUserId,
        ),
      ),
    );
  }

  else if (message.notification != null) {
    final title = message.notification!.title ?? 'Уведомление';
    final body = message.notification!.body ?? '';

    showSimpleNotification(
      Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      subtitle: Text(body, style: const TextStyle(color: Colors.white70)),
      background: Colors.blueAccent,
      autoDismiss: true,
      duration: const Duration(seconds: 2),
      slideDismiss: true,
    );
  }
});

  runApp(MyApp(initialScreen: initialScreen));
}
void _handleMessage(RemoteMessage message) {
  final data = message.data;
  final type = data['type'];

  if (type == 'group_chat') {
    final chatType = data['chatType'];
    final currentUserId = data['userId'];
    final title = _getTitleFromChatType(chatType);

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (context) => GroupChatScreen(
          currentUserId: currentUserId,
          chatType: chatType,
          title: title,
        ),
      ),
    );
  }

  else if (type == 'incoming_call') {
    final callerName = data['callerName'];
    final callerId = data['callerId'];
    final currentUserId = data['receiverId'];

    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => IncomingCallScreen(
          callerId: callerId,
          callerName: callerName,
          currentUserId: currentUserId,
        ),
      ),
    );
  }
}

String _getTitleFromChatType(String chatType) {
  switch (chatType) {
    case 'dispatcher_chat':
      return 'Чат с диспетчерами';
    case 'responsible_chat':
    case 'driver_responsible_chat':
      return 'Чат с ответственными';
    case 'dispatcher_responsible_chat':
      return 'Чат диспетчеры ↔ ответственные';
    default:
      return 'Общий чат';
  }
}

class MyApp extends StatelessWidget {
  final Widget initialScreen;

  const MyApp({super.key, required this.initialScreen});

  @override
  Widget build(BuildContext context) {
    return OverlaySupport.global(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Управление статусом водителей',
        theme: ThemeData(primarySwatch: Colors.blue),
        home: initialScreen,
      ),
    );
  }
}


Future<String?> getSavedUserId() async {
  // реализация получения id из локального хранилища
  return null;
}
Future<void> logoutUser(String userId) async {
  await FirebaseFirestore.instance.collection('users').doc(userId).update({
    'fcmToken': FieldValue.delete(),
  });

  // Удаление сохранённых данных пользователя
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('userId');
  await prefs.remove('userRole');
}



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
    print("Запрос разрешений на микрофон...");
    if (!kIsWeb) {
      final status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        throw Exception('Разрешение на микрофон не получено');
      }
    }

    print("Создание записи о вызове в Firestore...");
    await FirebaseFirestore.instance.collection('calls').doc(widget.channelName).set({
      'status': 'pending',
      'caller': widget.currentUserId,
      'receiver': widget.otherUserId,
      'timestamp': FieldValue.serverTimestamp(),
    });

    print("Инициализация Agora...");
    _engine = createAgoraRtcEngine();
    await _engine!.initialize(const RtcEngineContext(
      appId: appId,
      channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
    ));

    await Future.delayed(const Duration(milliseconds: 500)); // Даем время на инициализацию

    await _engine!.enableAudio();
    await _engine!.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

    _engine!.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) {
          print("Подключение к каналу успешно!");
          setState(() {
            _localUserJoined = true;
          });
        },
        onUserJoined: (connection, remoteUid, elapsed) {
          print("Собеседник подключился: $remoteUid");
          setState(() {
            _remoteUid = remoteUid;
          });
        },
        onUserOffline: (connection, remoteUid, reason) {
          print("Собеседник отключился: $remoteUid");
          setState(() {
            _remoteUid = null;
          });
          _onCallEnd(context);
        },
        onError: (err, msg) {
          print("Ошибка Agora: $err, $msg");
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Ошибка звонка: $msg")),
          );
          _onCallEnd(context);
        },
      ),
    );

    print("Присоединение к каналу...");
    await _engine!.joinChannel(
      token: '',
      channelId: widget.channelName,
      uid: 0,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileLiveBroadcasting,
      ),
    );

    print("Ожидание изменений статуса звонка...");
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
    print("Ошибка при инициализации вызова: ${e.toString()}");
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Ошибка звонка: ${e.toString()}")),
      );
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
class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  _RegistrationScreenState createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();

  String _role = 'Водитель';

  Future<void> registerUser() async {
    final String? fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось получить FCM токен')));
      return;
    }

    if (_phoneController.text.trim().isEmpty) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Пожалуйста, введите номер телефона')),
  );
  return;
}


    final usersCollection = _role == 'Водитель'
        ? 'drivers'
        : _role == 'Диспетчер'
            ? 'dispatchers'
            : _role == 'Ответственный за эксплуатацию'
                ? 'otvetstveniy_za_ekspluataziu'
                : 'rtvetstveniy_po_podrazdeleniu';

    final existingUser = await FirebaseFirestore.instance
        .collection(usersCollection)
        .where('name', isEqualTo: _nameController.text)
        .get();

    if (existingUser.docs.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Пользователь с таким именем уже существует')),
      );
      return;
    }

    try {
      await FirebaseFirestore.instance.collection(usersCollection).add({
        'name': _nameController.text,
        'password': _passwordController.text, // Secure hashing needed in production
        'role': _role,
        'phoneNumber': _phoneController.text, 
        'fcmToken': fcmToken,
      });
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка регистрации: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Регистрация')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'ФИО'),
            ),
            TextField(
  controller: _phoneController,
  decoration: const InputDecoration(labelText: 'Номер телефона'),
  keyboardType: TextInputType.phone,
),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Пароль'),
              obscureText: true,
            ),
            DropdownButton<String>(
              value: _role,
              onChanged: (String? newValue) {
                setState(() {
                  _role = newValue!;
                });
              },
              items: <String>[
                'Водитель',
                'Диспетчер',
                'Ответственный за эксплуатацию',
                'Ответственный по подразделению'
              ].map<DropdownMenuItem<String>>((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: registerUser,
              child: const Text('Зарегистрироваться'),
            ),
          ],
        ),
      ),
    );
  }
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Добро пожаловать')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LoginScreen()),
              ),
              child: const Text('Авторизация'),
            ),
             const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const RegistrationScreen()),
              ),
              child: const Text('Регистрация'),
            ),
          ],
        ),
      ),
    );
  }
}

// Экран авторизации
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _rememberMe = false;


  Future<void> loginUser() async {
  final List<String> collections = [
    'drivers',
    'dispatchers',
    'otvetstveniy_za_ekspluataziu',
    'rtvetstveniy_po_podrazdeleniu',
  ];

  for (final String collection in collections) {
    try {
      final userSnapshot = await FirebaseFirestore.instance
          .collection(collection)
          .where('name', isEqualTo: _nameController.text)
          .where('password', isEqualTo: _passwordController.text)
          .get();

      if (userSnapshot.docs.isNotEmpty) {
        final String userId = userSnapshot.docs.first.id;
        final String? fcmToken = await FirebaseMessaging.instance.getToken();

        if (fcmToken != null) {
          print('FCM Token: $fcmToken');  // Check this output!

          try {
            await FirebaseFirestore.instance
                .collection(collection)
                .doc(userId)
                .update({'fcmToken': fcmToken});
            print('FCM token updated successfully in $collection for user $userId');
          } catch (e) {
            print('Error updating FCM token in $collection for user $userId: $e');
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error updating FCM token: $e')));
          }
        } else {
          print('Failed to retrieve FCM token from Firebase Messaging');
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Failed to retrieve FCM token')));
        }
        if (_rememberMe) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('userId', userId);
        await prefs.setString('userRole', collection);
      }


        // Navigation to dashboards (add your navigation logic here)
        if (collection == 'drivers') {
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) => DriverDashboard(driverId: userId)),
          );
        } else if (collection == 'dispatchers') {
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) => DispatcherDashboard(dispatcherId: userId)),
          );
        } else if (collection == 'otvetstveniy_za_ekspluataziu') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  OtvetstveniyZaEkspluataziuScreen(userId: userId),
            ),
          );
        } else if (collection == 'rtvetstveniy_po_podrazdeleniu') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  OtvetstveniyPoPodrazdeleniuScreen(userId: userId),
            ),
          );
        }
        return;
      }
    } catch (e) {
      print('Error during login process: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('An error occurred during login: $e')),
      );
      return;  // Exit the function if a general error occurred
    }
  }

  ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invalid credentials')));
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Авторизация')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'ФИО'),
            ),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Пароль'),
              obscureText: true,
            ),
                    CheckboxListTile(
          title: const Text("Запомнить меня"),
          value: _rememberMe,
          onChanged: (value) {
            setState(() {
              _rememberMe = value ?? false;
            });
          },
        ),

            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: loginUser,
              child: const Text('Войти'),
            ),
          ],
        ),
      ),
    );
  }
}

class DriverDashboard extends StatefulWidget {
  final String driverId;

  const DriverDashboard({super.key, required this.driverId});

  @override
  _DriverDashboardState createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard> {
  String _status = 'Свободен';
  int totalMileage = 0;
  int dailyMileage = 0;
  String selectedCar = 'Не выбрана';
  int carMileage = 0;

  @override
  void initState() {
    super.initState();
    _loadDriverData();
  }
  Future<void> _changePassword() async {
    TextEditingController oldPasswordController = TextEditingController();
    TextEditingController newPasswordController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Изменить пароль'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: oldPasswordController,
                decoration: const InputDecoration(labelText: 'Старый пароль'),
                obscureText: true,
              ),
              TextField(
                controller: newPasswordController,
                decoration: const InputDecoration(labelText: 'Новый пароль'),
                obscureText: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (oldPasswordController.text.isNotEmpty &&
                    newPasswordController.text.isNotEmpty) {
                  // Обновить пароль в Firestore
                  try {
                    // Получаем текущие данные водителя из коллекции 'drivers'
                    var driverDoc = await FirebaseFirestore.instance
                        .collection('drivers')
                        .doc(widget.driverId) // Используем driverId вместо userId
                        .get();

                    if (driverDoc.exists) {
                      // Получаем текущий пароль
                      String currentPassword = driverDoc['password']; // Предположим, что пароль хранится в поле 'password'

                      if (currentPassword == oldPasswordController.text) {
                        // Если старый пароль правильный, обновляем его
                        await FirebaseFirestore.instance
                            .collection('drivers') // Коллекция 'drivers'
                            .doc(widget.driverId) // Используем driverId
                            .update({'password': newPasswordController.text});

                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Пароль обновлен')),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Неверный старый пароль')),
                        );
                      }
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Водитель не найден')),
                      );
                    }
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Ошибка при обновлении пароля: $e')),
                    );
                  }

                  Navigator.of(context).pop();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Пожалуйста, заполните все поля')),
                  );
                }
              },
              child: const Text('Сохранить'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена'),
            ),
          ],
        );
      },
    );
  }

Future<void> _loadDriverData() async {
  var driverDoc = await FirebaseFirestore.instance.collection('drivers').doc(widget.driverId).get();
  if (driverDoc.exists) {
    var data = driverDoc.data() as Map<String, dynamic>;
    Future.delayed(const Duration(milliseconds: 100), () {
      setState(() {
        _status = data['status'] ?? 'Свободен';
        totalMileage = int.tryParse(data['totalMileage'].toString()) ?? 0;
        dailyMileage = int.tryParse(data['dailyMileage'].toString()) ?? 0;
        selectedCar = data['selectedCar'] ?? 'Не выбрана';
        carMileage = int.tryParse(data['carMileage'].toString()) ?? 0;
      });
    });
  }
}


void _showStatusChangeDialog() {
    showDialog(
        context: context,
        builder: (context) {
            return AlertDialog(
                title: const Text('Выберите новый статус'),
                content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: ['На линии', 'Свободен', 'На выезде', 'Убыл с линии'].map((status) {
                        return ListTile(
                            title: Text(status),
                            onTap: () {
                                _updateStatus(status); // Обновляем статус
                                Navigator.of(context).pop();
                            },
                        );
                    }).toList(),
                ),
            );
        },
    );
}
  void _showDispatcherList() {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Выберите диспетчера'),
        content: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('dispatchers').snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

            final dispatchers = snapshot.data!.docs;

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: dispatchers.map((doc) {
                  var dispatcher = doc.data() as Map<String, dynamic>;
                  String? phoneNumber = dispatcher['phoneNumber'];
                  String dispatcherName = dispatcher['name'] ?? 'Неизвестный диспетчер';
                  String dispatcherId = doc.id; // Получаем ID диспетчера


                  return ListTile(
                    title: Text(dispatcherName),
                    subtitle: Text(phoneNumber ?? 'Нет номера'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Иконка вызова
                        // IconButton(
                        //   icon: const Icon(Icons.phone),
                        //   onPressed: () {
                        //     if (phoneNumber != null && phoneNumber.isNotEmpty) {
                        //       Navigator.of(context).pop();
                        //       _callDispatcher(doc.id, dispatcherName);
                        //     } else {
                        //       ScaffoldMessenger.of(context).showSnackBar(
                        //         const SnackBar(content: Text("У диспетчера нет номера телефона")),
                        //       );
                        //     }
                        //   },
                        // ),
                        // Иконка чата
                        IconButton(
                          icon: const Icon(Icons.chat),
                          onPressed: () {
                            Navigator.of(context).pop();
                            _openChatWithDispatcher(doc.id, dispatcherName);
                          },
                        ),
                      ],
                    ),
                    onTap: () {
                      // Действие при клике на диспетчера, если нужно
                    },
                  );
                }).toList(),
              ),
            );
          },
        ),
      );
    },
  );
}


void _callDispatcher(String dispatcherId, String dispatcherName) async {
  print("Попытка вызова диспетчера: $dispatcherId ($dispatcherName)");

  // Проверяем, есть ли уже активный вызов
  var callDoc = await FirebaseFirestore.instance.collection('calls').doc(dispatcherId).get();

  if (callDoc.exists && callDoc.data()?['status'] == 'active') {
    print("Вызов уже идет. Ожидаем завершения.");
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Вызов уже идет. Пожалуйста, подождите.")),
    );
    return;
  }

  // Создаем вызов в Firestore
  await FirebaseFirestore.instance.collection('calls').doc(dispatcherId).set({
    'status': 'active',
    'caller': widget.driverId,
    'receiver': dispatcherId,
    'timestamp': FieldValue.serverTimestamp(),
  });

  // Запускаем экран вызова
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => CallScreen(
        channelName: dispatcherId, // Канал связи
        currentUserId: widget.driverId, // ID текущего пользователя
        otherUserId: dispatcherId, // ID диспетчера
        otherUserName: dispatcherName, // Имя диспетчера
      ),
    ),
  );
}




  Future<void> _updateStatus(String newStatus) async {
  var driverDoc = await FirebaseFirestore.instance.collection('drivers').doc(widget.driverId).get();
  String driverName = (driverDoc.exists && driverDoc.data() != null) 
      ? (driverDoc.data()?['name'] ?? 'Водитель') 
      : 'Водитель';

  await FirebaseFirestore.instance.collection('drivers').doc(widget.driverId).update({
    'status': newStatus,
    if (newStatus == "Свободен") 'startTime': Timestamp.now(),
    if (newStatus == "Убыл с линии") 'endTime': Timestamp.now(),
  });

  _sendStatusChangeNotification(driverName, newStatus);

  setState(() {
    _status = newStatus;
  });
}
Future<void> _sendPushNotificationStatus(String token, String driverName, String status) async {
  try {
    print('Loading service account credentials...');
    final serviceAccount = jsonDecode(await rootBundle.loadString('assets/google-services.json'));
    print('Service account credentials loaded.');

    print('Authenticating with FCM v1 API...');
    auth.ServiceAccountCredentials credentials = auth.ServiceAccountCredentials.fromJson(serviceAccount);
    final scopes = ['https://www.googleapis.com/auth/firebase.messaging'];
    final client = await auth.clientViaServiceAccount(credentials, scopes);
    final accessToken = client.credentials.accessToken;

    final body = {
      "message": {
        "token": token,
        "notification": {
          "title": "Изменение статуса водителя",
          "body": "$driverName обновил статус: $status",
        },
        "data": {
          "driverName": driverName,
          "status": status,
          "click_action": "FLUTTER_NOTIFICATION_CLICK"
        },
      },
    };

    print('Sending status change push notification...');
    final response = await http.post(
      Uri.parse("https://fcm.googleapis.com/v1/projects/pril123/messages:send"),
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer ${accessToken.data}",
      },
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      print("✅ Push notification for status change sent successfully!");
    } else {
      print("❌ Error sending push notification: ${response.body}");
    }
  } catch (e) {
    print("❗ Error sending FCM notification: $e");
  }
}


Future<void> _sendStatusChangeNotification(String driverName, String status) async {
  var dispatcherSnapshot = await FirebaseFirestore.instance.collection('dispatchers').get();
  var responsibleSnapshot = await FirebaseFirestore.instance.collection('otvetstveniy_za_ekspluataziu').get();

  List<String> tokens = [];

  for (var doc in dispatcherSnapshot.docs) {
    String? token = doc['fcmToken'];
    if (token != null && token.isNotEmpty) tokens.add(token);
  }

  for (var doc in responsibleSnapshot.docs) {
    String? token = doc['fcmToken'];
    if (token != null && token.isNotEmpty) tokens.add(token);
  }

  for (var token in tokens) {
    await _sendPushNotificationStatus(token, driverName, status);
  }
}



  void _showMileageDialog() {
    final TextEditingController mileageController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Ввести суточный пробег'),
          content: TextField(
            controller: mileageController,
            decoration: const InputDecoration(labelText: 'Суточный пробег (км)'),
            keyboardType: TextInputType.number,
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (mileageController.text.isNotEmpty) {
                  int mileageToAdd = int.parse(mileageController.text);
                  await FirebaseFirestore.instance.collection('drivers').doc(widget.driverId).update({
                    'dailyMileage': FieldValue.increment(mileageToAdd),
                    'totalMileage': FieldValue.increment(mileageToAdd),
                    'carMileage': FieldValue.increment(mileageToAdd),
                  });

                  setState(() {
                    dailyMileage += mileageToAdd;
                    totalMileage += mileageToAdd;
                    carMileage += mileageToAdd;
                  });

                  Navigator.of(context).pop();
                }
              },
              child: const Text('Сохранить'),
            ),
            TextButton(
              onPressed: () async {
                await FirebaseFirestore.instance.collection('drivers').doc(widget.driverId).update({
                  'dailyMileage': 0,
                });

                setState(() {
                  dailyMileage = 0;
                });

                Navigator.of(context).pop();
              },
              child: const Text('Обновить'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена'),
            ),
          ],
        );
      },
    );
  }


void _showCarSelectionDialog() {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Выберите машину'),
        content: SizedBox(
          height: 300,
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('cars').snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return const Center(child: Text('Ошибка при загрузке данных.'));
              }

              final cars = snapshot.data!.docs;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: ListView(
                      children: cars.map((doc) {
                        var car = doc.data() as Map<String, dynamic>;
                        return ListTile(
                          title: Text(car['callSign'] ?? 'Без номера'),
                          onTap: () {
                            // Выполняем операцию на главном потоке без addPostFrameCallback
                            _selectCar(doc.id, car['callSign'], car['mileage']);
                          },
                        );
                      }).toList(),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop(); // Закрываем текущий диалог
                      _showAddCarDialog(); // Открываем диалог добавления машины
                    },
                    child: const Text('Добавить машину'),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}


Future<void> _selectCar(String carId, String carNumber, int mileage) async {
  try {
    await FirebaseFirestore.instance.collection('drivers').doc(widget.driverId).update({
      'selectedCar': carNumber,
      'carMileage': mileage,
    });

    if (mounted) {
      setState(() {
        selectedCar = carNumber;
        carMileage = mileage;
      });
    }

    Navigator.of(context).pop(); // Закрываем диалог выбора машины
  } catch (e) {
    print("Ошибка при выборе машины: $e");
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Ошибка при выборе машины: $e")),
    );
  }
}

Future<void> _showAddCarDialog() {
  final TextEditingController carNumberController = TextEditingController();
  final TextEditingController carMileageController = TextEditingController();

  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Добавить машину'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: carNumberController,
              decoration: const InputDecoration(labelText: 'Номер автомобиля (Позывной)'),
            ),
            TextField(
              controller: carMileageController,
              decoration: const InputDecoration(labelText: 'Общий пробег (км)'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              if (carNumberController.text.isNotEmpty && carMileageController.text.isNotEmpty) {
                try {
                  int mileage = int.parse(carMileageController.text);
                  await FirebaseFirestore.instance.collection('cars').add({
                    'callSign': carNumberController.text,
                    'mileage': mileage,
                  });

                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Машина добавлена")),
                  );
                } catch (e) {
                  print("Ошибка при добавлении машины: $e"); // Выводим ошибку в консоль
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Ошибка при добавлении машины: $e")),
                  );
                }
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Пожалуйста, заполните все поля.")),
                );
              }
                        },
            child: const Text('Сохранить'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
        ],
      );
    },
  );
}



void _openChat(BuildContext context, String chatPartnerId, String chatPartnerRole) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          currentUserId: widget.driverId,
          otherUserId: chatPartnerId,
          otherUserName: chatPartnerRole,
          chatPartnerRole: chatPartnerRole,  // Pass chatPartnerRole
        ),
      ),
    );
  }
void _showResponsibleList() {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Выберите ответственного'),
        content: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('otvetstveniy_za_ekspluataziu').snapshots(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

            final Responsible = snapshot.data!.docs;

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: Responsible.map((doc) {
                  var responsible = doc.data() as Map<String, dynamic>;
                  String? phoneNumber = responsible['phoneNumber'];
                  String responsibleName = responsible['name'] ?? 'Неизвестный диспетчер';

                  return ListTile(
                    title: Text(responsibleName),
                    subtitle: Text(phoneNumber ?? 'Нет номера'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Иконка вызова
                        // IconButton(
                        //   icon: const Icon(Icons.phone),
                        //   onPressed: () {
                        //     Navigator.of(context).pop();
                        //     _callResponsible('responsibleId', responsibleName);  // Без проверки на наличие номера
                        //   },
                        // ),
                        // Иконка чата
                        IconButton(
                          icon: const Icon(Icons.chat),
                          onPressed: () {
                            Navigator.of(context).pop();
                            _openChatWithResponsible('responsibleId', responsibleName);
                          },
                        ),
                      ],
                    ),
                    onTap: () {
                      // Действие при клике на диспетчера, если нужно
                    },
                  );
                }).toList(),
              ),
            );
          },
        ),
      );
    },
  );
}

 void _callResponsible(String responsibleId, String responsibleName) async {
  print("Попытка вызова ответственного: $responsibleId ($responsibleName)");

  // Проверяем, есть ли уже активный вызов
  var callDoc = await FirebaseFirestore.instance.collection('calls').doc(responsibleId).get();

  if (callDoc.exists && callDoc.data()?['status'] == 'active') {
    print("Вызов уже идет. Ожидаем завершения.");
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Вызов уже идет. Пожалуйста, подождите.")),
    );
    return;
  }

  // Создаем вызов в Firestore
  await FirebaseFirestore.instance.collection('calls').doc(responsibleId).set({
    'status': 'active',
    'caller': widget.driverId,
    'receiver': responsibleId,
    'timestamp': FieldValue.serverTimestamp(),
  });

  // Запускаем экран вызова
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => CallScreen(
        channelName: responsibleId, // Канал связи
        currentUserId: widget.driverId, // ID текущего пользователя
        otherUserId: responsibleId, // ID диспетчера
        otherUserName: responsibleName, // Имя диспетчера
      ),
    ),
  );
}
  void _openChatWithResponsible(String responsibleId, String responsibleName) {
  _openChat(context, responsibleId, responsibleName);
}
  
  void _openChatWithDispatcher(String dispatcherId, String dispatcherName) {
  _openChat(context, dispatcherId, dispatcherName);
}

  @override
Widget build(BuildContext context) {
  return WillPopScope(
    onWillPop: () async {
  final shouldExit = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Подтверждение'),
      content: const Text('Вы точно хотите выйти в меню авторизации?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Выйти'),
        ),
      ],
    ),
  );

  if (shouldExit == true) {
    await logoutUser(widget.driverId);
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const WelcomeScreen()),
      (route) => false,
    );
    return false;
  }

  return false;
},

    child:  Scaffold(
      appBar: AppBar(
        title: const Text('Панель водителя'),
        // actions: [
//   IconButton(
//     icon: const Icon(Icons.contacts),
//     onPressed: () {
//       Navigator.push(
//         context,
//         MaterialPageRoute(
//           builder: (context) => ContactsScreen(
//             currentUserId: widget.driverId,
//             currentUserRole: 'Водитель',
//           ),
//         ),
//       );
//     },
//   ),
// ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Ваш статус: $_status', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Text('Выбранная машина: $selectedCar', style: const TextStyle(fontSize: 20)),
              Text('Пробег машины: $carMileage км', style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _showMileageDialog,
                child: const Text('Ввести пробег'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: _showCarSelectionDialog,
                child: const Text('Выбрать машину'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => GroupChatScreen(
                      currentUserId: widget.driverId,
                      chatType: 'dispatcher_chat',
                      title: 'Чат с диспетчерами',
                    ),
                  ),
                );
              },
              child: const Text('Чат с диспетчерами'),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupChatScreen(
          currentUserId: widget.driverId,
          chatType: 'driver_responsible_chat',
          title: 'Чат с ответственными',
        ),
      ),
    );
  },
  child: const Text('Чат с ответственными'),
),
              
              const SizedBox(height: 10),
             ElevatedButton(
  onPressed: _showStatusChangeDialog, // ✅ Теперь метод вызывается
  child: const Text('Изменить статус'),
),

              const SizedBox(height: 10),
              const SizedBox(height: 10),
               ElevatedButton(
                onPressed: _changePassword,  // Теперь без параметра
                child: const Text('Изменить пароль'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }
}




class DispatcherDashboard extends StatefulWidget {
  final String dispatcherId;

  const DispatcherDashboard({required this.dispatcherId, Key? key}) : super(key: key);

  @override
  _DispatcherDashboardState createState() => _DispatcherDashboardState();
}

class _DispatcherDashboardState extends State<DispatcherDashboard> {
  String? expandedDriverId;
  bool _isOnline = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final doc = await FirebaseFirestore.instance.collection('dispatchers').doc(widget.dispatcherId).get();
    if (doc.exists) {
      setState(() {
        _isOnline = doc['isOnline'] ?? false;
      });
    }
  }

  Future<void> _updateStatus(bool value) async {
    setState(() => _isOnline = value);
    await FirebaseFirestore.instance.collection('dispatchers').doc(widget.dispatcherId).update({'isOnline': value});
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'Свободен':
        return Colors.green;
      case 'На линии':
      case 'На выезде':
      case 'Убыл с линии':
        return Colors.red;
      default:
        return Colors.black;
    }
  }

  Future<void> _changePassword() async {
    TextEditingController oldPasswordController = TextEditingController();
    TextEditingController newPasswordController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Изменить пароль'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: oldPasswordController,
                decoration: const InputDecoration(labelText: 'Старый пароль'),
                obscureText: true,
              ),
              TextField(
                controller: newPasswordController,
                decoration: const InputDecoration(labelText: 'Новый пароль'),
                obscureText: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (oldPasswordController.text.isNotEmpty && newPasswordController.text.isNotEmpty) {
                  var dispatcherDoc = await FirebaseFirestore.instance.collection('dispatchers').doc(widget.dispatcherId).get();

                  if (dispatcherDoc.exists) {
                    String currentPassword = dispatcherDoc['password'];

                    if (currentPassword == oldPasswordController.text) {
                      await FirebaseFirestore.instance.collection('dispatchers').doc(widget.dispatcherId).update({'password': newPasswordController.text});
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пароль обновлен')));
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Неверный старый пароль')));
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Диспетчер не найден')));
                  }
                  Navigator.of(context).pop();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пожалуйста, заполните все поля')));
                }
              },
              child: const Text('Сохранить'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена'),
            ),
          ],
        );
      },
    );
  }

  @override
Widget build(BuildContext context) {
  return WillPopScope(
    onWillPop: () async {
  final shouldExit = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Подтверждение'),
      content: const Text('Вы точно хотите выйти в меню авторизации?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Выйти'),
        ),
      ],
    ),
  );

  if (shouldExit == true) {
    await logoutUser(widget.dispatcherId); // или widget.dispatcherId / widget.userId
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const WelcomeScreen()),
      (route) => false,
    );
    return false;
  }

  return false;
},

    child: Scaffold(
      appBar: AppBar(title: const Text('Панель диспетчера')),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text("Вы онлайн"),
            value: _isOnline,
            onChanged: _updateStatus,
            secondary: Icon(
              _isOnline ? Icons.circle : Icons.circle_outlined,
              color: _isOnline ? Colors.green : Colors.grey,
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('drivers').snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final drivers = snapshot.data!.docs;

                return ListView.builder(
                  itemCount: drivers.length,
                  itemBuilder: (context, index) {
                    var driverData = drivers[index].data() as Map<String, dynamic>;
                    String driverId = drivers[index].id;
                    String selectedCar = driverData['selectedCar'] ?? 'Машина не выбрана';
                    String status = driverData['status'] ?? 'Неизвестно';
                    String driverName = driverData['name'] ?? 'Неизвестный водитель';
                    bool isExpanded = expandedDriverId == driverId;

                    return Card(
                      margin: const EdgeInsets.all(8.0),
                      child: Column(
                        children: [
                          ListTile(
                            title: Text("Машина: $selectedCar"),
                            subtitle: Text("Статус: $status", style: TextStyle(color: _getStatusColor(status))),
                            trailing: PopupMenuButton<String>(
                              onSelected: (newStatus) => _updateDriverStatus(driverId, newStatus),
                              itemBuilder: (context) => ["На линии", "Свободен", "На выезде", "Убыл с линии"]
                                  .map((status) => PopupMenuItem(value: status, child: Text(status)))
                                  .toList(),
                            ),
                            onTap: () {
                              setState(() {
                                expandedDriverId = isExpanded ? null : driverId;
                              });
                            },
                          ),
                          if (isExpanded) _buildExpandedSection(driverData, driverId, driverName),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.group),
              label: const Text("Чат с Водителями"),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => GroupChatScreen(
                      currentUserId: widget.dispatcherId,
                      chatType: 'dispatcher_chat',
                      title: 'Общий чат с водителями',
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
  icon: const Icon(Icons.support_agent),
  label: const Text("Чат с Ответственными"),
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupChatScreen(
          currentUserId: widget.dispatcherId,
          chatType: 'dispatcher_responsible_chat',
          title: 'Общий чат с ответственными',
        ),
      ),
    );
  },
),
            ElevatedButton(
              onPressed: _changePassword,
              child: const Text('Изменить пароль'),
            ),
          ],
        ),
      ),
    ),
  );
}
    void _openChatWithResponsible() {
    FirebaseFirestore.instance.collection('otvetstveniy_za_ekspluataziu').limit(1).get().then((snapshot) {
      if (snapshot.docs.isNotEmpty) {
        var responsibleData = snapshot.docs.first.data();
        String responsibleId = snapshot.docs.first.id;
        String responsibleName = responsibleData['name'] ?? 'Неизвестный ответственный';
        _openChat(context, responsibleId, responsibleName);
      }
    });
  }
  void _openChat(BuildContext context, String chatPartnerId, String chatPartnerRole) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          currentUserId: widget.dispatcherId,
          otherUserId: chatPartnerId,
          otherUserName: chatPartnerRole,
          chatPartnerRole: chatPartnerRole,  // Pass chatPartnerRole
        ),
      ),
    );
  }


    void _callResponsible() async {
    var ResponsibleSnapshot = await FirebaseFirestore.instance.collection('otvetstveniy_za_ekspluataziu').limit(1).get();
    if (ResponsibleSnapshot.docs.isNotEmpty) {
      var Responsible = ResponsibleSnapshot.docs.first.data();
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CallScreen(
            channelName: 'otvetstveniy_za_ekspluataziu', // Unique channel identifier for dispatcher
            currentUserId: widget.dispatcherId, // Responsible person's ID
            otherUserId: 'otvetstveniy_za_ekspluataziu', // Dispatcher ID (could be a fixed value or retrieved)
            otherUserName: Responsible['name'] ?? 'Неизвестный Ответственный', // Dispatcher name
          ),
        ),
      );
    }
  }

  void _callDriver(String driverId, String driverName) async {
  print("Попытка вызова водителя: $driverId ($driverName)");

  // Проверяем, есть ли уже активный вызов
  var callDoc = await FirebaseFirestore.instance.collection('calls').doc(driverId).get();

  if (callDoc.exists && callDoc.data()?['status'] == 'active') {
    print("Вызов уже идет. Ожидаем завершения.");
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Вызов уже идет. Пожалуйста, подождите.")),
    );
    return;
  }

  // Создаем вызов в Firestore
  await FirebaseFirestore.instance.collection('calls').doc(driverId).set({
    'status': 'active',
    'caller': widget.dispatcherId,
    'receiver': driverId,
    'timestamp': FieldValue.serverTimestamp(),
  });

  // Запускаем экран вызова
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => CallScreen(
        channelName: driverId, // Канал связи
        currentUserId: widget.dispatcherId, // ID текущего пользователя
        otherUserId: driverId, // ID диспетчера
        otherUserName: driverName, // Имя диспетчера
      ),
    ),
  );
}


  Widget _buildExpandedSection(Map<String, dynamic> driverData, String driverId, String driverName) {
    int dailyMileage = driverData['dailyMileage'] ?? 0;
    String? selectedCar = driverData['selectedCar'];
    int carMileage = driverData['carMileage'] ?? 0;
    Timestamp? startTime = driverData['startTime'];
    Timestamp? endTime = driverData['endTime'];

    String formattedStartTime = startTime != null
        ? "${startTime.toDate().hour}:${startTime.toDate().minute}"
        : "Не указано";

    String formattedEndTime = endTime != null
        ? "${endTime.toDate().hour}:${endTime.toDate().minute}"
        : "Не указано";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Водитель: $driverName", style: const TextStyle(fontWeight: FontWeight.bold)),
          Text("Время начала: $formattedStartTime"),
          Text("Время окончания: $formattedEndTime"),
          Text("Суточный пробег: $dailyMileage км"),
          if (selectedCar != null) ...[
            Text("Выбранная машина: $selectedCar"),
            Text("Пробег машины: $carMileage км"),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
//               IconButton(
//   icon: const Icon(Icons.phone),
//   onPressed: () {
//     Navigator.push(
//       context,
//       MaterialPageRoute(
//         builder: (context) => CallScreen(
//           channelName: driverId, // Уникальный идентификатор канала
//           currentUserId: widget.dispatcherId, // ID текущего пользователя
//           otherUserId: driverId, // ID водителя
//           otherUserName: driverData['name'] ?? 'Водитель', // Имя водителя
//         ),
//       ),
//     );
//   },
// ),
IconButton(
  icon: const Icon(Icons.chat),
  onPressed: () => _openChatWithDriver(
    context, 
    widget.dispatcherId, // Используйте widget.dispatcherId для текущего пользователя
    driverId, 
    driverData['name'] ?? 'Имя водителя', 
    "driver"
  ),
),

              IconButton(
                icon: const Icon(Icons.speed),
                onPressed: () => _showMileageDialog(context, driverId),
              ),
            ],
          )
        ],
      ),
    );
  }

  Future<void> _updateDriverStatus(String driverId, String newStatus) async {
    await FirebaseFirestore.instance.collection('drivers').doc(driverId).update({
      'status': newStatus,
      if (newStatus == "Свободен") 'startTime': Timestamp.now(),
      if (newStatus == "Убыл с линии") 'endTime': Timestamp.now(),
    });
  }

  void _showMileageDialog(BuildContext context, String driverId) {
    TextEditingController mileageController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Добавить суточный пробег'),
          content: TextField(
            controller: mileageController,
            decoration: const InputDecoration(labelText: 'Суточный пробег (км)'),
            keyboardType: TextInputType.number,
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (mileageController.text.isNotEmpty) {
                  int mileageToAdd = int.parse(mileageController.text);
                  await FirebaseFirestore.instance.collection('drivers').doc(driverId).update({
                    'dailyMileage': FieldValue.increment(mileageToAdd),
                    'carMileage': FieldValue.increment(mileageToAdd),
                  });
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Сохранить'),
            ),
            TextButton(
              onPressed: () async {
                await FirebaseFirestore.instance.collection('drivers').doc(driverId).update({
                  'dailyMileage': 0,
                });
                Navigator.of(context).pop();
              },
              child: const Text('Обновить'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _makeCall(String? phoneNumber) async {
    if (phoneNumber != null && phoneNumber.isNotEmpty) {
      final Uri callUri = Uri(scheme: 'tel', path: phoneNumber);
      if (await canLaunchUrl(callUri)) {
        await launchUrl(callUri);
      }
    }
  }

void _openChatWithDriver(BuildContext context, String currentUserId, String otherUserId, String otherUserName, String chatPartnerRole) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => ChatScreen(
        currentUserId: currentUserId,     // ID текущего пользователя
        otherUserId: otherUserId,         // ID собеседника
        otherUserName: otherUserName,     // Имя собеседника
        chatPartnerRole: chatPartnerRole, // Роль собеседника
      ),
    ),
  );
}

}

class OtvetstveniyZaEkspluataziuScreen extends StatefulWidget {
  final String userId;

  const OtvetstveniyZaEkspluataziuScreen({required this.userId, Key? key}) : super(key: key);

  @override
  _OtvetstveniyZaEkspluataziuScreenState createState() => _OtvetstveniyZaEkspluataziuScreenState();
}

class _OtvetstveniyZaEkspluataziuScreenState extends State<OtvetstveniyZaEkspluataziuScreen> {
  Map<String, bool> expandedCards = {};

  @override
Widget build(BuildContext context) {
  return WillPopScope(
    onWillPop: () async {
  final shouldExit = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Подтверждение'),
      content: const Text('Вы точно хотите выйти в меню авторизации?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Выйти'),
        ),
      ],
    ),
  );

  if (shouldExit == true) {
    await logoutUser(widget.userId); // или widget.dispatcherId / widget.userId
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const WelcomeScreen()),
      (route) => false,
    );
    return false;
  }

  return false;
},

    child:  Scaffold(
      appBar: AppBar(title: const Text('Ответственный за эксплуатацию')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('drivers').snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final drivers = snapshot.data!.docs;

          return ListView.builder(
            itemCount: drivers.length,
            itemBuilder: (context, index) {
              var driverData = drivers[index].data() as Map<String, dynamic>;
              String driverId = drivers[index].id;
              String driverName = driverData['name'] ?? 'Неизвестный водитель';
              String status = driverData['status'] ?? 'Неизвестно';
              int dailyMileage = int.tryParse(driverData['dailyMileage'].toString()) ?? 0;
              int carMileage = int.tryParse(driverData['carMileage'].toString()) ?? 0;
              String? selectedCar = driverData['selectedCar'];
              Color statusColor;

              switch (status) {
                case 'Свободен':
                  statusColor = Colors.green;
                  break;
                case 'На линии':
                case 'На выезде':
                case 'Убыл с линии':
                  statusColor = Colors.red;
                  break;
                default:
                  statusColor = Colors.grey;
                  break;
              }

              Timestamp? startTime = driverData['startTime'] is Timestamp ? driverData['startTime'] : null;
              Timestamp? endTime = driverData['endTime'] is Timestamp ? driverData['endTime'] : null;

              String formattedStartTime = startTime != null
                  ? "${startTime.toDate().hour}:${startTime.toDate().minute}"
                  : "Не указано";

              String formattedEndTime = endTime != null
                  ? "${endTime.toDate().hour}:${endTime.toDate().minute}"
                  : "Не указано";

              bool isExpanded = expandedCards[driverId] ?? false;

              return Card(
                margin: const EdgeInsets.all(8.0),
                child: Column(
                  children: [
                    ListTile(
                      title: Text("Машина: ${selectedCar ?? 'Машина не выбрана'}"),
                      subtitle: Text("Статус: $status", style: TextStyle(color: statusColor)),
                      onTap: () {
                        setState(() {
                          expandedCards[driverId] = !isExpanded;
                        });
                      },
                    ),
                    if (isExpanded)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Водитель: $driverName", style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text("Время начала: $formattedStartTime"),
                            Text("Время окончания: $formattedEndTime"),
                            Text("Суточный пробег: $dailyMileage км"),
                            Text("Общий пробег: $carMileage км"),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                // Expanded(
                                //   child: ElevatedButton.icon(
                                //     icon: const Icon(Icons.phone),
                                //     label: const Text("Позвонить водителю"),
                                //     onPressed: () => _callDriver(driverId, driverData['phoneNumber'], driverName),
                                //   ),
                                // ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    icon: const Icon(Icons.chat),
                                    label: const Text("Чат с водителем"),
                                    onPressed: () => _openChat(context, driverId, "Водитель"),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton.icon(
  icon: const Icon(Icons.group),
  label: const Text("Чат с Водителями"),
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupChatScreen(
  currentUserId: widget.userId,
  chatType: 'driver_responsible_chat',
  title: 'Чат с водителями',
),
      ),
    );
  },
),
const SizedBox(height: 10),
ElevatedButton.icon(
  icon: const Icon(Icons.support_agent),
  label: const Text("Чат с Диспетчерами"),
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => GroupChatScreen(
  currentUserId: widget.userId,
  chatType: 'dispatcher_responsible_chat',
  title: 'Чат с диспетчерами',
),
      ),
    );
  },
),
const SizedBox(height: 10),
            
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.lock),
              label: const Text("Изменить пароль"),
              onPressed: () => _changePassword(context, widget.userId),
            ),
          ],
        ),
      ),
    ),
    );
  }

  void _showDispatcherList({required BuildContext context, required String userId}) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Выберите диспетчера'),
          content: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('dispatchers').snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

              final dispatchers = snapshot.data!.docs;

              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: dispatchers.map((doc) {
                    var dispatcher = doc.data() as Map<String, dynamic>;
                    String? phoneNumber = dispatcher['phoneNumber'];
                    String dispatcherName = dispatcher['name'] ?? 'Неизвестный диспетчер';
                    String dispatcherId = doc.id; // Получаем ID диспетчера

                    return ListTile(
                      title: Text(dispatcherName),
                      subtitle: Text(phoneNumber ?? 'Нет номера'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Иконка вызова
                          // IconButton(
                          //   icon: const Icon(Icons.phone),
                          //   onPressed: () {
                          //     if (phoneNumber != null && phoneNumber.isNotEmpty) {
                          //       Navigator.of(context).pop();
                          //       _callDispatcher(dispatcherId: dispatcherId, dispatcherName: dispatcherName);
                          //     } else {
                          //       ScaffoldMessenger.of(context).showSnackBar(
                          //         const SnackBar(content: Text("У диспетчера нет номера телефона")),
                          //       );
                          //     }
                          //   },
                          // ),
                          // Иконка чата
                          IconButton(
                            icon: const Icon(Icons.chat),
                            onPressed: () {
                              Navigator.of(context).pop();
                              _openChatWithDispatcher(dispatcherId: dispatcherId, dispatcherName: dispatcherName);
                            },
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _callDriver(String driverId, String? phoneNumber, String driverName) async {
    if (phoneNumber != null && phoneNumber.isNotEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CallScreen(
            channelName: driverId, // Unique channel identifier for the driver
            currentUserId: widget.userId, // ID of the responsible person (dispatcher)
            otherUserId: driverId, // Driver ID
            otherUserName: driverName, // Driver's name
          ),
        ),
      );
    }
  }

  void _callDispatcher({required String dispatcherId, required String dispatcherName}) async {
    var dispatcherSnapshot = await FirebaseFirestore.instance.collection('dispatchers').doc(dispatcherId).get();

    if (dispatcherSnapshot.exists) {
      var dispatcher = dispatcherSnapshot.data() as Map<String, dynamic>;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => CallScreen(
            channelName: 'dispatcher', // Unique channel identifier for dispatcher
            currentUserId: widget.userId, // ID of responsible person
            otherUserId: dispatcherId, // Dispatcher ID
            otherUserName: dispatcher['name'] ?? 'Неизвестный диспетчер', // Dispatcher name
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Диспетчер не найден")),
      );
    }
  }

  void _openChat(BuildContext context, String chatPartnerId, String chatPartnerRole) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          currentUserId: widget.userId,
          otherUserId: chatPartnerId,
          otherUserName: chatPartnerRole,
          chatPartnerRole: chatPartnerRole,  // Pass chatPartnerRole
        ),
      ),
    );
  }

  void _openChatWithDispatcher({required String dispatcherId, required String dispatcherName}) {
    FirebaseFirestore.instance.collection('dispatchers').doc(dispatcherId).get().then((snapshot) {
      if (snapshot.exists) {
        var dispatcherData = snapshot.data() as Map<String, dynamic>;
        _openChat(context, dispatcherId, dispatcherName);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Диспетчер не найден")),
        );
      }
    });
  }



Future<void> _changePassword(BuildContext context, String userId) async {
  TextEditingController currentPasswordController = TextEditingController();
  TextEditingController newPasswordController = TextEditingController();

  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text("Изменить пароль"),
        content: Column(
          mainAxisSize: MainAxisSize.min, // Чтобы диалог не растягивался
          children: [
            TextField(
              controller: currentPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: "Текущий пароль"),
            ),
            TextField(
              controller: newPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: "Новый пароль"),
            ),
          ],
        ),
        actions: [
          TextButton(
            child: const Text("Отмена"),
            onPressed: () => Navigator.pop(context),
          ),
          TextButton(
            child: const Text("Подтвердить"),
            onPressed: () async {
              try {
                var userSnapshot = await FirebaseFirestore.instance
                    .collection('otvetstveniy_za_ekspluataziu')
                    .doc(userId)
                    .get();

                if (userSnapshot.exists) {
                  var userData = userSnapshot.data() as Map<String, dynamic>;
                  String currentPassword = userData['password'] ?? '';

                  if (currentPasswordController.text == currentPassword) {
                    await FirebaseFirestore.instance
                        .collection('otvetstveniy_za_ekspluataziu')
                        .doc(userId)
                        .update({'password': newPasswordController.text});

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Пароль изменён")),
                    );
                    Navigator.pop(context);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Неверный текущий пароль")),
                    );
                  }
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Ошибка: $e")),
                );
              }
            },
          ),
        ],
      );
    },
  );
}
}

class OtvetstveniyPoPodrazdeleniuScreen extends StatelessWidget {
  final String userId;  // ID пользователя, который будет изменять пароль

  const OtvetstveniyPoPodrazdeleniuScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ответственный по подразделению')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('drivers').snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final drivers = snapshot.data!.docs;

          return ListView.builder(
            itemCount: drivers.length,
            itemBuilder: (context, index) {
              var driverData = drivers[index].data() as Map<String, dynamic>;
              String driverId = drivers[index].id;
              String driverName = driverData['name'] ?? 'Неизвестный водитель';
              String departureTime = driverData.containsKey('departureTime') 
                  ? (driverData['departureTime'] as Timestamp).toDate().toString() 
                  : "Не указано";
              String arrivalTime = driverData.containsKey('arrivalTime') 
                  ? (driverData['arrivalTime'] as Timestamp).toDate().toString() 
                  : "Не указано";

              return Card(
                margin: const EdgeInsets.all(8.0),
                child: ListTile(
                  title: Text("Водитель: $driverName"),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Время убытия: $departureTime"),
                      Text("Время прибытия: $arrivalTime"),
                      const SizedBox(height: 10),
                      _buildStatusDropdown(driverId), // Add the dropdown here
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ElevatedButton.icon(
          icon: const Icon(Icons.lock),
          label: const Text("Изменить пароль"),
          onPressed: () => _changePassword(context),
        ),
      ),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    TextEditingController currentPasswordController = TextEditingController();
    TextEditingController newPasswordController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Изменить пароль"),
          content: Column(
            children: [
              TextField(
                controller: currentPasswordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: "Текущий пароль"),
              ),
              TextField(
                controller: newPasswordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: "Новый пароль"),
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text("Отмена"),
              onPressed: () => Navigator.pop(context),
            ),
            TextButton(
              child: const Text("Подтвердить"),
              onPressed: () async {
                try {
                  var userSnapshot = await FirebaseFirestore.instance
                      .collection('rtvetstveniy_po_podrazdeleniu')
                      .doc(userId)
                      .get();

                  if (userSnapshot.exists) {
                    var userData = userSnapshot.data() as Map<String, dynamic>;

                    // Проверка текущего пароля
                    String currentPassword = userData['password'];
                    if (currentPasswordController.text == currentPassword) {
                      // Обновление пароля
                      await FirebaseFirestore.instance
                          .collection('rtvetstveniy_po_podrazdeleniu')
                          .doc(userId)
                          .update({'password': newPasswordController.text});

                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Пароль изменён")));
                      Navigator.pop(context);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Неверный текущий пароль")));
                    }
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Ошибка: $e")));
                }
              },
            ),
          ],
        );
      },
    );
  }

  // Dropdown для статуса убытия и прибытия
  Widget _buildStatusDropdown(String driverId) {
    return StatefulBuilder(
      builder: (context, setState) {
        String? selectedAction;

        return DropdownButton<String>(
          value: selectedAction,
          hint: const Text("Выберите действие"),
          isExpanded: true,
          items: const [
            DropdownMenuItem(value: "departure", child: Text("Подтвердить убытие")),
            DropdownMenuItem(value: "arrival", child: Text("Подтвердить прибытие")),
          ],
          onChanged: (value) {
            setState(() {
              selectedAction = value;
            });

            if (value == "departure") {
              _confirmDeparture(driverId);
            } else if (value == "arrival") {
              _confirmArrival(driverId);
            }
          },
        );
      },
    );
  }

  void _confirmDeparture(String driverId) async {
    await FirebaseFirestore.instance.collection('drivers').doc(driverId).update({
      'departureTime': Timestamp.now(),
    });
    print('Убытие водителя $driverId подтверждено.');
  }

  void _confirmArrival(String driverId) async {
    await FirebaseFirestore.instance.collection('drivers').doc(driverId).update({
      'arrivalTime': Timestamp.now(),
    });
    print('Прибытие водителя $driverId подтверждено.');
  }
}


class ChatScreen extends StatefulWidget {
  final String currentUserId;
  final String otherUserId;
  final String otherUserName;
  final String chatPartnerRole;

  const ChatScreen({
    required this.currentUserId,
    required this.otherUserId,
    required this.otherUserName,
    required this.chatPartnerRole,
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
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
            // Обработка входящих уведомлений
            print('Получено сообщение: ${message.notification?.title}, ${message.notification?.body}');});
    _initChatRoomId();
    _scrollController.addListener(_scrollListener);
  }

  void _initChatRoomId() {
    final List<String> users = [widget.currentUserId, widget.otherUserId];
    users.sort();
    _chatRoomId = users.join('_');
    print('Chat room ID: $_chatRoomId');
  }
  // Future<void> sendStatusChangeNotification(String status) async {
  //       // Получаем токены всех диспетчеров
  //       var dispatcherSnapshot = await FirebaseFirestore.instance.collection('dispatchers').get();
  //       var responsibleSnapshot = await FirebaseFirestore.instance.collection('otvetstveniy_za_ekspluataziu').get();

  //       List<String> tokens = [];

  //       // Проверяем токены диспетчеров
  //       for (var doc in dispatcherSnapshot.docs) {
  //           // Проверяем наличие поля fcmToken
  //           if (doc.data().containsKey('fcmToken')) {
  //               String? token = doc['fcmToken'];
  //               if (token != null && token.isNotEmpty) {
  //                   tokens.add(token);
  //               } else {
  //                   print("fcmToken не найден для диспетчера: ${doc.id}");
  //               }
  //           } else {
  //               print("Поле fcmToken отсутствует для диспетчера: ${doc.id}");
  //           }
  //       }

  //       // Проверяем токены ответственных за эксплуатацию
  //       for (var doc in responsibleSnapshot.docs) {
  //           // Проверяем наличие поля fcmToken
  //           if (doc.data().containsKey('fcmToken')) {
  //               String? token = doc['fcmToken'];
  //               if (token != null && token.isNotEmpty) {
  //                   tokens.add(token);
  //               } else {
  //                   print("fcmToken не найден для ответственного: ${doc.id}");
  //               }
  //           } else {
  //               print("Поле fcmToken отсутствует для ответственного: ${doc.id}");
  //           }
  //       }

  //       // Отправляем уведомления только тем, у кого есть токены
  //       for (var token in tokens) {
  //           await FirebaseFirestore.instance.collection('notifications').add({
  //               'token': token,
  //               'title': 'Изменение статуса водителя',
  //               'body': 'Водитель обновил статус: $status',
  //               'timestamp': FieldValue.serverTimestamp(),
  //           });
  //       }

  //       if (tokens.isEmpty) {
  //           print("Нет доступных токенов для отправки уведомлений.");
  //       }
  //   }

  //   // Пример вызова метода при изменении статуса
  //   void updateDriverStatus(String newStatus) {
  //       // Логика для обновления статуса водителя...
        
  //       // Отправка уведомления
  //       sendStatusChangeNotification(newStatus);
  //   }
  void _scrollListener() {
    if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent) {
      // Do something here when you reach the end of the list
    }
  }
  void _sendCallNotification() async {
  final receiverCollection = await _getReceiverCollection(widget.otherUserId);
  final fcmToken = await _getFcmToken(widget.otherUserId, receiverCollection);

  if (fcmToken != null) {
    try {
      // 1. Загрузка учетных данных сервисного аккаунта
      print('Loading service account credentials...');
      final serviceAccount = jsonDecode(await rootBundle.loadString('assets/google-services.json'));
      print('Service account credentials loaded.');

      // 2. Аутентификация с помощью FCM v1 API
      print('Authenticating with FCM v1 API...');
      auth.ServiceAccountCredentials credentials = auth.ServiceAccountCredentials.fromJson(serviceAccount);
      final scopes = [
        'https://www.googleapis.com/auth/firebase.messaging'
      ]; // необходимый scope
      final client = await auth.clientViaServiceAccount(credentials, scopes);
      final accessToken = client.credentials.accessToken;

      // 3. Подготовка полезной нагрузки уведомления
      final body = {
        "message": {
          "token": fcmToken,
          "notification": {
            "title": "Входящий звонок📞",
            "body": "${widget.otherUserName} звонит вам!☎️",
          },
          "data": {
            "callStatus": "incoming",
            "callerId": widget.currentUserId,
            "callerName": widget.otherUserName,
          },
        },
      };

      // 4. Отправка уведомления
      print('Sending call push notification...');
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


  Future<void> _sendMessage() async {
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

      await FirebaseFirestore.instance
          .collection('chats')
          .doc(_chatRoomId)
          .collection('messages')
          .add(message);

      // Send push notification after successful message sending
      await _sendPushNotification(message);

      _messageController.clear();
      _scrollToBottom();
    } catch (e) {
      print('Error sending message: $e');
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка отправки сообщения: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _sendPushNotification(Map<String, dynamic> message) async {
    // 1. Validate input: Check if necessary data is available
    if (!message.containsKey('receiverId') ||
        !message.containsKey('message') ||
        !message.containsKey('senderId')) {
      print('Error: Incomplete message data for push notification.');
      return;
    }

    String receiverId = message['receiverId'];
    String messageText = message['message'];
    String senderId = message['senderId'];

    String? fcmToken;
    String receiverCollection;

    try {
      // 2. Determine the collection and retrieve FCM token from Firestore
      print('Retrieving collection for receiverId: $receiverId');
      receiverCollection = await _getReceiverCollection(receiverId);
      print('Receiver collection determined: $receiverCollection');

      print('Fetching FCM token for receiverId: $receiverId');
      fcmToken = await _getFcmToken(receiverId, receiverCollection);
      if (fcmToken == null) {
        print('FCM token not found for receiver: $receiverId in collection $receiverCollection');
        return;
      }
      print('FCM token retrieved successfully: $fcmToken');
    } catch (e) {
      print('Error retrieving FCM token: $e');
      return;
    }

    // 3. Load service account credentials
    print('Loading service account credentials...');
    final serviceAccount = jsonDecode(await rootBundle.loadString('assets/google-services.json'));
    print('Service account credentials loaded.');

    // 4. Authenticate with the FCM v1 API
    try {
      print('Authenticating with FCM v1 API...');
      auth.ServiceAccountCredentials credentials = auth.ServiceAccountCredentials.fromJson(serviceAccount);
            final scopes = [
        'https://www.googleapis.com/auth/firebase.messaging'
      ]; // required scope
      final client = await auth.clientViaServiceAccount(credentials, scopes);
      final accessToken = client.credentials.accessToken;

      // 5. Prepare notification payload
      print('Retrieving sender name for senderId: $senderId');
      final senderName = await _getSenderName(senderId);
      print('Sender name retrieved: $senderName');

      final body = {
        "message": {
          "token": fcmToken,
          "notification": {
            "title": "Новое сообщение от $senderName",
            "body": messageText,
          },
          "data": {
            "senderId": senderId,
            "receiverId": receiverId,
          }
        }
      };

      // 6. Send the notification
      print('Sending push notification...');
      try {
        final response = await http.post(
          Uri.parse("https://fcm.googleapis.com/v1/projects/pril123/messages:send"),
          headers: {
            "Content-Type": "application/json",
            "Authorization": "Bearer ${accessToken.data}",
          },
          body: jsonEncode(body),
        );

        client.close(); // Close the HTTP client

        if (response.statusCode == 200) {
          print("Push notification sent successfully!");
        } else {
          print("Error sending push notification: Status Code ${response.statusCode}, Body: ${response.body}");
        }
      } catch (e) {
        print("Error sending push notification (HTTP request): $e");
      }
    } catch (e) {
      print("Error authenticating with FCM v1 API: $e");
    }
  }

  Future<String?> _getFcmToken(String userId, String receiverCollection) async {
    try {
      print('Fetching FCM token for userId: $userId from collection: $receiverCollection');
      final snapshot = await FirebaseFirestore.instance
          .collection(receiverCollection)
          .doc(userId)
          .get();

      if (snapshot.exists && snapshot.data() != null) {
        final fcmToken = snapshot.data()?['fcmToken'] as String?;
        print('FCM token found: $fcmToken');
        return fcmToken;
      } else {
        print('Document does not exist for userId: $userId in collection $receiverCollection');
        return null;
      }
    } catch (e) {
      print("Error fetching FCM token: $e");
      return null;
    }
  }

  Future<String> _getReceiverCollection(String receiverId) async {
    const List<String> collections = [
      'drivers',
      'dispatchers',
      'otvetstveniy_za_ekspluataziu',
      'rtvetstveniy_po_podrazdeleniu',
    ];

    for (final String collection in collections) {
      try {
        print('Searching for user $receiverId in collection: $collection');
        final userDoc = await FirebaseFirestore.instance
            .collection(collection)
            .doc(receiverId)
            .get();

        if (userDoc.exists) {
          print('User  $receiverId found in collection: $collection');
          return collection;
        } else {
          print('User  $receiverId not found in collection: $collection');
        }
      } catch (e) {
        print('Error searching for user $receiverId in collection $collection: $e');
      }
    }

    print('User  $receiverId not found in any of the user collections.');
    throw Exception('User  not found in any known collection');
  }

  Future<String> _getSenderName(String senderId) async {
    List<String> collections = [
      'drivers',
      'dispatchers',
      'otvetstveniy_za_ekspluataziu',
      'rtvetstveniy_po_podrazdeleniu'
    ];

    for (String collection in collections) {
      try {
        print('Searching for senderId $senderId in collection: $collection');
        var snapshot = await FirebaseFirestore.instance.collection(collection).doc(senderId).get();

        if (snapshot.exists) {
          String? name = snapshot.data()?['name'];
          if (name != null && name.isNotEmpty) {
            print('Sender name found: $name');
            return name;
          }
        } else {
          print('senderId $senderId not found in collection: $collection');
        }
      } catch (e) {
        print("Error searching for senderId $senderId in collection $collection: $e");
      }
    }

    print("senderId $senderId не найден ни в одной коллекции.");
    return "Неизвестный"; // Default name if user not found
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
              _sendCallNotification(); // Отправляем уведомление о звонке
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
		            IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


