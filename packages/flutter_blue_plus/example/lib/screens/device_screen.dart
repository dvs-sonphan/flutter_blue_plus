import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/snackbar.dart';
import '../utils/extra.dart';
import 'login_screen.dart';

class DeviceScreen extends StatefulWidget {
  final BluetoothDevice device;
  final String? username;
  final String? password;

  const DeviceScreen({
    super.key,
    required this.device,
    this.username,
    this.password,
  });

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  int? _rssi;
  double? _distance;
  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  bool _isConnecting = false;
  bool _isDisconnecting = false;
  int? _remainingHours;
  int? _remainingDays;
  int? _remainingMinutes;
  DateTime? _sessionTime;
  Timer? _updateTimer;
  Timer? _rssiUpdateTimer;
  bool _hasSentSessionCommand = false;
  bool _hasAutoLoggedOut = false;
  bool _isAutoModeEnabled = false;
  String? _lastAutoCommand;
  List<int> _rssiHistory = [];
  static const int _rssiWindowSize = 5;
  int? _lastNotificationTime;

  late StreamSubscription<BluetoothConnectionState> _connectionStateSubscription;
  late StreamSubscription<bool> _isConnectingSubscription;
  late StreamSubscription<bool> _isDisconnectingSubscription;
  StreamSubscription<List<int>>? _characteristicSubscription;

  static const String SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb";
  static const String CONTROL_CHARACTERISTIC_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb";
  static const String _KEY_SAVED_BLE_DEVICE_NAME = 'savedBleDeviceName';

  bool _isLockPressed = false;
  bool _isUnlockPressed = false;

  BluetoothCharacteristic? _controlCharacteristic;

  // GlobalKey for ScaffoldMessenger
  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  // Check if session has expired or no session data
  bool get _isSessionExpired {
    if (_sessionTime == null) return true; // No session data
    return _sessionTime!.isBefore(DateTime.now()) ||
        (_remainingHours == null && _remainingMinutes == null && _remainingDays == null);
  }

  @override
  void initState() {
    super.initState();
    FlutterBluePlus.setLogLevel(LogLevel.error);

    _connectionStateSubscription = widget.device.connectionState.listen((state) async {
      _connectionState = state;
      if (state == BluetoothConnectionState.connected) {
        await _findControlCharacteristic();
        _saveDeviceName(widget.device.advName);
        if (!_hasSentSessionCommand && _controlCharacteristic != null) {
          await _sendSessionCommand();
          _hasSentSessionCommand = true;
        }
        _startUpdateTimer();
        _startRssiUpdateTimer();
      } else {
        _stopUpdateTimer();
        _stopRssiUpdateTimer();
        setState(() {
          _remainingHours = null;
          _remainingDays = null;
          _remainingMinutes = null;
          _sessionTime = null;
          _distance = null;
          _hasSentSessionCommand = false;
          _lastAutoCommand = null;
        });
      }
      if (state == BluetoothConnectionState.connected && _rssi == null) {
        try {
          _rssi = await widget.device.readRssi();
          _updateDistance();
        } catch (e) {
          print("Lỗi đọc RSSI: $e");
        }
      }
      if (mounted) {
        setState(() {});
      }
    });

    _isConnectingSubscription = widget.device.isConnecting.listen((value) {
      _isConnecting = value;
      if (mounted) {
        setState(() {});
      }
    });

    _isDisconnectingSubscription = widget.device.isDisconnecting.listen((value) {
      _isDisconnecting = value;
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    _isConnectingSubscription.cancel();
    _isDisconnectingSubscription.cancel();
    _characteristicSubscription?.cancel();
    _stopUpdateTimer();
    _stopRssiUpdateTimer();
    super.dispose();
  }

  bool get isConnected {
    return _connectionState == BluetoothConnectionState.connected;
  }

  // Method to show SnackBar
  void _showSnackBar({
    required String message,
    required Color backgroundColor,
    Duration duration = const Duration(seconds: 3),
  }) {
    if (mounted && _scaffoldMessengerKey.currentState != null) {
      _scaffoldMessengerKey.currentState!.removeCurrentSnackBar();
      _scaffoldMessengerKey.currentState!.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: backgroundColor,
          duration: duration,
        ),
      );
    } else {
      print("Không thể hiển thị SnackBar: $message (mounted: $mounted)");
    }
  }

