import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/snackbar.dart';
import '../utils/extra.dart';
import 'login_screen.dart';

// Lớp DeviceScreen là một StatefulWidget, đại diện cho màn hình điều khiển thiết bị BLE
class DeviceScreen extends StatefulWidget {
  final BluetoothDevice device; // Thiết bị Bluetooth được truyền vào
  final String? username; // Tên người dùng (tùy chọn)
  final String? password; // Mật khẩu (tùy chọn)

  const DeviceScreen({
    super.key,
    required this.device,
    this.username,
    this.password,
  });

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

// Trạng thái của DeviceScreen
class _DeviceScreenState extends State<DeviceScreen> {
  int? _rssi; // Giá trị RSSI (cường độ tín hiệu)
  double? _distance; // Khoảng cách tức thời đến thiết bị
  double? _averageDistance; // Khoảng cách trung bình
  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected; // Trạng thái kết nối
  bool _isConnecting = false; // Đang kết nối
  bool _isDisconnecting = false; // Đang ngắt kết nối
  int? _remainingHours; // Số giờ còn lại của phiên
  int? _remainingDays; // Số ngày còn lại của phiên
  int? _remainingMinutes; // Số phút còn lại của phiên
  DateTime? _sessionTime; // Thời gian hết hạn của phiên
  Timer? _updateTimer; // Timer để cập nhật thời gian còn lại
  Timer? _rssiUpdateTimer; // Timer để cập nhật RSSI
  Timer? _reconnectTimer; // Timer để thử kết nối lại
  bool _hasSentSessionCommand = false; // Đã gửi lệnh SESSION chưa
  bool _hasAutoLoggedOut = false; // Đã tự động đăng xuất chưa
  bool _isAutoModeEnabled = false; // Chế độ AUTO có bật không
  String? _lastAutoCommand; // Lệnh AUTO cuối cùng (LOCK hoặc UNLOCK)
  List<int> _rssiHistory = []; // Lịch sử RSSI
  List<double> _distanceHistory = []; // Lịch sử khoảng cách
  static const int _rssiWindowSize = 5; // Kích thước cửa sổ trung bình RSSI
  static const int _distanceWindowSize = 5; // Kích thước cửa sổ trung bình khoảng cách
  int? _lastNotificationTime; // Thời gian thông báo gần nhất
  DateTime? _lastCommandTime; // Thời gian gửi lệnh gần nhất
  static const Duration _minCommandInterval = Duration(seconds: 3); // Khoảng thời gian tối thiểu giữa các lệnh

  bool _isLockPressed = false; // Trạng thái nhấn nút Lock
  bool _isUnlockPressed = false; // Trạng thái nhấn nút Unlock

  late StreamSubscription<BluetoothConnectionState>
      _connectionStateSubscription; // Subscription theo dõi trạng thái kết nối
  late StreamSubscription<bool> _isConnectingSubscription; // Subscription theo dõi trạng thái đang kết nối
  late StreamSubscription<bool> _isDisconnectingSubscription; // Subscription theo dõi trạng thái đang ngắt kết nối
  StreamSubscription<List<int>>? _characteristicSubscription; // Subscription theo dõi giá trị đặc tính

  static const String SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb"; // UUID của dịch vụ BLE
  static const String CONTROL_CHARACTERISTIC_UUID =
      "0000ffe1-0000-1000-8000-00805f9b34fb"; // UUID của đặc tính điều khiển
  static const String _KEY_SAVED_BLE_DEVICE_NAME = 'savedBleDeviceName'; // Key lưu tên thiết bị trong SharedPreferences

  BluetoothCharacteristic? _controlCharacteristic; // Đặc tính điều khiển BLE

  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>(); // Key cho ScaffoldMessenger

  // Kiểm tra xem phiên có hết hạn chưa
  bool get _isSessionExpired {
    if (_sessionTime == null) return true;
    return _sessionTime!.isBefore(DateTime.now()) ||
        (_remainingHours == null && _remainingMinutes == null && _remainingDays == null);
  }

  // Kiểm tra trạng thái kết nối
  bool get isConnected {
    return _connectionState == BluetoothConnectionState.connected;
  }

