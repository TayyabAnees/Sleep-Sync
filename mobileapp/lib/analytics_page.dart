import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  late Database _database;
  MqttServerClient? _mqttClient;
  final int _mqttPort = 8883;
  String _viewType = 'Weekly';
  final String _broker = '';
  final String _clientId = 'flutter_client_${DateTime.now().millisecondsSinceEpoch}';
  final String _mqttUsername = '';
  final String _mqttPassword = '';
  final String _topic = 'sleepdata/';
  DateTime _selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _initializeDatabase();
    _initializeMqttClient();

  }

  Future<void> _initializeDatabase() async {
    final databasesPath = await getDatabasesPath();
    final path = p.join(databasesPath, 'sleep_data.db');
    _database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sleep_data (
            ax REAL,
            ay REAL,
            az REAL,
            timestamp TEXT PRIMARY KEY,
            sleep_state TEXT,
            window_start TEXT,
            window_end TEXT
          )
        ''');
      },
    );
    setState(() {});
  }

  Future<void> _initializeMqttClient() async {
    _mqttClient = MqttServerClient(_broker, _clientId);
    _mqttClient!.port = _mqttPort;
    _mqttClient!.secure = true;
    _mqttClient!.logging(on: false);

    // Use the context from the widget, now safe to use after initState
    final cert = await DefaultAssetBundle.of(context).loadString('assets/emqxsl-ca.crt');
    final securityContext = SecurityContext.defaultContext;
    securityContext.setTrustedCertificatesBytes(utf8.encode(cert));

    _mqttClient!.securityContext = securityContext;

    _mqttClient!.onDisconnected = () => print('MQTT Disconnected');
    _mqttClient!.onConnected = () {
      print('MQTT Connected');
      _onMqttConnected();
    };

    try {
      await _mqttClient!.connect(_mqttUsername, _mqttPassword);
    } catch (e) {
      print('MQTT Connection failed: $e');
      _mqttClient!.disconnect();
    }
  }

  void _onMqttConnected() {
    _mqttClient!.subscribe(_topic, MqttQos.atLeastOnce);
    _mqttClient!.updates?.listen((List<MqttReceivedMessage<MqttMessage>> c) {
      final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
      final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      final List<dynamic> data = jsonDecode(payload);
      print('Received MQTT payload: $payload');
      _storeMqttData(data);
      setState(() {}); // Refresh UI when new data arrives
    });
  }

  Future<void> _storeMqttData(List<dynamic> data) async {
    final batch = _database.batch();
    for (var item in data) {
      batch.insert('sleep_data', {
        'ax': item['ax'],
        'ay': item['ay'],
        'az': item['az'],
        'timestamp': item['timestamp'],
        'sleep_state': item['sleep_state'],
        'window_start': item['window_start'],
        'window_end': item['window_end'],
      });
    }
    await batch.commit();
  }

  Future<List<Map<String, dynamic>>> _getSleepData(String viewType) async {
    final now = DateTime.now();
    String whereClause;
    DateTime start;

    whereClause = "DATE(timestamp) = '${DateFormat('yyyy-MM-dd').format(_selectedDate)}'";

    return await _database.query(
      'sleep_data',
      where: whereClause,
      orderBy: 'timestamp ASC',
    );
  }

  List<FlSpot> _generateSleepStateSpots(List<Map<String, dynamic>> data) {
    final spots = <FlSpot>[];
    for (var i = 0; i < data.length; i++) {
      double sleepState;
      final state = data[i]['sleep_state'];

      if (state == 'Awake') {
        sleepState = 1.0;
      } else if (state == 'REM') {
        sleepState = 2.0;
      } else if (state == 'Light Sleep') {
        sleepState = 3.0;
      } else if (state == 'Deep Sleep') {
        sleepState = 4.0;
      } else {
        sleepState = 0.0;
      }
      spots.add(FlSpot(i.toDouble(), sleepState));
    }
    return spots;
  }

  List<FlSpot> _generateAccelerometerSpots(List<Map<String, dynamic>> data, String axis) {
    final spots = <FlSpot>[];
    for (var i = 0; i < data.length; i++) {
      spots.add(FlSpot(i.toDouble(), data[i][axis].toDouble()));
    }
    return spots;
  }

  Map<int, String> _getBottomTitles(List<Map<String, dynamic>> data) {
    if (data.isEmpty) return {};

    int len = data.length;
    Map<int, String> titles = {};

    final startTime = DateTime.parse(data.first['timestamp']);
    final endTime = DateTime.parse(data.last['timestamp']);
    final centerTime = DateTime.parse(data[len ~/ 2]['timestamp']);

    titles[0] = DateFormat('HH:mm').format(startTime);
    titles[len ~/ 2] = DateFormat('HH:mm').format(centerTime);
    titles[len - 1] = DateFormat('HH:mm').format(endTime);

    return titles;
  }


  @override
  void dispose() {
    _mqttClient!.disconnect();
    _database.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(15.0),
          child: Text(
            'Sleep Analytics',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6C63FF),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              DateTime? pickedDate = await showDatePicker(
                context: context,
                initialDate: _selectedDate,
                firstDate: DateTime(2020), // Set your desired start date
                lastDate: DateTime(2100),
              );

              if (pickedDate != null && pickedDate != _selectedDate) {
                setState(() {
                  _selectedDate = pickedDate;
                  // Call your function to fetch data for selected date

                });
              }
            },
            child: Text(
              DateFormat('yyyy-MM-dd').format(_selectedDate),
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),

        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _getSleepData(_viewType),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snapshot.data!;
              if (data.isEmpty) {
                return const Center(
                  child: Text(
                    'No sleep data available',
                    style: TextStyle(color: Colors.white70),
                  ),
                );
              }
              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Sleep State',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          height: 200,
                          child: LineChart(
                            LineChartData(
                              gridData: const FlGridData(show: true),
                              borderData: FlBorderData(
                                show: true,
                                border: const Border(
                                  left: BorderSide(color: Color(0xff60A2DC), width: 2),
                                  bottom: BorderSide(color: Color(0xff60A2DC), width: 2),
                                  right: BorderSide(color: Colors.transparent),
                                  top: BorderSide(color: Colors.transparent),
                                ),
                              ),
                              titlesData: FlTitlesData(
                                leftTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    interval: 1,
                                    reservedSize: 50,
                                    getTitlesWidget: (value, meta) {
                                      String text;
                                      switch (value.toInt()) {
                                        case 1:
                                          text = 'Awake';
                                          break;
                                        case 2:
                                          text = 'REM';
                                          break;
                                        case 3:
                                          text = 'Light';
                                          break;
                                        case 4:
                                          text = 'Deep';
                                          break;
                                        default:
                                          return const SizedBox.shrink(); // skip values not in 1–3
                                      }
                                      return Text(
                                        text,
                                        style: const TextStyle(color: Colors.white, fontSize: 12),
                                      );
                                    },
                                  ),
                                ),
                                rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    getTitlesWidget: (value, meta) {
                                      final index = value.toInt();
                                      final titles = _getBottomTitles(data);
                                      if (titles.containsKey(index)) {
                                        return Text(
                                          titles[index]!,
                                          style: const TextStyle(color: Colors.white, fontSize: 10),
                                        );
                                      }
                                      return const SizedBox.shrink();
                                    },
                                    interval: 1,
                                    reservedSize: 35,
                                  ),
                                ),
                              ),
                              lineBarsData: [
                                LineChartBarData(
                                  spots: _generateSleepStateSpots(data),
                                  isCurved: false,
                                  color: Colors.white,
                                  barWidth: 2,
                                  dotData: const FlDotData(show: false),
                                ),
                              ],
                              minY: 0,
                              maxY: 4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Accelerometer Data (Z-axis)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          height: 200,
                          child: LineChart(
                            LineChartData(
                              gridData: const FlGridData(show: true),
                              borderData: FlBorderData(
                                show: true,
                                border: const Border(
                                  left: BorderSide(color: Color(0xff60A2DC), width: 2),
                                  bottom: BorderSide(color: Color(0xff60A2DC), width: 2),
                                  right: BorderSide(color: Colors.transparent),
                                  top: BorderSide(color: Colors.transparent),
                                ),
                              ),
                              titlesData: FlTitlesData(
                                leftTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    interval: 1,
                                    getTitlesWidget: (value, meta) {
                                      String label;
                                      if (value >= 1000) {
                                        label = '${(value / 1000).toStringAsFixed(1)}K';
                                      } else {
                                        label = value.toStringAsFixed(0);
                                      }
                                      return Text(
                                        label,
                                        style: const TextStyle(color: Colors.white, fontSize: 12),
                                      );
                                    },
                                    reservedSize: 40,
                                  ),
                                ),
                                rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    getTitlesWidget: (value, meta) {
                                      final index = value.toInt();
                                      final titles = _getBottomTitles(data);
                                      if (titles.containsKey(index)) {
                                        return Text(
                                          titles[index]!,
                                          style: const TextStyle(color: Colors.white, fontSize: 10),
                                        );
                                      }
                                      return const SizedBox.shrink();
                                    },
                                    interval: 1,
                                    reservedSize: 35,
                                  ),
                                ),
                              ),
                              lineBarsData: [
                                LineChartBarData(
                                  spots: _generateAccelerometerSpots(data, 'az'),
                                  isCurved: false,
                                  color: Colors.white,
                                  barWidth: 2,
                                  dotData: const FlDotData(show: false),
                                ),
                              ],
                              minY: -2,
                              maxY: 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}