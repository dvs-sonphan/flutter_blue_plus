// packages/flutter_blue_plus/example/lib/screens/device_screen.dart

import 'dart:async';
import 'dart:convert'; // Import this for utf8.encode

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Thêm import này cho SharedPreferences

import '../utils/snackbar.dart';
import '../utils/extra.dart';

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
  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  bool _isConnecting = false;
  bool _isDisconnecting = false;

  late StreamSubscription<BluetoothConnectionState> _connectionStateSubscription;
  late StreamSubscription<bool> _isConnectingSubscription;
  late StreamSubscription<bool> _isDisconnectingSubscription;

  // --- BLE Service & Characteristic UUIDs for Lock/Unlock ---
  static const String SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb";
  static const String CONTROL_CHARACTERISTIC_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb";
  // --- End BLE Service & Characteristic UUIDs ---

  BluetoothCharacteristic? _controlCharacteristic;

  // Khóa lưu trữ tên BLE
  static const String _KEY_SAVED_BLE_DEVICE_NAME = 'savedBleDeviceName';

  // Thêm biến trạng thái cho màu của các nút
  bool _isLockPressed = false;
  bool _isUnlockPressed = false;

  @override
  void initState() {
    super.initState();

    _connectionStateSubscription = widget.device.connectionState.listen((state) async {
      _connectionState = state;
      if (state == BluetoothConnectionState.connected) {
        _findControlCharacteristic(); // Vẫn cần tìm characteristic để gửi lệnh
        _saveDeviceName(widget.device.advName); // LƯU TÊN THIẾT BỊ KHI KẾT NỐI THÀNH CÔNG
      }
      if (state == BluetoothConnectionState.connected && _rssi == null) {
        _rssi = await widget.device.readRssi();
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
    super.dispose();
  }

  bool get isConnected {
    return _connectionState == BluetoothConnectionState.connected;
  }

  // Hàm lưu tên thiết bị vào SharedPreferences
  Future<void> _saveDeviceName(String deviceName) async {
    if (deviceName.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_KEY_SAVED_BLE_DEVICE_NAME, deviceName);
      FlutterBluePlus.log("[FBP] Saved device name for auto-connect: $deviceName");
    }
  }

  // Hàm kết nối
  Future onConnectPressed() async {
    try {
      await widget.device.connectAndUpdateStream();
      Snackbar.show(ABC.c, "Connect: Success", success: true);
    } catch (e, backtrace) {
      if (e is FlutterBluePlusException && e.code == FbpErrorCode.connectionCanceled.index) {
        // ignore connections canceled by the user
      } else {
        Snackbar.show(ABC.c, prettyException("Connect Error:", e), success: false);
        print(e);
        print("backtrace: $backtrace");
      }
    }
  }

  // Hàm hủy kết nối đang diễn ra
  Future onCancelPressed() async {
    try {
      await widget.device.disconnectAndUpdateStream(queue: false);
      Snackbar.show(ABC.c, "Cancel: Success", success: true);
    } catch (e, backtrace) {
      Snackbar.show(ABC.c, prettyException("Cancel Error:", e), success: false);
      print("$e");
      print("backtrace: $backtrace");
    }
  }

  // Hàm ngắt kết nối
  Future onDisconnectPressed() async {
    try {
      await widget.device.disconnectAndUpdateStream();
      Snackbar.show(ABC.c, "Disconnect: Success", success: true);
    } catch (e, backtrace) {
      Snackbar.show(ABC.c, prettyException("Disconnect Error:", e), success: false);
      print("$e backtrace: $backtrace");
    }
  }

  // Hàm tìm đặc tính điều khiển
  void _findControlCharacteristic() async {
    _controlCharacteristic = null; // Reset

    try {
      List<BluetoothService> discoveredServices = await widget.device.discoverServices();

      for (var service in discoveredServices) {
        if (service.uuid == Guid(SERVICE_UUID)) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid == Guid(CONTROL_CHARACTERISTIC_UUID)) {
              _controlCharacteristic = characteristic;
              print("Found control characteristic: ${characteristic.uuid}");
              break;
            }
          }
        }
        if (_controlCharacteristic != null) break;
      }
      if (_controlCharacteristic == null) {
        print("Control characteristic not found. Make sure SERVICE_UUID and CONTROL_CHARACTERISTIC_UUID are correct.");
      }
    } catch (e) {
      print("Error discovering services in _findControlCharacteristic: $e");
    }
  }

  // Hàm ghi lệnh điều khiển
  Future _writeControlCommand(List<int> command, String commandType) async {
    if (_controlCharacteristic == null) {
      Snackbar.show(ABC.c, "Control characteristic not found!", success: false);
      return;
    }
    if (!isConnected) {
      Snackbar.show(ABC.c, "Device is disconnected!", success: false);
      return;
    }
    try {
      await _controlCharacteristic!
          .write(command, withoutResponse: _controlCharacteristic!.properties.writeWithoutResponse);
      Snackbar.show(ABC.c, commandType == "LOCK" ? "Car LOCK" : "Car UNLOCK", success: true);
    } catch (e, backtrace) {
      Snackbar.show(ABC.c, prettyException("Write Command Error:", e), success: false);
      print(e);
      print("backtrace: $backtrace");
    }
  }

  // Hàm xử lý khi nhấn nút LOCK
  Future onLockPressed() async {
    final username = widget.username ?? "default_user";
    final password = widget.password ?? "default_pass";
    final lockCommandString = "$username,$password,LOCK#";
    final lockCommandBytes = utf8.encode(lockCommandString);
    await _writeControlCommand(lockCommandBytes, "LOCK");
  }

  // Hàm xử lý khi nhấn nút UNLOCK
  Future onUnlockPressed() async {
    final username = widget.username ?? "default_user";
    final password = widget.password ?? "default_pass";
    final unlockCommandString = "$username,$password,UNLOCK#";
    final unlockCommandBytes = utf8.encode(unlockCommandString);
    await _writeControlCommand(unlockCommandBytes, "UNLOCK");
  }

  // Hàm reset màu nút sau khi nhấn
  void _resetButtonColor({required bool isLock}) {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          if (isLock) {
            _isLockPressed = false;
          } else {
            _isUnlockPressed = false;
          }
        });
      }
    });
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

  Widget buildRemoteId(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Text('${widget.device.remoteId}'),
    );
  }

  Widget buildRssiTile(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        isConnected ? const Icon(Icons.bluetooth_connected) : const Icon(Icons.bluetooth_disabled),
        Text(((isConnected && _rssi != null) ? '${_rssi!} dBm' : ''), style: Theme.of(context).textTheme.bodySmall)
      ],
    );
  }

  Widget buildConnectButton(BuildContext context) {
    return Row(children: [
      if (_isConnecting || _isDisconnecting) buildSpinner(context),
      ElevatedButton(
          onPressed: _isConnecting ? onCancelPressed : (isConnected ? onDisconnectPressed : onConnectPressed),
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
          ),
          child: Text(
            _isConnecting ? "CANCEL" : (isConnected ? "DISCONNECT" : "CONNECT"),
            style: Theme.of(context).primaryTextTheme.labelLarge?.copyWith(color: Colors.white),
          ))
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: Snackbar.snackBarKeyC,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.device.platformName),
          actions: [buildConnectButton(context), const SizedBox(width: 20.0)], // Khoảng cách 20.0
        ),
        body: Column(
          children: [
            // Đặt buildRemoteId và ListTile ở phía trên
            buildRemoteId(context),
            ListTile(
              leading: buildRssiTile(context),
              title: Text('Device is ${_connectionState.toString().split('.')[1]}.'),
            ),
            // Khu vực căn giữa cho các nút LOCK và UNLOCK
            Expanded(
              child: Center(
                child: isConnected && _controlCharacteristic != null
                    ? Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Nút LOCK với biểu tượng ổ khóa
                            ElevatedButton(
                              onPressed: () async {
                                setState(() {
                                  _isLockPressed = true;
                                });
                                await onLockPressed();
                                _resetButtonColor(isLock: true); // Reset màu sau 300ms
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _isLockPressed ? Colors.red : Colors.orange, // Màu cam mặc định
                                foregroundColor: Colors.white,
                                shape: const CircleBorder(), // Hình tròn
                                padding: const EdgeInsets.all(45.0), // Tăng kích thước nút
                              ),
                              child: const Icon(
                                Icons.lock,
                                color: Colors.white,
                                size: 40.0, // Tăng kích thước biểu tượng
                              ),
                            ),
                            const SizedBox(height: 40.0), // Khoảng cách giữa LOCK và UNLOCK
                            // Nút UNLOCK với biểu tượng ổ khóa mở
                            ElevatedButton(
                              onPressed: () async {
                                setState(() {
                                  _isUnlockPressed = true;
                                });
                                await onUnlockPressed();
                                _resetButtonColor(isLock: false); // Reset màu sau 300ms
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _isUnlockPressed ? Colors.red : Colors.orange, // Màu cam mặc định
                                foregroundColor: Colors.white,
                                shape: const CircleBorder(), // Hình tròn
                                padding: const EdgeInsets.all(45.0), // Tăng kích thước nút
                              ),
                              child: const Icon(
                                Icons.lock_open,
                                color: Colors.white,
                                size: 40.0, // Tăng kích thước biểu tượng
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(), // Ẩn nếu không kết nối
              ),
            ),
          ],
        ),
      ),
    );
  }
}
