import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:url_launcher/url_launcher.dart';
import 'package:yandex_mapkit/yandex_mapkit.dart';
import 'package:geolocator/geolocator.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';

// Cached colors for performance
const _white95 = Color(0xF2FFFFFF);
const _white92 = Color(0xEBFFFFFF);
const _white90 = Color(0xE6FFFFFF);
const _white88 = Color(0xE0FFFFFF);
const _white85 = Color(0xD9FFFFFF);
const _white80 = Color(0xCCFFFFFF);
const _white78 = Color(0xC7FFFFFF);
const _white75 = Color(0xBFFFFFFF);
const _white70 = Color(0xB3FFFFFF);
const _white68 = Color(0xADFFFFFF);
const _white65 = Color(0xA6FFFFFF);
const _white60 = Color(0x99FFFFFF);
const _white50 = Color(0x80FFFFFF);
const _white12 = Color(0x1FFFFFFF);
const _white10 = Color(0x1AFFFFFF);
const _white06 = Color(0x0FFFFFFF);
const _white04 = Color(0x0AFFFFFF);
const _white18 = Color(0x2EFFFFFF);
const _black45 = Color(0x73000000);
const _black42 = Color(0x6B000000);
const _black40 = Color(0x66000000);
const _black35 = Color(0x59000000);
const _black55 = Color(0x8C000000);
const _black58 = Color(0x94000000);
const _white55 = Color(0x8CFFFFFF);
const _white08 = Color(0x14FFFFFF);
const _white35 = Color(0x59FFFFFF);
const _white72 = Color(0xB8FFFFFF);
const _white84 = Color(0xD6FFFFFF);
const _white98 = Color(0xFAFFFFFF);
const _white82 = Color(0xD1FFFFFF);
const _black65 = Color(0xA6000000);
const _white40 = Color(0x66FFFFFF);
const _black08 = Color(0x14000000);

class _FastPageRoute<T> extends PageRouteBuilder<T> {
  _FastPageRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => builder(context),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: const Duration(milliseconds: 100),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (secondaryAnimation.status == AnimationStatus.forward) {
              return child;
            }
            return FadeTransition(opacity: animation, child: child);
          },
        );
}

const _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://194.67.84.155',
);

String _formatRubAmount(num? value) {
  final n = (value ?? 0).round();
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final left = s.length - i;
    b.write(s[i]);
    if (left > 1 && left % 3 == 1) b.write(' ');
  }
  final v = n < 0 ? '-${b.toString()}' : b.toString();
  return '$v ₽';
}

bool _isSameCalendarDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}
const _accentColor = Color(0xFFFF2D55);
const _accentDark = Color(0xFFFF3D00);
const _activeOrderPrefsKey = 'driver_active_order_v1';
const _activeOrderStateKey = 'driver_active_order_state_v1';
const _preorderPrefsKey = 'driver_preorder_v1';
const _iosPushChannel = MethodChannel('ru.prostotaxi.driver/push');

final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
final AudioPlayer _orderNotificationPlayer = AudioPlayer();
const AndroidNotificationChannel _orderChannel = AndroidNotificationChannel(
  'orders',
  'Новые заказы',
  description: 'Уведомления о новых заказах',
  importance: Importance.high,
);

Future<void> _initNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );
  await _notifications.initialize(settings: initSettings);
  final android = _notifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(_orderChannel);
  await android?.requestNotificationsPermission();
  final ios = _notifications.resolvePlatformSpecificImplementation<
      IOSFlutterLocalNotificationsPlugin>();
  await ios?.requestPermissions(alert: true, badge: true, sound: true);
}

Future<String?> _requestIosPushToken() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
  try {
    await _iosPushChannel.invokeMethod('requestPushPermissions');
    for (var attempt = 0; attempt < 5; attempt++) {
      final token = await _iosPushChannel.invokeMethod<String>('getPushToken');
      if (token != null && token.trim().isNotEmpty) {
        return token.trim();
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  } catch (_) {}
  return null;
}

Future<void> _syncDriverPushToken(String authToken) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  try {
    final token = await _requestIosPushToken();
    if (token == null || token.isEmpty) return;
    await http
        .post(
          Uri.parse('$_apiBaseUrl/api/driver/push-token'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $authToken',
          },
          body: jsonEncode({
            'token': token,
            'platform': 'ios',
          }),
        )
        .timeout(const Duration(seconds: 10));
  } catch (_) {}
}

NotificationDetails _orderNotificationDetails() {
  return NotificationDetails(
    android: AndroidNotificationDetails(
      _orderChannel.id,
      _orderChannel.name,
      channelDescription: _orderChannel.description,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
    ),
    iOS: const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    ),
  );
}

Future<void> _playIncomingOrderSound() async {
  try {
    await _orderNotificationPlayer.stop();
    await _orderNotificationPlayer.setReleaseMode(ReleaseMode.stop);
    await _orderNotificationPlayer.play(AssetSource('sounds/fantastic_siren.mp3'));
  } catch (_) {}
}

Future<void> _stopIncomingOrderSound() async {
  try {
    await _orderNotificationPlayer.stop();
  } catch (_) {}
}

class _AuthStore {
  static const _tokenKey = 'auth_token';

  Future<String?> readToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    if (token == null || token.trim().isEmpty) return null;
    return token;
  }

  Future<void> writeToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }
}

class _AuthApi {
  const _AuthApi();

  Uri _u(String path) => Uri.parse('$_apiBaseUrl$path');

  String _normalizePhone(String input) {
    var digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('8')) {
      digits = '7${digits.substring(1)}';
    }
    if (digits.length == 10) {
      digits = '7$digits';
    }
    return digits;
  }

  String _formatPhoneForDisplay(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('7')) {
      return '+7 (${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7, 9)}-${digits.substring(9)}';
    }
    return raw;
  }

  String _normalizeCode(String input) {
    return input.replaceAll(RegExp(r'\D'), '');
  }

  String _extractToken(Map<String, dynamic> map) {
    final candidates = <Object?>[
      map['token'],
      map['accessToken'],
      map['access_token'],
      map['jwt'],
    ];
    for (final c in candidates) {
      if (c is String && c.trim().isNotEmpty) return c;
    }
    throw Exception('No token');
  }

  Future<int> requestOtp({required String phone}) async {
    final normalizedPhone = _normalizePhone(phone);
    final res = await http.post(
      _u('/api/auth/otp/request'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone': normalizedPhone}),
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final map = (jsonDecode(res.body) as Map).cast<String, dynamic>();
      final ttl = map['ttlSec'];
      return (ttl is num) ? ttl.toInt() : 300;
    }

    throw _ApiException(statusCode: res.statusCode, body: res.body);
  }

  Future<String> verifyOtp({
    required String phone,
    required String code,
  }) async {
    final normalizedPhone = _normalizePhone(phone);
    final normalizedCode = _normalizeCode(code);
    final res = await http.post(
      _u('/api/auth/otp/verify'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone': normalizedPhone, 'code': normalizedCode, 'role': 'driver'}),
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final map = (jsonDecode(res.body) as Map).cast<String, dynamic>();
      return _extractToken(map);
    }

    throw _ApiException(statusCode: res.statusCode, body: res.body);
  }
}

class _ApiException implements Exception {
  _ApiException({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  String toString() => 'ApiException($statusCode): $body';
}

String _apiErrorMessage(Object error) {
  if (error is _ApiException) {
    if (error.statusCode == 429) {
      return 'Слишком часто. Подождите минуту';
    }
    if (error.statusCode == 502) {
      return 'СМС сервис недоступен. Попробуйте позже';
    }
    try {
      final map = jsonDecode(error.body) as Map<String, dynamic>;
      final msg = map['message'];
      if (msg is String && msg.trim().isNotEmpty) return msg;
    } catch (_) {}
  }
  return 'Не удалось отправить код';
}

class _AuthGate extends StatefulWidget {
  const _AuthGate({required this.childBuilder});

  final Widget Function(String token, Future<void> Function() logout) childBuilder;

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  final _store = _AuthStore();
  String? _token;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = await _store.readToken();
    if (!mounted) return;
    setState(() {
      _token = token;
      _loading = false;
    });
  }

  Future<void> _onLoggedIn(String token) async {
    await _store.writeToken(token);
    if (!mounted) return;
    setState(() {
      _token = token;
    });
  }

  Future<void> _logout() async {
    await _store.clear();
    if (!mounted) return;
    setState(() {
      _token = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF05060A),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final token = _token;
    if (token == null) {
      return _LoginPage(onLoggedIn: _onLoggedIn);
    }

    return widget.childBuilder(token, _logout);
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.onLoggedIn});

  final Future<void> Function(String token) onLoggedIn;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  final _api = const _AuthApi();
  final _phone = TextEditingController();
  final _code = TextEditingController();

  bool _requesting = false;
  bool _verifying = false;
  bool _codeStage = false;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _requestOtp() async {
    setState(() {
      _requesting = true;
    });
    try {
      await _api.requestOtp(phone: _phone.text);
      if (!mounted) return;
      setState(() {
        _codeStage = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Код отправлен')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_apiErrorMessage(e))),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _requesting = false;
      });
    }
  }

  Future<void> _verifyOtp() async {
    setState(() {
      _verifying = true;
    });
    try {
      final token = await _api.verifyOtp(phone: _phone.text, code: _code.text);
      await widget.onLoggedIn(token);
    } catch (e) {
      if (!mounted) return;
      final msg = (e is _ApiException && e.statusCode == 429)
          ? 'Слишком часто. Подождите и попробуйте снова'
          : 'Неверный код';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _verifying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05060A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Вход водителя',
                style: TextStyle(
                  color: _white95,
                  fontWeight: FontWeight.w900,
                  fontSize: 26,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: _white92, fontWeight: FontWeight.w800),
                decoration: InputDecoration(
                  labelText: 'Телефон',
                  labelStyle: TextStyle(color: _white60, fontWeight: FontWeight.w800),
                  filled: true,
                  fillColor: _white06,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                ),
              ),
              if (_codeStage) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: _white92, fontWeight: FontWeight.w800),
                  decoration: InputDecoration(
                    labelText: 'Код (4 цифры)',
                    labelStyle: TextStyle(color: _white60, fontWeight: FontWeight.w800),
                    filled: true,
                    fillColor: _white06,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                  ),
                ),
              ],
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      _FastPageRoute<void>(builder: (_) => _DriverPrivacyPolicyScreen()),
                    );
                  },
                  child: Text(
                    'Регистрируясь, вы даёте согласие на обработку персональных данных и соглашаетесь с политикой конфиденциальности.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
              if (!_codeStage)
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _requesting ? null : _requestOtp,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accentColor,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    child: _requesting
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Получить код', style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                )
              else
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _verifying ? null : _verifyOtp,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accentColor,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    child: _verifying
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Войти', style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DriverPrivacyPolicyScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    Future<void> openUrl(String url) async {
      final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }

    return Scaffold(
      backgroundColor: const Color(0xFF05060A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Политика конфиденциальности',
          style: TextStyle(color: _white95, fontWeight: FontWeight.w900, fontSize: 16),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(
            color: _black35,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _white10),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Использование приложения водителя означает согласие с условиями политики конфиденциальности и согласие на обработку персональных данных при регистрации и работе в приложении. ',
                style: TextStyle(color: _white85, fontSize: 14, height: 1.45),
              ),
              const SizedBox(height: 12),
              _DriverPolicyLink(
                label: 'Политика конфиденциальности',
                onTap: () => openUrl('https://www.trezv777.ru/privacy'),
              ),
              _DriverPolicyLink(
                label: 'Согласие на обработку персональных данных',
                onTap: () => openUrl('https://www.trezv777.ru/personal-data'),
              ),
              const SizedBox(height: 12),
              Text(
                'Водители при регистрации дают согласие на обработку персональных данных в соответствии с указанными документами.',
                style: TextStyle(
                  color: _white90,
                  fontSize: 14,
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DriverPolicyLink extends StatelessWidget {
  const _DriverPolicyLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF4A9EFF),
              fontSize: 14,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
    );
  }
}

class _DriverShell extends StatefulWidget {
  const _DriverShell({required this.token, required this.onLogout});

  final String token;
  final Future<void> Function() onLogout;

  @override
  State<_DriverShell> createState() => _DriverShellState();
}

class _DriverShellState extends State<_DriverShell> {
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MyHomePage(title: 'Водитель', token: widget.token, onLogout: widget.onLogout),
        const SizedBox.shrink(),
      ],
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initNotifications();
  runApp(const MyApp());
}

class _ProfileTileEarnings extends StatelessWidget {
  const _ProfileTileEarnings({
    required this.earnedRub,
    required this.earnedGross,
    required this.earnedCommission,
  });

  final int earnedRub;
  final int earnedGross;
  final int earnedCommission;