  @override
  void initState() {
    super.initState();
    FlutterBluePlus.setLogLevel(LogLevel.error); // Thiết lập mức log cho flutter_blue_plus

    // Theo dõi trạng thái kết nối của thiết bị
    _connectionStateSubscription = widget.device.connectionState.listen((state) async {
      _connectionState = state;
      if (state == BluetoothConnectionState.connected) {
        await _findControlCharacteristic(); // Tìm đặc tính điều khiển
        _saveDeviceName(widget.device.advName); // Lưu tên thiết bị
        if (!_hasSentSessionCommand && _controlCharacteristic != null) {
          await _sendSessionCommand(); // Gửi lệnh SESSION
          _hasSentSessionCommand = true;
        }
        _startUpdateTimer(); // Bắt đầu timer cập nhật thời gian
        if (_isAutoModeEnabled) {
          _startRssiUpdateTimer(); // Bắt đầu timer cập nhật RSSI nếu ở chế độ AUTO
        }
        _stopReconnectTimer(); // Dừng timer kết nối lại
      } else if (state == BluetoothConnectionState.disconnected) {
        _stopUpdateTimer(); // Dừng timer cập nhật thời gian
        if (!_isAutoModeEnabled) {
          _stopRssiUpdateTimer(); // Dừng timer RSSI nếu không ở chế độ AUTO
        }
        setState(() {
          _remainingHours = null;
          _remainingDays = null;
          _remainingMinutes = null;
          _sessionTime = null;
          _hasSentSessionCommand = false;
          _lastAutoCommand = null;
        });
        _startReconnectTimer(); // Bắt đầu timer kết nối lại
      }
      if (state == BluetoothConnectionState.connected && _rssi == null) {
        try {
          _rssi = await widget.device.readRssi(); // Đọc RSSI khi kết nối
          _updateDistance(); // Cập nhật khoảng cách
        } catch (e) {
          print("Lỗi đọc RSSI: $e");
        }
      }
      if (mounted) {
        setState(() {}); // Cập nhật giao diện
      }
    });

    // Theo dõi trạng thái đang kết nối
    _isConnectingSubscription = widget.device.isConnecting.listen((value) {
      _isConnecting = value;
      if (mounted) {
        setState(() {});
      }
    });

    // Theo dõi trạng thái đang ngắt kết nối
    _isDisconnectingSubscription = widget.device.isDisconnecting.listen((value) {
      _isDisconnecting = value;
      if (mounted) {
        setState(() {});
      }
    });

    if (_connectionState == BluetoothConnectionState.disconnected) {
      _startReconnectTimer(); // Bắt đầu timer kết nối lại nếu chưa kết nối
    }
  }

  @override
  void dispose() {
    // Hủy tất cả các subscription và timer để tránh rò rỉ bộ nhớ
    _connectionStateSubscription.cancel();
    _isConnectingSubscription.cancel();
    _isDisconnectingSubscription.cancel();
    _characteristicSubscription?.cancel();
    _stopUpdateTimer();
    _stopRssiUpdateTimer();
    _stopReconnectTimer();
    super.dispose();
  }

  // Hiển thị SnackBar với thông báo
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

  // Lưu tên thiết bị vào SharedPreferences
  Future<void> _saveDeviceName(String deviceName) async {
    if (deviceName.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_KEY_SAVED_BLE_DEVICE_NAME, deviceName);
      print("[LoginScreen] Lưu tên thiết bị để kết nối tự động: $deviceName");
    }
  }

