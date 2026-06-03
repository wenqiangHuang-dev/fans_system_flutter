import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String kServerBaseUrl = 'http://154.64.245.24';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MobileClientApp());
}

class MobileClientApp extends StatefulWidget {
  const MobileClientApp({super.key});

  @override
  State<MobileClientApp> createState() => _MobileClientAppState();
}

class _MobileClientAppState extends State<MobileClientApp> {
  late final ClientController controller;

  @override
  void initState() {
    super.initState();
    controller = ClientController()..initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        const seed = Color(0xFF1D6FD6);
        return MaterialApp(
          title: 'Tiktok',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: seed,
              surface: const Color(0xFFFFFFFF),
            ),
            scaffoldBackgroundColor: const Color(0xFFF4F7FB),
            useMaterial3: true,
            cardTheme: CardThemeData(
              color: Colors.white,
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: Color(0xFFE0E7F2)),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFD6DEEB)),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          home: AppShell(controller: controller),
        );
      },
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.ready) {
      return const SplashPage();
    }
    if (controller.blueScreen) {
      return const WhiteScreenPage();
    }
    if (controller.forceExit) {
      return DisabledPage(controller: controller);
    }
    return MainShell(controller: controller);
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.controller});

  final ClientController controller;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int selectedIndex = 4;

  static const List<String> _titles = <String>[
    '首页',
    '说明',
    '评论配置',
    '工作模式',
    '我的',
  ];

  Future<void> _handleTabTap(int index) async {
    if (index != 4 && !widget.controller.loggedIn) {
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('请先登录'),
            content: const Text('登录后才能使用该功能。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ],
          );
        },
      );
      if (mounted) {
        setState(() => selectedIndex = 4);
      }
      return;
    }

    setState(() => selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = widget.controller.loggedIn ? selectedIndex : 4;
    return Scaffold(
      extendBodyBehindAppBar: false,
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(_titles[currentIndex])),
      body: _AppBackground(
        child: IndexedStack(
          index: currentIndex,
          children: [
            HomePage(controller: widget.controller),
            InstructionPage(controller: widget.controller),
            const CommentConfigPage(),
            WorkModePage(
              controller: widget.controller,
              active: currentIndex == 3,
            ),
            MinePage(controller: widget.controller),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: _handleTabTap,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
          NavigationDestination(icon: Icon(Icons.info_outline), label: '说明'),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            label: '评论配置',
          ),
          NavigationDestination(icon: Icon(Icons.tune_outlined), label: '工作模式'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
        ],
      ),
    );
  }
}

class ClientController extends ChangeNotifier {
  static const _deviceIdKey = 'deviceId';
  static const _loggedInKey = 'loggedIn';
  static const _usernameKey = 'username';

  final Random _random = Random();

  SharedPreferences? _preferences;
  Timer? _pollTimer;
  Timer? _displayTimer;
  Timer? _socketReconnectTimer;
  StreamSubscription<dynamic>? _controlSocketSubscription;
  WebSocket? _controlSocket;
  bool _disposed = false;
  bool _fetchingState = false;

  bool ready = false;
  bool loggedIn = false;
  bool busy = false;
  bool blueScreen = false;
  bool forceExit = false;

  String deviceId = '';
  String deviceName = '';
  String appVersion = '1.0.0';
  String username = '';
  String statusMessage = '请登录账号';
  String controlStatusName = '正常';
  String lastSyncTime = '';
  ClientInstructionModel instruction = ClientInstructionModel.defaults();

  AccountModel? account;
  List<AccountModel> accounts = <AccountModel>[];
  int displayFans = 0;

  Future<void> initialize() async {
    _preferences = await SharedPreferences.getInstance();
    deviceId = _preferences?.getString(_deviceIdKey) ?? _createDeviceId();
    loggedIn = _preferences?.getBool(_loggedInKey) ?? false;
    username = _preferences?.getString(_usernameKey) ?? '';
    deviceName = _resolveDeviceName();
    await _preferences?.setString(_deviceIdKey, deviceId);
    _startDisplayTimer();
    ready = true;
    _notify();

    if (loggedIn) {
      await fetchState(showBusy: false, allowLogoutOnFailure: true);
      if (loggedIn) {
        _startPolling();
        await _connectControlSocket();
      }
    }
  }