  String _formatRub(int value) {
    final s = value.abs().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final left = s.length - i;
      buffer.write(s[i]);
      if (left > 1 && left % 3 == 1) buffer.write(' ');
    }
    return value < 0 ? '-${buffer.toString()}' : buffer.toString();
  }

  String _rub(int? value) => '${_formatRub((value ?? 0))} ₽';

  @override
  Widget build(BuildContext context) {
    return _ProfileTileBase(
      title: 'Заработок',
      icon: Icons.account_balance_wallet_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _rub(earnedRub),
            style: TextStyle(
              color: _white95,
              fontWeight: FontWeight.w900,
              fontSize: 22,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Общий: ${_rub(earnedGross)}',
                  style: TextStyle(
                    color: _white60,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Комиссия: ${_rub(earnedCommission)}',
                  style: TextStyle(
                    color: const Color(0xFFFF6B6B).withValues(alpha: 0.85),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Чистыми: ${_rub(earnedRub)}',
                  style: TextStyle(
                    color: Colors.greenAccent.shade400.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionResultCard extends StatelessWidget {
  const _ActionResultCard({required this.state});

  final _ActionResultOverlay state;

  @override
  Widget build(BuildContext context) {
    final (title, circleColor, icon) = switch (state) {
      _ActionResultOverlay.none => ('', Colors.transparent, Icons.circle),
      _ActionResultOverlay.accepted => ('Принято', const Color(0xFF1B7F3A), Icons.check),
      _ActionResultOverlay.declined => ('Отклонено', const Color(0xFFB90E0E), Icons.close),
      _ActionResultOverlay.alreadyTaken => ('Заказ уже принят', const Color(0xFFB07A00), Icons.person),
      _ActionResultOverlay.orderCanceled => ('Заказ отменён', const Color(0xFFB90E0E), Icons.cancel),
      _ActionResultOverlay.earningsLimit => ('Оплатите комиссию', const Color(0xFFB07A00), Icons.lock),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
        ),
        border: Border.all(color: const Color(0xFF1C2030), width: 1),
        boxShadow: [
          BoxShadow(
            color: _black55,
            blurRadius: 14,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: circleColor,
            ),
            child: Icon(icon, color: Colors.white, size: 34),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: _white95,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DriverProfileData {
  const _DriverProfileData({
    required this.rating,
    required this.acceptedOrders,
    required this.trips,
    required this.earnedRub,
    required this.fullName,
    required this.phone,
    required this.inn,
    required this.passport,
    required this.docsSigned,
    required this.registrationStatus,
    required this.referralCount,
    required this.referralCode,
    required this.bonusBalance,
    this.avatarBytes,
    this.passportFrontBytes,
    this.passportRegBytes,
    this.driverLicenseBackBytes,
    this.selfieBytes,
    this.earnedGross = 0,
    this.earnedCommission = 0,
    this.earningsLimit = 15000,
    this.limitReached = false,
  });

  final double rating;
  final int acceptedOrders;
  final int trips;
  final int earnedRub;
  final int earnedGross;
  final int earnedCommission;
  final int earningsLimit;
  final bool limitReached;
  final String fullName;
  final String phone;
  final String inn;
  final String passport;
  final bool docsSigned;
  final String registrationStatus;
  final int referralCount;
  final String referralCode;
  final int bonusBalance;
  final Uint8List? avatarBytes;
  final Uint8List? passportFrontBytes;
  final Uint8List? passportRegBytes;
  final Uint8List? driverLicenseBackBytes;
  final Uint8List? selfieBytes;

  _DriverProfileData copyWith({
    double? rating,
    int? acceptedOrders,
    int? trips,
    int? earnedRub,
    int? earnedGross,
    int? earnedCommission,
    int? earningsLimit,
    bool? limitReached,
    String? fullName,
    String? phone,
    String? inn,
    String? passport,
    bool? docsSigned,
    String? registrationStatus,
    int? referralCount,
    String? referralCode,
    int? bonusBalance,
    Uint8List? avatarBytes,
    Uint8List? passportFrontBytes,
    Uint8List? passportRegBytes,
    Uint8List? driverLicenseBackBytes,
    Uint8List? selfieBytes,
    bool clearAvatar = false,
  }) {
    return _DriverProfileData(
      rating: rating ?? this.rating,
      acceptedOrders: acceptedOrders ?? this.acceptedOrders,
      trips: trips ?? this.trips,
      earnedRub: earnedRub ?? this.earnedRub,
      earnedGross: earnedGross ?? this.earnedGross,
      earnedCommission: earnedCommission ?? this.earnedCommission,
      earningsLimit: earningsLimit ?? this.earningsLimit,
      limitReached: limitReached ?? this.limitReached,
      fullName: fullName ?? this.fullName,
      phone: phone ?? this.phone,
      inn: inn ?? this.inn,
      passport: passport ?? this.passport,
      docsSigned: docsSigned ?? this.docsSigned,
      registrationStatus: registrationStatus ?? this.registrationStatus,
      referralCount: referralCount ?? this.referralCount,
      referralCode: referralCode ?? this.referralCode,
      bonusBalance: bonusBalance ?? this.bonusBalance,
      avatarBytes: clearAvatar ? null : (avatarBytes ?? this.avatarBytes),
      passportFrontBytes: passportFrontBytes ?? this.passportFrontBytes,
      passportRegBytes: passportRegBytes ?? this.passportRegBytes,
      driverLicenseBackBytes: driverLicenseBackBytes ?? this.driverLicenseBackBytes,
      selfieBytes: selfieBytes ?? this.selfieBytes,
    );
  }
}

class _DriverProfilePage extends StatefulWidget {
  const _DriverProfilePage({
    required this.online,
    required this.onOnlineChanged,
    required this.onLogout,
    required this.token,
    required this.driverPhone,
  });

  final bool online;
  final ValueChanged<bool> onOnlineChanged;
  final Future<void> Function() onLogout;
  final String token;
  final String? driverPhone;

  @override
  State<_DriverProfilePage> createState() => _DriverProfilePageState();
}

class _DriverProfilePageState extends State<_DriverProfilePage> {
  static const _profilePrefsKey = 'driver_profile_v1';

  Uint8List? _decodeBase64(dynamic value) {
    if (value == null) return null;
    final s = value.toString();
    if (s.isEmpty) return null;
    try { return base64Decode(s); } catch (_) { return null; }
  }

  int _parseInt(dynamic value, int fallback) {
    if (value is num) return value.toInt();
    final s = value?.toString() ?? '';
    final asInt = int.tryParse(s);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(s);
    if (asDouble != null) return asDouble.toInt();
    return fallback;
  }

  Future<http.Response> _profileAuthGet(Uri uri) async {
    final res = await http.get(
      uri,
      headers: {'Authorization': 'Bearer ${widget.token}'},
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode == 401) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сессия истекла. Войдите заново.')),
        );
      }
      await widget.onLogout();
    }
    return res;
  }

  Future<http.Response> _profileAuthPost(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    final response = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer ${widget.token}',
        ...?headers,
      },
      body: body,
    ).timeout(const Duration(seconds: 60));
    if (response.statusCode == 401) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сессия истекла. Войдите заново.')),
        );
      }
      await widget.onLogout();
    }
    return response;
  }

  _DriverProfileData _data = const _DriverProfileData(
    rating: 0,
    acceptedOrders: 0,
    trips: 0,
    earnedRub: 0,
    fullName: '',
    phone: '',
    inn: '',
    passport: '',
    docsSigned: false,
    registrationStatus: 'incomplete',
    referralCount: 0,
    referralCode: '',
    bonusBalance: 0,
  );
  late bool _online;

  @override
  void initState() {
    super.initState();
    _online = widget.online;
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profilePrefsKey);
    if (!mounted) return;
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final avatarBase64 = map['avatarBase64']?.toString();
        setState(() {
          _data = _data.copyWith(
            rating: double.tryParse(map['rating']?.toString() ?? '') ?? _data.rating,
            acceptedOrders: _parseInt(map['acceptedOrders'], _data.acceptedOrders),
            trips: _parseInt(map['trips'], _data.trips),
            earnedRub: _parseInt(map['earnedRub'], _data.earnedRub),
            fullName: (map['fullName']?.toString() ?? _data.fullName),
            phone: (map['phone']?.toString() ?? _data.phone),
            inn: (map['inn']?.toString() ?? _data.inn),
            passport: (map['passport']?.toString() ?? _data.passport),
            docsSigned: map['docsSigned'] == true,
            registrationStatus: (map['registrationStatus']?.toString() ?? _data.registrationStatus),
            referralCount: _parseInt(map['referralCount'], _data.referralCount),
            referralCode: (map['referralCode']?.toString() ?? _data.referralCode),
            bonusBalance: _parseInt(map['bonusBalance'], _data.bonusBalance),
            avatarBytes: avatarBase64 == null || avatarBase64.isEmpty
                ? _data.avatarBytes
                : base64Decode(avatarBase64),
            passportFrontBytes: _decodeBase64(map['passportFrontBase64']) ?? _data.passportFrontBytes,
            passportRegBytes: _decodeBase64(map['passportRegBase64']) ?? _data.passportRegBytes,
            driverLicenseBackBytes: _decodeBase64(map['driverLicenseBackBase64']) ?? _data.driverLicenseBackBytes,
            selfieBytes: _decodeBase64(map['selfieBase64']) ?? _data.selfieBytes,
          );
        });
      } catch (_) {}
    }

    final phone = widget.driverPhone;
    if (phone == null || phone.trim().isEmpty) return;
    await _fetchProfileFromServer(phone.trim());
  }

  bool _serverLoaded = false;

  Future<void> _fetchProfileFromServer(String phone) async {
    try {
      final uri = Uri.parse('$_apiBaseUrl/api/driver/profile')
          .replace(queryParameters: {'phone': phone});
      debugPrint('[PROFILE] fetch: $uri');
      final res = await _profileAuthGet(uri);
      debugPrint('[PROFILE] status=${res.statusCode} body=${res.body.length > 200 ? res.body.substring(0, 200) : res.body}');
      if (res.statusCode == 401) return;
      if (res.statusCode < 200 || res.statusCode >= 300) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка загрузки профиля: ${res.statusCode}')),
          );
        }
        return;
      }
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final profile = map['profile'];
      final bonus = map['bonus'] as Map?;
      if (profile is! Map) return;
      final avatarBase64 = profile['avatarBase64']?.toString();
      final rating = double.tryParse(profile['rating']?.toString() ?? '');
      final acceptedOrders = _parseInt(profile['acceptedOrders'], _data.acceptedOrders);
      final trips = _parseInt(profile['trips'], _data.trips);
      final earnedRub = _parseInt(profile['earnedRub'], _data.earnedRub);
      final earnedGross = _parseInt(profile['earnedGross'], _data.earnedGross);
      final earnedCommission = _parseInt(profile['earnedCommission'], _data.earnedCommission);
      final earningsLimit = _parseInt(profile['earningsLimit'], _data.earningsLimit);
      final limitReached = profile['limitReached'] == true;
      if (!mounted) return;
      setState(() {
        _data = _data.copyWith(
          rating: rating ?? _data.rating,
          acceptedOrders: acceptedOrders,
          trips: trips,
          earnedRub: earnedRub,
          earnedGross: earnedGross,
          earnedCommission: earnedCommission,
          earningsLimit: earningsLimit,
          limitReached: limitReached,
          fullName: (profile['fullName']?.toString() ?? _data.fullName),
          phone: (profile['phone']?.toString() ?? _data.phone),
          inn: (profile['inn']?.toString() ?? _data.inn),
          passport: (profile['passport']?.toString() ?? _data.passport),
          docsSigned: profile['docsSigned'] == true,
          registrationStatus:
              (profile['registrationStatus']?.toString() ?? _data.registrationStatus),
          referralCount: _parseInt(profile['referralCount'], _data.referralCount),
          referralCode: (profile['referralCode']?.toString() ?? _data.referralCode),
          bonusBalance: _parseInt(bonus?['available'], _data.bonusBalance),
          avatarBytes: avatarBase64 == null || avatarBase64.isEmpty
              ? _data.avatarBytes
              : base64Decode(avatarBase64),
          passportFrontBytes: _decodeBase64(profile['passportFrontBase64']) ?? _data.passportFrontBytes,
          passportRegBytes: _decodeBase64(profile['passportRegBase64']) ?? _data.passportRegBytes,
          driverLicenseBackBytes: _decodeBase64(profile['driverLicenseBackBase64']) ?? _data.driverLicenseBackBytes,
          selfieBytes: _decodeBase64(profile['selfieBase64']) ?? _data.selfieBytes,
        );
      });
      // Обновляем локальный кеш серверными данными
      final cacheMap = <String, dynamic>{
        'rating': _data.rating,
        'acceptedOrders': _data.acceptedOrders,
        'trips': _data.trips,
        'earnedRub': _data.earnedRub,
        'fullName': _data.fullName,
        'phone': _data.phone,
        'inn': _data.inn,
        'passport': _data.passport,
        'docsSigned': _data.docsSigned,
        'registrationStatus': _data.registrationStatus,
        'referralCount': _data.referralCount,
        'referralCode': _data.referralCode,
        'bonusBalance': _data.bonusBalance,
        'avatarBase64': _data.avatarBytes != null ? base64Encode(_data.avatarBytes!) : null,
        'passportFrontBase64': _data.passportFrontBytes != null ? base64Encode(_data.passportFrontBytes!) : null,
        'passportRegBase64': _data.passportRegBytes != null ? base64Encode(_data.passportRegBytes!) : null,
        'driverLicenseBackBase64': _data.driverLicenseBackBytes != null ? base64Encode(_data.driverLicenseBackBytes!) : null,
        'selfieBase64': _data.selfieBytes != null ? base64Encode(_data.selfieBytes!) : null,
      };
      SharedPreferences.getInstance().then((p) => p.setString(_profilePrefsKey, jsonEncode(cacheMap)));
      if (mounted) setState(() => _serverLoaded = true);
    } catch (e) {
      debugPrint('[PROFILE] error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось загрузить профиль: $e')),
        );
      }
    }
  }

  Future<void> _saveProfile(_DriverProfileData data) async {
    final phoneDigits = data.phone.replaceAll(RegExp(r'\D'), '');
    final map = <String, dynamic>{
      'rating': data.rating,
      'acceptedOrders': data.acceptedOrders,
      'trips': data.trips,
      'earnedRub': data.earnedRub,
      'fullName': data.fullName,
      'phone': phoneDigits.isNotEmpty ? phoneDigits : data.phone,
      'inn': data.inn,
      'passport': data.passport,
      'docsSigned': data.docsSigned,
      'registrationStatus': data.registrationStatus,
      'referralCount': data.referralCount,
      'referralCode': data.referralCode,
      'bonusBalance': data.bonusBalance,
      'avatarBase64': data.avatarBytes == null ? null : base64Encode(data.avatarBytes!),
      'passportFrontBase64': data.passportFrontBytes == null ? null : base64Encode(data.passportFrontBytes!),
      'passportRegBase64': data.passportRegBytes == null ? null : base64Encode(data.passportRegBytes!),
      'driverLicenseBackBase64': data.driverLicenseBackBytes == null ? null : base64Encode(data.driverLicenseBackBytes!),
      'selfieBase64': data.selfieBytes == null ? null : base64Encode(data.selfieBytes!),
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profilePrefsKey, jsonEncode(map));

    final phone = widget.driverPhone;
    if (phone == null || phone.trim().isEmpty) return;
    try {
      final serverMap = Map<String, dynamic>.from(map);
      if (data.registrationStatus == 'completed') {
        serverMap.remove('registrationStatus');
      }
      final uri = Uri.parse('$_apiBaseUrl/api/driver/profile');
      final resp = await _profileAuthPost(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'phone': phone.trim(), ...serverMap}),
      );
      debugPrint('[PROFILE SAVE] status=${resp.statusCode} body=${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}');
      if (resp.statusCode == 401) return;
      if (resp.statusCode != 200 && resp.statusCode != 201) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка отправки профиля: ${resp.statusCode}')),
          );
        }
      }
    } catch (e) {
      debugPrint('[PROFILE SAVE] error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка сети: $e')),
        );
      }
    }
  }

  Future<void> _openEdit() async {
    if (_data.registrationStatus == 'pending') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заявка на проверке. Редактирование недоступно.')),
      );
      return;
    }
    final result = await Navigator.of(context).push<_DriverProfileData>(
      _FastPageRoute(
        builder: (context) => _DriverProfileEditPage(initial: _data),
      ),
    );
    if (!mounted) return;
    if (result == null) return;

    setState(() {
      _data = result;
    });
    unawaited(_saveProfile(result));
  }

  @override
  Widget build(BuildContext context) {
    final isPending = _data.registrationStatus == 'pending';
    return Scaffold(
      backgroundColor: const Color(0xFF05060A),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _TopIconButton(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  _TopIconButton(
                    icon: Icons.refresh,
                    onTap: () {
                      final phone = widget.driverPhone;
                      if (phone != null && phone.trim().isNotEmpty) {
                        _fetchProfileFromServer(phone.trim());
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  _TopTextButton(
                    title: 'Изменить',
                    onTap: isPending ? null : _openEdit,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: _openEdit,
                    child: Stack(
                      children: [
                        _AvatarCircle(bytes: _data.avatarBytes, size: 80),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFFF3D00),
                              border: Border.all(color: const Color(0xFF05060A), width: 2),
                            ),
                            child: const Icon(Icons.camera_alt, color: Colors.white, size: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _data.fullName.trim().isNotEmpty ? _data.fullName.trim() : 'Водитель',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _white95,
                            fontWeight: FontWeight.w900,
                            fontSize: 20,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.driverPhone ?? '',
                          style: TextStyle(
                            color: _white60,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 6),
                        GestureDetector(
                          onTap: _openEdit,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: _white10,
                            ),
                            child: Text(
                              'Изменить фото',
                              style: TextStyle(
                                color: _white80,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: _white06,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _white10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.wifi_tethering, color: _white80),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _online ? 'Статус: Онлайн' : 'Статус: Оффлайн',
                        style: TextStyle(
                          color: _white92,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Switch.adaptive(
                      value: _online,
                      activeColor: _accentColor,
                      onChanged: (value) {
                        setState(() {
                          _online = value;
                        });
                        widget.onOnlineChanged(value);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: _black55,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _white10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _data.registrationStatus == 'completed'
                          ? Icons.verified
                          : _data.registrationStatus == 'pending'
                              ? Icons.hourglass_top
                              : Icons.info_outline,
                      color: _data.registrationStatus == 'completed'
                          ? const Color(0xFF6DD66D)
                          : _data.registrationStatus == 'pending'
                              ? const Color(0xFFFFC857)
                              : _white70,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _data.registrationStatus == 'completed'
                                ? 'Регистрация завершена'
                                : _data.registrationStatus == 'pending'
                                    ? 'Ожидает подтверждения'
                                    : 'Регистрация не завершена',
                            style: TextStyle(
                              color: _white92,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _data.docsSigned ? 'Документы подписаны' : 'Документы не подписаны',
                            style: TextStyle(
                              color: _white60,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: isPending ? null : _openEdit,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Изменить', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _ProfileTileRating(rating: _data.rating),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ProfileTileTrips(
                        acceptedOrders: _data.acceptedOrders,
                        trips: _data.trips,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _ProfileTileEarnings(
                earnedRub: _data.earnedRub,
                earnedGross: _data.earnedGross,
                earnedCommission: _data.earnedCommission,
              ),
              const SizedBox(height: 12),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () {
                    Navigator.of(context).push(
                      _FastPageRoute<void>(
                        builder: (_) => _DriverTripsHistoryPage(
                          token: widget.token,
                          driverPhone: widget.driverPhone,
                          onLogout: widget.onLogout,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: _white06,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _white10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.history, color: _white80),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'История поездок',
                            style: TextStyle(
                              color: _white92,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: _white50),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopTextButton extends StatelessWidget {
  const _TopTextButton({required this.title, required this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: enabled ? _white08 : _white04,
            border: Border.all(color: enabled ? _white12 : _white06),
          ),
          child: Center(
            child: Text(
              title,
              style: TextStyle(
                color: enabled ? _white82 : _white50,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AvatarCircle extends StatelessWidget {
  const _AvatarCircle({required this.bytes, required this.size});

  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _black35,
        border: Border.all(color: _white10),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes == null
          ? Icon(
              Icons.person_outline,
              color: _white92,
              size: size * 0.52,
            )
          : Image.memory(bytes!, fit: BoxFit.cover),
    );
  }
}

class _ProfileTileBase extends StatelessWidget {
  const _ProfileTileBase({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const accent = _accentColor;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: _white06,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: _black35,
                  border: Border.all(color: _white10),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.28),
                      blurRadius: 12,
                      spreadRadius: 0.5,
                    ),
                  ],
                ),
                child: Icon(icon, color: accent.withValues(alpha: 0.95), size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: _white92,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _ProfileTileRating extends StatelessWidget {
  const _ProfileTileRating({required this.rating});

  final double rating;

  @override
  Widget build(BuildContext context) {
    final ratingText = rating.toStringAsFixed(1).replaceAll('.', ',');
    return _ProfileTileBase(
      title: 'Оценка',
      icon: Icons.star_border,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            ratingText,
            style: TextStyle(
              color: _white95,
              fontWeight: FontWeight.w900,
              fontSize: 22,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: _StarRatingRow(rating: rating)),
        ],
      ),
    );
  }
}

class _StarRatingRow extends StatelessWidget {
  const _StarRatingRow({required this.rating});

  final double rating;

  @override
  Widget build(BuildContext context) {
    final fullStars = rating.floor().clamp(0, 5);
    final hasHalf = (rating - fullStars) >= 0.5;
    final emptyStars = 5 - fullStars - (hasHalf ? 1 : 0);
    final starColor = _accentColor;

    final icons = <Widget>[];
    for (var i = 0; i < fullStars; i++) {
      icons.add(Icon(Icons.star, color: starColor, size: 14));
    }
    if (hasHalf) {
      icons.add(Icon(Icons.star_half, color: starColor, size: 14));
    }
    for (var i = 0; i < emptyStars; i++) {
      icons.add(Icon(Icons.star_border, color: _white35, size: 14));
    }

    return Wrap(children: icons);
  }
}

class _ProfileTileTrips extends StatelessWidget {
  const _ProfileTileTrips({required this.acceptedOrders, required this.trips});

  final int acceptedOrders;
  final int trips;

  @override
  Widget build(BuildContext context) {
    return _ProfileTileBase(
      title: 'Поездки',
      icon: Icons.route,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Принял: $acceptedOrders',
            style: TextStyle(
              color: _white90,
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Поездок: $trips',
            style: TextStyle(
              color: _white72,
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _DriverTripsHistoryPage extends StatefulWidget {
  const _DriverTripsHistoryPage({
    required this.token,
    required this.driverPhone,
    required this.onLogout,
  });

  final String token;
  final String? driverPhone;
  final Future<void> Function() onLogout;

  @override
  State<_DriverTripsHistoryPage> createState() => _DriverTripsHistoryPageState();
}

class _DriverTripsHistoryPageState extends State<_DriverTripsHistoryPage> {
  List<Map<String, dynamic>> _trips = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadTrips();
  }

  Future<void> _loadTrips() async {
    final phone = widget.driverPhone;
    if (phone == null || phone.trim().isEmpty) {
      setState(() => _loading = false);
      return;
    }
    try {
      final uri = Uri.parse('$_apiBaseUrl/api/driver/trips')
          .replace(queryParameters: {'phone': phone, 'limit': '100'});
      final res = await http.get(
        uri,
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode == 401) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Сессия истекла. Войдите заново.')),
          );
        }
        await widget.onLogout();
        return;
      }
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final map = jsonDecode(res.body) as Map<String, dynamic>;
        final trips = (map['trips'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (mounted) setState(() => _trips = trips);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось загрузить поездки: ${res.statusCode}')),
        );
      }
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сервер долго отвечает. Попробуйте снова.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка сети: $e')),
        );
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  String _fmtDate(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    final local = dt.toLocal();
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05060A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'История поездок',
          style: TextStyle(
            color: _white95,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _trips.isEmpty
              ? Center(
                  child: Text(
                    'Пока нет поездок',
                    style: TextStyle(
                      color: _white50,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(14),
                  itemCount: _trips.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final t = _trips[index];
                    final from = (t['fromAddress'] ?? '').toString();
                    final to = (t['toAddress'] ?? '').toString();
                    final price = t['priceFinal'] ?? t['priceFrom'] ?? 0;
                    final started = _fmtDate(t['startedAt']?.toString());
                    final completed = _fmtDate(t['completedAt']?.toString());
                    final status = (t['status'] ?? '').toString();
                    final scheduledAtRaw = t['scheduledAt']?.toString();
                    final scheduledAtStr = scheduledAtRaw != null ? _fmtDate(scheduledAtRaw) : null;
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _white06,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _white08),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (scheduledAtStr != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: const Color(0xFF7C3AED).withOpacity(0.15),
                                border: Border.all(color: const Color(0xFF7C3AED).withOpacity(0.3)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.schedule, size: 12, color: Color(0xFFB07CFF)),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Предзаказ на $scheduledAtStr',
                                    style: const TextStyle(
                                      color: Color(0xFFB07CFF),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  from.isNotEmpty ? from : '—',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _white90,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _formatRubAmount(price),
                                style: TextStyle(
                                  color: _accentColor,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '→ ${to.isNotEmpty ? to : '—'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _white60,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(Icons.play_arrow, size: 12, color: Colors.greenAccent.withValues(alpha: 0.6)),
                              const SizedBox(width: 4),
                              Text(started, style: TextStyle(color: _white50, fontSize: 11, fontWeight: FontWeight.w700)),
                              const SizedBox(width: 12),
                              Icon(Icons.stop, size: 12, color: Colors.redAccent.withValues(alpha: 0.6)),
                              const SizedBox(width: 4),
                              Text(completed, style: TextStyle(color: _white50, fontSize: 11, fontWeight: FontWeight.w700)),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: status == 'completed'
                                      ? Colors.greenAccent.withValues(alpha: 0.15)
                                      : Colors.orangeAccent.withValues(alpha: 0.15),
                                ),
                                child: Text(
                                  status == 'completed' ? 'Завершён' : status,
                                  style: TextStyle(
                                    color: status == 'completed' ? Colors.greenAccent : Colors.orangeAccent,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

class _DriverProfileEditPage extends StatefulWidget {
  const _DriverProfileEditPage({required this.initial});

  final _DriverProfileData initial;

  @override
  State<_DriverProfileEditPage> createState() => _DriverProfileEditPageState();
}

class _DriverProfileEditPageState extends State<_DriverProfileEditPage> {
  final _picker = ImagePicker();

  late final TextEditingController _fioController;
  late final TextEditingController _phoneController;
  late final TextEditingController _innController;
  late final TextEditingController _passportController;

  Uint8List? _avatarBytes;
  Uint8List? _passportFrontBytes;
  Uint8List? _passportRegBytes;
  Uint8List? _driverLicenseBackBytes;
  Uint8List? _selfieBytes;
  bool _docsSigned = false;
  /// Статус регистрации с сервера (не меняется локально до сохранения)
  late final String _serverRegistrationStatus;

  @override
  void initState() {
    super.initState();
    _fioController = TextEditingController(text: widget.initial.fullName);
    _phoneController = TextEditingController(text: widget.initial.phone);
    _innController = TextEditingController(text: widget.initial.inn);
    _passportController = TextEditingController(text: widget.initial.passport);
    _avatarBytes = widget.initial.avatarBytes;
    _passportFrontBytes = widget.initial.passportFrontBytes;
    _passportRegBytes = widget.initial.passportRegBytes;
    _driverLicenseBackBytes = widget.initial.driverLicenseBackBytes;
    _selfieBytes = widget.initial.selfieBytes;
    _docsSigned = widget.initial.docsSigned;
    _serverRegistrationStatus = widget.initial.registrationStatus;
  }

  @override
  void dispose() {
    _fioController.dispose();
    _phoneController.dispose();
    _innController.dispose();
    _passportController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar(ImageSource source) async {
    try {
      final file = await _picker.pickImage(source: source, imageQuality: 88);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _avatarBytes = bytes;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выбрать фото')),
      );
    }
  }

  Future<void> _pickPhoto(String title, void Function(Uint8List) onPicked) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E0E12),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(title, style: TextStyle(color: _white92, fontWeight: FontWeight.w900, fontSize: 15)),
              ),
              ListTile(
                leading: Icon(Icons.photo_camera_outlined, color: _white90),
                title: Text('Сделать фото', style: TextStyle(color: _white92, fontWeight: FontWeight.w800)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  try {
                    final file = await _picker.pickImage(source: ImageSource.camera, imageQuality: 92);
                    if (file == null) return;
                    final bytes = await file.readAsBytes();
                    if (!mounted) return;
                    setState(() => onPicked(bytes));
                  } catch (_) {}
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_library_outlined, color: _white90),
                title: Text('Из галереи', style: TextStyle(color: _white92, fontWeight: FontWeight.w800)),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  try {
                    final file = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 92);
                    if (file == null) return;
                    final bytes = await file.readAsBytes();
                    if (!mounted) return;
                    setState(() => onPicked(bytes));
                  } catch (_) {}
                },
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAvatarSourceMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E0E12),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.photo_library_outlined, color: _white90),
                title: Text(
                  'Загрузить из Галереи',
                  style: TextStyle(color: _white92, fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickAvatar(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: Icon(Icons.photo_camera_outlined, color: _white90),
                title: Text(
                  'Сделать фото',
                  style: TextStyle(color: _white92, fontWeight: FontWeight.w800),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickAvatar(ImageSource.camera);
                },
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  void _save() {
    // Если регистрация уже подтверждена админом — не трогаем статус
    if (_serverRegistrationStatus == 'completed') {
      final next = widget.initial.copyWith(
        fullName: _fioController.text,
        phone: _phoneController.text,
        inn: _innController.text,
        passport: _passportController.text,
        docsSigned: _docsSigned,
        registrationStatus: 'completed',
        avatarBytes: _avatarBytes,
        passportFrontBytes: _passportFrontBytes,
        passportRegBytes: _passportRegBytes,
        driverLicenseBackBytes: _driverLicenseBackBytes,
        selfieBytes: _selfieBytes,
      );
      Navigator.of(context).pop(next);
      return;
    }
    final hasRequired = _fioController.text.trim().isNotEmpty &&
        _innController.text.trim().isNotEmpty &&
        _passportController.text.trim().isNotEmpty;
    final hasPhotos = _passportFrontBytes != null &&
        _passportRegBytes != null &&
        _driverLicenseBackBytes != null &&
        _selfieBytes != null;
    final nextStatus = _docsSigned && hasRequired && hasPhotos ? 'pending' : 'incomplete';
    if (!hasPhotos && _docsSigned && hasRequired) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Загрузите 4 фото документов для завершения регистрации')),
      );
    }
    final next = widget.initial.copyWith(
      fullName: _fioController.text,
      phone: _phoneController.text,
      inn: _innController.text,
      passport: _passportController.text,
      docsSigned: _docsSigned,
      registrationStatus: nextStatus,
      avatarBytes: _avatarBytes,
      passportFrontBytes: _passportFrontBytes,
      passportRegBytes: _passportRegBytes,
      driverLicenseBackBytes: _driverLicenseBackBytes,
      selfieBytes: _selfieBytes,
    );
    Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) {
    final locked = _serverRegistrationStatus == 'pending';
    final photosOnlyMode = _serverRegistrationStatus == 'completed';
    return Scaffold(
      backgroundColor: const Color(0xFF05060A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            children: [
              Row(
                children: [
                  _TopIconButton(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  _TopTextButton(
                    title: 'Сохранить',
                    onTap: locked ? null : _save,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
              const SizedBox(height: 10),
              Center(
                child: GestureDetector(
                  onTap: locked ? null : _showAvatarSourceMenu,
                  child: _AvatarCircle(bytes: _avatarBytes, size: 96),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                decoration: BoxDecoration(
                  color: _black55,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Документы',
                      style: TextStyle(
                        color: _white92,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Документы подписаны',
                            style: TextStyle(
                              color: _white84,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Switch(
                          value: _docsSigned,
                          activeColor: _accentColor,
                          onChanged: (locked || photosOnlyMode)
                              ? null
                              : (v) => setState(() {
                                    _docsSigned = v;
                                  }),
                        ),
                      ],
                    ),
                    Text(
                      _serverRegistrationStatus == 'completed'
                          ? 'Регистрация завершена'
                          : _serverRegistrationStatus == 'pending'
                              ? 'Ожидает подтверждения'
                              : _docsSigned
                                  ? 'Нажмите «Сохранить» для отправки'
                                  : 'Регистрация не завершена',
                      style: TextStyle(
                        color: _serverRegistrationStatus == 'completed'
                            ? const Color(0xFF6DD66D)
                            : _serverRegistrationStatus == 'pending'
                                ? const Color(0xFFFFC857)
                                : _docsSigned
                                    ? const Color(0xFF6DD66D)
                                    : _white55,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    if (locked) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Заявка на проверке. Редактирование временно недоступно.',
                        style: TextStyle(
                          color: _white60,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (photosOnlyMode) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Можно изменить только фотографии.',
                        style: TextStyle(
                          color: _white60,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _EditField(
                label: 'ФИО',
                controller: _fioController,
                keyboardType: TextInputType.name,
                inputFormatters: const [],
                enabled: !locked && !photosOnlyMode,
              ),
              const SizedBox(height: 12),
              _EditField(
                label: 'Номер',
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                inputFormatters: [const _RuPhoneInputFormatter()],
                enabled: !locked && !photosOnlyMode,
              ),
              const SizedBox(height: 12),
              _EditField(
                label: 'ИНН',
                controller: _innController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(12)],
                enabled: !locked && !photosOnlyMode,
              ),
              const SizedBox(height: 12),
              _EditField(
                label: 'Серия и номер паспорта',
                controller: _passportController,
                keyboardType: TextInputType.number,
                inputFormatters: [const _RuPassportInputFormatter()],
                enabled: !locked && !photosOnlyMode,
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                decoration: BoxDecoration(
                  color: _black55,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Фотографии документов',
                      style: TextStyle(
                        color: _white92,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Загрузите 4 фото: паспорт, права спереди, права сзади и селфи с правами',
                      style: TextStyle(color: _white55, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _PhotoUploadTile(
                            label: 'Паспорт\n(главная)',
                            icon: Icons.badge_outlined,
                            bytes: _passportFrontBytes,
                            onTap: locked ? null : () => _pickPhoto(
                              'Фото паспорта (главная страница)',
                              (b) => _passportFrontBytes = b,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _PhotoUploadTile(
                            label: 'Вод. удост.\n(перед)',
                            icon: Icons.directions_car_outlined,
                            bytes: _passportRegBytes,
                            onTap: locked ? null : () => _pickPhoto(
                              'Фото водительского удостоверения (передняя сторона)',
                              (b) => _passportRegBytes = b,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _PhotoUploadTile(
                            label: 'Вод. удост.\n(оборот)',
                            icon: Icons.credit_card_outlined,
                            bytes: _driverLicenseBackBytes,
                            onTap: locked ? null : () => _pickPhoto(
                              'Фото водительского удостоверения (обратная сторона)',
                              (b) => _driverLicenseBackBytes = b,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _PhotoUploadTile(
                            label: 'Селфи с\nправами',
                            icon: Icons.person_outline,
                            bytes: _selfieBytes,
                            onTap: locked ? null : () => _pickPhoto(
                              'Селфи с водительским удостоверением в руке',
                              (b) => _selfieBytes = b,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoUploadTile extends StatelessWidget {
  const _PhotoUploadTile({
    required this.label,
    required this.icon,
    required this.bytes,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Uint8List? bytes;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 110,
        decoration: BoxDecoration(
          color: bytes != null ? null : const Color(0xFF15161E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: bytes != null ? const Color(0xFF6DD66D).withOpacity(0.5) : _white10,
            width: bytes != null ? 2 : 1,
          ),
          image: bytes != null
              ? DecorationImage(
                  image: MemoryImage(bytes!),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: bytes != null
            ? Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                  ),
                  child: Icon(Icons.check_circle, color: const Color(0xFF6DD66D), size: 18),
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: _white55, size: 28),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _white55, fontWeight: FontWeight.w700, fontSize: 10),
                  ),
                ],
              ),
      ),
    );
  }
}

class _EditField extends StatelessWidget {
  const _EditField({
    required this.label,
    required this.controller,
    required this.keyboardType,
    required this.inputFormatters,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final TextInputType keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      enabled: enabled,
      style: TextStyle(
        color: enabled ? _white92 : _white55,
        fontWeight: FontWeight.w800,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: _white55, fontWeight: FontWeight.w800),
        filled: true,
        fillColor: _black55,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: _white10),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: _white18),
        ),
      ),
    );
  }
}

class _RuPassportInputFormatter extends TextInputFormatter {
  const _RuPassportInputFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final trimmed = digits.length > 10 ? digits.substring(0, 10) : digits;

    final buffer = StringBuffer();
    for (var i = 0; i < trimmed.length; i++) {
      if (i == 4) buffer.write(' ');
      buffer.write(trimmed[i]);
    }

    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class _RuPhoneInputFormatter extends TextInputFormatter {
  const _RuPhoneInputFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');

    if (digits.isEmpty) {
      return const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));
    }

    if (digits.startsWith('8')) {
      digits = '7${digits.substring(1)}';
    }

    if (!digits.startsWith('7') && digits.length >= 10) {
      digits = '7$digits';
    }

    if (digits.length > 11) {
      digits = digits.substring(0, 11);
    }

    final buffer = StringBuffer();
    buffer.write('+');
    buffer.write(digits[0]);

    final part1End = digits.length < 4 ? digits.length : 4;
    final part2End = digits.length < 7 ? digits.length : 7;
    final part3End = digits.length < 9 ? digits.length : 9;
    final part4End = digits.length < 11 ? digits.length : 11;

    if (digits.length > 1) {
      buffer.write(' (');
      buffer.write(digits.substring(1, part1End));
      if (digits.length >= 4) buffer.write(')');
    }

    if (digits.length > 4) {
      buffer.write(' ');
      buffer.write(digits.substring(4, part2End));
    }
    if (digits.length > 7) {
      buffer.write('-');
      buffer.write(digits.substring(7, part3End));
    }
    if (digits.length > 9) {
      buffer.write('-');
      buffer.write(digits.substring(9, part4End));
    }

    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: _black55,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _white10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: _white92,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: _white55),
            ],
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Ноль промилле',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _accentColor,
          brightness: Brightness.dark,
        ),
      ),
      home: _AuthGate(
        childBuilder: (token, logout) => _DriverShell(token: token, onLogout: logout),
      ),
    );
  }
}

const _mapPlaceholderDecoration = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF1A1D33),
      Color(0xFF0B0D14),
    ],
  ),
);

class _MapBlock extends StatefulWidget {
  const _MapBlock({
    required this.initialPoint,
    this.mapObjects = const <MapObject>[],
    this.onMapCreated,
  });

  final Point initialPoint;
  final List<MapObject> mapObjects;
  final ValueChanged<YandexMapController>? onMapCreated;

  @override
  State<_MapBlock> createState() => _MapBlockState();
}

class _MapBlockState extends State<_MapBlock> {
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Future.delayed(const Duration(milliseconds: 80), () {
        if (!mounted) return;
        setState(() {
          _mapReady = true;
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMobilePlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    if (!isMobilePlatform || !_mapReady) {
      return const DecoratedBox(
        decoration: _mapPlaceholderDecoration,
      );
    }

    return YandexMap(
      onMapCreated: (controller) async {
        await controller.moveCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: widget.initialPoint, zoom: 12),
          ),
        );
        if (widget.onMapCreated != null) {
          widget.onMapCreated!(controller);
        }
      },
      mapObjects: widget.mapObjects,
      mapType: MapType.map,
      nightModeEnabled: true,
      fastTapEnabled: true,
      scrollGesturesEnabled: true,
      zoomGesturesEnabled: true,
      tiltGesturesEnabled: true,
      rotateGesturesEnabled: true,
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title, required this.token, required this.onLogout});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;
  final String token;
  final Future<void> Function() onLogout;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  int _counter = 0;

  static const _initialPoint = Point(latitude: 55.751244, longitude: 37.618423);
  // MKAD radius constants removed — pricing uses kmOutsideMkad from order

  _DriverOrderUiState _orderState = _DriverOrderUiState.incoming;
  _DriverOrder? _order;
  IO.Socket? _socket;
  StreamSubscription<Position>? _posSub;
  String? _driverPhone;
  bool _driverOnline = false;
  bool _driverBlocked = false;
  String? _driverBlockReason;
  DateTime? _driverBlockUntil;
  bool _earningsLimitReached = false;
  bool _socketConnected = true; // true пока не было первого disconnect
  bool _socketEverConnected = false;
  String _registrationStatus = 'incomplete';
  Point? _driverPoint;
  bool _fetchingDriverPoint = false;
  bool _fetchingOrderDetails = false;

  // ── Предзаказ (хранится отдельно, водитель может брать обычные заказы) ──
  _DriverOrder? _preorder;
  Timer? _preorderCheckTimer;
  bool _preorderReminderShown60 = false;
  bool _preorderReminderShown30 = false;
  bool _preorderActivating = false;

  YandexMapController? _mapController;
  List<MapObject> _mapObjects = const <MapObject>[];
  DrivingSession? _drivingSession;
  int _drivingRequestId = 0;
  Point? _routeFrom;
  Point? _routeTo;
  Polyline? _routePolyline;
  double? _routeDistanceMeters;
  double? _routeEtaSeconds;
  bool _shouldFitRoute = false;
  BitmapDescriptor? _pickupPinIcon;
  BitmapDescriptor? _finishFlagIcon;

  PermissionStatus? _locationPermission;
  PermissionStatus? _locationAlwaysPermission;
  bool _requestingLocation = false;
  bool? _locationServiceEnabled;
  _ActionResultOverlay _resultOverlay = _ActionResultOverlay.none;
  Timer? _tripTimer;
  int _tripElapsedSeconds = 0;
  int _tripPriceRub = 0;
  DateTime? _tripStartedAt;

  Timer? _statusPollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _driverPhone = _phoneFromJwt(widget.token);
    _refreshLocationPermission();
    _initOnlineAndConnect();
    unawaited(_syncDriverPushToken(widget.token));
    unawaited(Future<void>.delayed(const Duration(seconds: 5), () => _syncDriverPushToken(widget.token)));
    _startLocationStream();
    unawaited(_recoverActiveOrderState());
    unawaited(_restorePreorder());
    unawaited(_checkBlockStatus());
    // Периодически проверяем статус регистрации и блокировки (каждые 15с)
    _statusPollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkBlockStatus();
    });
  }

  /// Сначала восстанавливаем сохранённый статус, затем подключаем сокет.
  Future<void> _initOnlineAndConnect() async {
    await _restoreOnlineStatus();
    _connectOrderSocket();
  }

  Future<void> _restoreOnlineStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool('driver_online_v1');
    final savedRegStatus = prefs.getString('driver_registration_status');
    if (!mounted) return;
    setState(() {
      if (saved != null) _driverOnline = saved;
      // Восстанавливаем статус регистрации, чтобы не начинать с 'incomplete'
      if (savedRegStatus != null && savedRegStatus.isNotEmpty) {
        _registrationStatus = savedRegStatus;
      }
    });
  }

  /// Обработка 401 — сессия истекла, разлогиниваем
  void _handleSessionExpired() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Сессия истекла. Войдите заново.'),
        backgroundColor: Color(0xFFD32F2F),
        duration: Duration(seconds: 3),
      ),
    );
    widget.onLogout();
  }

  String _socketAuthErrorText(dynamic data) {
    if (data is Map) {
      final parts = <String>[
        data['message']?.toString() ?? '',
        data['error']?.toString() ?? '',
        data['description']?.toString() ?? '',
        data['reason']?.toString() ?? '',
      ].where((part) => part.trim().isNotEmpty).toList();
      return parts.join(' ').toLowerCase();
    }
    return (data?.toString() ?? '').toLowerCase();
  }

  bool _isExplicitSocketAuthError(dynamic data) {
    final msg = _socketAuthErrorText(data);
    if (msg.isEmpty) return false;
    return msg.contains('unauthorized') ||
        msg.contains('invalid token') ||
        msg.contains('jwt expired') ||
        msg.contains('jwt malformed') ||
        msg.contains('authorization required') ||
        msg.contains('driver token required');
  }

  String _driverBlockMessage() {
    if (_driverBlockReason == 'missed_orders') {
      final until = _driverBlockUntil;
      final untilText = until == null
          ? ''
          : '\nРазблокировка: ${until.toLocal().day.toString().padLeft(2, '0')}.'
              '${until.toLocal().month.toString().padLeft(2, '0')} '
              '${until.toLocal().hour.toString().padLeft(2, '0')}:'
              '${until.toLocal().minute.toString().padLeft(2, '0')}';
      return 'Вы пропустили 3 заказа подряд.\nДоступ к новым заказам заблокирован на 48 часов.$untilText';
    }
    return 'Доступ к заказам временно ограничен.\nОбратитесь в поддержку для уточнения.';
  }

  /// Обёртка для GET-запросов с проверкой 401 и таймаутом
  Future<http.Response> _authGet(Uri uri) async {
    final res = await http.get(uri, headers: {'Authorization': 'Bearer ${widget.token}'}).timeout(const Duration(seconds: 15));
    if (res.statusCode == 401) {
      _handleSessionExpired();
    }
    return res;
  }

  /// Обёртка для POST-запросов с проверкой 401 и таймаутом
  Future<http.Response> _authPost(Uri uri, {Map<String, String>? headers, Object? body}) async {
    final h = <String, String>{'Authorization': 'Bearer ${widget.token}', ...?headers};
    final res = await http.post(uri, headers: h, body: body).timeout(const Duration(seconds: 15));
    if (res.statusCode == 401) {
      _handleSessionExpired();
    }
    return res;
  }

  Future<void> _checkBlockStatus() async {
    final phone = _driverPhone;
    if (phone == null || phone.trim().isEmpty) return;
    try {
      final uri = Uri.parse('$_apiBaseUrl/api/driver/profile')
          .replace(queryParameters: {'phone': phone});
      final res = await _authGet(uri);
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final profile = map['profile'];
      if (profile is! Map) return;
      final blocked = profile['blocked'] == true;
      final blockReason = profile['blockReason']?.toString();
      final blockUntil = DateTime.tryParse(profile['blockUntil']?.toString() ?? '');
      final regStatus = (profile['registrationStatus']?.toString() ?? 'incomplete');
      final limitReached = profile['limitReached'] == true;
      if (!mounted) return;
      final prevRegStatus = _registrationStatus;
      final wasLimitReached = _earningsLimitReached;
      setState(() {
        _registrationStatus = regStatus;
        _earningsLimitReached = limitReached;
        _driverBlockReason = blockReason;
        _driverBlockUntil = blockUntil;
        // Если лимит снят — убираем оверлей блокировки
        if (!limitReached && _resultOverlay == _ActionResultOverlay.earningsLimit) {
          _resultOverlay = _ActionResultOverlay.none;
        }
      });
      // Сохраняем статус регистрации, чтобы при следующем запуске не терялся
      unawaited(SharedPreferences.getInstance().then((prefs) {
        prefs.setString('driver_registration_status', regStatus);
      }));
      if (limitReached && !wasLimitReached) {
        final hasActiveOrder = _order != null &&
            _orderState != _DriverOrderUiState.incoming &&
            _orderState != _DriverOrderUiState.declined;
        if (!hasActiveOrder) {
          // Нет активного заказа — сразу блокируем
          setState(() {
            _driverOnline = false;
            _order = null;
            _orderState = _DriverOrderUiState.incoming;
          });
          _socket?.emit('driver:status', {'status': 'offline'});
          _clearRouteState();
          _refreshRoutePreview();
        }
        // Если есть активный заказ — НЕ прерываем его.
        // Флаг _earningsLimitReached уже установлен,
        // блокировка сработает после завершения/отмены заказа.
      }
      // Показать диалог «Документы подтверждены» только 1 раз
      if (regStatus == 'completed') {
        final prefs = await SharedPreferences.getInstance();
        final shown = prefs.getBool('reg_approved_shown') ?? false;
        if (!shown && mounted) {
          await prefs.setBool('reg_approved_shown', true);
          _showRegistrationApprovedDialog();
        }
      }
      if (blocked && !_driverBlocked) {
        setState(() {
          _driverBlocked = true;
          _driverBlockReason = blockReason;
          _driverBlockUntil = blockUntil;
          _driverOnline = false;
          _order = null;
          _orderState = _DriverOrderUiState.incoming;
        });
        _clearRouteState();
        _refreshRoutePreview();
      } else if (!blocked && _driverBlocked) {
        setState(() {
          _driverBlocked = false;
          _driverBlockReason = null;
          _driverBlockUntil = null;
        });
        _clearRouteState();
        _refreshRoutePreview();
      }
    } catch (_) {}
  }

  String? _phoneFromJwt(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final map = jsonDecode(payload) as Map<String, dynamic>;
      final phone = map['phone']?.toString();
      if (phone == null || phone.trim().isEmpty) return null;
      return phone.trim();
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshLocationPermission() async {
    final status = await Permission.location.status;
    final always = await Permission.locationAlways.status;
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!mounted) return;
    setState(() {
      _locationPermission = status;
      _locationAlwaysPermission = always;
      _locationServiceEnabled = serviceEnabled;
    });
  }

  Future<void> _requestLocationPermission() async {
    setState(() {
      _requestingLocation = true;
    });

    final status = await Permission.location.request();
    final always = await Permission.locationAlways.request();
    if (!mounted) return;

    setState(() {
      _requestingLocation = false;
      _locationPermission = status;
      _locationAlwaysPermission = always;
    });

    if (status.isPermanentlyDenied) {
      await openAppSettings();
    }
  }

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusPollTimer?.cancel();
    _preorderCheckTimer?.cancel();
    _tripTimer?.cancel();
    final s = _socket;
    if (s != null) {
      s.dispose();
    }
    _posSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncDriverPushToken(widget.token));
      // Восстанавливаем сокет-соединение, но НЕ меняем онлайн-статус:
      // пользователь мог выбрать «оффлайн» перед сворачиванием.
      // Просто повторно отправляем текущий статус на сервер.
      _emitDriverStatusGuarded(_driverOnline ? 'online' : 'offline');
      unawaited(_recoverActiveOrderState());
      unawaited(_checkBlockStatus());
      // Проверяем предзаказ при возобновлении
      if (_preorder != null) _checkPreorderTiming();
    }
  }

  Future<void> _startLocationStream() async {
    try {
      final status = await Permission.location.request();
      if (!status.isGranted) return;
      // Запрашиваем background, но не блокируем работу в foreground
      await Permission.locationAlways.request();
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (mounted) {
        setState(() {
          _locationServiceEnabled = enabled;
          _locationPermission = status;
        });
      }
      if (!enabled) return;
      final settings = defaultTargetPlatform == TargetPlatform.android
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 50,
              intervalDuration: Duration(seconds: 15),
              foregroundNotificationConfig: ForegroundNotificationConfig(
                notificationTitle: 'Ноль промилле',
                notificationText: 'Приложение определяет местоположение',
                enableWakeLock: true,
                setOngoing: true,
              ),
            )
          : defaultTargetPlatform == TargetPlatform.iOS
              ? AppleSettings(
                  accuracy: LocationAccuracy.bestForNavigation,
                  activityType: ActivityType.automotiveNavigation,
                  allowBackgroundLocationUpdates: true,
                  pauseLocationUpdatesAutomatically: false,
                )
              : LocationSettings(
                  accuracy: LocationAccuracy.high,
                  distanceFilter: 50,
                );
      _posSub = Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
        final nextPoint = Point(latitude: pos.latitude, longitude: pos.longitude);
        _driverPoint = nextPoint;
        if (_driverOnline) {
          _socket?.emit('driver:location', {'lat': pos.latitude, 'lng': pos.longitude});
        }
        _refreshRoutePreview();
      });
    } catch (_) {}
  }

  Future<Point?> _ensureDriverPoint() async {
    if (_driverPoint != null) return _driverPoint;
    if (_fetchingDriverPoint) return null;
    _fetchingDriverPoint = true;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        _driverPoint = Point(latitude: last.latitude, longitude: last.longitude);
        return _driverPoint;
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 6));
      _driverPoint = Point(latitude: pos.latitude, longitude: pos.longitude);
      return _driverPoint;
    } catch (_) {
      return null;
    } finally {
      _fetchingDriverPoint = false;
    }
  }

  Future<void> _callSupport() async {
    const phone = '+79060424241';
    final uri = Uri(scheme: 'tel', path: phone);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _emitDriverStatusGuarded(String status, {IO.Socket? socket}) {
    final target = socket ?? _socket;
    if (target == null) return;
    if (status == 'online') {
      target.emitWithAck('driver:status', {'status': status}, ack: (response) {
        if (!mounted) return;
        if (response is Map && response['error'] == 'EARNINGS_LIMIT_REACHED') {
          setState(() {
            _driverOnline = false;
          });
          SharedPreferences.getInstance().then((p) => p.setBool('driver_online_v1', false));
          _showEarningsLimitOverlay();
        }
      });
      return;
    }
    target.emit('driver:status', {'status': status});
  }

  void _setDriverOnline(bool value) {
    if (_driverOnline == value) return;
    // Блокируем выход в онлайн, если регистрация не завершена
    if (value && _registrationStatus != 'completed') {
      // Перепроверяем с сервером — статус мог устареть
      unawaited(_checkBlockStatus().then((_) {
        if (!mounted) return;
        if (_registrationStatus == 'completed') {
          // Статус обновился — повторяем попытку
          _setDriverOnline(true);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Завершите регистрацию, чтобы принимать заказы')),
          );
        }
      }));
      return;
    }
    // Блокируем, если достигнут лимит заработка
    // Но сначала проверяем актуальные данные с сервера (комиссия могла быть оплачена)
    if (value && _earningsLimitReached) {
      unawaited(_checkBlockStatus().then((_) {
        if (!mounted) return;
        if (!_earningsLimitReached) {
          // Лимит снят — повторяем попытку выйти в онлайн
          _setDriverOnline(true);
        } else {
          _showEarningsLimitOverlay();
        }
      }));
      return;
    }
    setState(() {
      _driverOnline = value;
    });
    _emitDriverStatusGuarded(value ? 'online' : 'offline');
    // Сохраняем онлайн-статус, чтобы восстановить при перезапуске
    SharedPreferences.getInstance().then((p) => p.setBool('driver_online_v1', value));
  }

  Future<void> _clearRouteState() async {
    try {
      await _drivingSession?.cancel();
    } catch (_) {}
    try {
      await _drivingSession?.close();
    } catch (_) {}
    _drivingSession = null;
    _routeFrom = null;
    _routeTo = null;
    _routePolyline = null;
    _routeDistanceMeters = null;
    _routeEtaSeconds = null;
  }

  bool _samePoint(Point a, Point b) =>
      (a.latitude - b.latitude).abs() < 0.0001 && (a.longitude - b.longitude).abs() < 0.0001;

  Future<Polyline> _ensureDrivingRoute({required Point from, required Point to}) async {
    final cachedPolyline = _routePolyline;
    final cachedFrom = _routeFrom;
    final cachedTo = _routeTo;
    if (cachedPolyline != null && cachedFrom != null && cachedTo != null) {
      if (_samePoint(from, cachedFrom) && _samePoint(to, cachedTo)) {
        return cachedPolyline;
      }
    }

    final requestId = ++_drivingRequestId;
    await _clearRouteState();

    final points = <RequestPoint>[
      RequestPoint(point: from, requestPointType: RequestPointType.wayPoint),
      RequestPoint(point: to, requestPointType: RequestPointType.wayPoint),
    ];

    DrivingSession session;
    Future<DrivingSessionResult> futureResult;
    try {
      final result = await YandexDriving.requestRoutes(
        points: points,
        drivingOptions: DrivingOptions(routesCount: 1),
      );
      session = result.$1;
      futureResult = result.$2;
    } catch (_) {
      _routeFrom = from;
      _routeTo = to;
      _routePolyline = Polyline(points: <Point>[from, to]);
      _routeDistanceMeters = null;
      _routeEtaSeconds = null;
      return _routePolyline!;
    }

    _drivingSession = session;

    DrivingSessionResult result;
    try {
      result = await futureResult;
    } finally {
      try {
        await session.close();
      } catch (_) {}
      if (identical(_drivingSession, session)) {
        _drivingSession = null;
      }
    }

    if (!mounted || requestId != _drivingRequestId) {
      return Polyline(points: <Point>[from, to]);
    }

    final err = result.error ?? '';
    final routes = result.routes ?? const <DrivingRoute>[];
    if (err.isNotEmpty || routes.isEmpty) {
      _routeFrom = from;
      _routeTo = to;
      _routePolyline = Polyline(points: <Point>[from, to]);
      _routeDistanceMeters = null;
      _routeEtaSeconds = null;
      return _routePolyline!;
    }

    final route = routes.first;
    final polyline = route.geometry;
    final w = route.metadata.weight;
    _routeFrom = from;
    _routeTo = to;
    _routePolyline = polyline;
    _routeDistanceMeters = w.distance.value;
    _routeEtaSeconds = w.timeWithTraffic.value ?? w.time.value;
    return polyline;
  }

  Future<void> _refreshRoutePreview() async {
    final order = _order;
    var driverPoint = _driverPoint;
    if (driverPoint == null) {
      driverPoint = await _ensureDriverPoint();
    }
    if (order == null) {
      if (!mounted) return;
      final dp = driverPoint;
      setState(() {
        _mapObjects = dp == null
            ? const <MapObject>[]
            : <MapObject>[
                CircleMapObject(
                  mapId: const MapObjectId('driver'),
                  circle: Circle(center: dp, radius: 8),
                  fillColor: _accentColor.withOpacity(0.85),
                  strokeColor: _accentDark,
                  strokeWidth: 2,
                  zIndex: 3,
                ),
              ];
      });
      return;
    }

    final pickupPoint = order.pickupPoint;
    final dropoffPoint = order.dropoffPoint;
    if (pickupPoint == null && dropoffPoint == null) {
      if (!mounted) return;
      final dp = driverPoint;
      setState(() {
        _mapObjects = dp == null
            ? const <MapObject>[]
            : <MapObject>[
                CircleMapObject(
                  mapId: const MapObjectId('driver'),
                  circle: Circle(center: dp, radius: 8),
                  fillColor: _accentColor.withOpacity(0.85),
                  strokeColor: _accentDark,
                  strokeWidth: 2,
                  zIndex: 3,
                ),
              ];
      });
      return;
    }

    final isPickupPhase = _orderState == _DriverOrderUiState.incoming ||
        _orderState == _DriverOrderUiState.accepted ||
        _orderState == _DriverOrderUiState.enroute;

    Point? routeFrom;
    Point? routeTo;
    if (isPickupPhase) {
      if (driverPoint != null) {
        routeFrom = driverPoint;
        routeTo = pickupPoint ?? dropoffPoint;
      } else if (pickupPoint != null && dropoffPoint != null) {
        // если нет локации водителя — хотя бы покажем маршрут A->B
        routeFrom = pickupPoint;
        routeTo = dropoffPoint;
      } else {
        routeFrom = pickupPoint ?? dropoffPoint;
        routeTo = routeFrom;
      }
    } else if (driverPoint != null) {
      routeFrom = pickupPoint ?? driverPoint;
      routeTo = dropoffPoint ?? pickupPoint;
    } else if (pickupPoint != null && dropoffPoint != null) {
      routeFrom = pickupPoint;
      routeTo = dropoffPoint;
    } else {
      routeFrom = pickupPoint ?? dropoffPoint;
      routeTo = routeFrom;
    }

    if (routeFrom == null || routeTo == null) {
      if (!mounted) return;
      final baseObjects = <MapObject>[
        if (driverPoint != null)
          CircleMapObject(
            mapId: const MapObjectId('driver'),
            circle: Circle(center: driverPoint, radius: 8),
            fillColor: _accentColor.withOpacity(0.85),
            strokeColor: _accentDark,
            strokeWidth: 2,
            zIndex: 4,
          ),
        if (pickupPoint != null)
          CircleMapObject(
            mapId: const MapObjectId('pickup'),
            circle: Circle(center: pickupPoint, radius: 7),
            fillColor: const Color(0xFF1D5B8F).withOpacity(0.9),
            strokeColor: const Color(0xFF1D5B8F),
            strokeWidth: 2,
            zIndex: 3,
          ),
        if (dropoffPoint != null)
          CircleMapObject(
            mapId: const MapObjectId('dropoff'),
            circle: Circle(center: dropoffPoint, radius: 7),
            fillColor: const Color(0xFF6A3CA5).withOpacity(0.9),
            strokeColor: const Color(0xFF6A3CA5),
            strokeWidth: 2,
            zIndex: 2,
          ),
      ];
      setState(() {
        _mapObjects = baseObjects;
      });
      unawaited(() async {
        final pickupIcon = await _ensurePickupPinIcon();
        final finishIcon = await _ensureFinishFlagIcon();
        if (!mounted) return;
        setState(() {
          _mapObjects = <MapObject>[
            if (driverPoint != null)
              CircleMapObject(
                mapId: const MapObjectId('driver'),
                circle: Circle(center: driverPoint, radius: 8),
                fillColor: _accentColor.withOpacity(0.85),
                strokeColor: _accentDark,
                strokeWidth: 2,
                zIndex: 4,
              ),
            if (pickupPoint != null)
              PlacemarkMapObject(
                mapId: const MapObjectId('pickup'),
                point: pickupPoint,
                isVisible: true,
                opacity: 1.0,
                zIndex: 3,
                icon: PlacemarkIcon.single(
                  PlacemarkIconStyle(
                    image: pickupIcon,
                    scale: 1.05,
                    anchor: const Offset(0.5, 1.0),
                  ),
                ),
              ),
            if (dropoffPoint != null)
              PlacemarkMapObject(
                mapId: const MapObjectId('dropoff'),
                point: dropoffPoint,
                isVisible: true,
                opacity: 1.0,
                zIndex: 2,
                icon: PlacemarkIcon.single(
                  PlacemarkIconStyle(
                    image: finishIcon,
                    scale: 1.0,
                    anchor: const Offset(0.5, 1.0),
                  ),
                ),
              ),
          ];
        });
      }());
      return;
    }
    final routeLine = await _ensureDrivingRoute(from: routeFrom, to: routeTo);
    final distanceMeters = _routeDistanceMeters ?? 0.0;
    final etaSeconds = _routeEtaSeconds ?? 0.0;
    final double distanceKm = distanceMeters > 0 ? distanceMeters / 1000.0 : 0.0;
    final int etaMin = etaSeconds > 0 ? (etaSeconds / 60).ceil() : 0;
    final isPickupRoute = driverPoint != null && isPickupPhase;

    if (!mounted) return;
    final baseObjects = <MapObject>[
      if (driverPoint != null)
        CircleMapObject(
          mapId: const MapObjectId('driver'),
          circle: Circle(center: driverPoint, radius: 8),
          fillColor: _accentColor.withOpacity(0.85),
          strokeColor: _accentDark,
          strokeWidth: 2,
          zIndex: 4,
        ),
      if (pickupPoint != null)
        CircleMapObject(
          mapId: const MapObjectId('pickup'),
          circle: Circle(center: pickupPoint, radius: 7),
          fillColor: const Color(0xFF1D5B8F).withOpacity(0.9),
          strokeColor: const Color(0xFF1D5B8F),
          strokeWidth: 2,
          zIndex: 3,
        ),
      if (dropoffPoint != null)
        CircleMapObject(
          mapId: const MapObjectId('dropoff'),
          circle: Circle(center: dropoffPoint, radius: 7),
          fillColor: const Color(0xFF6A3CA5).withOpacity(0.9),
          strokeColor: const Color(0xFF6A3CA5),
          strokeWidth: 2,
          zIndex: 2,
        ),
      PolylineMapObject(
        mapId: const MapObjectId('route'),
        polyline: routeLine,
        strokeColor: _accentDark,
        strokeWidth: 5,
        outlineWidth: 2,
        outlineColor: _black45,
        zIndex: 1,
      ),
    ];
    setState(() {
      _order = isPickupRoute
          ? order.copyWith(
              pickupDistanceKm: distanceKm > 0 ? distanceKm : order.pickupDistanceKm,
              pickupEtaMin: etaMin > 0 ? etaMin : order.pickupEtaMin,
            )
          : order.copyWith(
              tripDistanceKm: distanceKm > 0 ? distanceKm : order.tripDistanceKm,
              tripEtaMin: etaMin > 0 ? etaMin : order.tripEtaMin,
            );
      _mapObjects = baseObjects;
    });

    unawaited(() async {
      final pickupIcon = await _ensurePickupPinIcon();
      final finishIcon = await _ensureFinishFlagIcon();
      if (!mounted) return;
      setState(() {
        _mapObjects = <MapObject>[
          if (driverPoint != null)
            CircleMapObject(
              mapId: const MapObjectId('driver'),
              circle: Circle(center: driverPoint, radius: 8),
              fillColor: _accentColor.withOpacity(0.85),
              strokeColor: _accentDark,
              strokeWidth: 2,
              zIndex: 4,
            ),
          if (pickupPoint != null)
            PlacemarkMapObject(
              mapId: const MapObjectId('pickup'),
              point: pickupPoint,
              isVisible: true,
              opacity: 1.0,
              zIndex: 3,
              icon: PlacemarkIcon.single(
                PlacemarkIconStyle(
                  image: pickupIcon,
                  scale: 1.05,
                  anchor: const Offset(0.5, 1.0),
                ),
              ),
            ),
          if (dropoffPoint != null)
            PlacemarkMapObject(
              mapId: const MapObjectId('dropoff'),
              point: dropoffPoint,
              isVisible: true,
              opacity: 1.0,
              zIndex: 2,
              icon: PlacemarkIcon.single(
                PlacemarkIconStyle(
                  image: finishIcon,
                  scale: 1.0,
                  anchor: const Offset(0.5, 1.0),
                ),
              ),
            ),
          PolylineMapObject(
            mapId: const MapObjectId('route'),
            polyline: routeLine,
            strokeColor: _accentDark,
            strokeWidth: 5,
            outlineWidth: 2,
            outlineColor: _black45,
            zIndex: 1,
          ),
        ];
      });
    }());

    if (_shouldFitRoute) {
      _shouldFitRoute = false;
      final points = <Point>[];
      if (driverPoint != null) points.add(driverPoint);
      if (pickupPoint != null) points.add(pickupPoint);
      if (dropoffPoint != null) points.add(dropoffPoint);
      if (points.isEmpty) return;
      await _fitRouteBounds(points);
    }
  }

  Future<void> _fitRouteBounds(List<Point> points) async {
    final controller = _mapController;
    if (controller == null || points.isEmpty) return;
    var north = points.first.latitude;
    var south = points.first.latitude;
    var east = points.first.longitude;
    var west = points.first.longitude;
    for (final p in points.skip(1)) {
      north = math.max(north, p.latitude);
      south = math.min(south, p.latitude);
      east = math.max(east, p.longitude);
      west = math.min(west, p.longitude);
    }
    final bbox = BoundingBox(
      northEast: Point(latitude: north, longitude: east),
      southWest: Point(latitude: south, longitude: west),
    );
    await controller.moveCamera(
      CameraUpdate.newGeometry(
        Geometry.fromBoundingBox(bbox),
      ),
    );
  }

  Future<void> _launchNavigatorTo(Point to, {Point? from}) async {
    final naviUri =
        Uri.parse('yandexnavi://build_route_on_map?lat_to=${to.latitude}&lon_to=${to.longitude}');
    if (await canLaunchUrl(naviUri)) {
      await launchUrl(naviUri, mode: LaunchMode.externalApplication);
      return;
    }
    final fromText = from != null ? '${from.latitude},${from.longitude}' : '';
    final rtext = fromText.isNotEmpty ? '${Uri.encodeComponent(fromText)}~${to.latitude},${to.longitude}' : '';
    final fallback = rtext.isNotEmpty
        ? 'https://yandex.ru/maps/?rtext=$rtext&rtt=auto'
        : 'https://yandex.ru/maps/?pt=${to.longitude},${to.latitude}&z=14&l=map';
    await launchUrl(Uri.parse(fallback), mode: LaunchMode.externalApplication);
  }

  Future<void> _openOrderNavigator() async {
    final order = _order;
    if (order == null) return;
    final target = (_orderState == _DriverOrderUiState.incoming ||
            _orderState == _DriverOrderUiState.accepted ||
            _orderState == _DriverOrderUiState.enroute ||
            _orderState == _DriverOrderUiState.arrived)
        ? order.pickupPoint
        : order.dropoffPoint;
    if (target == null) return;
    await _launchNavigatorTo(target, from: _driverPoint);
  }

  Future<void> _openManualRouteDialog() async {
    final order = _order;
    final fromController = TextEditingController(text: order?.pickupTitle ?? '');
    final toController = TextEditingController(text: order?.dropoffTitle ?? '');
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF05060A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        return Padding(
          padding: MediaQuery.of(context).viewInsets,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Маршрут вручную',
                  style: TextStyle(
                    color: _white92,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: fromController,
                  style: TextStyle(color: _white90, fontWeight: FontWeight.w700),
                  decoration: InputDecoration(
                    labelText: 'Откуда',
                    labelStyle: TextStyle(color: _white60),
                    filled: true,
                    fillColor: _white06,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: toController,
                  style: TextStyle(color: _white90, fontWeight: FontWeight.w700),
                  decoration: InputDecoration(
                    labelText: 'Куда',
                    labelStyle: TextStyle(color: _white60),
                    filled: true,
                    fillColor: _white06,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 14),
                _ActionButton(
                  label: 'ОТКРЫТЬ В НАВИГАТОРЕ',
                  isPrimary: true,
                  enabled: true,
                  onPressed: () async {
                    final from = fromController.text.trim();
                    final to = toController.text.trim();
                    if (to.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Введите куда ехать')),
                      );
                      return;
                    }
                    final fromText = from.isNotEmpty ? Uri.encodeComponent(from) : '';
                    final toText = Uri.encodeComponent(to);
                    final rtext = fromText.isNotEmpty ? '$fromText~$toText' : toText;
                    final url = 'https://yandex.ru/maps/?rtext=$rtext&rtt=auto';
                    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _centerOnDriver() async {
    final controller = _mapController;
    if (controller == null) return;
    final point = _driverPoint ?? await _ensureDriverPoint();
    if (point == null) return;
    await controller.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: point, zoom: 16),
      ),
    );
  }

  String _formatTripElapsed(int seconds) {
    final total = math.max(0, seconds);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '${h}ч ${m.toString().padLeft(2, '0')}м';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  int _kmFee(double km) {
    final k = km <= 0 ? 0 : km.ceil();
    return k * 50;
  }

  int _calcTripPrice(_DriverOrder order, int minutes) {
    final safeMinutes = math.max(1, minutes);
    final serviceIndex = order.serviceIndex;
    final kmOutside = order.kmOutsideMkad;

    int calculated;
    if (serviceIndex == 1) {
      const includedMin = 5 * 60;
      final extraMin = math.max(0, safeMinutes - includedMin);
      calculated = 9000 + extraMin * 25;
    } else {
      // serviceIndex 0 (Трезвый водитель) и 2 (Перегон) — единая формула
      final outsideMkad = kmOutside > 0.5; // >500m = выезд за МКАД
      const includedMin = 60;
      final extraMin = math.max(0, safeMinutes - includedMin);
      final base = outsideMkad ? 2900 : 2500;
      final kmCharge = outsideMkad ? _kmFee(kmOutside) : 0;
      calculated = base + extraMin * 25 + kmCharge;
    }
    // Цена не может быть ниже начальной оценки (priceFrom)
    return math.max(calculated, order.priceRub);
  }

  String _stateToString(_DriverOrderUiState state) {
    return switch (state) {
      _DriverOrderUiState.incoming => 'incoming',
      _DriverOrderUiState.accepted => 'accepted',
      _DriverOrderUiState.enroute => 'enroute',
      _DriverOrderUiState.arrived => 'arrived',
      _DriverOrderUiState.started => 'started',
      _DriverOrderUiState.completed => 'completed',
      _DriverOrderUiState.declined => 'declined',
    };
  }

  _DriverOrderUiState _stateFromString(String value) {
    return switch (value) {
      'accepted' => _DriverOrderUiState.accepted,
      'enroute' => _DriverOrderUiState.enroute,
      'arrived' => _DriverOrderUiState.arrived,
      'started' => _DriverOrderUiState.started,
      'completed' => _DriverOrderUiState.completed,
      'declined' => _DriverOrderUiState.declined,
      _ => _DriverOrderUiState.incoming,
    };
  }

  Future<void> _persistActiveOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final order = _order;
    if (order == null) {
      await prefs.remove(_activeOrderPrefsKey);
      await prefs.remove(_activeOrderStateKey);
      return;
    }
    final payload = <String, dynamic>{
      'id': order.id,
      'pickupTitle': order.pickupTitle,
      'dropoffTitle': order.dropoffTitle,
      'pickupPoint': order.pickupPoint == null
          ? null
          : {'lat': order.pickupPoint!.latitude, 'lng': order.pickupPoint!.longitude},
      'dropoffPoint': order.dropoffPoint == null
          ? null
          : {'lat': order.dropoffPoint!.latitude, 'lng': order.dropoffPoint!.longitude},
      'pickupDistanceKm': order.pickupDistanceKm,
      'pickupEtaMin': order.pickupEtaMin,
      'tripDistanceKm': order.tripDistanceKm,
      'tripEtaMin': order.tripEtaMin,
      'priceRub': order.priceRub,
      'priceFinal': order.priceFinal,
      'promoDiscountPercent': order.promoDiscountPercent,
      'serviceIndex': order.serviceIndex,
      'kmOutsideMkad': order.kmOutsideMkad,
      'startedAt': order.startedAt?.toIso8601String(),
      'completedAt': order.completedAt?.toIso8601String(),
      'clientPhone': order.clientPhone,
      'comment': order.comment,
      'wish': order.wish,
      'scheduledAt': order.scheduledAt?.toIso8601String(),
      'notifiedAt': order.notifiedAt?.toIso8601String(),
    };
    await prefs.setString(_activeOrderPrefsKey, jsonEncode(payload));
    await prefs.setString(_activeOrderStateKey, _stateToString(_orderState));
  }

  Future<void> _restoreActiveOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_activeOrderPrefsKey);
    if (raw == null || raw.trim().isEmpty) return;
    final stateRaw = prefs.getString(_activeOrderStateKey) ?? 'incoming';
    Map<String, dynamic> map;
    try {
      map = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      await prefs.remove(_activeOrderPrefsKey);
      return;
    }
    final restored = _orderFromMap(map);
    if (stateRaw == 'incoming' &&
        restored.notifiedAt != null &&
        DateTime.now().isAfter(restored.notifiedAt!.add(const Duration(seconds: 10)))) {
      await prefs.remove(_activeOrderPrefsKey);
      await prefs.remove(_activeOrderStateKey);
      return;
    }

    // Не восстанавливаем, если этот заказ уже в _preorder
    if (_preorder != null && restored.id == _preorder!.id) return;

    if (!mounted) return;
    setState(() {
      _order = restored;
      _orderState = _stateFromString(stateRaw);
      _shouldFitRoute = _orderState == _DriverOrderUiState.accepted ||
          _orderState == _DriverOrderUiState.enroute ||
          _orderState == _DriverOrderUiState.arrived ||
          _orderState == _DriverOrderUiState.started;
    });
    _syncTripTimer(_orderState, restored);
    _refreshRoutePreview();
    if (restored.id.isNotEmpty) {
      unawaited(_fetchOrderDetails(restored.id));
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // Предзаказ — persistence & timer
  // ═══════════════════════════════════════════════════════════════

  Map<String, dynamic> _orderToMap(_DriverOrder order) {
    return {
      'id': order.id,
      'pickupTitle': order.pickupTitle,
      'dropoffTitle': order.dropoffTitle,
      'pickupPoint': order.pickupPoint == null
          ? null
          : {'lat': order.pickupPoint!.latitude, 'lng': order.pickupPoint!.longitude},
      'dropoffPoint': order.dropoffPoint == null
          ? null
          : {'lat': order.dropoffPoint!.latitude, 'lng': order.dropoffPoint!.longitude},
      'pickupDistanceKm': order.pickupDistanceKm,
      'pickupEtaMin': order.pickupEtaMin,
      'tripDistanceKm': order.tripDistanceKm,
      'tripEtaMin': order.tripEtaMin,
      'priceRub': order.priceRub,
      'priceFinal': order.priceFinal,
      'promoDiscountPercent': order.promoDiscountPercent,
      'serviceIndex': order.serviceIndex,
      'kmOutsideMkad': order.kmOutsideMkad,
      'startedAt': order.startedAt?.toIso8601String(),
      'completedAt': order.completedAt?.toIso8601String(),
      'clientPhone': order.clientPhone,
      'comment': order.comment,
      'wish': order.wish,
      'scheduledAt': order.scheduledAt?.toIso8601String(),
      'notifiedAt': order.notifiedAt?.toIso8601String(),
    };
  }

  _DriverOrder _orderFromMap(Map<String, dynamic> map) {
    Point? readPoint(dynamic value) {
      if (value is Map) {
        final lat = double.tryParse(value['lat']?.toString() ?? '');
        final lng = double.tryParse(value['lng']?.toString() ?? '');
        if (lat != null && lng != null) return Point(latitude: lat, longitude: lng);
      }
      return null;
    }
    return _DriverOrder(
      id: map['id']?.toString() ?? '',
      pickupTitle: map['pickupTitle']?.toString() ?? '',
      dropoffTitle: map['dropoffTitle']?.toString() ?? '—',
      pickupPoint: readPoint(map['pickupPoint']),
      dropoffPoint: readPoint(map['dropoffPoint']),
      pickupDistanceKm: (map['pickupDistanceKm'] ?? 0).toDouble(),
      pickupEtaMin: int.tryParse(map['pickupEtaMin']?.toString() ?? '') ?? 0,
      tripDistanceKm: (map['tripDistanceKm'] ?? 0).toDouble(),
      tripEtaMin: int.tryParse(map['tripEtaMin']?.toString() ?? '') ?? 0,
      priceRub: int.tryParse(map['priceRub']?.toString() ?? '') ?? 0,
      priceFinal: int.tryParse(map['priceFinal']?.toString() ?? '') ?? 0,
      promoDiscountPercent: int.tryParse(map['promoDiscountPercent']?.toString() ?? '') ?? 0,
      serviceIndex: int.tryParse(map['serviceIndex']?.toString() ?? '') ?? 0,
      kmOutsideMkad: double.tryParse(map['kmOutsideMkad']?.toString() ?? '') ?? 0.0,
      startedAt: DateTime.tryParse(map['startedAt']?.toString() ?? ''),
      completedAt: DateTime.tryParse(map['completedAt']?.toString() ?? ''),
      clientPhone: map['clientPhone']?.toString(),
      comment: (map['comment']?.toString() ?? '').trim().isNotEmpty ? map['comment'].toString().trim() : null,
      wish: (map['wish']?.toString() ?? '').trim().isNotEmpty ? map['wish'].toString().trim() : null,
      scheduledAt: DateTime.tryParse(map['scheduledAt']?.toString() ?? ''),
      notifiedAt: DateTime.tryParse(map['notifiedAt']?.toString() ?? ''),
    );
  }

  Future<void> _persistPreorder() async {
    final prefs = await SharedPreferences.getInstance();
    final po = _preorder;
    if (po == null) {
      await prefs.remove(_preorderPrefsKey);
      return;
    }
    await prefs.setString(_preorderPrefsKey, jsonEncode(_orderToMap(po)));
  }

  Future<void> _restorePreorder() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_preorderPrefsKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final restored = _orderFromMap(map);
      // Если время предзаказа уже прошло более 2 часов — удаляем
      if (restored.scheduledAt != null &&
          restored.scheduledAt!.isBefore(DateTime.now().subtract(const Duration(hours: 2)))) {
        await prefs.remove(_preorderPrefsKey);
        return;
      }
      if (!mounted) return;
      setState(() => _preorder = restored);
      _startPreorderCheckTimer();
    } catch (_) {
      await prefs.remove(_preorderPrefsKey);
    }
  }

  void _startPreorderCheckTimer() {
    _preorderCheckTimer?.cancel();
    _preorderCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkPreorderTiming();
    });
    // Сразу проверяем
    _checkPreorderTiming();
  }

  void _checkPreorderTiming() {
    final po = _preorder;
    if (po == null || po.scheduledAt == null) return;
    final now = DateTime.now();
    final diff = po.scheduledAt!.difference(now);

    // За 60 минут — уведомление
    if (!_preorderReminderShown60 && diff.inMinutes <= 60 && diff.inMinutes > 30) {
      _preorderReminderShown60 = true;
      _showPreorderReminderNotification(po, 'Предзаказ через 1 час');
    }

    // За 30 минут — уведомление + снэкбар
    if (!_preorderReminderShown30 && diff.inMinutes <= 30 && diff.inMinutes > 15) {
      _preorderReminderShown30 = true;
      _showPreorderReminderNotification(po, 'Предзаказ через 30 минут');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Предзаказ через ${diff.inMinutes} мин — завершайте текущий заказ'),
            backgroundColor: const Color(0xFF7C3AED),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }

    // За 15 минут или менее — активируем, если водитель свободен
    if (diff.inMinutes <= 15) {
      final hasActiveOrder = _order != null &&
          _orderState != _DriverOrderUiState.incoming &&
          _orderState != _DriverOrderUiState.declined;
      if (!hasActiveOrder) {
        _activatePreorder();
      } else if (!_preorderActivating) {
        _preorderActivating = true;
        _showPreorderReminderNotification(po, 'Предзаказ через ${diff.inMinutes} мин! Завершайте поездку');
      }
    }

    // Время наступило — принудительно активируем после завершения текущего заказа
    if (diff.isNegative) {
      final hasActiveOrder = _order != null &&
          _orderState != _DriverOrderUiState.incoming &&
          _orderState != _DriverOrderUiState.declined;
      if (!hasActiveOrder) {
        _activatePreorder();
      }
      // Если есть активный заказ — ждём его завершения (проверка в onDismissCompleted)
    }
  }

  void _activatePreorder() {
    final po = _preorder;
    if (po == null) return;
    _preorderCheckTimer?.cancel();
    setState(() {
      _preorder = null;
      _order = po;
      _orderState = _DriverOrderUiState.accepted;
      _shouldFitRoute = true;
      _preorderReminderShown60 = false;
      _preorderReminderShown30 = false;
      _preorderActivating = false;
    });
    _socket?.emit('driver:status', {'status': 'busy'});
    _persistActiveOrder();
    unawaited(_persistPreorder());
    _sendCurrentLocationNow();
    unawaited(_ensureDriverPoint().then((_) => _refreshRoutePreview()));
    unawaited(_fetchOrderDetails(po.id));
    _refreshRoutePreview();
    _showPreorderReminderNotification(po, 'Предзаказ активирован — время подачи!');
  }

  Future<void> _showPreorderReminderNotification(_DriverOrder order, String title) async {
    final sa = order.scheduledAt;
    final timeStr = sa != null
        ? '${sa.hour.toString().padLeft(2, '0')}:${sa.minute.toString().padLeft(2, '0')}'
        : '';
    final body = '${order.pickupTitle} → ${order.dropoffTitle}${timeStr.isNotEmpty ? ' в $timeStr' : ''}';
    try {
      await _notifications.show(
        id: 99,
        title: title,
        body: body,
        notificationDetails: _orderNotificationDetails(),
      );
    } catch (_) {}
  }

  void _cancelPreorder() {
    final po = _preorder;
    if (po == null) return;
    // Сервер не поддерживает order:cancel от водителя. Используем валидный статус-переход.
    _socket?.emit('order:update', {'orderId': po.id, 'status': 'canceled'});
    _preorderCheckTimer?.cancel();
    setState(() {
      _preorder = null;
      _preorderReminderShown60 = false;
      _preorderReminderShown30 = false;
      _preorderActivating = false;
    });
    unawaited(_persistPreorder());
  }

  void _syncTripTimer(_DriverOrderUiState state, _DriverOrder? order) {
    if (order == null) {
      _tripTimer?.cancel();
      _tripTimer = null;
      _tripElapsedSeconds = 0;
      _tripPriceRub = 0;
      return;
    }
    if (state == _DriverOrderUiState.completed) {
      _tripTimer?.cancel();
      _tripTimer = null;
      final finalPrice = order.priceFinal;
      final completedAt = order.completedAt;
      final startedAt = order.startedAt;
      int elapsed = _tripElapsedSeconds;
      if (completedAt != null && startedAt != null) {
        elapsed = completedAt.difference(startedAt).inSeconds;
      }
      if (finalPrice != null && finalPrice > 0) {
        if (mounted) {
          setState(() {
            _tripElapsedSeconds = elapsed;
            _tripPriceRub = finalPrice;
          });
        } else {
          _tripElapsedSeconds = elapsed;
          _tripPriceRub = finalPrice;
        }
      }
      return;
    }
    if (state != _DriverOrderUiState.started) {
      _tripTimer?.cancel();
      _tripTimer = null;
      return;
    }
    final startedAt = order.startedAt ?? DateTime.now();
    _tripStartedAt = startedAt;
    _tripTimer?.cancel();
    final initialElapsed = DateTime.now().difference(startedAt).inSeconds;
    final initialMinutes = (initialElapsed / 60).ceil();
    if (mounted) {
      setState(() {
        _tripElapsedSeconds = initialElapsed;
        _tripPriceRub = _calcTripPrice(order, initialMinutes);
      });
    } else {
      _tripElapsedSeconds = initialElapsed;
      _tripPriceRub = _calcTripPrice(order, initialMinutes);
    }
    _tripTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final elapsed = DateTime.now().difference(startedAt).inSeconds;
      final minutes = (elapsed / 60).ceil();
      final price = _calcTripPrice(order, minutes);
      if (!mounted) return;
      setState(() {
        _tripElapsedSeconds = elapsed;
        _tripPriceRub = price;
      });
    });
  }

  _DriverOrderUiState _statusToUi(String status) {
    return switch (status) {
      'accepted' => _DriverOrderUiState.accepted,
      'enroute' => _DriverOrderUiState.enroute,
      'arrived' => _DriverOrderUiState.arrived,
      'started' => _DriverOrderUiState.started,
      'completed' => _DriverOrderUiState.completed,
      _ => _DriverOrderUiState.incoming,
    };
  }

  Future<void> _loadActiveOrder() async {
    try {
      final res = await _authGet(Uri.parse('$_apiBaseUrl/api/orders/active/driver'));
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final raw = map['order'] as Map?;
      if (raw == null) return;
      final mapped = _mapOrder(raw.cast<String, dynamic>());
      final nextState = _statusToUi((raw['status'] ?? '').toString());

      // Если этот заказ уже сохранён как предзаказ — пропускаем
      if (_preorder != null && mapped.id == _preorder!.id) return;

      // Если это предзаказ (scheduledAt > 15 мин), сохраняем отдельно
      final isPreorder = mapped.scheduledAt != null &&
          mapped.scheduledAt!.isAfter(DateTime.now().add(const Duration(minutes: 15))) &&
          nextState == _DriverOrderUiState.accepted;
      if (isPreorder) {
        if (!mounted) return;
        setState(() {
          _preorder = mapped;
        });
        unawaited(_persistPreorder());
        _startPreorderCheckTimer();
        // Не ставим как активный заказ — водитель свободен
        return;
      }

      if (!mounted) return;
      setState(() {
        _order = mapped;
        _orderState = nextState;
        _shouldFitRoute = nextState == _DriverOrderUiState.accepted ||
            nextState == _DriverOrderUiState.enroute ||
            nextState == _DriverOrderUiState.arrived ||
            nextState == _DriverOrderUiState.started;
      });
      _syncTripTimer(nextState, mapped);
      _persistActiveOrder();
      _refreshRoutePreview();
    } catch (_) {}
  }

  void _connectOrderSocket() {
    final opts = IO.OptionBuilder()
        .setTransports(['websocket', 'polling']) // fallback to polling if websocket blocked
        .setPath('/socket.io/')
        .disableAutoConnect()
        .enableReconnection()
        .setReconnectionDelay(2000)
        .setReconnectionDelayMax(10000)
        .setReconnectionAttempts(double.maxFinite.toInt())
        .setTimeout(20000)
        .setAuth({'token': widget.token})
        .setExtraHeaders({'Authorization': 'Bearer ${widget.token}'})
        .build();

    final s = IO.io(_apiBaseUrl, opts);
    s.onConnect((_) {
      if (!mounted) return;
      setState(() {
        _socketConnected = true;
        _socketEverConnected = true;
      });
      _emitDriverStatusGuarded(_driverOnline ? 'online' : 'offline', socket: s);
      unawaited(_loadActiveOrder());
    });
    s.onDisconnect((_) {
      if (!mounted) return;
      setState(() => _socketConnected = false);
    });
    s.onReconnect((_) {
      if (!mounted) return;
      setState(() {
        _socketConnected = true;
        _socketEverConnected = true;
      });
      _emitDriverStatusGuarded(_driverOnline ? 'online' : 'offline', socket: s);
      unawaited(_recoverActiveOrderState());
    });
    s.on('order:new', (data) {
      if (!mounted) return;
      if (!_driverOnline) return;
      if (_earningsLimitReached) return;
      // Не показываем новый заказ, если уже есть активный (не предзаказ)
      final hasActiveOrder = _order != null &&
          _orderState != _DriverOrderUiState.incoming &&
          _orderState != _DriverOrderUiState.declined;
      if (hasActiveOrder) return;
      if (data is Map && data['order'] is Map) {
        final order = Map<String, dynamic>.from(data['order'] as Map);
        order['notifiedAt'] ??= data['notifiedAt'] ?? DateTime.now().toIso8601String();
        final mapped = _mapOrder(order);
        // Не показываем заказ, если он уже сохранён как предзаказ
        if (_preorder != null && mapped.id == _preorder!.id) return;
        setState(() {
          _order = mapped;
          _orderState = _DriverOrderUiState.incoming;
          _shouldFitRoute = true;
        });
        _persistActiveOrder();
        unawaited(_fetchOrderDetails(mapped.id));
        _refreshRoutePreview();
        unawaited(_showOrderNotification(_order!));
      }
    });
    s.on('order:nearby', (data) {
      if (!mounted) return;
      if (!_driverOnline) return;
      if (data is Map && data['order'] is Map) {
        final order = Map<String, dynamic>.from(data['order'] as Map);
        unawaited(_showNearbyOrderNotification(_mapOrder(order)));
      }
    });
    s.on('order:status', (data) {
      if (!mounted) return;
      if (data is Map) {
        final orderId = (data['orderId'] ?? '').toString();
        final status = (data['status'] ?? '').toString();
        final driverPhone = (data['driverPhone'] ?? '').toString();

        // Проверяем, не относится ли обновление к предзаказу
        if (_preorder != null && orderId == _preorder!.id) {
          if (status == 'canceled') {
            // Клиент отменил предзаказ
            _preorderCheckTimer?.cancel();
            setState(() {
              _preorder = null;
              _preorderReminderShown60 = false;
              _preorderReminderShown30 = false;
              _preorderActivating = false;
            });
            unawaited(_persistPreorder());
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Клиент отменил предзаказ'),
                  backgroundColor: Color(0xFFD32F2F),
                  duration: Duration(seconds: 3),
                ),
              );
            }
          }
          return;
        }

        if (_order == null) return;
        if (orderId == _order!.id && status != 'searching') {
          // Другой водитель принял заказ
          if (status == 'accepted' && driverPhone.isNotEmpty && driverPhone != _driverPhone) {
            _showAlreadyTakenOverlay();
            return;
          }
          // Клиент отменил заказ
          if (status == 'canceled') {
            _showOrderCanceledOverlay();
            return;
          }
          final nextState = _statusToUi(status);
          setState(() {
            _orderState = nextState;
            _shouldFitRoute = nextState == _DriverOrderUiState.accepted ||
                nextState == _DriverOrderUiState.enroute ||
                nextState == _DriverOrderUiState.arrived ||
                nextState == _DriverOrderUiState.started;
          });
          _syncTripTimer(nextState, _order);
          _persistActiveOrder();
          unawaited(_fetchOrderDetails(orderId));
          _refreshRoutePreview();
          if (nextState == _DriverOrderUiState.incoming) {
            Future<void>.delayed(const Duration(milliseconds: 800), () {
              if (!mounted) return;
              setState(() {
                _order = null;
                _orderState = _DriverOrderUiState.incoming;
              });
              _syncTripTimer(_DriverOrderUiState.incoming, null);
              _persistActiveOrder();
              _clearRouteState();
              _refreshRoutePreview();
            });
          }
          // При completed — не сбрасываем автоматически,
          // водитель закроет вручную кнопкой «ГОТОВО»
        }
      }
    });
    // Заказ забран другим водителем (при показе incoming)
    s.on('order:taken', (data) {
      if (!mounted) return;
      if (data is Map && _order != null) {
        final orderId = (data['orderId'] ?? '').toString();
        final takenBy = (data['driverPhone'] ?? '').toString();
        if (orderId == _order!.id && takenBy != _driverPhone) {
          _showAlreadyTakenOverlay();
        }
      }
    });
    // Клиент отменил заказ (водитель уже принял)
    s.on('order:canceled', (data) {
      if (!mounted) return;
      if (data is Map && _order != null) {
        final orderId = (data['orderId'] ?? '').toString();
        if (orderId == _order!.id) {
          _showOrderCanceledOverlay();
        }
      }
    });
    // Водитель заблокирован админом
    s.on('driver:blocked', (data) {
      if (!mounted) return;
      final payload = data is Map ? Map<String, dynamic>.from(data) : const <String, dynamic>{};
      setState(() {
        _driverBlocked = true;
        _driverBlockReason = payload['reason']?.toString();
        _driverBlockUntil = DateTime.tryParse(payload['until']?.toString() ?? '');
        _driverOnline = false;
        _order = null;
        _orderState = _DriverOrderUiState.incoming;
      });
      _clearRouteState();
      _refreshRoutePreview();
    });
    // Водитель разблокирован админом
    s.on('driver:unblocked', (_) {
      if (!mounted) return;
      setState(() {
        _driverBlocked = false;
        _driverBlockReason = null;
        _driverBlockUntil = null;
      });
    });
    s.on('driver:earnings-limit', (_) {
      if (!mounted) return;
      setState(() {
        _driverOnline = false;
      });
      SharedPreferences.getInstance().then((p) => p.setBool('driver_online_v1', false));
      _showEarningsLimitOverlay();
    });
    // Комиссия погашена — водитель снова может принимать заказы
    s.on('commission:cleared', (_) {
      if (!mounted) return;
      setState(() {
        _earningsLimitReached = false;
        // Убираем оверлей блокировки, если он показан
        if (_resultOverlay == _ActionResultOverlay.earningsLimit) {
          _resultOverlay = _ActionResultOverlay.none;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Комиссия погашена! Вы снова можете принимать заказы'),
          backgroundColor: Color(0xFF1B7F3A),
          duration: Duration(seconds: 4),
        ),
      );
      // Обновить данные профиля (поездки, заработок) с сервера
      unawaited(_checkBlockStatus());
    });
    s.onConnectError((data) {
      // Не разлогиниваем при обычных сетевых сбоях сокета.
      // Выходим только если сервер явно сообщил об ошибке авторизации.
      if (_isExplicitSocketAuthError(data)) {
        _handleSessionExpired();
      }
    });
    _socket = s;
    s.connect();
  }

  Future<void> _recoverActiveOrderState() async {
    await _loadActiveOrder();
    if (_order == null) {
      await _restoreActiveOrder();
    }
  }

  _DriverOrder _mapOrder(Map<String, dynamic> order) {
    final from = order['from'] as Map? ?? const {};
    final to = order['to'] as Map? ?? const {};
    double? _toDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    Point? _pointFrom(dynamic raw) {
      if (raw is Map) {
        final lat = _toDouble(raw['lat'] ?? raw['latitude']);
        final lng = _toDouble(raw['lng'] ?? raw['lon'] ?? raw['longitude']);
        if (lat != null && lng != null) {
          return Point(latitude: lat, longitude: lng);
        }
      }
      return null;
    }
    String _cleanAddress(String raw) {
      var value = raw.trim();
      final prefixes = <String>[
        'Россия,',
        'Russian Federation,',
        'Russia,',
        'РФ,',
      ];
      for (final p in prefixes) {
        if (value.startsWith(p)) {
          value = value.substring(p.length).trimLeft();
          break;
        }
      }
      return value;
    }

    final fromTitleRaw = (order['fromAddress']?.toString() ?? '').trim();
    final toTitleRaw = (order['toAddress']?.toString() ?? '').trim();
    final fromTitle = fromTitleRaw.isNotEmpty
        ? _cleanAddress(fromTitleRaw)
        : '(${from['lat']}, ${from['lng']})';
    final toTitle = toTitleRaw.isNotEmpty
        ? _cleanAddress(toTitleRaw)
        : '(${to['lat']}, ${to['lng']})';
    final pickupPoint = _pointFrom(from) ??
        _pointFrom({'lat': order['fromLat'], 'lng': order['fromLng']});
    final dropoffPoint = _pointFrom(to) ??
        _pointFrom({'lat': order['toLat'], 'lng': order['toLng']});
    final fromLat = pickupPoint?.latitude;
    final fromLng = pickupPoint?.longitude;
    final toLat = dropoffPoint?.latitude;
    final toLng = dropoffPoint?.longitude;
    final tripKm = (fromLat != null && fromLng != null && toLat != null && toLng != null)
        ? _distanceKm(fromLat, fromLng, toLat, toLng)
        : 0.0;
    final tripEtaMin = tripKm > 0 ? (tripKm / 0.5).round() : 0; // ~30 km/h
    final priceFrom = int.tryParse(order['priceFrom']?.toString() ?? '') ?? 0;
    final priceFinal = int.tryParse(order['priceFinal']?.toString() ?? '') ?? 0;
    final promoPercent = int.tryParse(order['promoDiscountPercent']?.toString() ?? '') ?? 0;
    final priceRub = (promoPercent > 0 && priceFrom > 0)
        ? (priceFrom * (1 - promoPercent / 100)).round()
        : priceFrom;
    final serviceIndex = int.tryParse(order['serviceIndex']?.toString() ?? '') ?? 0;
    final startedAtRaw = order['startedAt']?.toString();
    final completedAtRaw = order['completedAt']?.toString();
    final startedAt = startedAtRaw != null ? DateTime.tryParse(startedAtRaw) : null;
    final completedAt = completedAtRaw != null ? DateTime.tryParse(completedAtRaw) : null;
    final clientPhone = (order['clientId']?.toString() ?? '').trim();
    final kmOutside = double.tryParse(order['kmOutsideMkad']?.toString() ?? '') ?? 0.0;
    final scheduledAtRaw = order['scheduledAt']?.toString();
    final scheduledAt = scheduledAtRaw != null ? DateTime.tryParse(scheduledAtRaw) : null;
    final notifiedAtRaw = order['notifiedAt']?.toString();
    final createdAtRaw = order['createdAt']?.toString();
    final notifiedAt = DateTime.tryParse(notifiedAtRaw ?? '') ?? DateTime.tryParse(createdAtRaw ?? '');
    final commentRaw = (order['comment']?.toString() ?? '').trim();
    final wishRaw = (order['wish']?.toString() ?? '').trim();
    return _DriverOrder(
      id: order['id']?.toString() ?? '',
      pickupTitle: fromTitle,
      dropoffTitle: toTitle,
      pickupPoint: pickupPoint,
      dropoffPoint: dropoffPoint,
      pickupDistanceKm: 0,
      pickupEtaMin: 0,
      tripDistanceKm: tripKm,
      tripEtaMin: tripEtaMin,
      priceRub: priceRub,
      priceFinal: priceFinal > 0 ? priceFinal : null,
      promoDiscountPercent: promoPercent,
      serviceIndex: serviceIndex,
      kmOutsideMkad: kmOutside,
      startedAt: startedAt,
      completedAt: completedAt,
      clientPhone: clientPhone.isNotEmpty ? clientPhone : null,
      scheduledAt: scheduledAt,
      notifiedAt: notifiedAt,
      comment: commentRaw.isNotEmpty ? commentRaw : null,
      wish: wishRaw.isNotEmpty ? wishRaw : null,
    );
  }

  Future<void> _fetchOrderDetails(String orderId) async {
    if (_fetchingOrderDetails) return;
    _fetchingOrderDetails = true;
    try {
      // До принятия заказа сервер может временно не отдавать детали водителю.
      // Это не проблема сессии, поэтому не используем _authGet здесь.
      final res = await http.get(
        Uri.parse('$_apiBaseUrl/api/orders/$orderId'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final orderRaw = map['order'];
      if (orderRaw is Map) {
        final rawMap = Map<String, dynamic>.from(orderRaw);
        final nextOrder = _mapOrder(rawMap);
        if (!mounted) return;
        setState(() {
          _order = nextOrder;
        });
        _syncTripTimer(_orderState, nextOrder);
        _persistActiveOrder();
        _refreshRoutePreview();
      }
    } catch (_) {
    } finally {
      _fetchingOrderDetails = false;
    }
  }

  double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const earth = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earth * c;
  }

  double _degToRad(double deg) => deg * (math.pi / 180.0);

  Future<BitmapDescriptor> _ensurePickupPinIcon() async {
    final cached = _pickupPinIcon;
    if (cached != null) return cached;
    try {
      final built = await _buildPickupMarkerIcon();
      _pickupPinIcon = built;
      return built;
    } catch (_) {
      final fallback = await _buildFallbackDot(const ui.Color(0xFF6A00FF));
      _pickupPinIcon = fallback;
      return fallback;
    }
  }

  Future<BitmapDescriptor> _ensureFinishFlagIcon() async {
    final cached = _finishFlagIcon;
    if (cached != null) return cached;
    try {
      final built = await _buildFinishFlagIcon();
      _finishFlagIcon = built;
      return built;
    } catch (_) {
      final fallback = await _buildFallbackDot(const ui.Color(0xFF2E5BFF));
      _finishFlagIcon = fallback;
      return fallback;
    }
  }

  Future<BitmapDescriptor> _buildFallbackDot(ui.Color color) async {
    const size = 48.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, size, size));
    final paint = ui.Paint()..color = color;
    canvas.drawCircle(const ui.Offset(size / 2, size / 2), size / 2.5, paint);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      const transparentPngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9YlGg0QAAAAASUVORK5CYII=';
      return BitmapDescriptor.fromBytes(base64Decode(transparentPngBase64));
    }
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }

  /// Палочка-пин (stick pin) — такой же как в клиенте
  Future<BitmapDescriptor> _buildStickPinIcon(ui.Color color) async {
    const w = 24.0;
    const h = 80.0;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, w, h));

    // Палочка с градиентом (прозрачная сверху → цвет снизу)
    final stickGradient = ui.Paint()
      ..shader = ui.Gradient.linear(
        const ui.Offset(w / 2, 4),
        const ui.Offset(w / 2, h - 16),
        [color.withOpacity(0.0), color.withOpacity(0.90)],
      );
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        const ui.Rect.fromLTWH(w / 2 - 1.5, 4, 3, h - 16),
        const ui.Radius.circular(1.5),
      ),
      stickGradient,
    );

    // Кружок внизу
    final dotPaint = ui.Paint()..color = color;
    canvas.drawCircle(const ui.Offset(w / 2, h - 6), 6, dotPaint);

    // Белая обводка кружка
    final borderPaint = ui.Paint()
      ..color = const ui.Color(0xD9FFFFFF)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(const ui.Offset(w / 2, h - 6), 6, borderPaint);

    // Тень под кружком
    final shadowPaint = ui.Paint()
      ..color = const ui.Color(0x4D000000)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
    canvas.drawCircle(const ui.Offset(w / 2, h - 4), 4, shadowPaint);

    final picture = recorder.endRecording();
    final image = await picture.toImage(w.toInt(), h.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      return _buildFallbackDot(color);
    }
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }

  Future<BitmapDescriptor> _buildPickupMarkerIcon() async {
    return _buildStickPinIcon(const ui.Color(0xFFFFFFFF)); // Белый — точка A
  }

  Future<BitmapDescriptor> _buildFinishFlagIcon() async {
    return _buildStickPinIcon(const ui.Color(0xFFFF3D00)); // Красно-оранжевый — точка B
  }

  void _acceptOrder() {
    final order = _order;
    if (order == null) return;
    unawaited(_stopIncomingOrderSound());
    if (_earningsLimitReached) {
      _showEarningsLimitOverlay();
      return;
    }

    // Определяем, является ли заказ предзаказом (scheduledAt > 15 мин в будущем)
    final isPreorder = order.scheduledAt != null &&
        order.scheduledAt!.isAfter(DateTime.now().add(const Duration(minutes: 15)));

    if (isPreorder) {
      // ── Предзаказ: СРАЗУ перемещаем в _preorder и очищаем _order ──
      // Это предотвращает дублирование карточки от order:status / _loadActiveOrder
      setState(() {
        _preorder = order;
        _order = null;
        _orderState = _DriverOrderUiState.incoming;
        _resultOverlay = _ActionResultOverlay.none;
      });
      unawaited(_persistPreorder());
      _persistActiveOrder();
      _clearRouteState();
      _refreshRoutePreview();
      _startPreorderCheckTimer();

      _socket?.emitWithAck('order:accept', {'orderId': order.id}, ack: (response) {
        if (!mounted) return;
        final data = response is Map ? response : (response is List && response.isNotEmpty ? response[0] : null);
        if (data is Map && data['ok'] == true) {
          // Успешно — водитель остаётся онлайн
          _socket?.emit('driver:status', {'status': _driverOnline ? 'online' : 'offline'});
          if (mounted) {
            final sa = order.scheduledAt!;
            final timeStr = '${sa.hour.toString().padLeft(2, '0')}:${sa.minute.toString().padLeft(2, '0')}';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Предзаказ на $timeStr принят. Вы можете брать другие заказы.'),
                backgroundColor: const Color(0xFF7C3AED),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        } else if (data is Map && data['error'] == 'EARNINGS_LIMIT_REACHED') {
          // Откатываем — предзаказ не принят
          _preorderCheckTimer?.cancel();
          setState(() {
            _preorder = null;
            _preorderReminderShown60 = false;
            _preorderReminderShown30 = false;
          });
          unawaited(_persistPreorder());
          _showEarningsLimitOverlay();
        } else {
          // Откатываем — заказ уже принят другим
          _preorderCheckTimer?.cancel();
          setState(() {
            _preorder = null;
            _preorderReminderShown60 = false;
            _preorderReminderShown30 = false;
          });
          unawaited(_persistPreorder());
          _showAlreadyTakenOverlay();
        }
      });
      // Фолбэк: если ack не пришёл за 5 сек — считаем принятым
      Future<void>.delayed(const Duration(seconds: 5), () {
        if (!mounted) return;
        if (_preorder?.id == order.id) {
          // Предзаказ уже в _preorder — всё ок, просто возвращаем онлайн-статус
          _socket?.emit('driver:status', {'status': _driverOnline ? 'online' : 'offline'});
        }
      });
    } else {
      // ── Обычный заказ ──
      _socket?.emit('driver:status', {'status': 'busy'});
      _socket?.emitWithAck('order:accept', {'orderId': order.id}, ack: (response) {
        if (!mounted) return;
        final data = response is Map ? response : (response is List && response.isNotEmpty ? response[0] : null);
        if (data is Map && data['ok'] == true) {
          setState(() {
            _orderState = _DriverOrderUiState.accepted;
            _shouldFitRoute = true;
          });
          Future<void>.delayed(const Duration(milliseconds: 800), () {
            if (!mounted) return;
            setState(() {
              _resultOverlay = _ActionResultOverlay.none;
            });
          });
          _sendCurrentLocationNow();
          unawaited(_ensureDriverPoint().then((_) => _refreshRoutePreview()));
          unawaited(_fetchOrderDetails(order.id));
          _refreshRoutePreview();
        } else if (data is Map && data['error'] == 'EARNINGS_LIMIT_REACHED') {
          _showEarningsLimitOverlay();
        } else {
          _showAlreadyTakenOverlay();
        }
      });
      // Фолбэк для обычного заказа
      Future<void>.delayed(const Duration(seconds: 5), () {
        if (!mounted) return;
        if (_order?.id == order.id && _orderState == _DriverOrderUiState.incoming && _resultOverlay == _ActionResultOverlay.accepted) {
          setState(() {
            _orderState = _DriverOrderUiState.accepted;
            _shouldFitRoute = true;
            _resultOverlay = _ActionResultOverlay.none;
          });
          _sendCurrentLocationNow();
          unawaited(_ensureDriverPoint().then((_) => _refreshRoutePreview()));
          unawaited(_fetchOrderDetails(order.id));
          _refreshRoutePreview();
        }
      });
    }
  }

  void _showAlreadyTakenOverlay() {
    unawaited(_stopIncomingOrderSound());
    setState(() {
      _resultOverlay = _ActionResultOverlay.alreadyTaken;
    });
    Future<void>.delayed(const Duration(milliseconds: 2000), () {
      if (!mounted) return;
      setState(() {
        _resultOverlay = _ActionResultOverlay.none;
        _order = null;
        _orderState = _DriverOrderUiState.incoming;
        if (_earningsLimitReached) {
          _driverOnline = false;
        }
      });
      _syncTripTimer(_DriverOrderUiState.incoming, null);
      _persistActiveOrder();
      _clearRouteState();
      _refreshRoutePreview();
      if (_earningsLimitReached) {
        _socket?.emit('driver:status', {'status': 'offline'});
      } else {
        _socket?.emit('driver:status', {'status': _driverOnline ? 'online' : 'offline'});
      }
    });
  }

  void _showOrderCanceledOverlay() {
    unawaited(_stopIncomingOrderSound());
    setState(() {
      _resultOverlay = _ActionResultOverlay.orderCanceled;
    });
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() {
        _resultOverlay = _ActionResultOverlay.none;
        _order = null;
        _orderState = _DriverOrderUiState.incoming;
        // Если комиссия не оплачена — водитель остаётся офлайн, не может принимать заказы
        if (_earningsLimitReached) {
          _driverOnline = false;
        }
      });
      _syncTripTimer(_DriverOrderUiState.incoming, null);
      _persistActiveOrder();
      _clearRouteState();
      _refreshRoutePreview();
      // Если комиссия не оплачена — принудительно офлайн
      if (_earningsLimitReached) {
        _socket?.emit('driver:status', {'status': 'offline'});
      } else {
        _socket?.emit('driver:status', {'status': _driverOnline ? 'online' : 'offline'});
      }
      // Если есть предзаказ и время подошло — активируем
      if (_preorder != null && !_earningsLimitReached) {
        final diff = _preorder!.scheduledAt?.difference(DateTime.now());
        if (diff != null && diff.inMinutes <= 15) {
          _activatePreorder();
        }
      }
    });
  }

  void _showEarningsLimitOverlay() {
    final hasActiveOrder = _order != null &&
        _orderState != _DriverOrderUiState.incoming &&
        _orderState != _DriverOrderUiState.declined;
    setState(() {
      _earningsLimitReached = true;
      // Если есть активный заказ — не прерываем его, только ставим флаг.
      // Оверлей появится после завершения/отмены заказа.
      if (!hasActiveOrder) {
        _resultOverlay = _ActionResultOverlay.earningsLimit;
        _driverOnline = false;
      }
    });
    if (!hasActiveOrder) {
      _emitDriverStatusGuarded('offline');
      SharedPreferences.getInstance().then((p) => p.setBool('driver_online_v1', false));
      Future<void>.delayed(const Duration(milliseconds: 3500), () {
        if (!mounted) return;
        setState(() {
          _resultOverlay = _ActionResultOverlay.none;
          _order = null;
          _orderState = _DriverOrderUiState.incoming;
        });
        _syncTripTimer(_DriverOrderUiState.incoming, null);
        _persistActiveOrder();
        _clearRouteState();
        _refreshRoutePreview();
      });
    }
  }

  void _showRegistrationApprovedDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0B0D12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF6DD66D).withValues(alpha: 0.15),
                ),
                child: const Icon(Icons.verified, color: Color(0xFF6DD66D), size: 36),
              ),
              const SizedBox(height: 16),
              Text(
                'Документы подтверждены!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _white95,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Теперь вы можете принимать заказы',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _white60,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accentColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('Понятно', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Немедленно отправить текущую геопозицию на сервер
  void _sendCurrentLocationNow() {
    final point = _driverPoint;
    if (point != null) {
      _socket?.emit('driver:location', {'lat': point.latitude, 'lng': point.longitude});
      return;
    }
    // Если точка ещё не известна — запросить и отправить
    unawaited(() async {
      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        ).timeout(const Duration(seconds: 5));
        _driverPoint = Point(latitude: pos.latitude, longitude: pos.longitude);
        _socket?.emit('driver:location', {'lat': pos.latitude, 'lng': pos.longitude});
      } catch (_) {}
    }());
  }

  void _declineOrder() {
    final order = _order;
    if (order == null) return;
    unawaited(_stopIncomingOrderSound());
    _socket?.emit('driver:status', {'status': _driverOnline ? 'online' : 'offline'});
    _socket?.emit('order:decline', {'orderId': order.id});
    setState(() {
      _orderState = _DriverOrderUiState.declined;
    });
    _persistActiveOrder();
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      setState(() {
        _order = null;
        _orderState = _DriverOrderUiState.incoming;
      });
      _persistActiveOrder();
      _clearRouteState();
      _refreshRoutePreview();
    });
  }

  void _updateOrderStatus(String status) {
    final order = _order;
    if (order == null) return;
    _socket?.emit('order:update', {'orderId': order.id, 'status': status});
    setState(() {
      _orderState = switch (status) {
        'enroute' => _DriverOrderUiState.enroute,
        'arrived' => _DriverOrderUiState.arrived,
        'started' => _DriverOrderUiState.started,
        'completed' => _DriverOrderUiState.completed,
        _ => _orderState,
      };
      _shouldFitRoute = status == 'enroute' || status == 'arrived' || status == 'started';
    });
    // При смене статуса отправить позицию, чтобы клиент сразу получил ETA
    _sendCurrentLocationNow();
    _syncTripTimer(_orderState, order);
    _persistActiveOrder();
    unawaited(_ensureDriverPoint().then((_) => _refreshRoutePreview()));
    unawaited(_fetchOrderDetails(order.id));
    _refreshRoutePreview();
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    final locationPermission = _locationPermission;
    final locationAlwaysPermission = _locationAlwaysPermission;

    final needsAlways = locationAlwaysPermission != null && !locationAlwaysPermission.isGranted;
    final shouldShowLocationPrompt =
        locationPermission == null || (!locationPermission.isGranted) || needsAlways;

    final locationTitle = switch (locationPermission) {
      null => 'Проверяем геолокацию…',
      PermissionStatus.granted => '',
      PermissionStatus.denied => 'Нужна геолокация',
      PermissionStatus.restricted => 'Нужна геолокация',
      PermissionStatus.limited => 'Нужна геолокация',
      PermissionStatus.permanentlyDenied => 'Разрешение отключено',
      PermissionStatus.provisional => 'Нужна геолокация',
    };

    final locationSubtitle = switch (locationPermission) {
      null => 'Подготовка…',
      PermissionStatus.granted => '',
      PermissionStatus.denied => 'Разрешите доступ, чтобы видеть подачу и маршрут.',
      PermissionStatus.restricted => 'Разрешите доступ, чтобы видеть подачу и маршрут.',
      PermissionStatus.limited => 'Разрешите доступ, чтобы видеть подачу и маршрут.',
      PermissionStatus.permanentlyDenied => 'Откройте настройки и включите доступ к геолокации.',
      PermissionStatus.provisional => 'Разрешите доступ, чтобы видеть подачу и маршрут.',
    };

    final effectiveTitle = needsAlways ? 'Нужна геолокация в фоне' : locationTitle;
    final effectiveSubtitle = needsAlways
        ? 'Разрешите доступ «Всегда», чтобы заказы приходили в фоне.'
        : locationSubtitle;

    return Scaffold(
      backgroundColor: const Color(0xFF05060A),
      body: Stack(
        children: [
          Positioned.fill(
            child: _MapBlock(
              initialPoint: _initialPoint,
              mapObjects: _mapObjects,
              onMapCreated: (c) {
                _mapController = c;
                _refreshRoutePreview();
              },
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _black08,
                      _black65,
                    ],
                  ),
                ),
              ),
            ),
          ),
          // ─── Индикатор потери связи (только после первого подключения) ──
          if (_socketEverConnected && !_socketConnected)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  color: const Color(0xFFD32F2F),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                      SizedBox(width: 8),
                      Text('Нет связи с сервером…', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            right: 14,
            top: MediaQuery.of(context).size.height * 0.32,
            child: SafeArea(
              left: false,
              child: _TopIconButton(
                icon: Icons.my_location,
                onTap: _centerOnDriver,
              ),
            ),
          ),
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TopIconButton(
                          icon: Icons.person_outline,
                          onTap: () {
                            Navigator.of(context).push(
                              _FastPageRoute<void>(
                                builder: (_) => _DriverProfilePage(
                                  online: _driverOnline,
                                  onOnlineChanged: _setDriverOnline,
                                  onLogout: widget.onLogout,
                                  token: widget.token,
                                  driverPhone: _driverPhone,
                                ),
                              ),
                            );
                          },
                        ),
                        // ── Лейбл «Ноль Промилле» по центру ──
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: _black45,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _white08),
                          ),
                          child: Text(
                            'Ноль Промилле',
                            style: TextStyle(
                              color: _white85,
                              fontWeight: FontWeight.w900,
                              fontSize: 11,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        // Справа: звонок сверху, навигатор под ним
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _TopIconButton(
                              icon: Icons.call,
                              onTap: _callSupport,
                            ),
                            const SizedBox(height: 6),
                            _TopIconButton(
                              icon: Icons.navigation,
                              onTap: _openManualRouteDialog,
                            ),
                          ],
                        ),
                      ],
                    ),
                    Expanded(
                      child: IgnorePointer(
                        child: Container(),
                      ),
                    ),
                    if (shouldShowLocationPrompt)
                      _PermissionPrompt(
                        title: effectiveTitle,
                        subtitle: effectiveSubtitle,
                        isLoading: _requestingLocation,
                        isPermanentlyDenied: locationPermission?.isPermanentlyDenied ?? false,
                        onRequest: _requestLocationPermission,
                      ),
                    Expanded(
                      child: IgnorePointer(
                        child: Container(),
                      ),
                    ),
                    // ── Баннер предзаказа (если есть) ──
                    if (_preorder != null && _preorder!.scheduledAt != null)
                      _StoredPreorderBanner(
                        preorder: _preorder!,
                        onCancel: _cancelPreorder,
                        onActivate: () {
                          if (_order == null || _orderState == _DriverOrderUiState.incoming) {
                            _activatePreorder();
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Завершите текущий заказ, затем предзаказ активируется автоматически')),
                            );
                          }
                        },
                      ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 0),
                      child: _resultOverlay == _ActionResultOverlay.none
                          ? (_order == null
                              ? const SizedBox.shrink()
                              : _IncomingOrderCard(
                                  order: _order!,
                                  state: _orderState,
                                  canAct: _order != null && _orderState == _DriverOrderUiState.incoming,
                                  onAccept: () {
                                    setState(() {
                                      _resultOverlay = _ActionResultOverlay.accepted;
                                    });
                                    _acceptOrder();
                                  },
                                  onDecline: () {
                                    _declineOrder();
                                    setState(() {
                                      _resultOverlay = _ActionResultOverlay.declined;
                                    });
                                    Future<void>.delayed(const Duration(milliseconds: 900), () {
                                      if (!mounted) return;
                                      setState(() {
                                        _resultOverlay = _ActionResultOverlay.none;
                                      });
                                    });
                                  },
                                  onTimeout: () {
                                    _declineOrder();
                                    setState(() {
                                      _resultOverlay = _ActionResultOverlay.declined;
                                    });
                                    Future<void>.delayed(const Duration(milliseconds: 900), () {
                                      if (!mounted) return;
                                      setState(() {
                                        _resultOverlay = _ActionResultOverlay.none;
                                      });
                                    });
                                  },
                                  onEnroute: () => _updateOrderStatus('enroute'),
                                  onArrived: () => _updateOrderStatus('arrived'),
                                  onStarted: () => _updateOrderStatus('started'),
                                  onCompleted: () => _updateOrderStatus('completed'),
                                  onNavigate: _openOrderNavigator,
                                  tripElapsed: (_orderState == _DriverOrderUiState.started ||
                                          _orderState == _DriverOrderUiState.completed)
                                      ? _formatTripElapsed(_tripElapsedSeconds)
                                      : null,
                                  tripPriceRub: ((_orderState == _DriverOrderUiState.started ||
                                              _orderState == _DriverOrderUiState.completed) &&
                                          _tripPriceRub > 0)
                                      ? _tripPriceRub
                                      : null,
                                  onDismissCompleted: () {
                                    setState(() {
                                      _order = null;
                                      _orderState = _DriverOrderUiState.incoming;
                                    });
                                    _syncTripTimer(_DriverOrderUiState.incoming, null);
                                    _persistActiveOrder();
                                    _clearRouteState();
                                    _refreshRoutePreview();
                                    // После завершения заказа — гарантируем переподключение сокета
                                    final socket = _socket;
                                    if (socket != null && !socket.connected) {
                                      socket.connect();
                                    } else if (socket != null && socket.connected) {
                                      // Восстанавливаем статус — сокет мог "забыть" что мы online
                                      socket.emit('driver:status', {'status': _driverOnline ? 'online' : 'offline'});
                                    }
                                    // После завершения заказа — показать блокировку комиссии, если лимит достигнут
                                    if (_earningsLimitReached) {
                                      setState(() {
                                        _driverOnline = false;
                                      });
                                      _socket?.emit('driver:status', {'status': 'offline'});
                                    }
                                    // Если есть предзаказ и время подходит — активируем
                                    if (_preorder != null) {
                                      final diff = _preorder!.scheduledAt?.difference(DateTime.now());
                                      if (diff != null && diff.inMinutes <= 15) {
                                        _activatePreorder();
                                      }
                                    }
                                  },
                                ))
                          : _ActionResultCard(state: _resultOverlay),
                    ),
                    Offstage(offstage: true, child: Text('$_counter')),
                  ],
                ),
              ),
            ),
          ),
          // ─── Экран блокировки ──────────────────────────────────
          if (_driverBlocked)
            Positioned.fill(
              child: Container(
                color: const Color(0xF005060A),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              colors: [Color(0xFFFF2D55), Color(0xFFE11B22)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFFE11B22).withOpacity(0.45),
                                blurRadius: 14,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.block,
                            color: Colors.white,
                            size: 42,
                          ),
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          'Вы заблокированы',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _driverBlockMessage(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _white55,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // ─── Экран «Погасите комиссию» ───────────────────────────
          // Не показываем оверлей при активном заказе — водитель должен закончить поездку
          if (!_driverBlocked && _earningsLimitReached &&
              (_order == null || _orderState == _DriverOrderUiState.incoming))
            Positioned.fill(
              child: GestureDetector(
                onTap: () {},
                behavior: HitTestBehavior.opaque,
                child: Container(
                color: const Color(0xF005060A),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [Color(0xFFFFB24A), Color(0xFFE89B1E)],
                            ),
                          ),
                          child: const Icon(
                            Icons.lock,
                            color: Colors.white,
                            size: 42,
                          ),
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          'Погасите комиссию',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Вы набрали лимит заработка.\nОплатите комиссию, чтобы продолжить\nпринимать заказы.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _white55,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Обратитесь к администратору',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _white35,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _ActionResultOverlay {
  none,
  accepted,
  declined,
  alreadyTaken,
  orderCanceled,
  earningsLimit,
}

class _TopIconButton extends StatelessWidget {
  const _TopIconButton({required this.icon, required this.onTap});

  static final _decoration = BoxDecoration(
    borderRadius: BorderRadius.circular(14),
    color: _black35,
    border: Border.all(color: _white10),
  );

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          width: 44,
          height: 44,
          decoration: _decoration,
          child: Icon(icon, color: _white92),
        ),
      ),
    );
  }
}