  Future<void> _saveDeviceName(String deviceName) async {
    if (deviceName.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_KEY_SAVED_BLE_DEVICE_NAME, deviceName);
      print("[LoginScreen] Lưu tên thiết bị để kết nối tự động: $deviceName");
    }
  }

  Future<void> _sendSessionCommand() async {
    if (_controlCharacteristic == null || !isConnected) {
      _showSnackBar(
        message: "Không thể gửi lệnh SESSION: Không kết nối hoặc không tìm thấy đặc tính",
        backgroundColor: Colors.red,
      );
      return;
    }
    try {
      final sessionCommand = utf8.encode("SESSION#");
      await _controlCharacteristic!.write(sessionCommand, withoutResponse: false);
      print("Đã gửi lệnh SESSION#");

      if (_controlCharacteristic!.properties.notify || _controlCharacteristic!.properties.read) {
        await _controlCharacteristic!.setNotifyValue(true);
        _characteristicSubscription = _controlCharacteristic!.value.listen((value) {
          final response = utf8.decode(value);
          print("Nhận phản hồi: $response");
          if (response.startsWith("TSession:")) {
            _processSessionTime(response);
          }
        });
      }
    } catch (e, backtrace) {
      _showSnackBar(
        message: prettyException("Lỗi gửi lệnh SESSION:", e),
        backgroundColor: Colors.red,
      );
      print(e);
      print("backtrace: $backtrace");
    }
  }

  void _processSessionTime(String response) {
    try {
      final epochStr = response.replaceFirst("TSession:", "").trim();
      final epochSeconds = int.parse(epochStr);
      final sessionTime = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
      setState(() {
        _sessionTime = sessionTime;
        _updateRemainingHours();
      });
    } catch (e) {
      print("Lỗi xử lý Time_Session: $e");
      _showSnackBar(
        message: "Hết Thời Gian Chuyến Xe",
        backgroundColor: Colors.red,
      );
    }
  }

  void _updateRemainingHours() {
    if (_sessionTime == null) return;
    final now = DateTime.now();
    final duration = _sessionTime!.difference(now);
    final totalMinutes = duration.inMinutes.abs();
    final totalSeconds = duration.inSeconds.abs();

    if (totalMinutes <= 30 && totalSeconds > 0) {
      final notificationMinute = (totalMinutes ~/ 10) * 10;
      if (_lastNotificationTime == null || _lastNotificationTime != notificationMinute) {
        _lastNotificationTime = notificationMinute;
        _showSnackBar(
          message:
              "Thời gian chuyến gần hết. Để tiếp tục chuyến xe xin quý khách liên hệ 093.771.8811 gia hạn thêm thời gian. Cảm ơn quý khách.",
          backgroundColor: Colors.red,
          duration: Duration(minutes: 1),
        );
        print("Hiển thị thông báo tại $notificationMinute phút còn lại");
      }
    } else {
      _lastNotificationTime = null;
    }

    setState(() {
      if (totalSeconds <= 0) {
        _remainingHours = null;
        _remainingDays = null;
        _remainingMinutes = null;
        _stopUpdateTimer();
        if (!_hasAutoLoggedOut && mounted) {
          _hasAutoLoggedOut = true;
          print("Phiên hết hạn, kích hoạt tự động đăng xuất");
          onLogoutPressed();
        }
      } else if (totalMinutes < 2880) {
        _remainingHours = totalMinutes ~/ 60;
        _remainingMinutes = totalMinutes % 60;
        _remainingDays = null;
      } else {
        final days = totalMinutes ~/ 1440;
        final remainingMinutesAfterDays = totalMinutes % 1440;
        final remainingHours = remainingMinutesAfterDays ~/ 60;
        final remainingMinutes = remainingMinutesAfterDays % 60;
        _remainingDays = days;
        _remainingHours = remainingHours;
        _remainingMinutes = remainingMinutes;
      }
    });
  }

  void _updateDistance() {
    if (_rssi == null) return;

    _rssiHistory.add(_rssi!);
    if (_rssiHistory.length > _rssiWindowSize) {
      _rssiHistory.removeAt(0);
    }

    final averageRssi = _rssiHistory.reduce((a, b) => a + b) / _rssiHistory.length;

    const txPower = -60;
    const n = 2.5;
    final distance = pow(10, (txPower - averageRssi) / (10 * n)).toDouble();

    setState(() {
      _distance = double.parse(distance.toStringAsFixed(2));
      if (_isAutoModeEnabled && isConnected && _controlCharacteristic != null) {
        _handleAutoModeCommand();
      }
    });
  }

  void _handleAutoModeCommand() async {
    if (_distance == null || _isSessionExpired) {
      if (_isSessionExpired) {
        print("Auto Mode: Không gửi lệnh vì thời gian chuyến xe không hợp lệ");
      }
      return;
    }

    if (_distance! < 5 && _lastAutoCommand != "UNLOCK") {
      final username = "dvs25";
      final password = widget.password ?? "default_pass";
      final unlockCommandString = "$username,$password,UNLOCK#";
      final unlockCommandBytes = utf8.encode(unlockCommandString);
      await _writeControlCommand(unlockCommandBytes, "UNLOCK");
      _lastAutoCommand = "UNLOCK";
      print("Auto Mode: Đã gửi lệnh UNLOCK ở khoảng cách $_distance mét");
    } else if (_distance! > 5 && _lastAutoCommand != "LOCK") {
      final username = "dvs25";
      final password = widget.password ?? "default_pass";
      final lockCommandString = "$username,$password,LOCK#";
      final lockCommandBytes = utf8.encode(lockCommandString);
      await _writeControlCommand(lockCommandBytes, "LOCK");
      _lastAutoCommand = "LOCK";
      print("Auto Mode: Đã gửi lệnh LOCK ở khoảng cách $_distance mét");
    }
  }

  void _startRssiUpdateTimer() {
    _stopRssiUpdateTimer();
    _rssiUpdateTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (isConnected && mounted) {
        try {
          _rssi = await widget.device.readRssi();
          _updateDistance();
          setState(() {});
        } catch (e) {
          print("Lỗi cập nhật RSSI: $e");
        }
      }
    });
  }

  void _stopRssiUpdateTimer() {
    _rssiUpdateTimer?.cancel();
    _rssiUpdateTimer = null;
    _rssiHistory.clear();
  }

  void _startUpdateTimer() {
    _stopUpdateTimer();
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        _updateRemainingHours();
      }
    });
  }

  void _stopUpdateTimer() {
    _updateTimer?.cancel();
    _updateTimer = null;
    _lastNotificationTime = null;
  }

  Future<void> onConnectPressed() async {
    try {
      await widget.device.connect(timeout: Duration(seconds: 15));
      _showSnackBar(
        message: "Kết nối: Thành công",
        backgroundColor: Colors.green,
      );
    } catch (e) {
      if (e is FlutterBluePlusException && e.code == FbpErrorCode.connectionCanceled) {
        // Ignore user-canceled connections
      } else {
        _showSnackBar(
          message: prettyException("Lỗi kết nối:", e),
          backgroundColor: Colors.red,
        );
        print(e);
      }
    }
  }

  Future<void> onCancelPressed() async {
    try {
      await widget.device.disconnect(queue: false);
      _showSnackBar(
        message: "Hủy: Thành công",
        backgroundColor: Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        message: prettyException("Lỗi hủy:", e),
        backgroundColor: Colors.red,
      );
      print(e);
    }
  }

  Future<void> onDisconnectPressed() async {
    try {
      await widget.device.disconnect();
      _showSnackBar(
        message: "Ngắt kết nối: Thành công",
        backgroundColor: Colors.green,
      );
    } catch (e) {
      _showSnackBar(
        message: prettyException("Lỗi ngắt kết nối:", e),
        backgroundColor: Colors.red,
      );
      print(e);
    }
  }

  Future<void> onLogoutPressed() async {
    print("Nhấn đăng xuất, bắt đầu quá trình đăng xuất");
    try {
      print("Ngắt kết nối thiết bị: ${widget.device.remoteId}");
      await widget.device.disconnect();
      print("Ngắt kết nối thiết bị thành công");

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_KEY_SAVED_BLE_DEVICE_NAME);
      print("Đã xóa tên thiết bị đã lưu từ SharedPreferences");

      try {
        await FlutterBluePlus.stopScan();
        print("Đã dừng quét Bluetooth");
      } catch (e) {
        print("Lỗi dừng quét: $e");
      }

      if (mounted) {
        print("Chuyển đến LoginScreen");
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const LoginScreen()),
          (route) => false,
        );
        print("Chuyển đến LoginScreen thành công");
        _showSnackBar(
          message: "Đăng xuất thành công",
          backgroundColor: Colors.green,
        );
      } else {
        print("Widget không được gắn, bỏ qua điều hướng");
      }
    } catch (e, backtrace) {
      print("Lỗi đăng xuất: $e");
      print("Backtrace: $backtrace");
      _showSnackBar(
        message: prettyException("Lỗi đăng xuất:", e),
        backgroundColor: Colors.red,
      );
    }
  }

  Future<void> _findControlCharacteristic() async {
    _controlCharacteristic = null;

    try {
      List<BluetoothService> services = await widget.device.discoverServices();
      print("Dịch vụ tìm thấy: ${services.map((s) => s.uuid.toString()).toList()}");

      for (var service in services) {
        if (service.uuid == Guid(SERVICE_UUID)) {
          print("Tìm thấy dịch vụ: ${service.uuid.toString()}");
          for (var characteristic in service.characteristics) {
            print("Tìm thấy đặc tính: ${characteristic.uuid.toString()}");
            if (characteristic.uuid == Guid(CONTROL_CHARACTERISTIC_UUID)) {
              _controlCharacteristic = characteristic;
              print("Tìm thấy đặc tính điều khiển: ${characteristic.uuid}");
              break;
            }
          }
        }
        if (_controlCharacteristic != null) break;
      }
      if (_controlCharacteristic == null) {
        print(
            "Không tìm thấy đặc tính điều khiển. UUID dịch vụ mong đợi: $SERVICE_UUID, UUID đặc tính mong đợi: $CONTROL_CHARACTERISTIC_UUID");
      }
    } catch (e) {
      print("Lỗi khám phá dịch vụ: $e");
    }
  }

  Future<void> _writeControlCommand(List<int> command, String commandType) async {
    if (_controlCharacteristic == null) {
      _showSnackBar(
        message: "Không tìm thấy đặc tính điều khiển!",
        backgroundColor: Colors.red,
      );
      return;
    }
    if (!isConnected) {
      _showSnackBar(
        message: "Thiết bị đã ngắt kết nối!",
        backgroundColor: Colors.red,
      );
      return;
    }
    try {
      await _controlCharacteristic!.write(command, withoutResponse: false);
      _showSnackBar(
        message: commandType == "LOCK" ? "Khóa xe" : "Mở khóa xe",
        backgroundColor: Colors.green,
      );
    } catch (e, backtrace) {
      _showSnackBar(
        message: prettyException("Lỗi ghi lệnh:", e),
        backgroundColor: Colors.red,
      );
      print("Lỗi ghi lệnh: $e");
      print("Backtrace: $backtrace");
    }
  }

  // Reset button state
  void _resetButtonState({required bool isLock}) {
    if (mounted) {
      setState(() {
        if (isLock) {
          _isLockPressed = false;
          print("Đặt lại trạng thái nút Lock: _isLockPressed = $_isLockPressed");
        } else {
          _isUnlockPressed = false;
          print("Đặt lại trạng thái nút Unlock: _isUnlockPressed = $_isUnlockPressed");
        }
      });
    }
  }

  Future<void> onLockPressed() async {
    if (_isSessionExpired) {
      _showSnackBar(
        message: "Không thể khóa xe: Thời gian chuyến xe không hợp lệ",
        backgroundColor: Colors.red,
      );
      return;
    }
    setState(() {
      _isLockPressed = true;
      print("Nhấn nút Lock: _isLockPressed = $_isLockPressed");
    });
    try {
      final username = "dvs25";
      final password = widget.password ?? "default_pass";
      final lockCommandString = "$username,$password,LOCK#";
      final lockCommandBytes = utf8.encode(lockCommandString);
      await _writeControlCommand(lockCommandBytes, "LOCK");
    } finally {
      _resetButtonState(isLock: true);
    }
  }

  Future<void> onUnlockPressed() async {
    if (_isSessionExpired) {
      _showSnackBar(
        message: "Không thể mở khóa xe: Thời gian chuyến xe không hợp lệ",
        backgroundColor: Colors.red,
      );
      return;
    }
    setState(() {
      _isUnlockPressed = true;
      print("Nhấn nút Unlock: _isUnlockPressed = $_isUnlockPressed");
    });
    try {
      final username = "dvs25";
      final password = widget.password ?? "default_pass";
      final unlockCommandString = "$username,$password,UNLOCK#";
      final unlockCommandBytes = utf8.encode(unlockCommandString);
      await _writeControlCommand(unlockCommandBytes, "UNLOCK");
    } finally {
      _resetButtonState(isLock: false);
    }
  }

  Widget buildSpinner(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14.0),
      child: AspectRatio(
        aspectRatio: 1.0,
        child: CircularProgressIndicator(
          backgroundColor: Colors.black12,
          color: Colors.black26,
        ),
      ),
    );
  }

  Widget buildDeviceNameCard(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Biển Số Xe:",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              widget.device.platformName.isNotEmpty ? widget.device.platformName : 'Không xác định',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildRssiTile(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 56,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          isConnected
              ? const Icon(Icons.bluetooth_connected, size: 20)
              : const Icon(Icons.bluetooth_disabled, size: 20),
          Text(
            isConnected && _distance != null ? '${_distance!} m' : '',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget buildConnectButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (_isConnecting || _isDisconnecting)
            const Padding(
              padding: EdgeInsets.only(right: 8.0),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ElevatedButton(
            onPressed: _isConnecting ? onCancelPressed : (isConnected ? onDisconnectPressed : onConnectPressed),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
              shape: CircleBorder(),
              padding: EdgeInsets.zero,
              minimumSize: const Size(35, 35),
              fixedSize: const Size(35, 35),
            ),
            child: Center(
              child: Icon(
                isConnected ? Icons.bluetooth_disabled : Icons.bluetooth,
                size: 20,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 8.0),
          ElevatedButton(
            onPressed: onLogoutPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: CircleBorder(),
              padding: EdgeInsets.zero,
              minimumSize: const Size(35, 35),
              fixedSize: const Size(35, 35),
            ),
            child: Center(
              child: const Icon(
                Icons.logout,
                size: 20,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatRemainingTime() {
    if (_remainingHours != null && _remainingMinutes != null && _remainingDays == null) {
      return "${_remainingHours} giờ và ${_remainingMinutes} phút";
    } else if (_remainingDays != null && _remainingHours != null && _remainingMinutes != null) {
      return "${_remainingDays} ngày, ${_remainingHours} giờ, ${_remainingMinutes} phút";
    } else if (_sessionTime != null && _sessionTime!.isBefore(DateTime.now())) {
      return "Hết thời gian";
    } else {
      return "Chưa nhận được";
    }
  }

  Widget buildRemainingHoursCard(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Thời Gian Chuyến Xe:",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              _formatRemainingTime(),
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildAutoModeToggle(BuildContext context) {
    return Row(
      children: [
        const Text(
          "Auto Mode:",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(width: 8.0),
        Switch(
          value: _isAutoModeEnabled,
          onChanged: _isSessionExpired
              ? null
              : (value) {
                  setState(() {
                    _isAutoModeEnabled = value;
                    if (!_isAutoModeEnabled) {
                      _lastAutoCommand = null;
                    } else if (isConnected && _distance != null) {
                      _handleAutoModeCommand();
                    }
                  });
                  _showSnackBar(
                    message: _isAutoModeEnabled ? "Đã bật Auto Mode" : "Đã tắt Auto Mode",
                    backgroundColor: Colors.green,
                  );
                },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: _scaffoldMessengerKey,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(''),
          actions: [
            buildConnectButton(context),
            const SizedBox(width: 16.0),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  buildRssiTile(context),
                  if (isConnected && _controlCharacteristic != null) buildAutoModeToggle(context),
                  Text(
                    'Trạng thái: ${_connectionState.toString().split('.')[1]}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            buildDeviceNameCard(context),
            if (isConnected && _controlCharacteristic != null) buildRemainingHoursCard(context),
            Expanded(
              child: Center(
                child: isConnected && _controlCharacteristic != null
                    ? Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ElevatedButton(
                              onPressed: _isAutoModeEnabled || _isSessionExpired
                                  ? null
                                  : () async {
                                      await onLockPressed();
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _isLockPressed ? Colors.red : Colors.orange,
                                foregroundColor: Colors.white,
                                shape: const CircleBorder(),
                                padding: const EdgeInsets.all(40.0),
                              ),
                              child: const Icon(
                                Icons.lock,
                                color: Colors.white,
                                size: 45.0,
                              ),
                            ),
                            const SizedBox(height: 30.0),
                            ElevatedButton(
                              onPressed: _isAutoModeEnabled || _isSessionExpired
                                  ? null
                                  : () async {
                                      await onUnlockPressed();
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _isUnlockPressed ? Colors.red : Colors.orange,
                                foregroundColor: Colors.white,
                                shape: const CircleBorder(),
                                padding: const EdgeInsets.all(40.0),
                              ),
                              child: const Icon(
                                Icons.lock_open,
                                color: Colors.white,
                                size: 45.0,
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
