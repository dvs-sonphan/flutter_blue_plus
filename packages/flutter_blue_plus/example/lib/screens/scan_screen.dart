// packages/flutter_blue_plus/example/lib/screens/scan_screen.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart'; // Thêm import này

import 'device_screen.dart';
import '../utils/snackbar.dart';
import '../widgets/system_device_tile.dart';
import '../widgets/scan_result_tile.dart';
import '../utils/extra.dart';

class ScanScreen extends StatefulWidget {
  final String? initialDeviceNameToConnect;
  final String? username; // Thêm biến username
  final String? password; // Thêm biến password

  const ScanScreen({
    super.key,
    this.initialDeviceNameToConnect,
    this.username, // Thêm vào constructor
    this.password, // Thêm vào constructor
  });

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  List<BluetoothDevice> _systemDevices = [];
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  late StreamSubscription<List<ScanResult>> _scanResultsSubscription;
  late StreamSubscription<bool> _isScanningSubscription;
  BluetoothDevice? _connectedDevice; // Track the automatically connected device

  String? _savedDeviceNameForAutoConnect;
  static const String _KEY_SAVED_BLE_DEVICE_NAME = 'savedBleDeviceName'; // Khóa lưu trữ
  static const int _RSSI_THRESHOLD_3M = -75; // Ngưỡng RSSI ước tính 3m (cần điều chỉnh)

