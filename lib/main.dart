import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart'; // 추가
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // 추가
import 'firebase_options.dart'; // Firebase 설정 파일 포함 확인
import 'package:firebase_auth/firebase_auth.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  try {
    await FirebaseAuth.instance.signInAnonymously();
    print("메인 화면: 익명 로그인 성공!");
  } catch (e) {
    print("로그인 에러: $e");
  }

  // 1. 권한 먼저 확실히 요청
  await _requestPermissions();
  
  // 2. 서비스 초기화 및 실행
  await initializeService();

  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: GrandpaTrackerApp()
  ));
}

// 권한 요청 로직 (안드로이드 14 대응)
Future<void> _requestPermissions() async {
  await [
    Permission.location,
    Permission.notification, // 안드로이드 13+ 필수
  ].request();

  if (await Permission.location.isGranted) {
    // '항상 허용'은 설정 화면으로 이동해야 할 수 있습니다.
    await Permission.locationAlways.request();
  }
}

// 서비스 초기화 설정
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  // 안드로이드 14는 알림 채널이 미리 정의되어야 합니다.
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'tracker_service', // ID
    '위치 서비스', // 이름
    description: '실시간 위치 추적을 위한 알림입니다.',
    importance: Importance.low, // 알림 소리 없이 조용히
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'tracker_service', // 위에서 만든 ID와 일치해야 함
      initialNotificationTitle: '위치 공유 중',
      initialNotificationContent: '안전하게 위치를 확인하고 있습니다.',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  
  // 백그라운드 프로세스 전용 Firebase 초기화
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  try {
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
      print("백그라운드: 익명 로그인 성공!");
    }
  } catch (e) {
    print("백그라운드 로그인 에러: $e");
  }
  
  final FirebaseFirestore firestore = FirebaseFirestore.instance;

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsForegroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // 1. 위치 스트림 감시 (30m 이동 시)
  const locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 50,
  );

  Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) {
    _uploadLocation(firestore, position);
    
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "실시간 위치 공유 중",
        content: "마지막 업데이트: ${DateTime.now().hour}시 ${DateTime.now().minute}분",
      );
    }
  });

  // 2. 즉시 조회 명령 리스너
  firestore.collection('commands').doc('request_location').snapshots().listen((snapshot) async {
    if (snapshot.exists) {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _uploadLocation(firestore, position);
    }
  });
}

Future<void> _uploadLocation(FirebaseFirestore firestore, Position position) async {
  final now = DateTime.now();
  final expireAt = now.add(const Duration(hours: 24));

  await firestore.collection('locations').add({
    'latitude': position.latitude,
    'longitude': position.longitude,
    'timestamp': FieldValue.serverTimestamp(),
    'expireAt': Timestamp.fromDate(expireAt),
  });
}

class GrandpaTrackerApp extends StatelessWidget {
  const GrandpaTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.favorite, size: 80, color: Colors.redAccent),
            const SizedBox(height: 20),
            const Text(
              "위치 공유 활성 상태",
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              "현재 위치가 보호자에게 전달되고 있습니다.",
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}