  Future<void> login(String inputUsername, String inputPassword) async {
    final loginUsername = inputUsername.trim();
    final loginPassword = inputPassword.trim();
    if (loginUsername.isEmpty || loginPassword.isEmpty) {
      statusMessage = '请输入管理员账号和密码';
      _notify();
      return;
    }

    busy = true;
    statusMessage = '正在登录';
    _notify();

    try {
      final response = await http
          .post(
            Uri.parse('$kServerBaseUrl/api/client/auth/login'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'deviceId': deviceId,
              'deviceName': deviceName,
              'appVersion': appVersion,
              'username': loginUsername,
              'password': loginPassword,
            }),
          )
          .timeout(const Duration(seconds: 10));

      final payload = _readApiPayload(response, '登录失败，请检查账号或密码');
      if (payload['success'] != true) {
        throw Exception(_readApiMessage(payload, '登录失败，请检查账号或密码'));
      }

      username = loginUsername;
      loggedIn = true;
      await _preferences?.setBool(_loggedInKey, true);
      await _preferences?.setString(_usernameKey, username);
      _applyState(payload['data']);
      _startPolling();
      await _connectControlSocket();
      statusMessage = '登录成功';
    } catch (error) {
      loggedIn = false;
      blueScreen = false;
      forceExit = false;
      accounts = <AccountModel>[];
      account = null;
      displayFans = 0;
      statusMessage = '登录失败：${_formatError(error)}';
      await _preferences?.setBool(_loggedInKey, false);
      await _closeControlSocket();
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> logout() async {
    try {
      await http
          .post(
            Uri.parse('$kServerBaseUrl/api/client/auth/logout'),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{'deviceId': deviceId}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}

    _pollTimer?.cancel();
    _socketReconnectTimer?.cancel();
    await _closeControlSocket();
    loggedIn = false;
    blueScreen = false;
    forceExit = false;
    accounts = <AccountModel>[];
    account = null;
    displayFans = 0;
    statusMessage = '已退出登录';
    await _preferences?.setBool(_loggedInKey, false);
    _notify();
  }

  Future<void> refreshNow() async {
    await fetchState();
  }

  Future<ClientImportResult> bindImportAccounts(
    List<ImportUserCredential> importUsers,
  ) async {
    final users = importUsers
        .where(
          (user) =>
              user.username.trim().isNotEmpty &&
              user.password.trim().isNotEmpty,
        )
        .toList();
    if (users.isEmpty) {
      return const ClientImportResult(
        successCount: 0,
        failureCount: 0,
        accounts: <AccountModel>[],
        failures: <ImportFailureModel>[],
      );
    }

    final response = await http
        .post(
          Uri.parse('$kServerBaseUrl/api/client/import/bind'),
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{
            'deviceId': deviceId,
            'users': users
                .map(
                  (user) => <String, dynamic>{
                    'username': user.username.trim(),
                    'password': user.password.trim(),
                  },
                )
                .toList(),
          }),
        )
        .timeout(const Duration(seconds: 10));

    final payload = _readApiPayload(response, '导入绑定失败，请稍后重试');
    if (payload['success'] != true) {
      throw Exception(_readApiMessage(payload, '导入绑定失败，请稍后重试'));
    }

    final data = payload['data'];
    if (data is Map) {
      final result = ClientImportResult.fromJson(
        Map<String, dynamic>.from(data),
      );
      _applyAccounts(result.accounts);
      statusMessage = '导入绑定完成';
      _notify();
      return result;
    }
    throw Exception('接口返回格式错误');
  }

  Future<void> fetchState({
    bool showBusy = true,
    bool allowLogoutOnFailure = false,
  }) async {
    if (!loggedIn || _fetchingState) {
      return;
    }

    _fetchingState = true;
    if (showBusy) {
      busy = true;
      _notify();
    }

    try {
      final uri = Uri.parse(
        '$kServerBaseUrl/api/client/state',
      ).replace(queryParameters: <String, String>{'deviceId': deviceId});
      final response = await http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));

      final payload = _readApiPayload(response, '同步失败，请稍后重试');
      if (payload['success'] != true) {
        throw Exception(_readApiMessage(payload, '同步失败，请稍后重试'));
      }

      _applyState(payload['data']);
      statusMessage = '同步成功';
    } catch (error) {
      final message = _formatError(error);
      statusMessage = '同步失败：$message';
      if (allowLogoutOnFailure ||
          message.contains('请先登录') ||
          message.contains('重新登录')) {
        loggedIn = false;
        blueScreen = false;
        forceExit = false;
        accounts = <AccountModel>[];
        account = null;
        displayFans = 0;
        await _preferences?.setBool(_loggedInKey, false);
        await _closeControlSocket();
      }
    } finally {
      _fetchingState = false;
      if (showBusy) {
        busy = false;
      }
      _notify();
    }
  }

  Future<void> _connectControlSocket() async {
    if (!loggedIn || _disposed) {
      return;
    }
    if (_controlSocket != null) {
      return;
    }

    final uri = Uri.parse(kServerBaseUrl).replace(
      scheme: Uri.parse(kServerBaseUrl).scheme == 'https' ? 'wss' : 'ws',
      path: '/ws/client-control',
      queryParameters: <String, String>{'deviceId': deviceId},
    );

    try {
      final socket = await WebSocket.connect(uri.toString());
      _controlSocket = socket;
      _socketReconnectTimer?.cancel();
      _controlSocketSubscription = socket.listen(
        _handleControlSocketMessage,
        onDone: _scheduleSocketReconnect,
        onError: (_) => _scheduleSocketReconnect(),
        cancelOnError: true,
      );
      statusMessage = '实时控制已连接';
      _notify();
    } catch (_) {
      _scheduleSocketReconnect();
    }
  }

  Future<void> _closeControlSocket() async {
    _socketReconnectTimer?.cancel();
    await _controlSocketSubscription?.cancel();
    _controlSocketSubscription = null;
    await _controlSocket?.close();
    _controlSocket = null;
  }

  void _scheduleSocketReconnect() {
    _controlSocketSubscription = null;
    _controlSocket = null;
    if (!loggedIn || _disposed || forceExit) {
      return;
    }
    _socketReconnectTimer?.cancel();
    _socketReconnectTimer = Timer(const Duration(seconds: 5), () {
      _connectControlSocket();
    });
  }

  void _handleControlSocketMessage(dynamic rawMessage) {
    if (rawMessage is! String || rawMessage.isEmpty) {
      return;
    }

    try {
      final payload = jsonDecode(rawMessage);
      if (payload is! Map<String, dynamic>) {
        return;
      }
      if (payload['type'] != 'CONTROL_STATUS') {
        return;
      }

      final status = '${payload['controlStatus'] ?? 'NORMAL'}';
      final statusName = '${payload['controlStatusName'] ?? status}';
      controlStatusName = statusName;
      lastSyncTime = _formatSyncTime(payload['serverTime']);
      statusMessage = '收到控制指令：$statusName';
      _applyControlStatus(status);
    } catch (_) {}
  }

  void _applyState(dynamic data) {
    if (data is! Map) {
      throw Exception('状态数据缺失');
    }

    final map = Map<String, dynamic>.from(data);
    final instructionValue = map['instruction'];
    if (instructionValue is Map) {
      instruction = ClientInstructionModel.fromJson(
        Map<String, dynamic>.from(instructionValue),
      );
    }
    final accountsValue = map['accounts'];
    if (accountsValue is! List) {
      throw Exception('状态数据缺少账号列表');
    }

    final nextAccounts = accountsValue
        .whereType<Map>()
        .map((item) => AccountModel.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    _applyAccounts(nextAccounts);
    controlStatusName = '${map['controlStatusName'] ?? '正常'}';
    lastSyncTime = _formatSyncTime(map['serverTime']);
    _applyControlStatus('${map['controlStatus'] ?? 'NORMAL'}');
  }

  void _applyAccounts(List<AccountModel> nextAccounts) {
    final targetFans = nextAccounts.fold<int>(
      0,
      (sum, nextAccount) => sum + nextAccount.currentFans,
    );
    if (accounts.isEmpty || displayFans > targetFans) {
      displayFans = targetFans;
    } else {
      displayFans = min(displayFans, targetFans);
    }

    accounts = List<AccountModel>.unmodifiable(nextAccounts);
    account = accounts.isEmpty ? null : accounts.first;
  }

  void _applyControlStatus(String status) {
    blueScreen = status == 'BLUE_SCREEN';
    forceExit = status == 'FORCE_EXIT';
    if (status == 'FORCE_EXIT') {
      _notify();
      _triggerForceExit();
      return;
    }
    _notify();
  }

  void _triggerForceExit() {
    Future<void>.delayed(const Duration(milliseconds: 150), () async {
      if (_disposed) {
        return;
      }
      if (Platform.isAndroid) {
        await SystemNavigator.pop();
        return;
      }
      exit(0);
    });
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      fetchState(showBusy: false);
    });
  }

  void _startDisplayTimer() {
    _displayTimer?.cancel();
    _displayTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final targetFans = accounts.fold<int>(
        0,
        (sum, currentAccount) => sum + currentAccount.currentFans,
      );
      if (targetFans <= 0) {
        return;
      }
      if (displayFans >= targetFans) {
        return;
      }

      final remaining = targetFans - displayFans;
      final baseStep = max(1, remaining ~/ max(2, 4 + _random.nextInt(5)));
      final step = min(remaining, baseStep + _random.nextInt(max(1, baseStep)));
      displayFans += step;
      _notify();
    });
  }

  String _createDeviceId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomPart = _random.nextInt(999999).toString().padLeft(6, '0');
    return 'device-$timestamp-$randomPart';
  }

  String _resolveDeviceName() {
    if (Platform.isAndroid) {
      return 'Android 设备';
    }
    if (Platform.isIOS) {
      return 'iPhone';
    }
    return Platform.operatingSystem;
  }

  String _formatSyncTime(dynamic value) {
    if (value is String) {
      return value.replaceFirst('T', ' ');
    }
    if (value is List && value.length >= 6) {
      final values = value.map((item) => int.tryParse('$item') ?? 0).toList();
      final year = values[0];
      final month = values[1].toString().padLeft(2, '0');
      final day = values[2].toString().padLeft(2, '0');
      final hour = values[3].toString().padLeft(2, '0');
      final minute = values[4].toString().padLeft(2, '0');
      final second = values[5].toString().padLeft(2, '0');
      return '$year-$month-$day $hour:$minute:$second';
    }
    return '';
  }

  Map<String, dynamic> _readApiPayload(
    http.Response response,
    String fallbackMessage,
  ) {
    Map<String, dynamic>? payload;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        payload = decoded;
      }
    } catch (_) {}

    if (payload != null) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return payload;
      }
      throw Exception(_readApiMessage(payload, fallbackMessage));
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      throw Exception('接口返回格式错误');
    }
    throw Exception(fallbackMessage);
  }

  String _readApiMessage(Map<String, dynamic> payload, String fallbackMessage) {
    final message = '${payload['message'] ?? ''}'.trim();
    return message.isEmpty || message == 'null' ? fallbackMessage : message;
  }

  String _formatError(Object error) {
    final text = error.toString();
    if (text.startsWith('Exception: ')) {
      return text.substring('Exception: '.length);
    }
    return text;
  }

  String formatError(Object error) {
    return _formatError(error);
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _displayTimer?.cancel();
    _socketReconnectTimer?.cancel();
    _controlSocketSubscription?.cancel();
    _controlSocket?.close();
    super.dispose();
  }
}

