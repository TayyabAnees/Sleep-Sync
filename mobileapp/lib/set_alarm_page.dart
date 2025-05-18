import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SetAlarmPage extends StatefulWidget {
  const SetAlarmPage({super.key});

  @override
  State<SetAlarmPage> createState() => _AlarmSetPageState();
}

class _AlarmSetPageState extends State<SetAlarmPage> {
  final String _mqttBroker = '';
  final String _mqttUsername = '';
  final String _mqttPassword = '';
  final int _mqttPort = 8883;
  final String _clientId = 'flutter_alarm_${DateTime.now().millisecondsSinceEpoch}';
  MqttServerClient? _client;
  Alarm? _alarm;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Schedule MQTT initialization after the frame is built to ensure context is available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeMQTT();
    });
    _loadSavedAlarm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client?.disconnect();
    super.dispose();
  }

  Future<void> _initializeMQTT() async {
    _client = MqttServerClient(_mqttBroker, _clientId);
    _client!.port = _mqttPort;
    _client!.secure = true;
    _client!.logging(on: false);

    final cert = await DefaultAssetBundle.of(context).loadString('assets/emqxsl-ca.crt');
    final securityContext = SecurityContext.defaultContext;
    securityContext.setTrustedCertificatesBytes(utf8.encode(cert));

    _client!.securityContext = securityContext;

    _client!.onDisconnected = () => print('MQTT Disconnected');
    _client!.onConnected = () => print('MQTT Connected');

    try {
      await _client!.connect(_mqttUsername, _mqttPassword);
    } catch (e) {
      print('MQTT Connection failed: $e');
      _client!.disconnect();
    }
  }

  Future<void> _loadSavedAlarm() async {
    final prefs = await SharedPreferences.getInstance();
    final startHour = prefs.getInt('wakeUpStartHour');
    final startMinute = prefs.getInt('wakeUpStartMinute');
    final endHour = prefs.getInt('wakeUpEndHour');
    final endMinute = prefs.getInt('wakeUpEndMinute');

    if (startHour != null && startMinute != null && endHour != null && endMinute != null) {
      final now = DateTime.now();
      final alarmEndTime = DateTime(
        now.year,
        now.month,
        now.day,
        endHour,
        endMinute,
      );

      // Check if the alarm end time has already passed
      if (now.isAfter(alarmEndTime)) {
        await _clearAlarm();
        setState(() {
          _alarm = null;
        });
      } else {
        setState(() {
          _alarm = Alarm(
            wakeUpStart: TimeOfDay(hour: startHour, minute: startMinute),
            wakeUpEnd: TimeOfDay(hour: endHour, minute: endMinute),
          );
        });
        _startTimeCheck();
      }
    }
  }

  Future<void> _saveAlarm(Alarm alarm) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('wakeUpStartHour', alarm.wakeUpStart.hour);
    await prefs.setInt('wakeUpStartMinute', alarm.wakeUpStart.minute);
    await prefs.setInt('wakeUpEndHour', alarm.wakeUpEnd.hour);
    await prefs.setInt('wakeUpEndMinute', alarm.wakeUpEnd.minute);
  }

  Future<void> _clearAlarm() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('wakeUpStartHour');
    await prefs.remove('wakeUpStartMinute');
    await prefs.remove('wakeUpEndHour');
    await prefs.remove('wakeUpEndMinute');
  }

  void _publishAlarm(Alarm alarm) {
    if (_client?.connectionStatus?.state != MqttConnectionState.connected) {
      print('MQTT not connected');
      return;
    }

    final now = DateTime.now();
    final wakeUpStart = DateTime(
        now.year, now.month, now.day, alarm.wakeUpStart.hour, alarm.wakeUpStart.minute);
    final wakeUpEnd = DateTime(
        now.year, now.month, now.day, alarm.wakeUpEnd.hour, alarm.wakeUpEnd.minute);

    final wakeUpStartStr = DateFormat('yyyy-MM-dd_HH:mm').format(wakeUpStart);
    final wakeUpEndStr = DateFormat('yyyy-MM-dd_HH:mm').format(wakeUpEnd);

    final payload = '$wakeUpStartStr,$wakeUpEndStr';

    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);

    _client!.publishMessage('setalarm/', MqttQos.atLeastOnce, builder.payload!);
    print('Published to setAlarm: $payload');
  }

  void _startTimeCheck() {
    _timer?.cancel(); // Cancel any existing timer to avoid duplicates
    _timer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (_alarm == null) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      final alarmTime = DateTime(
        now.year,
        now.month,
        now.day,
        _alarm!.wakeUpEnd.hour,
        _alarm!.wakeUpEnd.minute,
      );

      // Handle case where alarm end time might be on the next day
      final adjustedAlarmTime = alarmTime.isBefore(now) && _alarm!.wakeUpEnd.hour < now.hour
          ? alarmTime.add(const Duration(days: 1))
          : alarmTime;

      if (now.isAfter(adjustedAlarmTime)) {
        setState(() {
          _alarm = null;
        });
        _clearAlarm();
        timer.cancel();
      }
    });
  }

  Future<void> _showAlarmPickerDialog() async {
    if (_alarm != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alarm already set!')),
      );
      return;
    }

    TimeOfDay? wakeUpStart = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF6C63FF),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black,
            ),
            dialogBackgroundColor: Colors.white,
          ),
          child: child!,
        );
      },
      helpText: 'Select Wake-Up Start Time',
    );

    if (wakeUpStart == null) return;

    TimeOfDay? wakeUpEnd = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: (wakeUpStart.hour + 1) % 24, minute: wakeUpStart.minute),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF6C63FF),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black,
            ),
            dialogBackgroundColor: Colors.white,
          ),
          child: child!,
        );
      },
      helpText: 'Select Wake-Up End Time',
    );

    if (wakeUpEnd == null) return;

    final newAlarm = Alarm(
      wakeUpStart: wakeUpStart,
      wakeUpEnd: wakeUpEnd,
    );

    setState(() {
      _alarm = newAlarm;
    });

    await _saveAlarm(newAlarm);
    _publishAlarm(newAlarm);
    _startTimeCheck(); // Start the timer for the new alarm
  }

  void _cancelAlarm() async {
    setState(() {
      _alarm = null;
    });

    _timer?.cancel();
    await _clearAlarm();

    // Publish 0 to topics
    final builder = MqttClientPayloadBuilder();
    builder.addString("0");

    if (_client?.connectionStatus?.state == MqttConnectionState.connected) {
      _client!.publishMessage("wakeUp/", MqttQos.atLeastOnce, builder.payload!);
      _client!.publishMessage("sleeptrackON/", MqttQos.atLeastOnce, builder.payload!);
      print("Cancelled alarm and published 0 to wakeUp/ and sleeptrackON/");
    } else {
      print("MQTT not connected, unable to publish cancel messages.");
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6C63FF), Color(0xFF3F3D56)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(20.0),
                child: Text(
                  'Set Your Alarm',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: _alarm == null
                      ? const Text(
                    'No Alarm Set',
                    style: TextStyle(
                      fontSize: 24,
                      color: Colors.white70,
                    ),
                  )
                      : AlarmCard(alarm: _alarm!),
                ),
              ),
              ElevatedButton(
                onPressed: _cancelAlarm,
                child: const Text('CANCEL')
              ),
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: NeumorphicButton(
                  onPressed: _showAlarmPickerDialog,
                  child: const Icon(Icons.add, size: 30, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Alarm {
  final TimeOfDay wakeUpStart;
  final TimeOfDay wakeUpEnd;

  Alarm({
    required this.wakeUpStart,
    required this.wakeUpEnd,
  });
}

class AlarmCard extends StatelessWidget {
  final Alarm alarm;

  const AlarmCard({super.key, required this.alarm});

  @override
  Widget build(BuildContext context) {
    final start = alarm.wakeUpStart.format(context);
    final end = alarm.wakeUpEnd.format(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 30, vertical: 10),
      color: Colors.white,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Alarm Set',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text('Wake-Up Start: $start', style: const TextStyle(fontSize: 16)),
            Text('Wake-Up End: $end', style: const TextStyle(fontSize: 16)),
          ],
        ),
      ),
    );
  }
}



class NeumorphicButton extends StatelessWidget {
  final VoidCallback onPressed;
  final Widget child;

  const NeumorphicButton({super.key, required this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF6C63FF),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              offset: const Offset(4, 4),
              blurRadius: 8,
            ),
            BoxShadow(
              color: Colors.white.withOpacity(0.1),
              offset: const Offset(-4, -4),
              blurRadius: 8,
            ),
          ],
        ),
        child: Center(child: child),
      ),
    );
  }
}

extension on BorderRadius {
  static BorderRadius overall(double radius) {
    return BorderRadius.all(Radius.circular(radius));
  }
}