
import 'package:flutter/material.dart';
import 'package:sleep_sync/set_alarm_page.dart';
import 'package:flutter/services.dart';

import 'analytics_page.dart';

void main() {
  runApp(const AlarmSetApp());
}

class AlarmSetApp extends StatelessWidget {
  const AlarmSetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sleep Tracker',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      debugShowCheckedModeBanner: false,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  Widget setAlarmPage = const SetAlarmPage();
  Widget analyticsPage = const AnalyticsPage();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
              TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: 'Alarm'),
                  Tab(text: 'Analytics')
                ],
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    setAlarmPage,
                    analyticsPage
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


}



extension on BorderRadius {
  static BorderRadius overall(double radius) {
    return BorderRadius.all(Radius.circular(radius));
  }
}