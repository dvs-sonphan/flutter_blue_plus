// packages/flutter_blue_plus/example/lib/screens/scan_screen.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// ignore: depend_on_referenced_packages

import 'device_screen.dart';
import '../utils/snackbar.dart';
import '../widgets/system_device_tile.dart';
import '../widgets/scan_result_tile.dart';
import '../utils/extra.dart';

class ScanScreen extends StatefulWidget {
  final String? username; // Biến username
  final String? password; // Biến password

  const ScanScreen({
    super.key,
    this.username,
    this.password,
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
  BluetoothDevice? _autoConnectingDevice; // Track the device currently being auto-connected

  @override
  void initState() {
    super.initState();
    // Tăng cường logging để gỡ lỗi chi tiết hơn về BLE
    FlutterBluePlus.setLogLevel(LogLevel.verbose);

    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        setState(() => _scanResults = results);
        _tryAutoConnectWithUsername(); // Đổi tên hàm để phản ánh logic mới
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
    // Đảm bảo dừng quét khi rời màn hình để tiết kiệm pin
    if (_isScanning) {
      FlutterBluePlus.stopScan();
    }
    super.dispose();
  }

  Future<void> _startInitialScan() async {
    // Đảm bảo adapter Bluetooth đã bật trước khi quét
    await FlutterBluePlus.adapterState.where((val) => val == BluetoothAdapterState.on).first;

    // Kiểm tra xem đã có thiết bị nào đang kết nối không
    // ignore: await_only_futures
    final connectedDevices = await FlutterBluePlus.connectedDevices;
    if (connectedDevices.isNotEmpty) {
      // Loại bỏ khoảng trắng ở username
      final trimmedUsername = widget.username?.trim();

      for (var d in connectedDevices) {
        // Trim tên thiết bị đã kết nối
        final trimmedPlatformName = d.platformName.trim();
        if (trimmedUsername != null && trimmedPlatformName == trimmedUsername) {
          // So sánh toàn bộ tên sau khi trim
          FlutterBluePlus.log("[FBP] Found already connected device: ${d.platformName}");
          if (mounted) {
            _autoConnectingDevice = d; // Đặt thiết bị đã kết nối là thiết bị tự động kết nối
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) => DeviceScreen(
                  device: d,
                  username: widget.username,
                  password: widget.password,
                ),
                settings: const RouteSettings(name: '/DeviceScreen'),
              ),
            );
          }
          return;
        }
      }
    }
    onScanPressed(); // Start scanning if no device is connected
  }

  // Logic tự động kết nối dựa trên toàn bộ username (đã loại bỏ khoảng trắng)
  void _tryAutoConnectWithUsername() {
    // Chỉ tự động kết nối nếu username không rỗng và chưa có thiết bị nào đang được tự động kết nối
    if (widget.username == null || widget.username!.isEmpty || _autoConnectingDevice != null) {
      return;
    }

    // Sắp xếp kết quả quét theo RSSI giảm dần để ưu tiên thiết bị gần nhất
    _scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));

    final expectedName = widget.username!.trim(); // Loại bỏ khoảng trắng từ username

    for (ScanResult r in _scanResults) {
      String advName = r.advertisementData.advName;
      final trimmedAdvName = advName.trim(); // Loại bỏ khoảng trắng ở đầu và cuối advName

      // So sánh toàn bộ tên sau khi loại bỏ khoảng trắng
      if (trimmedAdvName == expectedName) {
        FlutterBluePlus.log(
            "[FBP] Found device with matching trimmed name for auto-connect: ${r.advertisementData.advName} (RSSI: ${r.rssi})");
        FlutterBluePlus.stopScan(); // Dừng quét ngay lập tức
        onConnectPressed(r.device); // Cố gắng kết nối
        return; // Dừng lại sau khi tìm thấy và cố gắng kết nối
      }
    }
  }

  Future onScanPressed() async {
    try {
      _systemDevices = await FlutterBluePlus.systemDevices(const []); // Lấy các thiết bị hệ thống đã biết
    } catch (e, backtrace) {
      Snackbar.show(ABC.b, prettyException("System Devices Error:", e), success: false);
      print(e);
      print("backtrace: $backtrace");
    }
    try {
      // Đảm bảo không quét khi đã kết nối hoặc đang cố gắng kết nối tự động
      if (_autoConnectingDevice == null || !_autoConnectingDevice!.isConnected) {
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 10), // Giảm thời gian quét ban đầu
        );
      }
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
    // Ngăn chặn kết nối lại nếu đã kết nối hoặc đang cố gắng kết nối với cùng một thiết bị
    if (_autoConnectingDevice != null && _autoConnectingDevice!.remoteId == device.remoteId) {
      return;
    }
    _autoConnectingDevice = device; // Đánh dấu thiết bị đang được xử lý

    device.connectAndUpdateStream().catchError((e) {
      if (e is FlutterBluePlusException && e.code == FbpErrorCode.connectionCanceled.index) {
        // Bỏ qua lỗi hủy kết nối do người dùng
      } else {
        Snackbar.show(ABC.c, prettyException("Connect Error:", e), success: false);
      }
      if (mounted) {
        setState(() {
          _autoConnectingDevice = null; // Reset nếu kết nối thất bại
        });
      }
    }).whenComplete(() {
      // Khi quá trình kết nối hoàn tất (thành công hoặc thất bại)
      if (device.isConnected && mounted) {
        Navigator.of(context)
            .pushReplacement(
          // Sử dụng pushReplacement để tránh tích lũy màn hình
          MaterialPageRoute(
            builder: (context) => DeviceScreen(
              device: device,
              username: widget.username, // Truyền username
              password: widget.password, // Truyền password
            ),
            settings: const RouteSettings(name: '/DeviceScreen'),
          ),
        )
            .then((_) {
          // Khi quay lại từ DeviceScreen
          if (!device.isConnected && mounted) {
            setState(() {
              _autoConnectingDevice = null; // Reset trạng thái tự động kết nối
            });
            _startInitialScan(); // Bắt đầu quét lại
          }
        });
      } else {
        // Nếu không kết nối được, reset _autoConnectingDevice để có thể thử lại
        if (mounted) {
          setState(() {
            _autoConnectingDevice = null;
          });
        }
      }
    });
  }

  Future onRefresh() {
    if (_isScanning == false) {
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 10)); // Giảm thời gian quét khi refresh
    }
    if (mounted) {
      setState(() {});
    }
    return Future.delayed(const Duration(milliseconds: 500));
  }

  Widget buildScanButton() {
    return Row(children: [
      if (_isScanning ||
          (_autoConnectingDevice != null &&
              !_autoConnectingDevice!
                  .isConnected)) // Hiển thị spinner khi đang quét hoặc đang tự động kết nối (nhưng chưa kết nối xong)
        buildSpinner()
      else
        ElevatedButton(
            onPressed: onScanPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
            ),
            child: const Text("SCAN"))
    ]);
  }

  Widget buildSpinner() {
    return Padding(
      padding: const EdgeInsets.all(14.0),
      child: AspectRatio(
        aspectRatio: 1.0,
        child: const CircularProgressIndicator(
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
                settings: const RouteSettings(name: '/DeviceScreen'),
              ),
            ),
            onConnect: () => onConnectPressed(d),
          ),
        )
        .toList();
  }

  Iterable<Widget> _buildScanResultTiles() {
    // Hiển thị tất cả các thiết bị được quét thấy
    return _scanResults.where((r) {
      // Đảm bảo advName không rỗng và không phải là thiết bị đang được tự động kết nối
      return r.advertisementData.advName.isNotEmpty &&
          (_autoConnectingDevice == null || _autoConnectingDevice!.remoteId != r.device.remoteId);
    }).map((r) => ScanResultTile(result: r, onTap: () => onConnectPressed(r.device)));
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
          child: (_autoConnectingDevice != null &&
                  _autoConnectingDevice!.isConnected) // Nếu thiết bị đã kết nối (thông qua auto-connect hoặc manual)
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Connected to: ${_autoConnectingDevice!.platformName}',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.of(context)
                              .push(
                            MaterialPageRoute(
                              builder: (context) => DeviceScreen(
                                device: _autoConnectingDevice!,
                                username: widget.username,
                                password: widget.password,
                              ),
                              settings: const RouteSettings(name: '/DeviceScreen'),
                            ),
                          )
                              .then((_) {
                            if (!_autoConnectingDevice!.isConnected && mounted) {
                              setState(() {
                                _autoConnectingDevice = null;
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
                    if (_autoConnectingDevice != null &&
                        !_autoConnectingDevice!.isConnected) // Hiển thị thông báo đang kết nối nếu chưa kết nối xong
                      ListTile(
                        title: Text('Connecting to: ${_autoConnectingDevice!.platformName}...'),
                        trailing: buildSpinner(),
                      ),
                    ..._buildSystemDeviceTiles(),
                    ..._buildScanResultTiles(),
                  ],
                ),
        ),
      ),
    );
  }
}