class ClientInstructionModel {
  const ClientInstructionModel({required this.title, required this.content});

  final String title;
  final String content;

  factory ClientInstructionModel.fromJson(Map<String, dynamic> json) {
    final title = '${json['title'] ?? ''}'.trim();
    final content = '${json['content'] ?? ''}'.trim();
    if (title.isEmpty && content.isEmpty) {
      return ClientInstructionModel.defaults();
    }
    return ClientInstructionModel(
      title: title.isEmpty ? '操作说明' : title,
      content: content.isEmpty
          ? ClientInstructionModel.defaults().content
          : content,
    );
  }

  factory ClientInstructionModel.defaults() {
    return const ClientInstructionModel(
      title: '操作说明',
      content:
          '1. 使用后台创建的管理员账号和密码登录客户端。\n'
          '2. 在首页导入与后台相同的 txt 文件，文件格式为一行一个用户：用户名 密码。\n'
          '3. 只有后台已存在且密码匹配的用户会绑定成功，并开始按后台配置增长粉丝。\n'
          '4. 如需调整说明内容，请在后台管理端的客户端配置中修改。',
    );
  }

  List<String> get paragraphs {
    return content
        .split(RegExp(r'\n\s*\n|\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }
}

class _AppBackground extends StatelessWidget {
  const _AppBackground({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage('assets/background.png'),
          fit: BoxFit.cover,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF4F7FB).withValues(alpha: 0.78),
        ),
        child: child,
      ),
    );
  }
}