  // Gửi lệnh SESSION để lấy thời gian phiên với cơ chế thử lại
  Future<void> _sendSessionCommand({int maxRetries = 3, Duration timeout = const Duration(seconds: 5)}) async {
    if (_controlCharacteristic == null || !isConnected) {
      _showSnackBar(
        message: "Không thể gửi lệnh SESSION: Không kết nối hoặc không tìm thấy đặc tính",
        backgroundColor: Colors.red,
      );
      return;
    }

    int attempt = 0;
    bool receivedValidResponse = false;

    // Hủy subscription trước đó nếu có
    await _characteristicSubscription?.cancel();
    _characteristicSubscription = null;

    while (attempt < maxRetries && !receivedValidResponse && mounted) {
      attempt++;
      print("Thử gửi lệnh SESSION# (lần $attempt/$maxRetries)");

      try {
        // Gửi lệnh SESSION#
        final sessionCommand = utf8.encode("SESSION#");
        await _controlCharacteristic!.write(sessionCommand, withoutResponse: false);
        print("Đã gửi lệnh SESSION#");

        // Thiết lập subscription để nhận phản hồi
        if (_controlCharacteristic!.properties.notify || _controlCharacteristic!.properties.read) {
          await _controlCharacteristic!.setNotifyValue(true);
          Completer<bool> responseCompleter = Completer<bool>();

          _characteristicSubscription = _controlCharacteristic!.value.listen(
            (value) {
              try {
                final response = utf8.decode(value, allowMalformed: true); // Cho phép dữ liệu không hợp lệ
                print("Nhận phản hồi: $response");
                if (response.startsWith("TSession:") && !responseCompleter.isCompleted) {
                  _processSessionTime(response); // Xử lý phản hồi thời gian phiên
                  receivedValidResponse = true;
                  responseCompleter.complete(true);
                } else {
                  print("Phản hồi không phải TSession: $response");
                }
              } catch (e) {
                print("Lỗi giải mã phản hồi: $e");
                // Không hoàn thành Completer ở đây để tiếp tục chờ phản hồi hợp lệ
              }
            },
            onError: (e) {
              print("Lỗi subscription: $e");
              if (!responseCompleter.isCompleted) {
                responseCompleter.complete(false);
              }
            },
          );

          // Chờ phản hồi trong khoảng thời gian timeout
          bool success = await responseCompleter.future.timeout(timeout, onTimeout: () {
            print("Hết thời gian chờ phản hồi TSession ở lần thử $attempt");
            return false;
          });

          // Hủy subscription sau khi hoàn thành hoặc hết thời gian
          await _characteristicSubscription?.cancel();
          _characteristicSubscription = null;

          if (success && receivedValidResponse) {
            print("Nhận được phản hồi TSession hợp lệ");
            break;
          } else if (attempt < maxRetries) {
            print("Không nhận được TSession, thử lại sau 1 giây...");
            await Future.delayed(const Duration(seconds: 1));
          } else {
            _showSnackBar(
              message: "Không nhận được phản hồi TSession sau $maxRetries lần thử",
              backgroundColor: Colors.red,
            );
          }
        } else {
          _showSnackBar(
            message: "Đặc tính không hỗ trợ notify hoặc read",
            backgroundColor: Colors.red,
          );
          break;
        }
      } catch (e, backtrace) {
        print("Lỗi gửi lệnh SESSION (lần $attempt): $e");
        print("Backtrace: $backtrace");
        if (attempt == maxRetries) {
          _showSnackBar(
            message: prettyException("Lỗi gửi lệnh SESSION sau $maxRetries lần thử:", e),
            backgroundColor: Colors.red,
          );
        }
        if (attempt < maxRetries) {
          print("Thử lại sau 1 giây...");
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }

    // Nếu không nhận được phản hồi hợp lệ sau tất cả các lần thử
    if (!receivedValidResponse && mounted) {
      print("Không nhận được TSession sau $maxRetries lần thử, đánh dấu phiên hết hạn");
      setState(() {
        _sessionTime = null;
        _remainingHours = null;
        _remainingDays = null;
        _remainingMinutes = null;
      });
      _showSnackBar(
        message: "Không nhận được thời gian phiên, vui lòng thử lại",
        backgroundColor: Colors.red,
      );
    }
  }

  // Xử lý thời gian phiên từ phản hồi
  void _processSessionTime(String response) {
    try {
      final epochStr = response.replaceFirst("TSession:", "").trim();
      final epochSeconds = int.parse(epochStr);
      final sessionTime = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
      setState(() {
        _sessionTime = sessionTime;
        _updateRemainingHours(); // Cập nhật thời gian còn lại
      });
    } catch (e) {
      print("Lỗi xử lý Time_Session: $e");
      _showSnackBar(
        message: "Hết Thời Gian Chuyến Xe",
        backgroundColor: Colors.red,
      );
    }
  }

  // Cập nhật thời gian còn lại của phiên
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
          duration: const Duration(minutes: 1),
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

  // Cập nhật khoảng cách dựa trên RSSI
  void _updateDistance() {
    if (_rssi == null) return;

    _rssiHistory.add(_rssi!);
    if (_rssiHistory.length > _rssiWindowSize) {
      _rssiHistory.removeAt(0);
    }

    final averageRssi = _rssiHistory.reduce((a, b) => a + b) / _rssiHistory.length;

    const txPower = -60; // Công suất truyền (điều chỉnh theo thiết bị)
    const n = 2.0; // Hệ số môi trường (điều chỉnh theo môi trường)
    final distance = pow(10, (txPower - averageRssi) / (10 * n)).toDouble();

    _distanceHistory.add(distance);
    if (_distanceHistory.length > _distanceWindowSize) {
      _distanceHistory.removeAt(0);
    }

    final averageDistance = _distanceHistory.reduce((a, b) => a + b) / _distanceHistory.length;

    setState(() {
      _distance = double.parse(distance.toStringAsFixed(2));
      _averageDistance = double.parse(averageDistance.toStringAsFixed(2));
      if (_isAutoModeEnabled && isConnected && _controlCharacteristic != null) {
        _handleAutoModeCommand(); // Xử lý lệnh AUTO nếu bật
      }
    });
  }

  // Xử lý lệnh AUTO (khóa/mở khóa dựa trên khoảng cách)
  Future<void> _handleAutoModeCommand() async {
    if (_averageDistance == null || _isSessionExpired) {
      if (_isSessionExpired) {
        print("Auto Mode: Không gửi lệnh vì thời gian chuyến xe không hợp lệ");
      }
      return;
    }

    if (_lastCommandTime != null && DateTime.now().difference(_lastCommandTime!) < _minCommandInterval) {
      print("Auto Mode: Bỏ qua lệnh vì chưa đủ khoảng thời gian tối thiểu");
      return;
    }

    if (_averageDistance! < 5 && _lastAutoCommand != "UNLOCK" && isConnected && _controlCharacteristic != null) {
      final username = "dvs25";
      final password = widget.password ?? "default_pass";
      final unlockCommandString = "$username,$password,UNLOCK#";
      final unlockCommandBytes = utf8.encode(unlockCommandString);
      await _writeControlCommand(unlockCommandBytes, "UNLOCK");
      _lastAutoCommand = "UNLOCK";
      _lastCommandTime = DateTime.now();
      print("Auto Mode: Đã gửi lệnh UNLOCK ở trung bình khoảng cách $_averageDistance mét");
    } else if (_averageDistance! > 5 && _lastAutoCommand != "LOCK" && isConnected && _controlCharacteristic != null) {
      final username = "dvs25";
      final password = widget.password ?? "default_pass";
      final lockCommandString = "$username,$password,LOCK#";
      final lockCommandBytes = utf8.encode(lockCommandString);
      await _writeControlCommand(lockCommandBytes, "LOCK");
      _lastAutoCommand = "LOCK";
      _lastCommandTime = DateTime.now();
      print("Auto Mode: Đã gửi lệnh LOCK ở trung bình khoảng cách $_averageDistance mét");
    }
  }

  // Bắt đầu timer cập nhật RSSI
  void _startRssiUpdateTimer() {
    _stopRssiUpdateTimer();
    _rssiUpdateTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) async {
      if (_isAutoModeEnabled && mounted) {
        if (isConnected) {
          try {
            _rssi = await widget.device.readRssi(); // Đọc RSSI khi kết nối
            _updateDistance(); // Cập nhật khoảng cách
            setState(() {});
          } catch (e) {
            print("Lỗi cập nhật RSSI khi kết nối: $e");
          }
        } else {
          await _autoReconnect(); // Thử kết nối lại khi mất kết nối
        }
      }
    });
  }