  @override
  void initState() {
    super.initState();
    _loadSavedDeviceName(); // Tải tên thiết bị đã lưu khi khởi tạo màn hình

    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        setState(() => _scanResults = results);
        _tryAutoConnectWithRssi(); // THAY ĐỔI: Thử auto-connect với RSSI
      }
    }, onError: (e) {
      Snackbar.show(ABC.b, prettyException("Scan Error:", e), success: false);
    });

    _isScanningSubscription = FlutterBluePlus.isScanning.listen((state) {
      if (mounted) {
        setState(() => _isScanning = state);
      }
    });

    _startInitialScan(); // Start scan when the screen initializes
  }

  @override
  void dispose() {
    _scanResultsSubscription.cancel();
    _isScanningSubscription.cancel();
    super.dispose();
  }

  Future<void> _startInitialScan() async {
    // Ensure Bluetooth adapter is on before starting scan
    await FlutterBluePlus.adapterState.where((val) => val == BluetoothAdapterState.on).first;

    onScanPressed(); // Start scanning
  }

  // Tải tên thiết bị đã lưu từ SharedPreferences
  Future<void> _loadSavedDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    _savedDeviceNameForAutoConnect = prefs.getString(_KEY_SAVED_BLE_DEVICE_NAME);
    if (_savedDeviceNameForAutoConnect != null) {
      FlutterBluePlus.log("[FBP] Loaded saved device name for auto-connect: $_savedDeviceNameForAutoConnect");
    }
  }

  // THAY ĐỔI: Logic tự động kết nối dựa trên RSSI và tên đã lưu
  void _tryAutoConnectWithRssi() {
    // Ưu tiên kết nối lại thiết bị đã lưu theo RSSI
    if (_savedDeviceNameForAutoConnect != null && _connectedDevice == null) {
      for (ScanResult r in _scanResults) {
        // Nếu tên thiết bị quét được trùng với tên đã lưu VÀ RSSI vượt ngưỡng
        if (r.advertisementData.advName == _savedDeviceNameForAutoConnect && r.rssi >= _RSSI_THRESHOLD_3M) {
          FlutterBluePlus.log(
              "[FBP] Auto-connecting to saved device: ${r.advertisementData.advName} (RSSI: ${r.rssi})");
          FlutterBluePlus.stopScan(); // Dừng quét
          onConnectPressed(r.device); // Cố gắng kết nối
          return; // Dừng lại sau khi tìm thấy và cố gắng kết nối
        }
      }
    }
    // Nếu không có thiết bị đã lưu hoặc không tìm thấy trong phạm vi gần,
    // thì thử tự động kết nối với thiết bị dựa trên tên đăng nhập (logic cũ)
    if (widget.initialDeviceNameToConnect != null && _connectedDevice == null) {
      for (ScanResult r in _scanResults) {
        if (r.advertisementData.advName == widget.initialDeviceNameToConnect) {
          FlutterBluePlus.log("[FBP] Auto-connecting to login device: ${r.advertisementData.advName}");
          FlutterBluePlus.stopScan();
          onConnectPressed(r.device);
          return; // Dừng lại sau khi tìm thấy và cố gắng kết nối
        }
      }
    }
  }

  Future onScanPressed() async {
    try {
      // FIX: Provide an empty list of Guids as the argument.
      _systemDevices = await FlutterBluePlus.systemDevices(const []); // Corrected line
    } catch (e, backtrace) {
      Snackbar.show(ABC.b, prettyException("System Devices Error:", e), success: false);
      print(e);
      print("backtrace: $backtrace");
    }
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        // Add services or names if known for faster filtering
        // withNames: [widget.initialDeviceNameToConnect ?? ""], // Filter by the expected name
      );
    } catch (e, backtrace) {
      Snackbar.show(ABC.b, prettyException("Start Scan Error:", e), success: false);
      print(e);
      print("backtrace: $backtrace");
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future onStopPressed() async {
    try {
      FlutterBluePlus.stopScan();
    } catch (e, backtrace) {
      Snackbar.show(ABC.b, prettyException("Stop Scan Error:", e), success: false);
      print(e);
      print("backtrace: $backtrace");
    }
  }

  void onConnectPressed(BluetoothDevice device) {
    if (_connectedDevice != null && _connectedDevice!.remoteId == device.remoteId) {
      // Already connecting/connected to this device
      return;
    }
    setState(() {
      _connectedDevice = device;
    });
    device.connectAndUpdateStream().catchError((e) {
      Snackbar.show(ABC.c, prettyException("Connect Error:", e), success: false);
      setState(() {
        _connectedDevice = null; // Reset if connection fails
      });
    });
    MaterialPageRoute route = MaterialPageRoute(
      builder: (context) => DeviceScreen(
        device: device,
        username: widget.username, // Truyền username
        password: widget.password, // Truyền password
      ),
      settings: RouteSettings(name: '/DeviceScreen'),
    );
    Navigator.of(context).push(route).then((_) {
      if (!device.isConnected) {
        setState(() {
          _connectedDevice = null;
        });
        _startInitialScan();
      }
    });
  }

  Future onRefresh() {
    if (_isScanning == false) {
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    }
    if (mounted) {
      setState(() {});
    }
    return Future.delayed(Duration(milliseconds: 500));
  }

  Widget buildScanButton() {
    return Row(children: [
      if (FlutterBluePlus.isScanningNow)
        buildSpinner()
      else
        ElevatedButton(
            onPressed: onScanPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
            ),
            child: Text("SCAN"))
    ]);
  }

  Widget buildSpinner() {
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

  List<Widget> _buildSystemDeviceTiles() {
    return _systemDevices
        .map(
          (d) => SystemDeviceTile(
            device: d,
            onOpen: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => DeviceScreen(
                  device: d,
                  username: widget.username,
                  password: widget.password,
                ),
                settings: RouteSettings(name: '/DeviceScreen'),
              ),
            ),
            onConnect: () => onConnectPressed(d),
          ),
        )
        .toList();
  }

  Iterable<Widget> _buildScanResultTiles() {
    return _scanResults.map((r) => ScanResultTile(result: r, onTap: () => onConnectPressed(r.device)));
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      key: Snackbar.snackBarKeyB,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Find Devices'),
          actions: [buildScanButton(), const SizedBox(width: 15)],
        ),
        body: RefreshIndicator(
          onRefresh: onRefresh,
          child: _connectedDevice != null &&
                  _connectedDevice!.isConnected // If a device is connected, show only relevant controls
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Connected to: ${_connectedDevice!.platformName}',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.of(context)
                              .push(
                            MaterialPageRoute(
                              builder: (context) => DeviceScreen(
                                device: _connectedDevice!,
                                username: widget.username,
                                password: widget.password,
                              ),
                              settings: RouteSettings(name: '/DeviceScreen'),
                            ),
                          )
                              .then((_) {
                            if (!_connectedDevice!.isConnected) {
                              setState(() {
                                _connectedDevice = null;
                              });
                              _startInitialScan();
                            }
                          });
                        },
                        child: const Text('Open Device Controls'),
                      ),
                    ],
                  ),
                )
              : ListView(
                  children: <Widget>[
                    ..._buildSystemDeviceTiles(),
                    ..._buildScanResultTiles(),
                  ],
                ),
        ),
      ),
    );
  }
}