class AccountModel {
  AccountModel({
    required this.id,
    required this.accountName,
    required this.loginPassword,
    required this.currentFans,
    required this.hourlyIncrement,
    required this.growthEnabled,
    required this.growthStarted,
    required this.remark,
    required this.updatedAt,
  });

  final int id;
  final String accountName;
  final String loginPassword;
  final int currentFans;
  final int hourlyIncrement;
  final bool growthEnabled;
  final bool growthStarted;
  final String remark;
  final String updatedAt;

  factory AccountModel.fromJson(Map<String, dynamic> json) {
    return AccountModel(
      id: _readInt(json['id']),
      accountName: '${json['accountName'] ?? ''}',
      loginPassword: '${json['loginPassword'] ?? ''}',
      currentFans: _readInt(json['currentFans']),
      hourlyIncrement: _readInt(json['hourlyIncrement']),
      growthEnabled: _readBool(json['growthEnabled']),
      growthStarted: _readBool(json['growthStarted']),
      remark: '${json['remark'] ?? ''}',
      updatedAt: '${json['updatedAt'] ?? ''}',
    );
  }

  static int _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static bool _readBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return '$value'.toLowerCase() == 'true';
  }
}

class ClientImportResult {
  const ClientImportResult({
    required this.successCount,
    required this.failureCount,
    required this.accounts,
    required this.failures,
  });

