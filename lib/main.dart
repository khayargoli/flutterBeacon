import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:beacon_scanner/beacon_scanner.dart';
import 'package:bluetooth_enable_fork/bluetooth_enable_fork.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

DateTime? lastRequestTime;
String beaconUUID = '01020304-0506-0708-090A-0B0C0D0E0F10';
const String apiURL = "https://79fe3f3e21e3476d8b124751b88cfe73.api.mockbin.io/";
const int notificationId = 10001;

final BeaconScanner beaconScanner = BeaconScanner.instance;

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await checkPermissions();
  await initializeService();
  runApp(const MainApp());
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  /// OPTIONAL, using custom notification channel id
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'beacon_poc', // id
    'Beacon scan service', // title
    description: 'This channel is used for important notifications.', // description
    importance: Importance.low, // importance must be at low or higher level
  );

  if (Platform.isIOS || Platform.isAndroid) {
    await flutterLocalNotificationsPlugin.initialize(
      const InitializationSettings(
        iOS: DarwinInitializationSettings(),
        android: AndroidInitializationSettings('ic_launcher'),
      ),
    );
  }

  await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'beacon_poc',
      initialNotificationTitle: 'Beacon Foreground Scan',
      initialNotificationContent: 'Initializing',
      foregroundServiceNotificationId: notificationId,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  if (service is AndroidServiceInstance) {
    if (await service.isForegroundService()) {
      service.setForegroundNotificationInfo(
        title: "Beacon Scan Service",
        content: "Scan service is running.",
      );
    }

    await initBeaconScanner();
    startRangingBeacons(service);
  }
}

checkPermissions() async {
  // Bluetooth permissions
  await Permission.bluetoothScan.request();
  await Permission.bluetoothConnect.request();
  await BluetoothEnable.enableBluetooth;

  // Location permissions
  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    await Geolocator.requestPermission();
  }

  // Notification permissions
  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()!.requestNotificationsPermission();
  }
}

initBeaconScanner() async {
  try {
    await beaconScanner.initialize(false);
  } on PlatformException catch (e) {
    debugPrint('Error: $e');
  }
}

var foundBeacons = [];
startRangingBeacons(ServiceInstance service) {
  final regions = <Region>[];

  if (Platform.isIOS) {
    regions.add(Region(identifier: 'Apple Airlocate', beaconId: IBeaconId(proximityUUID: beaconUUID)));
  } else {
    regions.add(Region(identifier: 'com.beacon', beaconId: IBeaconId(proximityUUID: beaconUUID)));
  }

  beaconScanner.ranging(regions).listen((ScanResult? result) {
    if (result != null && result.beacons.isNotEmpty) {
      // debugPrint('Ranging: ${result.beacons}');

      DateTime now = DateTime.now();

      // Check if lastRequestTime is null (first request) or if it's been at least 1 minute since the last request
      if (lastRequestTime == null || now.difference(lastRequestTime!).inMinutes >= 1) {
        lastRequestTime = now;
        foundBeacons.add({"beacon": result.beacons.first.id.proximityUUID, "time": DateFormat('yyyy-MM-dd – kk:mm').format(now)});
        service.invoke('update', {
          "beacons": foundBeacons,
        });
        makePostRequest(result.beacons.first.id.proximityUUID);
      }
    } else {
      debugPrint('No beacons found');
    }
  });
}

Future<void> makePostRequest(String uuid) async {
  debugPrint('Posting data: $uuid');
  final url = Uri.parse(apiURL);
  final headers = {"Content-Type": "application/json"};
  final jsonBody = json.encode({"message": uuid});

  try {
    final response = await http.post(url, headers: headers, body: jsonBody);

    if (response.statusCode == 200) {
      debugPrint('Response status: ${response.statusCode}');
    } else {
      debugPrint('Request failed with status: ${response.statusCode}.');
    }
  } catch (e) {
    debugPrint('Error making POST request: $e');
  }
}

handlePosition(Position? position) {
  if (position != null) {
    String pos = 'Sending location update: ${position.latitude}, ${position.longitude}';
    BotToast.showText(text: pos);
    makePostRequest(pos);
  }
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with WidgetsBindingObserver {
  final GeolocatorPlatform _geolocatorPlatform = GeolocatorPlatform.instance;
  StreamSubscription<Position>? _positionStreamSubscription;
  final ScrollController _scrollController = ScrollController();
  bool startedLocationUpdates = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    startListeningLocationUpdates();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && !startedLocationUpdates) {
      startListeningLocationUpdates();
    }
  }

  startListeningLocationUpdates() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (serviceEnabled) {
      startedLocationUpdates = true;
      if (_positionStreamSubscription == null) {
        late LocationSettings locationSettings;

        if (defaultTargetPlatform == TargetPlatform.android) {
          locationSettings = AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
              intervalDuration: const Duration(seconds: 60),
              foregroundNotificationConfig:
                  const ForegroundNotificationConfig(notificationText: "Updating location every minute", notificationTitle: "Location Update", enableWakeLock: true, setOngoing: true));
        } else if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS) {
          locationSettings = AppleSettings(
            accuracy: LocationAccuracy.high,
            activityType: ActivityType.automotiveNavigation,
            distanceFilter: 0,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: false,
          );
        } else {
          locationSettings = const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
          );
        }
        final positionStream = _geolocatorPlatform.getPositionStream(locationSettings: locationSettings);
        _positionStreamSubscription = positionStream.handleError((error) {
          startedLocationUpdates = false;
          debugPrint('Error: $error');
          _positionStreamSubscription?.cancel();
          _positionStreamSubscription = null;
        }).listen((position) => handlePosition(position));
      }
    } else {
      showCustomLocationDialog();
      startedLocationUpdates = false;
    }
  }

  void showCustomLocationDialog() {
    BotToast.showCustomNotification(
      toastBuilder: (cancelFunc) {
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 15),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  'Location Service Disabled',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Please enable location services to continue using this feature.',
                  style: TextStyle(fontSize: 16),
                ),
                ButtonBar(
                  children: <Widget>[
                    TextButton(
                      onPressed: () {
                        if (Platform.isAndroid) {
                          Geolocator.openLocationSettings();
                        }
                        cancelFunc(); // Close the custom notification
                      },
                      child: Text((Platform.isAndroid) ? 'Open Settings' : 'OK'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
      align: const Alignment(0, 0), // Center the card
      duration: const Duration(seconds: 5), // How long the notification will be shown
      animationDuration: const Duration(milliseconds: 300), // Animation duration
    );
  }

  @override
  void dispose() {
    if (_positionStreamSubscription != null) {
      _positionStreamSubscription!.cancel();
      _positionStreamSubscription = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      builder: BotToastInit(),
      navigatorObservers: [BotToastNavigatorObserver()],
      home: Scaffold(
          appBar: AppBar(
            title: const Text('Monitoring Beacons'),
          ),
          body: _buildResultsList()),
    );
  }

  Widget _buildResultsList() {
    return Scrollbar(
      controller: _scrollController,
      child: StreamBuilder<Map<String, dynamic>?>(
          stream: FlutterBackgroundService().on('update'),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: CircularProgressIndicator(),
              );
            } else {
              final results = snapshot.data!['beacons'];
              return ListView.builder(
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final item = results[index];
                  return ListTile(
                    title: Text(item['beacon'] ?? 'No message'),
                    subtitle: Text(item['time'] ?? 'No time'),
                  );
                },
              );
            }
          }),
    );
  }
}