class _PermissionPrompt extends StatelessWidget {
  const _PermissionPrompt({
    required this.title,
    required this.subtitle,
    required this.isLoading,
    required this.isPermanentlyDenied,
    required this.onRequest,
  });

  final String title;
  final String subtitle;
  final bool isLoading;
  final bool isPermanentlyDenied;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _black55,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _white10),
        boxShadow: [
          BoxShadow(
            color: _black55,
            blurRadius: 14,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: _white06,
                  border: Border.all(color: _white08),
                ),
                child: Icon(Icons.my_location, color: _white90, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: _white92,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: _white72,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _accentColor,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: isLoading ? null : onRequest,
              child: isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      isPermanentlyDenied ? 'ОТКРЫТЬ НАСТРОЙКИ' : 'РАЗРЕШИТЬ ГЕОЛОКАЦИЮ',
                      style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.6),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _DriverOrderUiState {
  incoming,
  accepted,
  enroute,
  arrived,
  started,
  completed,
  declined,
}

class _DriverOrder {
  const _DriverOrder({
    required this.id,
    required this.pickupTitle,
    required this.dropoffTitle,
    required this.pickupPoint,
    required this.dropoffPoint,
    required this.pickupDistanceKm,
    required this.pickupEtaMin,
    required this.tripDistanceKm,
    required this.tripEtaMin,
    required this.priceRub,
    required this.serviceIndex,
    this.promoDiscountPercent = 0,
    this.kmOutsideMkad = 0.0,
    this.priceFinal,
    this.startedAt,
    this.completedAt,
    this.clientPhone,
    this.scheduledAt,
    this.notifiedAt,
    this.comment,
    this.wish,
  });

  const _DriverOrder.empty()
      : id = '',
        pickupTitle = 'Ожидаем заказ',
        dropoffTitle = '—',
        pickupPoint = null,
        dropoffPoint = null,
        pickupDistanceKm = 0,
        pickupEtaMin = 0,
        tripDistanceKm = 0,
        tripEtaMin = 0,
        priceRub = 0,
        serviceIndex = 0,
        promoDiscountPercent = 0,
        kmOutsideMkad = 0.0,
        priceFinal = null,
        startedAt = null,
        completedAt = null,
        clientPhone = null,
        scheduledAt = null,
        notifiedAt = null,
        comment = null,
        wish = null;

  final String id;
  final String pickupTitle;
  final String dropoffTitle;
  final Point? pickupPoint;
  final Point? dropoffPoint;
  final double pickupDistanceKm;
  final int pickupEtaMin;
  final double tripDistanceKm;
  final int tripEtaMin;
  final int priceRub;
  final int serviceIndex;
  final int promoDiscountPercent;
  final double kmOutsideMkad;
  final int? priceFinal;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? clientPhone;
  final DateTime? scheduledAt;
  final DateTime? notifiedAt;
  final String? comment;
  final String? wish;

  _DriverOrder copyWith({
    double? pickupDistanceKm,
    int? pickupEtaMin,
    double? tripDistanceKm,
    int? tripEtaMin,
    int? priceFinal,
    DateTime? startedAt,
    DateTime? completedAt,
    String? clientPhone,
    DateTime? scheduledAt,
    DateTime? notifiedAt,
    String? comment,
    String? wish,
  }) {
    return _DriverOrder(
      id: id,
      pickupTitle: pickupTitle,
      dropoffTitle: dropoffTitle,
      pickupPoint: pickupPoint,
      dropoffPoint: dropoffPoint,
      pickupDistanceKm: pickupDistanceKm ?? this.pickupDistanceKm,
      pickupEtaMin: pickupEtaMin ?? this.pickupEtaMin,
      tripDistanceKm: tripDistanceKm ?? this.tripDistanceKm,
      tripEtaMin: tripEtaMin ?? this.tripEtaMin,
      priceRub: priceRub,
      serviceIndex: serviceIndex,
      promoDiscountPercent: promoDiscountPercent,
      kmOutsideMkad: kmOutsideMkad,
      priceFinal: priceFinal ?? this.priceFinal,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      clientPhone: clientPhone ?? this.clientPhone,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      notifiedAt: notifiedAt ?? this.notifiedAt,
      comment: comment ?? this.comment,
      wish: wish ?? this.wish,
    );
  }

  double get rubPerKm {
    if (tripDistanceKm <= 0) return 0;
    return priceRub / tripDistanceKm;
  }
}

Future<void> _showOrderNotification(_DriverOrder order) async {
  final isPreorder = order.scheduledAt != null;
  String title;
  String body;
  if (isPreorder) {
    final sa = order.scheduledAt!;
    final now = DateTime.now();
    final timeStr = '${sa.hour.toString().padLeft(2, '0')}:${sa.minute.toString().padLeft(2, '0')}';
    final isToday = sa.year == now.year && sa.month == now.month && sa.day == now.day;
    final datePrefix = isToday ? 'сегодня' : '${sa.day.toString().padLeft(2, '0')}.${sa.month.toString().padLeft(2, '0')}';
    title = '⏰ Предзаказ на $datePrefix в $timeStr';
    body = '${order.pickupTitle} → ${order.dropoffTitle} • ${_formatRubAmount(order.priceRub)}'
        '${order.promoDiscountPercent > 0 ? '  (-${order.promoDiscountPercent}% клиенту)' : ''}';
  } else {
    title = 'Новый заказ';
    body = '${order.pickupTitle} → ${order.dropoffTitle} • ${_formatRubAmount(order.priceRub)}'
        '${order.promoDiscountPercent > 0 ? '  (-${order.promoDiscountPercent}% клиенту)' : ''}';
  }
  await _notifications.show(
    id: 1,
    title: title,
    body: body,
    notificationDetails: _orderNotificationDetails(),
  );
  await _playIncomingOrderSound();
}

Future<void> _showNearbyOrderNotification(_DriverOrder order) async {
  final title = 'Заказ рядом';
  final body = '${order.pickupTitle} → ${order.dropoffTitle} • ${_formatRubAmount(order.priceRub)}'
      '${order.promoDiscountPercent > 0 ? '  (-${order.promoDiscountPercent}% клиенту)' : ''}';
  await _notifications.show(
    id: 2,
    title: title,
    body: body,
    notificationDetails: _orderNotificationDetails(),
  );
  await _playIncomingOrderSound();
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.state});

  final _DriverOrderUiState state;

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch (state) {
      _DriverOrderUiState.incoming => (
          'НОВЫЙ ЗАКАЗ',
          _accentColor.withValues(alpha: 0.92),
          Colors.black,
        ),
      _DriverOrderUiState.accepted => (
          'ПРИНЯТО',
          const Color(0xFF1B7F3A).withValues(alpha: 0.92),
          Colors.white,
        ),
      _DriverOrderUiState.enroute => (
          'В ПУТИ',
          const Color(0xFF1D5B8F).withValues(alpha: 0.92),
          Colors.white,
        ),
      _DriverOrderUiState.arrived => (
          'НА МЕСТЕ',
          const Color(0xFF6A3CA5).withValues(alpha: 0.92),
          Colors.white,
        ),
      _DriverOrderUiState.started => (
          'ПОЕЗДКА',
          const Color(0xFF1B7F3A).withValues(alpha: 0.92),
          Colors.white,
        ),
      _DriverOrderUiState.completed => (
          'ЗАВЕРШЕНО',
          _black65,
          Colors.white,
        ),
      _DriverOrderUiState.declined => (
          'ОТКЛОНЕНО',
          _black65,
          Colors.white,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: _black55,
            blurRadius: 14,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.6,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _IncomingOrderCard extends StatefulWidget {
  const _IncomingOrderCard({
    required this.order,
    required this.state,
    required this.canAct,
    required this.onAccept,
    required this.onDecline,
    required this.onEnroute,
    required this.onArrived,
    required this.onStarted,
    required this.onCompleted,
    required this.onNavigate,
    this.tripElapsed,
    this.tripPriceRub,
    this.onDismissCompleted,
    this.onTimeout,
  });

  final _DriverOrder order;
  final _DriverOrderUiState state;
  final bool canAct;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onEnroute;
  final VoidCallback onArrived;
  final VoidCallback onStarted;
  final VoidCallback onCompleted;
  final VoidCallback onNavigate;
  final String? tripElapsed;
  final int? tripPriceRub;
  final VoidCallback? onDismissCompleted;
  final VoidCallback? onTimeout;

  @override
  State<_IncomingOrderCard> createState() => _IncomingOrderCardState();
}

class _IncomingOrderCardState extends State<_IncomingOrderCard>
    with SingleTickerProviderStateMixin {
  static const _acceptTimeoutMs = 10000;
  static const _urgentThresholdMs = 5000;
  static const _tickIntervalMs = 50;

  Timer? _countdownTimer;
  int _msRemaining = _acceptTimeoutMs;
  DateTime? _deadlineAt;
  late AnimationController _glowController;
  AudioPlayer? _audioPlayer;
  bool _isUrgent = false;
  bool _timedOut = false;
  bool _vibrationTriggered = false;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    if (widget.state == _DriverOrderUiState.incoming && widget.order.id.isNotEmpty) {
      _startCountdown();
    }
  }

  @override
  void didUpdateWidget(covariant _IncomingOrderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state != _DriverOrderUiState.incoming || widget.order.id.isEmpty) {
      _stopCountdown();
    } else if (oldWidget.order.id != widget.order.id ||
        oldWidget.order.notifiedAt != widget.order.notifiedAt) {
      _resetCountdown();
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _glowController.dispose();
    _audioPlayer?.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    final notifiedAt = widget.order.notifiedAt ?? DateTime.now();
    _deadlineAt = notifiedAt.add(const Duration(milliseconds: _acceptTimeoutMs));
    _msRemaining = _deadlineAt!.difference(DateTime.now()).inMilliseconds;
    _timedOut = false;
    _vibrationTriggered = false;
    if (_msRemaining <= 0) {
      _timedOut = true;
      widget.onTimeout?.call();
      return;
    }
    if (_msRemaining <= _urgentThresholdMs && !_isUrgent) {
      _isUrgent = true;
      _glowController.repeat(reverse: true);
      unawaited(_playUrgentFeedback());
    }
    _countdownTimer = Timer.periodic(const Duration(milliseconds: _tickIntervalMs), (_) {
      if (!mounted) return;
      final deadlineAt = _deadlineAt;
      _msRemaining = deadlineAt == null
          ? 0
          : deadlineAt.difference(DateTime.now()).inMilliseconds;
      
      if (_msRemaining <= _urgentThresholdMs && !_isUrgent) {
        _isUrgent = true;
        _glowController.repeat(reverse: true);
        _playUrgentFeedback();
      }
      
      if (_msRemaining <= 0 && !_timedOut) {
        _timedOut = true;
        _stopCountdown();
        widget.onTimeout?.call();
        return;
      }
      
      setState(() {});
    });
  }

  void _resetCountdown() {
    _stopCountdown();
    _isUrgent = false;
    _msRemaining = _acceptTimeoutMs;
    _deadlineAt = null;
    _vibrationTriggered = false;
    _startCountdown();
  }

  void _stopCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _glowController.stop();
    _glowController.reset();
    _audioPlayer?.stop();
    _isUrgent = false;
    _deadlineAt = null;
  }

  Future<void> _playUrgentFeedback() async {
    if (_vibrationTriggered) return;
    _vibrationTriggered = true;
    try {
      final hasVibrator = await Vibration.hasVibrator() ?? false;
      if (hasVibrator) {
        Vibration.vibrate(pattern: [0, 300, 150, 300, 150, 500], intensities: [0, 255, 0, 255, 0, 255]);
      }
    } catch (_) {
      HapticFeedback.heavyImpact();
    }
    _startAlarmSound();
  }

  Future<void> _startAlarmSound() async {
    try {
      _audioPlayer ??= AudioPlayer();
      await _audioPlayer!.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer!.play(AssetSource('sounds/fantastic_siren.mp3'));
    } catch (_) {
      _playFallbackNotification();
    }
  }

  Future<void> _playFallbackNotification() async {
    try {
      await _notifications.show(
        id: 999,
        title: 'ЗАКАЗ УХОДИТ!',
        body: 'Примите заказ, пока не поздно!',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'urgent_order',
            'Срочные заказы',
            channelDescription: 'Уведомления о заканчивающемся времени на принятие заказа',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            category: AndroidNotificationCategory.alarm,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.critical,
          ),
        ),
      );
    } catch (_) {}
  }

  double get _progress => _msRemaining / _acceptTimeoutMs;
  int get _secondsRemaining => (_msRemaining / 1000).ceil();

  @override
  Widget build(BuildContext context) {
    final isEmpty = widget.order.id.isEmpty;
    final showPreorderBanner = widget.order.scheduledAt != null &&
        (widget.state == _DriverOrderUiState.incoming || widget.state == _DriverOrderUiState.accepted);
    final isActive = widget.state == _DriverOrderUiState.enroute ||
        widget.state == _DriverOrderUiState.arrived ||
        widget.state == _DriverOrderUiState.started ||
        widget.state == _DriverOrderUiState.completed;
    final showCountdown = widget.state == _DriverOrderUiState.incoming && !isEmpty;
    final progress = _progress.clamp(0.0, 1.0);
    final urgency = 1.0 - progress;
    final borderColor = showCountdown
        ? Color.lerp(
            const Color(0xFF39D98A),
            const Color(0xFFFF3D00),
            _isUrgent ? (0.78 + _glowController.value * 0.18).clamp(0.0, 1.0) : urgency,
          )!
        : _white10;
    final borderWidth = showCountdown ? (_isUrgent ? 2.2 : 1.45) : 1.0;
    final borderShadow = showCountdown
        ? borderColor.withOpacity(_isUrgent ? 0.34 : 0.18)
        : _black65;

    final cardDecoration = BoxDecoration(
      color: _black55,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: borderColor,
        width: borderWidth,
      ),
      boxShadow: [
        BoxShadow(color: borderShadow, blurRadius: showCountdown ? 16 : 14, offset: const Offset(0, 14)),
      ],
    );

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.65,
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: cardDecoration,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showCountdown) ...[
              _SmoothCountdownBanner(
                progress: _progress,
                secondsRemaining: _secondsRemaining,
                isUrgent: _isUrgent,
                glowController: _glowController,
              ),
              const SizedBox(height: 10),
            ],
            if (showPreorderBanner) ...[
              _PreorderBanner(scheduledAt: widget.order.scheduledAt!),
              const SizedBox(height: 10),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Подача',
                        style: TextStyle(
                          color: _white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isEmpty ? 'Ожидаем заказ' : widget.order.pickupTitle,
                        maxLines: 3,
                        softWrap: true,
                        style: TextStyle(
                          color: _white95,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Куда',
                        style: TextStyle(
                          color: _white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isEmpty ? '—' : widget.order.dropoffTitle,
                        maxLines: 3,
                        softWrap: true,
                        style: TextStyle(
                          color: _white95,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      if (widget.order.comment != null && widget.order.comment!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A2636),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF2A3A50)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.chat_bubble_outline, color: _white55, size: 14),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  widget.order.comment!,
                                  style: TextStyle(color: _white78, fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (widget.order.wish != null && widget.order.wish!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A1F00),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF4A3A00)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.star_outline, color: const Color(0xFFFFB24A), size: 14),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  widget.order.wish!,
                                  style: TextStyle(color: const Color(0xFFFFD080), fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _PriceBlock(
                  order: widget.order,
                  livePrice: (widget.state == _DriverOrderUiState.started ||
                          widget.state == _DriverOrderUiState.completed)
                      ? widget.tripPriceRub
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!isEmpty) ...[
              if (!isActive) ...[
                Row(
                  children: [
                    Expanded(
                      child: _MetricChip(
                        icon: Icons.navigation,
                        label: '${widget.order.pickupDistanceKm.toStringAsFixed(1)} км • ${widget.order.pickupEtaMin} мин до подачи',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _MetricChip(
                        icon: Icons.route,
                        label: '${widget.order.tripDistanceKm.toStringAsFixed(1)} км • ${widget.order.tripEtaMin} мин поездка',
                      ),
                    ),
                  ],
                ),
              ],
              if (widget.state == _DriverOrderUiState.started &&
                  widget.tripElapsed != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _MetricChip(
                        icon: Icons.timer,
                        label: 'В пути: ${widget.tripElapsed}',
                      ),
                    ),
                  ],
                ),
              ],
              if (widget.state == _DriverOrderUiState.completed &&
                  widget.tripElapsed != null &&
                  widget.tripPriceRub != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _MetricChip(
                        icon: Icons.payments,
                        label: 'Итог: ${_formatRubAmount(widget.tripPriceRub)} • ${widget.tripElapsed}',
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        onTap: widget.onNavigate,
                        borderRadius: BorderRadius.circular(14),
                        child: Ink(
                          height: 48,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF1A2636), Color(0xFF0F1620)],
                            ),
                            border: Border.all(color: const Color(0xFF2A3A50)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.navigation_rounded, color: const Color(0xFF4A9EFF), size: 20),
                              const SizedBox(width: 8),
                              Text(
                                'Навигатор',
                                style: TextStyle(
                                  color: const Color(0xFFD0E0FF),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.order.clientPhone != null &&
                      widget.order.clientPhone!.isNotEmpty &&
                      widget.state != _DriverOrderUiState.incoming &&
                      widget.state != _DriverOrderUiState.declined) ...[
                    const SizedBox(width: 10),
                    _CallClientButton(phone: widget.order.clientPhone!),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 12),
            if (widget.state == _DriverOrderUiState.incoming)
              _ActionButton(
                label: 'ПРИНЯТЬ  ${showCountdown ? "($_secondsRemaining)" : ""}',
                isPrimary: true,
                enabled: widget.canAct && !_timedOut,
                onPressed: () {
                  _stopCountdown();
                  widget.onAccept();
                },
                isUrgent: _isUrgent,
              )
            else if (widget.state == _DriverOrderUiState.accepted)
              Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: 'В ПУТИ',
                      isPrimary: true,
                      enabled: true,
                      onPressed: widget.onEnroute,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      label: 'НА МЕСТЕ',
                      isPrimary: false,
                      enabled: true,
                      onPressed: widget.onArrived,
                    ),
                  ),
                ],
              )
            else if (widget.state == _DriverOrderUiState.enroute)
              _ActionButton(
                label: 'НА МЕСТЕ',
                isPrimary: true,
                enabled: true,
                onPressed: widget.onArrived,
              )
            else if (widget.state == _DriverOrderUiState.arrived)
              _ActionButton(
                label: 'НАЧАТЬ ПОЕЗДКУ',
                isPrimary: true,
                enabled: true,
                onPressed: widget.onStarted,
              )
            else if (widget.state == _DriverOrderUiState.started)
              _ActionButton(
                label: 'ЗАВЕРШИТЬ',
                isPrimary: true,
                enabled: true,
                onPressed: widget.onCompleted,
              )
            else if (widget.state == _DriverOrderUiState.completed) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: _white06,
                  border: Border.all(color: _white10),
                ),
                child: Text(
                  'Предложите визитку клиенту!',
                  style: TextStyle(
                    color: Colors.greenAccent.shade400.withOpacity(0.85),
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 10),
              _ActionButton(
                label: 'ГОТОВО',
                isPrimary: true,
                enabled: true,
                onPressed: widget.onDismissCompleted ?? () {},
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SmoothCountdownBanner extends StatelessWidget {
  const _SmoothCountdownBanner({
    required this.progress,
    required this.secondsRemaining,
    required this.isUrgent,
    required this.glowController,
  });

  final double progress;
  final int secondsRemaining;
  final bool isUrgent;
  final AnimationController glowController;

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);
    final urgency = 1.0 - clamped;
    final pulse = isUrgent ? glowController.value : 0.0;
    final safeBgStart = Color.lerp(const Color(0xFF187A69), const Color(0xFF1D8A75), urgency * 0.55)!;
    final safeBgEnd = Color.lerp(const Color(0xFF18435D), const Color(0xFF3F2E63), urgency * 0.55)!;
    final dangerBgStart = Color.lerp(const Color(0xFF7A2A1A), const Color(0xFFFF5A1F), urgency)!;
    final dangerBgEnd = Color.lerp(const Color(0xFF49204E), const Color(0xFFE03131), urgency)!;
    final accentColor = Color.lerp(
      const Color(0xFF7CFF9E),
      const Color(0xFFFF6B2C),
      isUrgent ? (0.78 + pulse * 0.2).clamp(0.0, 1.0) : urgency,
    )!;
    final textColor = const Color(0xFFF8FAFF);

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [dangerBgStart, dangerBgEnd],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: MediaQuery.of(context).size.width * 0.78 * clamped,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [safeBgStart, safeBgEnd],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                opacity: isUrgent ? (0.08 + pulse * 0.10) : (0.02 + urgency * 0.03),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(0.16),
                        Colors.transparent,
                        accentColor.withOpacity(0.14),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isUrgent ? accentColor : const Color(0x99FFD08A),
                width: isUrgent ? 1.5 : 1,
              ),
              boxShadow: isUrgent
                  ? [BoxShadow(color: accentColor.withOpacity(0.30), blurRadius: 14)]
                  : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (isUrgent)
                      AnimatedBuilder(
                        animation: glowController,
                        builder: (_, __) => Icon(
                          Icons.warning_amber_rounded,
                          color: Color.lerp(accentColor, const Color(0xFFFFF176), glowController.value),
                          size: 20,
                        ),
                      )
                    else
                      Icon(Icons.timer_outlined, color: accentColor, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isUrgent ? 'ПРИМИТЕ ЗАКАЗ!' : 'Время на принятие',
                        style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: accentColor.withOpacity(0.55)),
                      ),
                      child: Text(
                        '$secondsRemaining',
                        style: TextStyle(
                          color: accentColor,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Баннер предзаказа на главном экране (когда водитель свободен)
// ═══════════════════════════════════════════════════════════════
class _StoredPreorderBanner extends StatefulWidget {
  const _StoredPreorderBanner({
    required this.preorder,
    required this.onCancel,
    required this.onActivate,
  });

  final _DriverOrder preorder;
  final VoidCallback onCancel;
  final VoidCallback onActivate;

  @override
  State<_StoredPreorderBanner> createState() => _StoredPreorderBannerState();
}

class _StoredPreorderBannerState extends State<_StoredPreorderBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sa = widget.preorder.scheduledAt!;
    final now = DateTime.now();
    final diff = sa.difference(now);
    final isPast = diff.isNegative;

    final timeStr =
        '${sa.hour.toString().padLeft(2, '0')}:${sa.minute.toString().padLeft(2, '0')}';
    final isToday = sa.year == now.year && sa.month == now.month && sa.day == now.day;
    final dateLabel = isToday ? 'Сегодня' : '${sa.day.toString().padLeft(2, '0')}.${sa.month.toString().padLeft(2, '0')}';

    String countdownStr;
    if (isPast) {
      countdownStr = 'Время подачи!';
    } else {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      final s = diff.inSeconds.remainder(60);
      if (h > 0) {
        countdownStr = '$h ч $m мин';
      } else if (m > 0) {
        countdownStr = '$m мин $s сек';
      } else {
        countdownStr = '$s сек';
      }
    }

    final isUrgent = !isPast && diff.inMinutes < 15;
    final borderColor = isPast
        ? const Color(0xFFFF2D55)
        : isUrgent
            ? const Color(0xFFFFC857)
            : const Color(0xFF7C3AED);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1E2C),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor.withOpacity(0.6), width: 1.5),
        boxShadow: [
          BoxShadow(color: borderColor.withOpacity(0.15), blurRadius: 12, spreadRadius: 2),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  gradient: LinearGradient(
                    colors: isPast
                        ? [const Color(0xFFFF2D55), const Color(0xFFFF6B35)]
                        : [const Color(0xFF7C3AED), const Color(0xFFFF2D55)],
                  ),
                ),
                child: const Icon(Icons.schedule_rounded, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Предзаказ на $dateLabel в $timeStr',
                      style: const TextStyle(
                        color: Color(0xFFE8E8E8),
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${widget.preorder.pickupTitle} → ${widget.preorder.dropoffTitle}',
                      style: const TextStyle(
                        color: Color(0xAA8888AA),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: borderColor.withOpacity(0.15),
                  border: Border.all(color: borderColor.withOpacity(0.3)),
                ),
                child: Text(
                  isPast ? countdownStr : 'До подачи: $countdownStr',
                  style: TextStyle(
                    color: borderColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ),
              const Spacer(),
              if (isPast || isUrgent)
                GestureDetector(
                  onTap: widget.onActivate,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF7C3AED), Color(0xFFFF2D55)],
                      ),
                    ),
                    child: const Text(
                      'Активировать',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: widget.onCancel,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: const Color(0xFF252A38),
                  ),
                  child: const Text(
                    'Отменить',
                    style: TextStyle(
                      color: Color(0xAA8888AA),
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreorderBanner extends StatefulWidget {
  const _PreorderBanner({required this.scheduledAt});

  final DateTime scheduledAt;

  @override
  State<_PreorderBanner> createState() => _PreorderBannerState();
}

class _PreorderBannerState extends State<_PreorderBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final sa = widget.scheduledAt;
    final diff = sa.difference(now);
    final isPast = diff.isNegative;

    // Formatted time
    final timeStr =
        '${sa.hour.toString().padLeft(2, '0')}:${sa.minute.toString().padLeft(2, '0')}';
    final isToday = _isSameCalendarDay(sa, now);
    final tomorrow = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final isTomorrow = _isSameCalendarDay(sa, tomorrow);
    final dateLabel = isToday
        ? 'Сегодня'
        : isTomorrow
            ? 'Завтра'
            : '${sa.day.toString().padLeft(2, '0')}.${sa.month.toString().padLeft(2, '0')}';

    // Countdown
    String countdownStr;
    if (isPast) {
      countdownStr = 'Время подачи наступило!';
    } else {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      final s = diff.inSeconds.remainder(60);
      if (h > 0) {
        countdownStr = '$h ч $m мин $s сек';
      } else if (m > 0) {
        countdownStr = '$m мин $s сек';
      } else {
        countdownStr = '$s сек';
      }
    }

    final bool isUrgent = !isPast && diff.inMinutes < 15;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isPast
              ? [const Color(0xFFFF2D55).withOpacity(0.25), const Color(0xFFFF3D00).withOpacity(0.18)]
              : isUrgent
                  ? [const Color(0xFFF5A623).withOpacity(0.28), const Color(0xFFFF6B00).withOpacity(0.18)]
                  : [const Color(0xFF7C3AED).withOpacity(0.22), const Color(0xFF4A9EFF).withOpacity(0.15)],
        ),
        border: Border.all(
          color: isPast
              ? const Color(0xFFFF2D55).withOpacity(0.6)
              : isUrgent
                  ? const Color(0xFFF5A623).withOpacity(0.5)
                  : const Color(0xFF7C3AED).withOpacity(0.4),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPast ? Icons.warning_amber_rounded : Icons.schedule_rounded,
                color: isPast
                    ? const Color(0xFFFF5A6E)
                    : isUrgent
                        ? const Color(0xFFF5A623)
                        : const Color(0xFFB07CFF),
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                'ПРЕДЗАКАЗ',
                style: TextStyle(
                  color: isPast
                      ? const Color(0xFFFF5A6E)
                      : isUrgent
                          ? const Color(0xFFF5A623)
                          : const Color(0xFFB07CFF),
                  fontWeight: FontWeight.w900,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              Text(
                dateLabel,
                style: TextStyle(
                  color: _white60,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                'Подача в ',
                style: TextStyle(
                  color: _white80,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Text(
                timeStr,
                style: TextStyle(
                  color: _white98,
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                isPast ? Icons.error_outline : Icons.hourglass_top_rounded,
                color: isPast
                    ? const Color(0xFFFF5A6E)
                    : isUrgent
                        ? const Color(0xFFF5A623)
                        : const Color(0xFF6DD6A0),
                size: 14,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  isPast ? countdownStr : 'До подачи: $countdownStr',
                  style: TextStyle(
                    color: isPast
                        ? const Color(0xFFFF5A6E)
                        : isUrgent
                            ? const Color(0xFFF5A623)
                            : const Color(0xFF6DD6A0),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PriceBlock extends StatelessWidget {
  const _PriceBlock({required this.order, this.livePrice});

  final _DriverOrder order;
  final int? livePrice;

  @override
  Widget build(BuildContext context) {
    final price = livePrice ?? order.priceFinal ?? order.priceRub;
    final discount = order.promoDiscountPercent;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
        ),
        border: Border.all(color: const Color(0xFFFF2D55).withOpacity(0.6)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _formatRubAmount(price),
            style: TextStyle(
              color: _white98,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          if (discount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.18),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withOpacity(0.35)),
              ),
              child: Text(
                '-$discount%',
                style: TextStyle(
                  color: _white98,
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CallClientButton extends StatelessWidget {
  const _CallClientButton({required this.phone});

  final String phone;

  void _call() {
    var digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('8')) {
      digits = '7${digits.substring(1)}';
    }
    if (digits.length == 10) {
      digits = '7$digits';
    }
    final normalized = digits.startsWith('7') ? '+$digits' : phone;
    final uri = Uri(scheme: 'tel', path: normalized);
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static String _formatPhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('7')) {
      return '+7 (${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7, 9)}-${digits.substring(9)}';
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _call,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: const Color(0xFF1C2030),
            border: Border.all(color: _white12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phone, color: Colors.greenAccent.shade400, size: 20),
              const SizedBox(width: 8),
              Text(
                _formatPhone(phone),
                style: TextStyle(
                  color: Colors.greenAccent.shade400,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PricePill extends StatelessWidget {
  const _PricePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF1B7F3A).withValues(alpha: 0.9),
        border: Border.all(color: _white18),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: _white95,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF141723), Color(0xFF0B0D12)],
        ),
        border: Border.all(color: const Color(0xFF1C2030), width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: _white90, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _white90,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.isPrimary,
    required this.enabled,
    required this.onPressed,
    this.isUrgent = false,
  });

  final String label;
  final bool isPrimary;
  final bool enabled;
  final VoidCallback onPressed;
  final bool isUrgent;

  @override
  Widget build(BuildContext context) {
    final bg = isUrgent
        ? const LinearGradient(
            colors: [Color(0xFFFF1744), Color(0xFFD50000)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : isPrimary
            ? const LinearGradient(
                colors: [_accentColor, _accentDark],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : LinearGradient(
                colors: [
                  _white12,
                  _white06,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              );

    final fg = enabled
        ? (isPrimary || isUrgent ? Colors.white : _white92)
        : _white40;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          height: 52,
          decoration: BoxDecoration(
            gradient: bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isUrgent
                  ? const Color(0xFFFF1744)
                  : isPrimary
                      ? Colors.transparent
                      : _white12,
              width: isUrgent ? 2 : 1,
            ),
            boxShadow: isPrimary || isUrgent
                ? [
                    BoxShadow(
                      color: isUrgent ? const Color(0x66FF1744) : _black55,
                      blurRadius: isUrgent ? 20 : 14,
                      offset: const Offset(0, 12),
                      spreadRadius: isUrgent ? 2 : 0,
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.7,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