  final int successCount;
  final int failureCount;
  final List<AccountModel> accounts;
  final List<ImportFailureModel> failures;

  factory ClientImportResult.fromJson(Map<String, dynamic> json) {
    final accountsValue = json['accounts'];
    final failuresValue = json['failures'];
    return ClientImportResult(
      successCount: AccountModel._readInt(json['successCount']),
      failureCount: AccountModel._readInt(json['failureCount']),
      accounts: accountsValue is List
          ? accountsValue
                .whereType<Map>()
                .map(
                  (item) =>
                      AccountModel.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList()
          : <AccountModel>[],
      failures: failuresValue is List
          ? failuresValue
                .whereType<Map>()
                .map(
                  (item) => ImportFailureModel.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : <ImportFailureModel>[],
    );
  }
}

class ImportFailureModel {
  const ImportFailureModel({
    required this.lineNo,
    required this.content,
    required this.reason,
  });

  final int lineNo;
  final String content;
  final String reason;

  factory ImportFailureModel.fromJson(Map<String, dynamic> json) {
    return ImportFailureModel(
      lineNo: AccountModel._readInt(json['lineNo']),
      content: '${json['content'] ?? ''}',
      reason: '${json['reason'] ?? ''}',
    );
  }
}

class ImportUserCredential {
  const ImportUserCredential({required this.username, required this.password});

  final String username;
  final String password;
}

class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.6),
            ),
            SizedBox(height: 16),
            Text('正在初始化客户端'),
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final ClientController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<AccountModel> users = <AccountModel>[];
  bool importing = false;

  Future<void> _pickAndValidateImportFile() async {
    if (importing) {
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['txt'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        _showMessage('文件内容为空');
        return;
      }

      final rows = _parseUsers(utf8.decode(bytes, allowMalformed: true));
      if (rows.isEmpty) {
        _showMessage('没有识别到可导入的账号');
        return;
      }

      setState(() => importing = true);
      final importResult = await widget.controller.bindImportAccounts(rows);
      if (!mounted) {
        return;
      }

      setState(() {
        users
          ..clear()
          ..addAll(importResult.accounts);
      });

      _showMessage(
        '导入完成，成功 ${importResult.successCount} 条，失败 ${importResult.failureCount} 条',
      );
    } catch (error) {
      _showMessage('导入失败：${widget.controller.formatError(error)}');
    } finally {
      if (mounted) {
        setState(() => importing = false);
      }
    }
  }

  List<ImportUserCredential> _parseUsers(String rawText) {
    final lines = rawText
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    final parsedUsers = <ImportUserCredential>[];

    for (final line in lines) {
      final parts = line
          .split(RegExp(r'\s+'))
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();
      if (parts.length != 2) {
        continue;
      }

      final accountName = parts[0];
      final normalizedHeader = accountName.toLowerCase();
      if (normalizedHeader == 'username' ||
          normalizedHeader == 'account' ||
          normalizedHeader == 'accountname' ||
          normalizedHeader == 'account_name' ||
          accountName == '用户名' ||
          accountName == '账号') {
        continue;
      }
      parsedUsers.add(
        ImportUserCredential(username: accountName, password: parts[1]),
      );
    }

    return parsedUsers;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayedUsers = users.isEmpty ? widget.controller.accounts : users;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '用户导入',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '导入后会在下方展示用户列表。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: importing ? null : _pickAndValidateImportFile,
                  icon: importing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload_file_outlined),
                  label: Text(importing ? '导入中' : '选择同一份 txt 导入'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (displayedUsers.isEmpty && !importing)
          const _HomeEmptyState()
        else
          _UserListCard(users: displayedUsers, importing: importing),
      ],
    );
  }
}

