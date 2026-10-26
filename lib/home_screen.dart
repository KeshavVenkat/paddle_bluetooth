import 'package:battery_plus/battery_plus.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:permission_handler/permission_handler.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Battery _battery = Battery();
  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  final TextEditingController _nameController =
      TextEditingController(text: 'realme narzo 50A Prime');
  final TextEditingController _messageController =
      TextEditingController(text: '');

  bool _isAdvertising = false;
  bool _isConnected = false;
  bool _isSubscribed = false;
  final List<String> _logs = [];

  String? _player1;
  String? _player2;
  String? _pointsToWin;
  String? _winBy;

  @override
  void initState() {
    super.initState();
    _initBle();
  }

  void _log(String msg) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[${DateTime.now().toIso8601String().substring(11, 19)}] $msg');
      if (_logs.length > 50) _logs.removeLast();
    });
  }

  
  Future<void> _sendBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      _log('Sending phone battery: $level%');
      await _sendValue('BATTERY: $level%');
      debugPrint('🔋 [BLE BATTERY SENT]: $level%');
    } catch (e) {
      _log('Battery error: $e');
      debugPrint('❌ [BATTERY ERROR]: $e');
    }
  }

  Future<void> _initBle() async {
    _peripheral.onPeripheralStateChanged?.listen((state) {
      if (!mounted) return;
      setState(() {
        _isAdvertising = state == PeripheralState.advertising;
        _isConnected = state == PeripheralState.connected;
      });
      _log('BLE State: $state');
      debugPrint('📡 [BLE PERIPHERAL STATE]: $state');
    });

    _peripheral.onSubscriptionChanged.listen((subscribed) async {
      if (!mounted) return;
      setState(() => _isSubscribed = subscribed);
      _log(subscribed ? 'Central subscribed to notifications!' : 'Central unsubscribed');
      debugPrint('📡 [BLE PERIPHERAL] Subscription changed: $subscribed');
      if (subscribed) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _sendBatteryLevel();
      }
    });

    _peripheral.onDataReceived.listen((data) async {
      final text = utf8.decode(data, allowMalformed: true);
      _log('Received from App: $text');
      debugPrint('📥 [BLE PERIPHERAL RECEIVED]: "$text" | raw bytes: $data');
      if (text.toUpperCase().contains('BATTERY')) {
        await _sendBatteryLevel();
      }

      try {
        final trimmed = text.trim();
        if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
          final map = jsonDecode(trimmed);
          if (map is Map) {
            setState(() {
              if (map.containsKey('player1')) _player1 = map['player1']?.toString();
              if (map.containsKey('player2')) _player2 = map['player2']?.toString();
              if (map.containsKey('pointsToWin')) _pointsToWin = map['pointsToWin']?.toString();
              if (map.containsKey('winBy')) _winBy = map['winBy']?.toString();
            });
            _log('Game: ${_player1 ?? "-"} vs ${_player2 ?? "-"} (Pts: ${_pointsToWin ?? "-"}, WinBy: ${_winBy ?? "-"})');
          }
        }
      } catch (e) {
        debugPrint('Error parsing config: $e');
      }
    });
  }

  Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
        Permission.location,
      ].request();

      final canAdvertise = statuses[Permission.bluetoothAdvertise]?.isGranted ?? false;
      final canConnect = statuses[Permission.bluetoothConnect]?.isGranted ?? false;

      if (!canAdvertise && !canConnect && statuses[Permission.location]?.isGranted != true) {
        _log('Error: Bluetooth permissions denied.');
        debugPrint('❌ [BLE PERIPHERAL] Permissions denied.');
        return false;
      }
    } else if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      if (!status.isGranted) {
        _log('Error: iOS Bluetooth permission denied.');
        debugPrint('❌ [BLE PERIPHERAL] iOS Bluetooth permission denied.');
        return false;
      }
    }
    return true;
  }

  Future<void> _toggleAdvertising() async {
    if (_isAdvertising) {
      await _peripheral.stop();
      setState(() {
        _isAdvertising = false;
        _isConnected = false;
        _isSubscribed = false;
      });
      _log('Stopped advertising.');
      debugPrint('🛑 [BLE PERIPHERAL] Stopped advertising.');
      return;
    }

    final granted = await _requestPermissions();
    if (!granted) return;

    final deviceName = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : 'realme narzo 50A Prime';

    final advertiseData = AdvertiseDataCore(
      localName: deviceName,
      serviceUuid: nordicUartServiceUuid,
      includeTxPowerLevel: true,
    );

    final androidSettings = AndroidAdvertiseSettings(
      advertiseSettings: const AdvertiseSettings(
        connectable: true,
        advertiseMode: AdvertiseMode.advertiseModeLowLatency,
        txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
      ),
      advertiseResponseData: AndroidAdvertiseData(
        includeDeviceName: true,
        localName: deviceName,
      ),
    );

    try {
      await _peripheral.start(
        advertiseData: advertiseData,
        androidSettings: androidSettings,
        gattServer: const GattServerSettings(
          serviceUuid: nordicUartServiceUuid,
        ),
      );
      setState(() => _isAdvertising = true);
      _log('Broadcasting as "$deviceName" on air...');
      debugPrint('🟢 [BLE PERIPHERAL] Started advertising as "$deviceName" (connectable: true)');
    } catch (e, stack) {
      _log('Start advertise error: $e');
      debugPrint('🔴 [BLE PERIPHERAL START ERROR]: $e\n$stack');
    }
  }

  Future<void> _sendValue(String value) async {
    if (!_isAdvertising && !_isConnected) {
      _log('Please start advertising first.');
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode(value));
    debugPrint('📤 [BLE SENDING from paddle_bluetooth]: "$value" (${bytes.length} bytes)');
    try {
      await _peripheral.sendData(bytes);
      _log('Sent: "$value"');
      debugPrint('✅ [BLE DATA SENT successfully]: "$value"');
    } catch (e) {
      _log('Error sending: $e');
      debugPrint('❌ [BLE SEND ERROR]: $e');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _isSubscribed
        ? Colors.teal
        : _isConnected
            ? Colors.blue
            : _isAdvertising
                ? Colors.green
                : Colors.grey;

    final statusText = _isSubscribed
        ? 'Connected & Subscribed (Ready to Send)'
        : _isConnected
            ? 'Connected (Awaiting Subscription)'
            : _isAdvertising
                ? 'Advertising on Air (Connectable)'
                : 'Idle (Not Advertising)';

    return Scaffold(
      appBar: AppBar(
        title: const Text('PaddlePost Sender'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 3,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.bluetooth_audio, size: 40, color: statusColor),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: statusColor,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Name: ${_nameController.text}',
                            style: const TextStyle(fontSize: 13, color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),



            // Start/Stop button
            ElevatedButton.icon(
              onPressed: _toggleAdvertising,
              style: ElevatedButton.styleFrom(
                backgroundColor: _isAdvertising ? Colors.redAccent : Colors.teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: Icon(_isAdvertising ? Icons.stop : Icons.sensors),
              label: Text(
                _isAdvertising ? 'Stop Advertising' : 'Start Advertising (Broadcast)',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 32),

            // Quick Data Presets
            const Text(
              'Send Test Values to App',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _player1 != null
                        ? () => _sendValue('Score: $_player1 +1')
                        : null,
                    child: Text(_player1 ?? '-'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _player2 != null
                        ? () => _sendValue('Score: $_player2 +1')
                        : null,
                    child: Text(_player2 ?? '-'),
                  ),
                ),
              ],
            ),
            gameData(
                key: 'Points to win :',
                value: _pointsToWin ?? '-'),
            gameData(
                key: 'win by:',
                value: _winBy ?? '-'),
            gameData(
                key: 'To return',
                value: '2s'),
            const SizedBox(height: 8),

            // Custom Message
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: () {
                    if (_messageController.text.isNotEmpty) {
                      _sendValue(_messageController.text);
                    }
                  },
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget gameData({required String key, required String value}){
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        Text(key),
        Text(value)
      ],
    );
  }
}