  // Dừng timer cập nhật RSSI
  void _stopRssiUpdateTimer() {
    _rssiUpdateTimer?.cancel();
    _rssiUpdateTimer = null;
    _rssiHistory.clear();
    _distanceHistory.clear();
  }

  // Bắt đầu timer cập nhật thời gian
  void _startUpdateTimer() {
    _stopUpdateTimer();
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        _updateRemainingHours();
      }
    });
  }

  // Dừng timer cập nhật thời gian
  void _stopUpdateTimer() {
    _updateTimer?.cancel();
    _updateTimer = null;
    _lastNotificationTime = null;
  }

  // Bắt đầu timer thử kết nối lại
  void _startReconnectTimer() {
    _stopReconnectTimer();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (mounted && _connectionState == BluetoothConnectionState.disconnected) {
        await _autoReconnect();
      }
    });
  }

  // Dừng timer kết nối lại
  void _stopReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // Thử kết nối lại với thiết bị
  Future<void> _autoReconnect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedDeviceName = prefs.getString(_KEY_SAVED_BLE_DEVICE_NAME);
      if (savedDeviceName == null || savedDeviceName.isEmpty) {
        print("Không có tên thiết bị đã lưu để kết nối lại");
        return;
      }

      print("Bắt đầu quét lại thiết bị: $savedDeviceName");
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 2));

      final scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult result in results) {
          if (result.device.advName == savedDeviceName) {
            print("Tìm thấy thiết bị: ${result.device.advName}, kết nối lại...");
            await FlutterBluePlus.stopScan();
            try {
              await result.device.connect(timeout: const Duration(seconds: 15));
              _showSnackBar(
                message: "Kết nối lại: Thành công",
                backgroundColor: Colors.green,
              );
              if (_isAutoModeEnabled) {
                setState(() {
                  _rssi = result.rssi;
                  _updateDistance();
                });
                print("Cập nhật RSSI từ quét sau khi kết nối lại: ${_rssi}, khoảng cách: $_averageDistance mét");
              }
            } catch (e) {
              print("Lỗi kết nối lại: $e");
              _showSnackBar(
                message: prettyException("Lỗi kết nối lại:", e),
                backgroundColor: Colors.red,
              );
            }
            break;
          }
        }
      });

      await Future.delayed(const Duration(seconds: 2));
      await FlutterBluePlus.stopScan();
      scanSubscription.cancel();
    } catch (e) {
      print("Lỗi quét lại: $e");
      _showSnackBar(
        message: prettyException("Lỗi quét lại:", e),
        backgroundColor: Colors.red,
      );
    }
  }

  // Xử lý nút kết nối
  Future<void> onConnectPressed() async {
    try {
      await widget.device.connect(timeout: const Duration(seconds: 15));
      _showSnackBar(
        message: "Kết nối: Thành công",
        backgroundColor: Colors.green,
      );
    } catch (e) {
      if (e is FlutterBluePlusException && e.code == FbpErrorCode.connectionCanceled) {
        // Bỏ qua nếu người dùng hủy kết nối
      } else {
        _showSnackBar(
          message: prettyException("Lỗi kết nối:", e),
          backgroundColor: Colors.red,
        );
        print(e);
      }
    }
  }

  // Xử lý nút hủy
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

  // Xử lý nút ngắt kết nối
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

  // Xử lý nút đăng xuất
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

  // Tìm đặc tính điều khiển BLE
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

  // Ghi lệnh điều khiển (LOCK/UNLOCK)
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
      await _controlCharacteristic!.write(command, withoutResponse: true);
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

  // Xử lý nút khóa
  Future<void> onLockPressed() async {
    if (_isSessionExpired) {
      _showSnackBar(
        message: "Không thể khóa xe: Thời gian chuyến xe không hợp lệ",
        backgroundColor: Colors.red,
      );
      return;
    }
    try {
      final username = "dvs25";
      final password = widget.password ?? "default_pass";
      final lockCommandString = "$username,$password,LOCK#";
      final lockCommandBytes = utf8.encode(lockCommandString);
      await _writeControlCommand(lockCommandBytes, "LOCK");
    } catch (e) {
      print("Lỗi khi khóa xe: $e");
    }
  }

  // Xử lý nút mở khóa
  Future<void> onUnlockPressed() async {
    if (_isSessionExpired) {
      _showSnackBar(
        message: "Không thể mở khóa xe: Thời gian chuyến xe không hợp lệ",
        backgroundColor: Colors.red,
      );
      return;
    }
    try {
      final username = "dvs25";
      final password = widget.password ?? "default_pass";
      final unlockCommandString = "$username,$password,UNLOCK#";
      final unlockCommandBytes = utf8.encode(unlockCommandString);
      await _writeControlCommand(unlockCommandBytes, "UNLOCK");
    } catch (e) {
      print("Lỗi khi mở khóa xe: $e");
    }
  }

  // Widget hiển thị vòng tròn loading
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

  // Widget hiển thị thông tin tên thiết bị
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

  // Widget hiển thị RSSI và khoảng cách
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
            _averageDistance != null ? '${_averageDistance!} m' : '',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // Widget hiển thị nút kết nối/ngắt kết nối/đăng xuất
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
              shape: const CircleBorder(),
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
              shape: const CircleBorder(),
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

  // Định dạng thời gian còn lại
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

  // Widget hiển thị thời gian còn lại
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

  // Widget hiển thị công tắc chế độ AUTO
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
                    if (_isAutoModeEnabled) {
                      _startRssiUpdateTimer();
                    } else {
                      _lastAutoCommand = null;
                      _lastCommandTime = null;
                      if (!isConnected) {
                        _stopRssiUpdateTimer();
                      }
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

  // Xây dựng giao diện chính
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
                            // Nút Lock
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.grey.shade400, // Viền màu xám
                                  width: 6.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 15,
                                    offset: const Offset(5, 5), // Bóng đổ bên ngoài
                                  ),
                                ],
                              ),
                              child: GestureDetector(
                                onTapDown: _isAutoModeEnabled || _isSessionExpired
                                    ? null
                                    : (_) {
                                        setState(() {
                                          _isLockPressed = true;
                                        });
                                      },
                                onTapUp: _isAutoModeEnabled || _isSessionExpired
                                    ? null
                                    : (_) async {
                                        await onLockPressed();
                                        setState(() {
                                          _isLockPressed = false;
                                        });
                                      },
                                onTapCancel: _isAutoModeEnabled || _isSessionExpired
                                    ? null
                                    : () {
                                        setState(() {
                                          _isLockPressed = false;
                                        });
                                      },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200), // Thời gian animation
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: _isAutoModeEnabled || _isSessionExpired
                                          ? [Colors.grey.shade400, Colors.grey.shade600] // Màu xám khi vô hiệu hóa
                                          : _isLockPressed
                                              ? [Colors.red.shade400, Colors.red.shade600] // Màu đỏ khi nhấn
                                              : [
                                                  const Color.fromARGB(255, 250, 158, 0),
                                                  const Color.fromARGB(255, 250, 158, 0)
                                                ], // Gradient xanh lá
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    boxShadow: _isLockPressed
                                        ? [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.1),
                                              blurRadius: 5,
                                              offset: const Offset(2, 2), // Bóng nhỏ hơn khi nhấn
                                            ),
                                            BoxShadow(
                                              color: Colors.white.withOpacity(0.1),
                                              blurRadius: 5,
                                              offset: const Offset(-2, -2),
                                            ),
                                          ]
                                        : [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.3),
                                              blurRadius: 10,
                                              offset: const Offset(4, 4), // Bóng lớn hơn khi không nhấn
                                            ),
                                            BoxShadow(
                                              color: Colors.white.withOpacity(0.2),
                                              blurRadius: 10,
                                              offset: const Offset(-4, -4),
                                            ),
                                          ],
                                  ),
                                  width: 120, // Kích thước nút
                                  height: 120,
                                  child: const Center(
                                    child: Icon(
                                      Icons.lock,
                                      color: Colors.white,
                                      size: 45.0,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 30.0),
                            // Nút Unlock
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.grey.shade400, // Viền màu xám
                                  width: 6.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 15,
                                    offset: const Offset(5, 5), // Bóng đổ bên ngoài
                                  ),
                                ],
                              ),
                              child: GestureDetector(
                                onTapDown: _isAutoModeEnabled || _isSessionExpired
                                    ? null
                                    : (_) {
                                        setState(() {
                                          _isUnlockPressed = true;
                                        });
                                      },
                                onTapUp: _isAutoModeEnabled || _isSessionExpired
                                    ? null
                                    : (_) async {
                                        await onUnlockPressed();
                                        setState(() {
                                          _isUnlockPressed = false;
                                        });
                                      },
                                onTapCancel: _isAutoModeEnabled || _isSessionExpired
                                    ? null
                                    : () {
                                        setState(() {
                                          _isUnlockPressed = false;
                                        });
                                      },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200), // Thời gian animation
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: _isAutoModeEnabled || _isSessionExpired
                                          ? [Colors.grey.shade400, Colors.grey.shade600] // Màu xám khi vô hiệu hóa
                                          : _isUnlockPressed
                                              ? [Colors.red.shade400, Colors.red.shade600] // Màu đỏ khi nhấn
                                              : [
                                                  const Color.fromARGB(255, 250, 158, 0),
                                                  const Color.fromARGB(255, 250, 158, 0)
                                                ], // Gradient xanh lá
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    boxShadow: _isUnlockPressed
                                        ? [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.1),
                                              blurRadius: 5,
                                              offset: const Offset(2, 2), // Bóng nhỏ hơn khi nhấn
                                            ),
                                            BoxShadow(
                                              color: Colors.white.withOpacity(0.1),
                                              blurRadius: 5,
                                              offset: const Offset(-2, -2),
                                            ),
                                          ]
                                        : [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.3),
                                              blurRadius: 10,
                                              offset: const Offset(4, 4), // Bóng lớn hơn khi không nhấn
                                            ),
                                            BoxShadow(
                                              color: Colors.white.withOpacity(0.2),
                                              blurRadius: 10,
                                              offset: const Offset(-4, -4),
                                            ),
                                          ],
                                  ),
                                  width: 120, // Kích thước nút
                                  height: 120,
                                  child: const Center(
                                    child: Icon(
                                      Icons.lock_open,
                                      color: Colors.white,
                                      size: 45.0,
                                    ),
                                  ),
                                ),
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