class _UserListCard extends StatelessWidget {
  const _UserListCard({required this.users, required this.importing});

  final List<AccountModel> users;
  final bool importing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '用户列表',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '${users.length} 条',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (importing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ...users.map((user) => _UserListItem(user: user)),
          ],
        ),
      ),
    );
  }
}

class _UserListItem extends StatelessWidget {
  const _UserListItem({required this.user});

  final AccountModel user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F9FC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E7F2)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: theme.colorScheme.primary,
            child: Text(
              user.accountName.characters.first,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.accountName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '密码 ${user.loginPassword.isEmpty ? '-' : user.loginPassword} · 当前粉丝 ${user.currentFans} · 每小时增加 ${user.hourlyIncrement}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _StatusBadge(
            text: user.growthStarted ? '已启动' : '待启动',
            active: user.growthStarted,
          ),
        ],
      ),
    );
  }
}

class _HomeEmptyState extends StatelessWidget {
  const _HomeEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Icon(
              Icons.people_alt_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('暂无用户信息', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '请选择文件导入，或点击模拟导入查看列表效果。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InstructionPage extends StatelessWidget {
  const InstructionPage({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final instruction = controller.instruction;
    final paragraphs = instruction.paragraphs;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  instruction.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                for (var index = 0; index < paragraphs.length; index++) ...[
                  Text(
                    paragraphs[index],
                    style: theme.textTheme.bodyLarge?.copyWith(
                      height: 1.75,
                      color: const Color(0xFF263244),
                    ),
                  ),
                  if (index != paragraphs.length - 1)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Divider(height: 1),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class CommentConfigPage extends StatefulWidget {
  const CommentConfigPage({super.key});

  @override
  State<CommentConfigPage> createState() => _CommentConfigPageState();
}

class _CommentConfigPageState extends State<CommentConfigPage> {
  final TextEditingController videoRefreshController = TextEditingController();
  final TextEditingController commentIntervalController =
      TextEditingController();
  final TextEditingController likeIntervalController = TextEditingController();
  final TextEditingController coordinateController = TextEditingController();
  final TextEditingController scriptController = TextEditingController();

  bool antiBanEnabled = true;
  bool vpnEnabled = false;
  bool replyEnabled = true;
  bool followEnabled = true;

  @override
  void dispose() {
    videoRefreshController.dispose();
    commentIntervalController.dispose();
    likeIntervalController.dispose();
    coordinateController.dispose();
    scriptController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ConfigSection(
          title: '基础配置',
          children: [
            _InlineNumberField(
              leadingText: '采集最新视频 每',
              trailingText: '分钟刷新一次',
              controller: videoRefreshController,
            ),
            const SizedBox(height: 12),
            _InlineNumberField(
              leadingText: '评论间隔',
              trailingText: '秒',
              controller: commentIntervalController,
            ),
            const SizedBox(height: 12),
            _InlineNumberField(
              leadingText: '点赞间隔',
              trailingText: '秒',
              controller: likeIntervalController,
            ),
          ],
        ),
        const SizedBox(height: 14),
        _ConfigSection(
          title: '运行开关',
          children: [
            _ConfigSwitchTile(
              title: '开启防封模式',
              subtitle: '点赞、评论、回复智能循环',
              value: antiBanEnabled,
              onChanged: (value) => setState(() => antiBanEnabled = value),
            ),
            _ConfigSwitchTile(
              title: '开启 VPN 模式',
              value: vpnEnabled,
              onChanged: (value) => setState(() => vpnEnabled = value),
            ),
            _ConfigSwitchTile(
              title: '回复他人评论',
              value: replyEnabled,
              onChanged: (value) => setState(() => replyEnabled = value),
            ),
            _ConfigSwitchTile(
              title: '模拟真实用户点关注',
              value: followEnabled,
              onChanged: (value) => setState(() => followEnabled = value),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _ConfigSection(
          title: '抖音APP位置设置',
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _showMessage('百度地图选点功能待接入'),
                    icon: const Icon(Icons.map_outlined),
                    label: const Text('进入百度地图选点'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      coordinateController.clear();
                      _showMessage('已清除当前位置');
                    },
                    icon: const Icon(Icons.clear),
                    label: const Text('清除当前位置'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              controller: coordinateController,
              decoration: const InputDecoration(
                labelText: '输入坐标点',
                hintText: '例如：116.404,39.915',
                prefixIcon: Icon(Icons.place_outlined),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '需要点击上面的百度地图选点，进入百度坐标拾取系统，选好位置，将坐标点复制并粘贴；如果需要选取多个坐标点，请联系我，多个选点需要单独编辑。',
              style: TextStyle(
                color: Color(0xFFD92D20),
                fontSize: 13,
                height: 1.55,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _ConfigSection(
          title: '引流话术设置',
          children: [
            TextField(
              controller: scriptController,
              minLines: 6,
              maxLines: 10,
              decoration: const InputDecoration(
                alignLabelWithHint: true,
                labelText: '话术内容',
                hintText: '请输入需要使用的评论或回复话术',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ConfigSection extends StatelessWidget {
  const _ConfigSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InlineNumberField extends StatelessWidget {
  const _InlineNumberField({
    required this.leadingText,
    required this.trailingText,
    required this.controller,
  });

  final String leadingText;
  final String trailingText;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Flexible(
          flex: 3,
          child: Text(
            leadingText,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF263244),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 92,
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 12,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          flex: 2,
          child: Text(
            trailingText,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF263244),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ConfigSwitchTile extends StatelessWidget {
  const _ConfigSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
    );
  }
}

class WorkModePage extends StatefulWidget {
  const WorkModePage({
    super.key,
    required this.controller,
    required this.active,
  });

  final ClientController controller;
  final bool active;

  @override
  State<WorkModePage> createState() => _WorkModePageState();
}

class _WorkModePageState extends State<WorkModePage> {
  final ScrollController logScrollController = ScrollController();
  final List<String> logs = <String>[];

  int startFans = 0;
  int lastFans = 0;
  int addedFans = 0;

  @override
  void initState() {
    super.initState();
    _resetCounter();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant WorkModePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) {
      setState(_resetCounter);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    logScrollController.dispose();
    super.dispose();
  }

  void _resetCounter() {
    startFans = widget.controller.displayFans;
    lastFans = widget.controller.displayFans;
    addedFans = 0;
    logs.clear();
    logs.add('${_formatLogTime(DateTime.now())}：工作模式已启动，等待粉丝数据更新');
  }

  void _handleControllerChanged() {
    if (!mounted || !widget.active || !widget.controller.loggedIn) {
      return;
    }

    final currentFans = widget.controller.displayFans;
    if (currentFans <= lastFans) {
      return;
    }

    final increment = currentFans - lastFans;
    lastFans = currentFans;
    addedFans = currentFans - startFans;
    logs.add(
      '${_formatLogTime(DateTime.now())}：粉丝数新增 +$increment，累计新增 $addedFans',
    );
    if (logs.length > 200) {
      logs.removeRange(0, logs.length - 200);
    }

    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!logScrollController.hasClients) {
        return;
      }
      logScrollController.animateTo(
        logScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  String _formatLogTime(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    final millisecond = value.millisecond.toString().padLeft(3, '0');
    return '$year-$month-$day $hour:$minute:$second:$millisecond';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          color: Colors.white,
          child: Column(
            children: [
              Text(
                '$addedFans',
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: const Color(0xFF152033),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '本次进入页面后新增粉丝',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF101828),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF263244)),
              ),
              child: ListView.builder(
                controller: logScrollController,
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      logs[index],
                      style: const TextStyle(
                        color: Color(0xFFE6EDF7),
                        fontSize: 13,
                        height: 1.45,
                        fontFamily: 'monospace',
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class MinePage extends StatefulWidget {
  const MinePage({super.key, required this.controller});

  final ClientController controller;

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  late final TextEditingController usernameController;
  final TextEditingController passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    usernameController = TextEditingController(
      text: widget.controller.username,
    );
  }

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final currentAccount = controller.account;

    if (controller.loggedIn) {
      return RefreshIndicator(
        onRefresh: controller.refreshNow,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            controller.username.isEmpty
                                ? '我的账号'
                                : controller.username,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: controller.logout,
                          icon: const Icon(Icons.logout),
                          tooltip: '退出登录',
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '${controller.displayFans}',
                      style: theme.textTheme.displayMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF152033),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '当前粉丝数',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (currentAccount == null) ...[
                      const SizedBox(height: 16),
                      const Text('暂无可展示账号'),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _BrandHeader(),
        const SizedBox(height: 22),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('管理员登录', style: theme.textTheme.titleLarge),
                const SizedBox(height: 20),
                TextField(
                  controller: usernameController,
                  decoration: const InputDecoration(
                    labelText: '管理员账号',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: passwordController,
                  decoration: const InputDecoration(
                    labelText: '管理员密码',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => controller.login(
                    usernameController.text,
                    passwordController.text,
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: controller.busy
                      ? null
                      : () => controller.login(
                          usernameController.text,
                          passwordController.text,
                        ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: controller.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('登录'),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请联系管理员获取账号信息')),
                    );
                  },
                  icon: const Icon(Icons.support_agent),
                  label: const Text('联系我们'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _StatusNotice(message: controller.statusMessage),
      ],
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.trending_up, color: Colors.white),
        ),
        const SizedBox(height: 18),
        Text(
          'Tiktok',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '实时查看账号数据和设备状态',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final currentAccount = controller.account;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          controller.username.isEmpty ? 'Tiktok' : controller.username,
        ),
        actions: [
          IconButton(
            onPressed: controller.busy ? null : controller.refreshNow,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
          IconButton(
            onPressed: controller.logout,
            icon: const Icon(Icons.logout),
            tooltip: '退出登录',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.refreshNow,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (currentAccount == null)
              const _EmptyState()
            else
              AccountCard(
                account: currentAccount,
                displayFans: controller.displayFans,
              ),
            const SizedBox(height: 14),
            StatusCard(controller: controller),
          ],
        ),
      ),
    );
  }
}

class StatusCard extends StatelessWidget {
  const StatusCard({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('设备状态', style: theme.textTheme.titleMedium),
                ),
                if (controller.busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _InfoLine(label: '当前设备', value: controller.deviceName),
            const SizedBox(height: 8),
            _InfoLine(label: '控制状态', value: controller.controlStatusName),
            const SizedBox(height: 8),
            _InfoLine(
              label: '同步时间',
              value: controller.lastSyncTime.isEmpty
                  ? '-'
                  : controller.lastSyncTime,
            ),
            const SizedBox(height: 8),
            _InfoLine(label: '同步信息', value: controller.statusMessage),
          ],
        ),
      ),
    );
  }
}

class AccountCard extends StatelessWidget {
  const AccountCard({
    super.key,
    required this.account,
    required this.displayFans,
  });

  final AccountModel account;
  final int displayFans;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.accountName,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        account.growthStarted ? '客户端已启动增长' : '等待客户端导入启动',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: account.growthStarted
                              ? const Color(0xFF147850)
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusBadge(
                  text: account.growthStarted ? '已启动' : '待启动',
                  active: account.growthStarted,
                ),
              ],
            ),
            const SizedBox(height: 22),
            Text(
              '$displayFans',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF152033),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '当前粉丝数',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            _MetricTile(
              label: '更新时间',
              value: _formatShortDate(account.updatedAt),
            ),
            if (account.remark.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                account.remark,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatShortDate(String value) {
    if (value.isEmpty) return '-';
    return value.replaceFirst('T', ' ').split('.').first;
  }
}

class DisabledPage extends StatelessWidget {
  const DisabledPage({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101828),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.block, color: Colors.white, size: 72),
                const SizedBox(height: 20),
                const Text(
                  '应用正在关闭',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  controller.statusMessage,
                  style: const TextStyle(color: Color(0xFFD0D5DD)),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WhiteScreenPage extends StatelessWidget {
  const WhiteScreenPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: Colors.white);
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F9FC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E7F2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text, required this.active});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFE8F7EF) : const Color(0xFFEFF3F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: active ? const Color(0xFF147850) : const Color(0xFF536174),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StatusNotice extends StatelessWidget {
  const _StatusNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF4D39B)),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: const Color(0xFF6F4E12),
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 78,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF152033),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.inbox_outlined, size: 48),
            const SizedBox(height: 12),
            Text('暂无可展示账号', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '请确认后台已创建账号，并使用该账号登录当前设备。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
