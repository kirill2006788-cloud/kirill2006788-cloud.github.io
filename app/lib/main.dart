import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Gradient;
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:yandex_mapkit/yandex_mapkit.dart';

const _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://194.67.84.155',
);
const _systemRidePrices = ['от 2500₽/час', 'от 9000₽/5ч', 'от 2500₽/час'];

// ──────── Кешированные цвета — вместо .withOpacity() в каждом build ────────
const _white95 = Color(0xF2FFFFFF); // _white95
const _white92 = Color(0xEBFFFFFF); // _white92
const _white90 = Color(0xE6FFFFFF); // _white90
const _white88 = Color(0xE0FFFFFF); // _white88
const _white85 = Color(0xD9FFFFFF); // _white85
const _white80 = Color(0xCCFFFFFF); // Colors.white.withOpacity(0.80)
const _white78 = Color(0xC7FFFFFF); // _white78
const _white75 = Color(0xBFFFFFFF); // _white75
const _white70 = Color(0xB3FFFFFF); // Colors.white.withOpacity(0.70)
const _white68 = Color(0xADFFFFFF); // _white68
const _white65 = Color(0xA6FFFFFF); // _white65
const _white60 = Color(0x99FFFFFF); // Colors.white.withOpacity(0.60)
const _white50 = Color(0x80FFFFFF); // Colors.white.withOpacity(0.50)
const _white40 = Color(0x66FFFFFF); // Colors.white.withOpacity(0.40)
const _white12 = Color(0x1FFFFFFF); // _white12
const _white10 = Color(0x1AFFFFFF); // _white10
const _white06 = Color(0x0FFFFFFF); // _white06
const _white04 = Color(0x0AFFFFFF); // _white04
const _white18 = Color(0x2EFFFFFF); // _white18
const _black45 = Color(0x73000000); // _black45
const _black42 = Color(0x6B000000); // _black42
const _black40 = Color(0x66000000); // _black40
const _black35 = Color(0x59000000); // _black35
const _black55 = Color(0x8C000000); // _black55
const _black58 = Color(0x94000000); // _black58

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

const _profileNameKey = 'profile_display_name';
const _profileFullNameKey = 'profile_full_name';
const _profilePhoneKey = 'profile_phone';
const _profileAvatarKey = 'profile_avatar_b64';
const _promoCodeKey = 'promo_code';
const _promoDiscountKey = 'promo_discount_percent';
const _notificationsEnabledKey = 'notifications_enabled';
const _addressHomeKey = 'address_home';
const _addressWorkKey = 'address_work';
const _addressFavKey = 'address_favorite';
const _orderHistoryKey = 'order_history';
const _themeModeKey = 'theme_mode'; // 'dark' | 'light'
const _iosPushChannel = MethodChannel('ru.prostotaxi.client/push');

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

Future<void> _syncClientPushToken(
  String authToken,
  String clientId, {
  required bool enabled,
}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  try {
    final token = enabled ? await _requestIosPushToken() : '';
    if (enabled && (token == null || token.isEmpty)) return;
    await http
        .post(
          Uri.parse('$_apiBaseUrl/api/client/push-token'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $authToken',
          },
          body: jsonEncode({
            'clientId': clientId,
            'token': token ?? '',
            'platform': 'ios',
          }),
        )
        .timeout(const Duration(seconds: 10));
  } catch (_) {}
}

String _shortenAddress(String raw) {
  var s = raw.trim();
  // Убираем «Россия, » в начале
  final rxCountry = RegExp(r'^Россия,?\s*', caseSensitive: false);
  s = s.replaceFirst(rxCountry, '');
  // Убираем «Москва, », «Санкт-Петербург, » и т.д. (город в начале)
  final rxCity = RegExp(
    r'^(Москва|Санкт-Петербург|Московская область|Ленинградская область),?\s*',
    caseSensitive: false,
  );
  s = s.replaceFirst(rxCity, '');
  // Убираем административные округа (Новомосковский АО, ЗАО, и т.д.)
  final rxOkrug = RegExp(
    r'(Новомосковский|Троицкий|Центральный|Северный|Северо-Восточный|'
    r'Восточный|Юго-Восточный|Южный|Юго-Западный|Западный|Северо-Западный|'
    r'Зеленоградский)\s+(административный\s+)?округ,?\s*',
    caseSensitive: false,
  );
  s = s.replaceAll(rxOkrug, '');
  // Убираем «округ ...» в любом месте (на случай иного порядка)
  final rxGenericOkrug = RegExp(
    r'округ\s+[А-Яа-яЁё\-]+,?\s*',
    caseSensitive: false,
  );
  s = s.replaceAll(rxGenericOkrug, '');
  // Убираем городской округ (напр. «городской округ Домодедово,»)
  final rxGO = RegExp(
    r'городской\s+округ\s+[А-Яа-яЁё\-]+,?\s*',
    caseSensitive: false,
  );
  s = s.replaceAll(rxGO, '');
  // Убираем «район ...» (напр. «район Тёплый Стан,»)
  final rxRayon = RegExp(
    r'район\s+[А-Яа-яЁё\s\-]+,\s*',
    caseSensitive: false,
  );
  s = s.replaceAll(rxRayon, '');
  // Убираем «поселение ...» (напр. «поселение Краснопахорское,»)
  final rxPoselenie = RegExp(
    r'поселение\s+[А-Яа-яЁё\-]+,?\s*',
    caseSensitive: false,
  );
  s = s.replaceAll(rxPoselenie, '');
  // Убираем двойные запятые и лишние пробелы после чистки
  s = s.replaceAll(RegExp(r',\s*,'), ',');
  s = s.replaceAll(RegExp(r'^\s*,\s*'), '');
  s = s.replaceAll(RegExp(r',\s*$'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  // Если после очистки пусто, вернуть оригинал
  return s.trim().isEmpty ? raw.trim() : s.trim();
}

int _applyDiscount(int price, int percent) {
  if (percent <= 0) return price;
  final next = price - (price * percent ~/ 100);
  return next < 0 ? 0 : next;
}

String? _phoneFromJwt(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final payload = parts[1];
    var normalized = payload.replaceAll('-', '+').replaceAll('_', '/');
    while (normalized.length % 4 != 0) normalized += '=';
    final decoded = utf8.decode(base64Decode(normalized));
    final map = jsonDecode(decoded) as Map<String, dynamic>;
    final phone = map['phone'];
    return phone is String ? phone : null;
  } catch (_) {
    return null;
  }
}

String _formatPhoneForDisplay(String? raw) {
  if (raw == null || raw.isEmpty) return '—';
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 11 && digits.startsWith('7')) {
    return '+7 (${digits.substring(1, 4)}) ${digits.substring(4, 7)}-${digits.substring(7, 9)}-${digits.substring(9)}';
  }
  return raw;
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
    );

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final map = (jsonDecode(res.body) as Map).cast<String, dynamic>();
      final ttl = map['ttlSec'];
      return (ttl is num) ? ttl.toInt() : 300;
    }

    throw Exception(res.body);
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
      body: jsonEncode({'phone': normalizedPhone, 'code': normalizedCode, 'role': 'client'}),
    );

    if (res.statusCode >= 200 && res.statusCode < 300) {
      final map = (jsonDecode(res.body) as Map).cast<String, dynamic>();
      return _extractToken(map);
    }

    throw Exception(res.body);
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate({
    required this.childBuilder,
    required this.onThemeModeChanged,
  });

  final Widget Function(String token, VoidCallback onLogout, void Function(ThemeMode) onThemeModeChanged) childBuilder;
  final void Function(ThemeMode) onThemeModeChanged;

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  static const _splashChannel = MethodChannel('com.prosto_taxi/splash');

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
    // Signal native splash that the app is ready to show
    try {
      await _splashChannel.invokeMethod('ready');
    } catch (_) {}
  }

  Future<void> _onLoggedIn(String token) async {
    await _store.writeToken(token);
    if (!mounted) return;
    setState(() {
      _token = token;
    });
  }

  void _logout() {
    _store.clear();
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

    if (_token == null) {
      return _LoginPage(onLoggedIn: _onLoggedIn);
    }

    return widget.childBuilder(_token!, _logout, widget.onThemeModeChanged);
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
  final _name = TextEditingController();

  bool _requesting = false;
  bool _verifying = false;
  bool _codeStage = false;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _name.dispose();
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
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить код')),
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
      // Сохраняем имя клиента
      final nameText = _name.text.trim();
      if (nameText.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_profileNameKey, nameText);
      }
      await widget.onLoggedIn(token);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Неверный код')),
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
    final isLight = Theme.of(context).brightness == Brightness.light;
    final primary = isLight ? const Color(0xFF1F2534) : _white95;
    final secondary = isLight ? const Color(0xFF5C6477) : Colors.white.withOpacity(0.55);
    final fieldLabel = isLight ? const Color(0xFF7A8296) : _white60;
    final fieldFill = isLight ? const Color(0xFFF1F3F8) : _white06;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Здравствуйте!',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 24,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Рады видеть вас с нами',
                style: TextStyle(
                  color: secondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                style: TextStyle(color: primary, fontWeight: FontWeight.w800),
                decoration: InputDecoration(
                  labelText: 'Как к вам обращаться? (Имя)',
                  labelStyle: TextStyle(color: fieldLabel, fontWeight: FontWeight.w700, fontSize: 13),
                  filled: true,
                  fillColor: fieldFill,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: primary, fontWeight: FontWeight.w800),
                decoration: InputDecoration(
                  labelText: 'Телефон',
                  labelStyle: TextStyle(color: fieldLabel, fontWeight: FontWeight.w800),
                  filled: true,
                  fillColor: fieldFill,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                ),
              ),
              if (_codeStage) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: primary, fontWeight: FontWeight.w800),
                  decoration: InputDecoration(
                    labelText: 'Код (4 цифры)',
                    labelStyle: TextStyle(color: fieldLabel, fontWeight: FontWeight.w800),
                    filled: true,
                    fillColor: fieldFill,
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
                      _FastPageRoute<void>(builder: (_) => _PrivacyPolicyScreen()),
                    );
                  },
                  child: Text(
                    'Регистрируясь, вы даёте согласие на обработку персональных данных и соглашаетесь с политикой конфиденциальности.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isLight ? const Color(0xFF7A8296) : Colors.white.withOpacity(0.6),
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
                      backgroundColor: const Color(0xFFB90E0E),
                      foregroundColor: Colors.white,
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
                      backgroundColor: const Color(0xFFB90E0E),
                      foregroundColor: Colors.white,
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

Future<void> _callSupport(BuildContext context) async {
  const phone = '+79060424241';
  final uri = Uri(scheme: 'tel', path: phone);
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось открыть приложение телефона'),
        ),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось открыть приложение телефона'),
        ),
      );
    }
  }
}

class _OrderSearchingSheet extends StatelessWidget {
  const _OrderSearchingSheet({
    required this.timeText,
    required this.onCancel,
    this.note,
    this.showCallSupport = false,
  });

  static const _supportPhone = '+79060424241';

  final String timeText;
  final VoidCallback onCancel;
  final String? note;
  final bool showCallSupport;

  Future<void> _callSupport() async {
    final uri = Uri.parse('tel:$_supportPhone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: isLight
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFFFFF), Color(0xFFF1F3F8)],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
              ),
        border: Border.all(
          color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isLight ? const Color(0x22000000) : _black55,
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 108,
                    height: 108,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 108,
                          height: 108,
                          child: CircularProgressIndicator(
                            strokeWidth: 5,
                            valueColor: const AlwaysStoppedAnimation(Color(0xFFFF3D00)),
                            backgroundColor: _white10,
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Поиск',
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF1F2534)
                                    : Colors.white.withOpacity(0.86),
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              timeText,
                              style: TextStyle(
                                color: isLight ? const Color(0xFF5C6477) : _white78,
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (showCallSupport) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: isLight ? const Color(0xFFF5F7FA) : const Color(0xFF1A1E28),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF2A3040),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.access_time_rounded,
                                color: isLight ? const Color(0xFF5C6477) : _white70,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Поиск занимает больше времени',
                                  style: TextStyle(
                                    color: isLight ? const Color(0xFF3A4050) : _white90,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Если водитель не найдётся в ближайшее время, позвоните нам — мы поможем подобрать водителя вручную.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isLight ? const Color(0xFF5C6477) : _white70,
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              child: InkWell(
                                onTap: _callSupport,
                                borderRadius: BorderRadius.circular(10),
                                child: Ink(
                                  height: 40,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFF4CAF50), Color(0xFF388E3C)],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(Icons.phone, color: Colors.white, size: 16),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Позвонить в поддержку',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else if (note != null && note!.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: isLight ? const Color(0xFFEAF0FA) : _white06,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isLight ? const Color(0xFFD8DFEA) : Colors.white.withOpacity(0.08),
                        ),
                      ),
                      child: Text(
                        note!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isLight ? const Color(0xFF5C6477) : _white78,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Center(
                    child: SizedBox(
                      width: 180,
                      height: 68,
                      child: _SheetActionButton(
                        icon: Icon(
                          Icons.close,
                          color: isLight ? const Color(0xFF1F2534) : _white90,
                          size: 18,
                        ),
                        label: 'Отменить\nпоездку',
                        onTap: onCancel,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderAssignedSheet extends StatelessWidget {
  const _OrderAssignedSheet({
    required this.title,
    required this.subtitle,
    required this.timeText,
    required this.onCancel,
    required this.onCall,
    required this.driverPhone,
    this.driverAvatarBytes,
    this.driverName,
    this.driverRating,
    this.driverRatingCount,
  });

  final String title;
  final String subtitle;
  final String timeText;
  final VoidCallback onCancel;
  final VoidCallback onCall;
  final String? driverPhone;
  final Uint8List? driverAvatarBytes;
  final String? driverName;
  final double? driverRating;
  final int? driverRatingCount;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final rating = driverRating;
    final ratingText = rating != null && rating > 0
        ? '★ ${rating.toStringAsFixed(rating % 1 == 0 ? 0 : 1)}'
        : '★ —';
    final ratingCount = driverRatingCount ?? 0;
    final ratingSuffix = ratingCount > 0 ? ' · $ratingCount' : '';
    final nameText = (driverName != null && driverName!.trim().isNotEmpty) ? driverName! : 'Водитель';
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: isLight
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFFFFF), Color(0xFFF1F3F8)],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
              ),
        border: Border.all(
          color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isLight ? const Color(0x22000000) : _black55,
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 6),
                  Text(
                    title,
                    style: TextStyle(
                      color: isLight ? const Color(0xFF1F2534) : Colors.white.withOpacity(0.9),
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: isLight ? const Color(0xFF5C6477) : _white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isLight ? const Color(0xFFEAF0FA) : _white10,
                          border: Border.all(
                            color: isLight ? const Color(0xFFD8DFEA) : _white12,
                            width: 1,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: driverAvatarBytes == null
                            ? Icon(
                                Icons.person,
                                color: isLight ? const Color(0xFF5C6477) : _white75,
                                size: 22,
                              )
                            : Image.memory(
                                driverAvatarBytes!,
                                fit: BoxFit.cover,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              nameText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isLight ? const Color(0xFF1F2534) : _white90,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$ratingText$ratingSuffix',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isLight ? const Color(0xFF5C6477) : _white68,
                                fontWeight: FontWeight.w900,
                                fontSize: 12,
                              ),
                            ),
                            if (driverPhone != null && driverPhone!.trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                _formatPhoneForDisplay(driverPhone),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isLight
                                      ? const Color(0xFF5C6477)
                                      : Colors.white.withOpacity(0.62),
                                  fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 108,
                        height: 108,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 108,
                              height: 108,
                              child: CircularProgressIndicator(
                                strokeWidth: 5,
                                value: 1.0,
                                valueColor: const AlwaysStoppedAnimation(Color(0xFFFF3D00)),
                                backgroundColor: isLight ? const Color(0xFFDDE5F4) : _white10,
                              ),
                            ),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Будет у вас',
                                  style: TextStyle(
                                    color: isLight ? const Color(0xFF5C6477) : _white78,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 11.5,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  timeText,
                                  style: TextStyle(
                                    color: isLight ? const Color(0xFF1F2534) : _white92,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 68,
                          child: _SheetActionButton(
                            icon: Icon(
                              Icons.close,
                              color: isLight ? const Color(0xFF1F2534) : _white90,
                              size: 18,
                            ),
                            label: 'Отменить\nпоездку',
                            onTap: onCancel,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(
                          height: 68,
                          child: _SheetActionButton(
                            icon: Icon(
                              Icons.call,
                              color: isLight ? const Color(0xFF1F2534) : _white90,
                              size: 18,
                            ),
                            label: 'Связь с\nводителем',
                            onTap: onCall,
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
    );
  }
}

class _OrderStatusSheet extends StatelessWidget {
  const _OrderStatusSheet({
    required this.title,
    required this.subtitle,
    required this.onCancel,
    required this.onCall,
    required this.showCancel,
  });

  final String title;
  final String subtitle;
  final VoidCallback onCancel;
  final VoidCallback onCall;
  final bool showCancel;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: isLight
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFFFFF), Color(0xFFF1F3F8)],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
              ),
        border: Border.all(
          color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isLight ? const Color(0x22000000) : _black55,
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: isLight ? const Color(0xFF1F2534) : _white92,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  color: isLight ? const Color(0xFF5C6477) : _white70,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (showCancel)
                    Expanded(
                      child: _SheetActionButton(
                        icon: Icon(
                          Icons.close,
                          color: isLight ? const Color(0xFF1F2534) : _white90,
                          size: 18,
                        ),
                        label: 'Отменить',
                        onTap: onCancel,
                      ),
                    ),
                  if (showCancel) const SizedBox(width: 10),
                  Expanded(
                    child: _SheetActionButton(
                      icon: Icon(
                        Icons.call,
                        color: isLight ? const Color(0xFF1F2534) : _white90,
                        size: 18,
                      ),
                      label: 'Позвонить',
                      onTap: onCall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderCompletedSheet extends StatelessWidget {
  const _OrderCompletedSheet({
    required this.onDone,
    required this.priceRub,
    required this.tripMinutes,
  });

  final VoidCallback onDone;
  final int priceRub;
  final int tripMinutes;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: isLight
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFFFFF), Color(0xFFF1F3F8)],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
              ),
        border: Border.all(
          color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isLight ? const Color(0x22000000) : _black55,
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Поездка завершена',
                style: TextStyle(
                  color: isLight ? const Color(0xFF1F2534) : _white92,
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
              if (priceRub > 0 || tripMinutes > 0) ...[
                const SizedBox(height: 8),
                Text(
                  priceRub > 0
                      ? 'Итог: $priceRub ₽'
                      : 'Итоговая стоимость',
                  style: TextStyle(
                    color: isLight ? const Color(0xFF1F2534) : Colors.white.withOpacity(0.86),
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                if (tripMinutes > 0)
                  Text(
                    'В пути: $tripMinutes мин',
                    style: TextStyle(
                      color: isLight ? const Color(0xFF5C6477) : _white70,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
              ],
              const SizedBox(height: 10),
              Text(
                'Сохраните наш номер: +7 (906) 042-42-41',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isLight ? const Color(0xFF5C6477) : _white60,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),
              _PrimaryGlowButton(
                label: 'ГОТОВО',
                onTap: onDone,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaymentPickerSheet extends StatelessWidget {
  const _PaymentPickerSheet({required this.selected});

  final _PaymentMethod selected;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final primary = isLight ? const Color(0xFF1F2534) : _white92;
    final iconColor = isLight ? const Color(0xFF1F2534) : _white90;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: isLight
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFF8FAFD), Color(0xFFEEF2F8)],
                  )
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
                  ),
            border: Border.all(
              color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: isLight ? const Color(0x18000000) : _black55,
                blurRadius: 34,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Оплата',
                        style: TextStyle(
                          color: primary,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.1,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _PaymentOptionTile(
                        icon: _SbpIcon(size: 20, dark: !isLight),
                        title: 'Перевод СБП',
                        selected: selected == _PaymentMethod.sbp,
                        onTap: () => Navigator.of(context).pop(_PaymentMethod.sbp),
                      ),
                      const SizedBox(height: 10),
                      _PaymentOptionTile(
                        icon: Icon(
                          Icons.payments_outlined,
                          color: iconColor,
                          size: 20,
                        ),
                        title: 'Наличные',
                        selected: selected == _PaymentMethod.cash,
                        onTap: () => Navigator.of(context).pop(_PaymentMethod.cash),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PaymentOptionTile extends StatelessWidget {
  const _PaymentOptionTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final Widget icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: isLight
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: selected
                        ? [const Color(0xFFFFF5F5), const Color(0xFFFFF0EE)]
                        : [const Color(0xFFFFFFFF), const Color(0xFFF3F6FC)],
                  )
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF141723), Color(0xFF0B0D12)],
                  ),
            border: Border.all(
              color: selected
                  ? const Color(0xFFFF3D00)
                  : (isLight ? const Color(0xFFDCE2EB) : const Color(0xFF222636)),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              icon,
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isLight ? const Color(0xFF1F2534) : _white90,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected
                    ? const Color(0xFFFF3D00)
                    : (isLight ? const Color(0xFFB0BAD0) : Colors.white.withOpacity(0.50)),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SbpIcon extends StatelessWidget {
  const _SbpIcon({required this.size, this.dark = false});

  final double size;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final isDarkBg = dark || Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(size: Size(size, size), painter: _SbpIconPainter(darkBg: isDarkBg));
  }
}

class _SbpIconPainter extends CustomPainter {
  const _SbpIconPainter({this.darkBg = true});
  final bool darkBg;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(size.width * 0.22),
    );

    final bg = Paint()..color = darkBg ? _white10 : const Color(0x1A000000);
    canvas.drawRRect(r, bg);

    final w = size.width;
    final h = size.height;

    final p1 = Paint()..color = const Color(0xFF00C853);
    final p2 = Paint()..color = const Color(0xFF2979FF);
    final p3 = Paint()..color = const Color(0xFFFF1744);
    final p4 = Paint()..color = const Color(0xFFAA00FF);

    final s = w * 0.16;
    final gap = w * 0.06;
    final left = (w - (s * 2 + gap)) / 2;
    final top = (h - (s * 2 + gap)) / 2;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, s, s),
        Radius.circular(s * 0.25),
      ),
      p1,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left + s + gap, top, s, s),
        Radius.circular(s * 0.25),
      ),
      p2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top + s + gap, s, s),
        Radius.circular(s * 0.25),
      ),
      p3,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left + s + gap, top + s + gap, s, s),
        Radius.circular(s * 0.25),
      ),
      p4,
    );
  }

  @override
  bool shouldRepaint(covariant _SbpIconPainter oldDelegate) => oldDelegate.darkBg != darkBg;
}

class _OrderTextBottomSheet extends StatefulWidget {
  const _OrderTextBottomSheet({
    required this.title,
    required this.initialValue,
    required this.hintText,
  });

  final String title;
  final String? initialValue;
  final String hintText;

  @override
  State<_OrderTextBottomSheet> createState() => _OrderTextBottomSheetState();
}

class _OrderTextBottomSheetState extends State<_OrderTextBottomSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _done() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return ScrollConfiguration(
      behavior: const _NoGlowScrollBehavior(),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 0, 14, 14 + bottomInset),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
                  ),
                  border: Border.all(color: const Color(0xFF1C2030), width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: _black55,
                      blurRadius: 40,
                      offset: const Offset(0, 22),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              const SizedBox(width: 34),
                              Expanded(
                                child: Text(
                                  widget.title,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.94),
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.15,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 34,
                                height: 34,
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () => Navigator.of(context).maybePop(),
                                    child: Center(
                                      child: Icon(
                                        Icons.close,
                                        color: _white75,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF1A1C25), Color(0xFF0B0C10)],
                              ),
                              border: Border.all(color: const Color(0xFF222636), width: 1),
                              boxShadow: [
                                BoxShadow(
                                  color: _black35,
                                  blurRadius: 20,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: TextField(
                                controller: _controller,
                                autofocus: true,
                                keyboardType: TextInputType.text,
                                textInputAction: TextInputAction.done,
                                maxLines: 5,
                                minLines: 3,
                                style: TextStyle(
                                  color: _white92,
                                  fontWeight: FontWeight.w800,
                                ),
                                cursorColor: const Color(0xFFFF2D55),
                                decoration: InputDecoration(
                                  contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                                  hintText: widget.hintText,
                                  hintStyle: TextStyle(
                                    color: Colors.white.withOpacity(0.45),
                                    fontWeight: FontWeight.w700,
                                  ),
                                  border: InputBorder.none,
                                ),
                                onSubmitted: (_) => _done(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            width: double.infinity,
                            child: _PrimaryGlowButton(
                              label: 'ГОТОВО',
                              onTap: _done,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoGlowScrollBehavior extends ScrollBehavior {
  const _NoGlowScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

enum _RouteField { from, to }

class _RouteSelection {
  const _RouteSelection({
    required this.fromAddress,
    required this.fromPoint,
    required this.toAddress,
    required this.toPoint,
  });

  final String fromAddress;
  final Point fromPoint;
  final String toAddress;
  final Point toPoint;
}

class _AddressSuggestion {
  const _AddressSuggestion(this.title, this.point, {this.searchText, this.icon, this.label});

  final String title;
  final Point? point;
  final String? searchText;
  final IconData? icon;
  final String? label; // "Дом", "Работа", "Избранное"
}

class _RoutePickerBottomSheet extends StatefulWidget {
  const _RoutePickerBottomSheet({
    required this.initialFromAddress,
    required this.initialFromPoint,
    required this.initialToAddress,
    required this.initialToPoint,
    this.onPickOnMap,
    this.onPickFromOnMap,
    this.initialActiveField = _RouteField.to,
    this.savedHome = '',
    this.savedWork = '',
    this.savedFavorite = '',
  });

  final String initialFromAddress;
  final Point initialFromPoint;
  final String? initialToAddress;
  final Point? initialToPoint;
  final VoidCallback? onPickOnMap;
  final VoidCallback? onPickFromOnMap;
  final _RouteField initialActiveField;
  final String savedHome;
  final String savedWork;
  final String savedFavorite;

  @override
  State<_RoutePickerBottomSheet> createState() => _RoutePickerBottomSheetState();
}

class _RoutePickerBottomSheetState extends State<_RoutePickerBottomSheet> {
  late final TextEditingController _fromController;
  late final TextEditingController _toController;

  late Point _fromPoint;
  Point? _toPoint;
  late _RouteField _activeField;

  bool _suppressSuggest = false;
  String _lastFromQuery = '';
  String _lastToQuery = '';

  Timer? _suggestDebounce;
  SuggestSession? _suggestSession;
  int _suggestRequestId = 0;
  bool _suggestLoading = false;
  List<_AddressSuggestion> _suggestions = const <_AddressSuggestion>[];

  static const int _minSuggestQueryLength = 2;
  static const Duration _suggestDebounceDuration = Duration(milliseconds: 320);

  BoundingBox _suggestBox() {
    final p = _fromPoint;
    const dLat = 0.2;
    const dLon = 0.2;
    return BoundingBox(
      northEast: Point(latitude: p.latitude + dLat, longitude: p.longitude + dLon),
      southWest: Point(latitude: p.latitude - dLat, longitude: p.longitude - dLon),
    );
  }

  static const _defaultSuggestions = <_AddressSuggestion>[
    _AddressSuggestion(
      'Аптекарский переулок, 1',
      Point(latitude: 55.76733, longitude: 37.63173),
    ),
    _AddressSuggestion(
      'Казанский вокзал',
      Point(latitude: 55.77612, longitude: 37.65588),
    ),
    _AddressSuggestion(
      'Белорусский вокзал',
      Point(latitude: 55.77675, longitude: 37.58286),
    ),
    _AddressSuggestion(
      'Парк Горького',
      Point(latitude: 55.72989, longitude: 37.60347),
    ),
    _AddressSuggestion(
      'Шереметьево (SVO)',
      Point(latitude: 55.97264, longitude: 37.41459),
    ),
    _AddressSuggestion(
      'Домодедово (DME)',
      Point(latitude: 55.40900, longitude: 37.90200),
    ),
    _AddressSuggestion(
      'Внуково (VKO)',
      Point(latitude: 55.60500, longitude: 37.28700),
    ),
    _AddressSuggestion(
      'Химки, Московская область',
      Point(latitude: 55.88900, longitude: 37.44500),
    ),
    _AddressSuggestion(
      'Одинцово, Московская область',
      Point(latitude: 55.67800, longitude: 37.27700),
    ),
    _AddressSuggestion(
      'Зеленоград',
      Point(latitude: 55.99200, longitude: 37.21400),
    ),
  ];

  /// Сохранённые адреса пользователя (Дом, Работа, Избранное) — показываются вверху
  List<_AddressSuggestion> _buildSavedAddresses({String query = ''}) {
    final saved = <_AddressSuggestion>[];
    final q = query.toLowerCase().trim();
    if (widget.savedHome.isNotEmpty) {
      if (q.isEmpty || widget.savedHome.toLowerCase().contains(q) || 'дом'.contains(q)) {
        saved.add(_AddressSuggestion(
          widget.savedHome,
          null,
          icon: Icons.home_rounded,
          label: 'Дом',
        ));
      }
    }
    if (widget.savedWork.isNotEmpty) {
      if (q.isEmpty || widget.savedWork.toLowerCase().contains(q) || 'работа'.contains(q)) {
        saved.add(_AddressSuggestion(
          widget.savedWork,
          null,
          icon: Icons.work_rounded,
          label: 'Работа',
        ));
      }
    }
    if (widget.savedFavorite.isNotEmpty) {
      if (q.isEmpty || widget.savedFavorite.toLowerCase().contains(q) || 'избранное'.contains(q)) {
        saved.add(_AddressSuggestion(
          widget.savedFavorite,
          null,
          icon: Icons.star_rounded,
          label: 'Избранное',
        ));
      }
    }
    return saved;
  }

  @override
  void initState() {
    super.initState();
    _activeField = widget.initialActiveField;
    _fromController = TextEditingController(text: widget.initialFromAddress);
    _toController = TextEditingController(text: widget.initialToAddress ?? '');
    _fromPoint = widget.initialFromPoint;
    _toPoint = widget.initialToPoint;

    _suggestions = [..._buildSavedAddresses(), ..._defaultSuggestions];

    _lastFromQuery = _fromController.text.trim();
    _lastToQuery = _toController.text.trim();

    _fromController.addListener(() {
      if (!mounted || _suppressSuggest) return;
      if (_activeField != _RouteField.from) return;
      final q = _fromController.text.trim();
      if (q == _lastFromQuery) return;
      _lastFromQuery = q;
      _scheduleSuggest();
    });

    _toController.addListener(() {
      if (!mounted || _suppressSuggest) return;
      if (_activeField != _RouteField.to) return;
      final q = _toController.text.trim();
      if (q == _lastToQuery) return;
      _lastToQuery = q;
      _scheduleSuggest();
    });
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _suggestSession?.close();
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  void _scheduleSuggest() {
    _suggestDebounce?.cancel();
    _suggestDebounce = Timer(_suggestDebounceDuration, () {
      _refreshSuggestions();
    });
  }

  Future<void> _refreshSuggestions() async {
    final query = (_activeField == _RouteField.from
            ? _fromController.text
            : _toController.text)
        .trim();

    final requestId = ++_suggestRequestId;

    if (query.isEmpty || query.runes.length < _minSuggestQueryLength) {
      if (!mounted) return;
      setState(() {
        _suggestLoading = false;
        _suggestions = [..._buildSavedAddresses(query: query), ..._defaultSuggestions];
      });
      return;
    }

    setState(() {
      _suggestLoading = true;
    });

    try {
      await _suggestSession?.close();
      _suggestSession = null;

      final (session, futureResult) = await YandexSuggest.getSuggestions(
        text: query,
        boundingBox: _suggestBox(),
        suggestOptions: SuggestOptions(
          suggestType: SuggestType.unspecified,
          strictBounds: false,
          suggestWords: true,
          userPosition: _fromPoint,
        ),
      );

      _suggestSession = session;

      final result = await futureResult;
      await session.close();
      if (!mounted || requestId != _suggestRequestId) return;

      var items = (result.items ?? const <SuggestItem>[])
          .map(
            (i) => _AddressSuggestion(
              _shortenAddress(i.displayText.isNotEmpty ? i.displayText : i.title),
              i.center,
              searchText: i.searchText,
            ),
          )
          .toList(growable: false);

      final geo = await _fallbackSearch(query);

      if (items.isEmpty) {
        items = geo;
      } else if (geo.isNotEmpty) {
        final merged = <_AddressSuggestion>[];
        final seen = <String>{};

        String keyOf(_AddressSuggestion s) {
          final p = s.point;
          final pl = p == null
              ? ''
              : '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}';
          return '${s.title.trim().toLowerCase()}|$pl';
        }

        for (final s in items) {
          final k = keyOf(s);
          if (seen.add(k)) merged.add(s);
        }
        for (final s in geo) {
          final k = keyOf(s);
          if (seen.add(k)) merged.add(s);
          if (merged.length >= 20) break;
        }

        items = merged;
      }

      if (!mounted || requestId != _suggestRequestId) return;

      // Добавляем сохранённые адреса в начало, если подходят по запросу
      final saved = _buildSavedAddresses(query: query);
      setState(() {
        _suggestLoading = false;
        _suggestions = [...saved, ...items];
      });
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('Suggest failed: $e');
        debugPrint('$st');
      }
      if (!mounted || requestId != _suggestRequestId) return;
      final fallback = await _fallbackSearch(query);
      if (!mounted || requestId != _suggestRequestId) return;
      final saved = _buildSavedAddresses(query: query);
      setState(() {
        _suggestLoading = false;
        _suggestions = [...saved, ...fallback];
      });
    }
  }

  Future<List<_AddressSuggestion>> _fallbackSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <_AddressSuggestion>[];

    try {
      final (session, futureResult) = await YandexSearch.searchByText(
        searchText: trimmed,
        geometry: Geometry.fromBoundingBox(_suggestBox()),
        searchOptions: SearchOptions(
          searchType: SearchType.geo,
          geometry: true,
          resultPageSize: 20,
          userPosition: _fromPoint,
        ),
      );

      final result = await futureResult;
      await session.close();
      final items = result.items ?? const <SearchItem>[];

      return items
          .map((item) {
            final formatted = item.toponymMetadata?.address.formattedAddress;
            final title = _shortenAddress(
              (formatted != null && formatted.trim().isNotEmpty)
                  ? formatted.trim()
                  : item.name,
            );
            final geometryPoint = item.geometry
                .map((g) => g.point)
                .firstWhere((p) => p != null, orElse: () => null);
            return _AddressSuggestion(
              title,
              item.toponymMetadata?.balloonPoint ?? geometryPoint,
              searchText: item.name,
            );
          })
          .where((s) => s.title.trim().isNotEmpty)
          .toList(growable: false);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('Search failed: $e');
        debugPrint('$st');
      }
      return const <_AddressSuggestion>[];
    }
  }

  List<_AddressSuggestion> _filtered() {
    final query = (_activeField == _RouteField.from
            ? _fromController.text
            : _toController.text)
        .trim()
        .toLowerCase();

    final list = _suggestions;
    if (query.isEmpty || list.isEmpty) return list;

    final filtered = list.toList(growable: true);

    int score(_AddressSuggestion s) {
      final t = (s.searchText ?? s.title).toLowerCase();
      if (t.startsWith(query)) return 0;
      if (t.contains(query)) return 1;
      return 2;
    }

    filtered.sort((a, b) {
      final sa = score(a);
      final sb = score(b);
      if (sa != sb) return sa.compareTo(sb);
      return a.title.length.compareTo(b.title.length);
    });

    return filtered;
  }

  Future<Point?> _resolveSuggestionPoint(_AddressSuggestion suggestion) async {
    if (suggestion.point != null) return suggestion.point;

    final query = (suggestion.searchText ?? suggestion.title).trim();
    if (query.isEmpty) return null;

    try {
      final (session, futureResult) = await YandexSearch.searchByText(
        searchText: query,
        geometry: Geometry.fromBoundingBox(_suggestBox()),
        searchOptions: SearchOptions(
          searchType: SearchType.geo,
          geometry: true,
          resultPageSize: 1,
          userPosition: _fromPoint,
        ),
      );

      final result = await futureResult;
      await session.close();
      final items = result.items;
      if (items == null || items.isEmpty) return null;

      final item = items.first;
      final geometryPoint = item.geometry
          .map((g) => g.point)
          .firstWhere((p) => p != null, orElse: () => null);

      return item.toponymMetadata?.balloonPoint ?? geometryPoint;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _formatSuggestionAddress(Point point) async {
    try {
      final (session, futureResult) = await YandexSearch.searchByPoint(
        point: point,
        zoom: 16,
        searchOptions: SearchOptions(
          searchType: SearchType.geo,
          geometry: false,
          userPosition: _fromPoint,
        ),
      );

      final result = await futureResult;
      await session.close();

      final items = result.items;
      if (items == null || items.isEmpty) return null;

      final item = items.first;
      final formatted = item.toponymMetadata?.address.formattedAddress;
      if (formatted != null && formatted.trim().isNotEmpty) {
        return _shortenAddress(formatted);
      }
      return item.name.trim().isEmpty ? null : _shortenAddress(item.name);
    } catch (_) {
      return null;
    }
  }



  Future<void> _applySuggestion(_AddressSuggestion s) async {
    // Мгновенно показываем выбранный адрес без ожидания сети
    _suppressSuggest = true;
    setState(() {
      if (_activeField == _RouteField.from) {
        _fromController.text = s.title;
        _activeField = _RouteField.to;
      } else {
        _toController.text = s.title;
      }
    });
    _suppressSuggest = false;

    // Резолвим точку (может быть мгновенно если уже есть)
    final point = s.point ?? await _resolveSuggestionPoint(s);
    if (!mounted) return;
    if (point == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Адрес не найден')),
      );
      return;
    }

    // Обновляем точку
    _suppressSuggest = true;
    setState(() {
      if (_activeField == _RouteField.to && _toController.text == s.title) {
        _toPoint = point;
      } else if (_fromController.text == s.title) {
        _fromPoint = point;
      }
    });
    _suppressSuggest = false;

    // Форматируем адрес в фоне (не блокируем UI)
    unawaited(() async {
      final formatted = await _formatSuggestionAddress(point);
      if (!mounted) return;
      final title = (formatted != null && formatted.trim().isNotEmpty)
          ? formatted.trim()
          : s.title;
      _suppressSuggest = true;
      setState(() {
        if (_toController.text == s.title) {
          _toController.text = title;
        } else if (_fromController.text == s.title) {
          _fromController.text = title;
        }
      });
      _suppressSuggest = false;
    }());
  }

  void _done() {
    final to = _toPoint;
    if (to == null || _toController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите пункт назначения')),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(
      _RouteSelection(
        fromAddress: _fromController.text.trim().isEmpty
            ? widget.initialFromAddress
            : _fromController.text.trim(),
        fromPoint: _fromPoint,
        toAddress: _toController.text.trim(),
        toPoint: to,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final list = _filtered();
    final isLight = Theme.of(context).brightness == Brightness.light;

    return ScrollConfiguration(
      behavior: const _NoGlowScrollBehavior(),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 0, 14, 14 + bottomInset),
          child: DecoratedBox(
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: isLight
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFF6F7FB), Color(0xFFEFF3FA)],
                        )
                      : const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xF8161A24), Color(0xF80B0D12)],
                        ),
                  border: Border.all(
                    color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isLight ? const Color(0x1A000000) : _black55,
                      blurRadius: 18,
                      offset: const Offset(0, 10),
                    ),
                  ],
              ),
            child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
              child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.72,
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                const SizedBox(width: 34),
                                Expanded(
                                  child: Text(
                                    'Маршрут',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: isLight
                                          ? const Color(0xFF1F2534)
                                          : Colors.white.withOpacity(0.94),
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.15,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 34,
                                  height: 34,
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: () => Navigator.of(context).maybePop(),
                                      child: Center(
                                        child: Icon(
                                          Icons.close,
                                          color: isLight ? const Color(0xFF5C6477) : _white75,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _RouteFieldInput(
                              icon: Icons.my_location,
                              hintText: 'Откуда',
                              controller: _fromController,
                              selected: _activeField == _RouteField.from,
                              onTap: () {
                                setState(() {
                                  _activeField = _RouteField.from;
                                  if (_fromController.text.trim() == 'Моё местоположение') {
                                    _fromController.clear();
                                  }
                                });

                                _fromController.selection = TextSelection.collapsed(
                                  offset: _fromController.text.length,
                                );

                                _scheduleSuggest();
                              },
                              onChanged: (_) => _scheduleSuggest(),
                              onClear: () {
                                setState(() {
                                  _activeField = _RouteField.from;
                                  _suggestions = [..._buildSavedAddresses(), ..._defaultSuggestions];
                                });
                              },
                              onMapPin: widget.onPickFromOnMap != null
                                  ? () {
                                      Navigator.of(context).pop();
                                      widget.onPickFromOnMap!.call();
                                    }
                                  : null,
                            ),
                            const SizedBox(height: 10),
                            _RouteFieldInput(
                              icon: Icons.place_outlined,
                              hintText: 'Куда',
                              controller: _toController,
                              selected: _activeField == _RouteField.to,
                              onTap: () {
                                setState(() {
                                  _activeField = _RouteField.to;
                                });

                                _toController.selection = TextSelection.collapsed(
                                  offset: _toController.text.length,
                                );

                                _scheduleSuggest();
                              },
                              onChanged: (_) {
                                setState(() {
                                  _toPoint = null;
                                });

                                _scheduleSuggest();
                              },
                              onClear: () {
                                setState(() {
                                  _toPoint = null;
                                  _activeField = _RouteField.to;
                                  _suggestions = [..._buildSavedAddresses(), ..._defaultSuggestions];
                                });
                              },
                              onMapPin: () {
                                Navigator.of(context).pop();
                                widget.onPickOnMap?.call();
                              },
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(18),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(18),
                                    gradient: isLight
                                        ? const LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: [Color(0xFFFFFFFF), Color(0xFFF3F6FC)],
                                          )
                                        : const LinearGradient(
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                            colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
                                          ),
                                    border: Border.all(
                                      color: isLight ? const Color(0xFFD8DFEA) : const Color(0xFF222636),
                                      width: 1,
                                    ),
                                  ),
                                  child: _suggestLoading
                                      ? Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: CircularProgressIndicator(
                                              valueColor: AlwaysStoppedAnimation<Color>(
                                                isLight ? const Color(0xFF1F2534) : _white75,
                                              ),
                                            ),
                                          ),
                                        )
                                      : (list.isEmpty
                                          ? Center(
                                              child: Padding(
                                                padding: const EdgeInsets.all(16),
                                                child: Text(
                                                  'Ничего не найдено',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    color: isLight
                                                        ? const Color(0xFF5C6477)
                                                        : Colors.white.withOpacity(0.62),
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                            )
                                          : ListView.separated(
                                              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                                              itemCount: list.length,
                                              separatorBuilder: (_, __) => Divider(
                                                height: 1,
                                                color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
                                              ),
                                              itemBuilder: (context, index) {
                                                final s = list[index];
                                                final isSaved = s.label != null;
                                                return Material(
                                                  color: Colors.transparent,
                                                  child: InkWell(
                                                    borderRadius: BorderRadius.circular(14),
                                                    onTap: () => _applySuggestion(s),
                                                    child: Padding(
                                                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                                                      child: Row(
                                                        children: [
                                                          Container(
                                                            width: 32,
                                                            height: 32,
                                                            decoration: isSaved
                                                                ? BoxDecoration(
                                                                    borderRadius: BorderRadius.circular(9),
                                                                    gradient: const LinearGradient(
                                                                      colors: [Color(0xFF7C3AED), Color(0xFFFF2D55)],
                                                                    ),
                                                                  )
                                                                : null,
                                                            child: Icon(
                                                              s.icon ?? Icons.location_on_outlined,
                                                              color: isSaved
                                                                  ? Colors.white
                                                                  : (isLight
                                                                      ? const Color(0xFF5C6477)
                                                                      : Colors.white.withOpacity(0.70)),
                                                              size: isSaved ? 18 : 18,
                                                            ),
                                                          ),
                                                          const SizedBox(width: 10),
                                                          Expanded(
                                                            child: Column(
                                                              crossAxisAlignment: CrossAxisAlignment.start,
                                                              children: [
                                                                if (isSaved)
                                                                  Text(
                                                                    s.label!,
                                                                    style: TextStyle(
                                                                    color: isLight
                                                                        ? const Color(0xFF7C3AED)
                                                                        : const Color(0xFFB07CFF),
                                                                      fontWeight: FontWeight.w900,
                                                                      fontSize: 11,
                                                                    ),
                                                                  ),
                                                                Text(
                                                                  s.title,
                                                                  maxLines: 2,
                                                                  overflow: TextOverflow.ellipsis,
                                                                  style: TextStyle(
                                                                  color: isLight ? const Color(0xFF1F2534) : _white88,
                                                                    fontWeight: FontWeight.w800,
                                                                    height: 1.05,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            )),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              width: double.infinity,
                              child: _PrimaryGlowButton(
                                label: 'ГОТОВО',
                                onTap: _done,
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
        ),
      ),
    );
  }
}

class _RouteFieldInput extends StatelessWidget {
  const _RouteFieldInput({
    required this.icon,
    required this.hintText,
    required this.controller,
    required this.selected,
    required this.onTap,
    required this.onChanged,
    this.onClear,
    this.onMapPin,
  });

  final IconData icon;
  final String hintText;
  final TextEditingController controller;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;
  final VoidCallback? onMapPin;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final border = selected
        ? const LinearGradient(colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)])
        : (isLight
            ? const LinearGradient(colors: [Color(0xFFE1E6EF), Color(0xFFD5DDEA)])
            : const LinearGradient(
                colors: [Color(0xFF2A2F3A), Color(0xFF161925)],
              ));

    final showClear = controller.text.trim().isNotEmpty;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: border,
          ),
          child: Padding(
            padding: const EdgeInsets.all(1.4),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16.6),
                gradient: selected
                    ? (isLight
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFFFFFFF), Color(0xFFF2F5FA)],
                          )
                        : const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF1E2333), Color(0xFF0E1017)],
                          ))
                    : (isLight
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFF7F9FD), Color(0xFFF0F3F9)],
                          )
                        : const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF141723), Color(0xFF0B0D12)],
                          )),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      color: isLight ? const Color(0xFF2B3344) : _white88,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        onTap: onTap,
                        onChanged: onChanged,
                        style: TextStyle(
                          color: isLight ? const Color(0xFF1F2534) : _white92,
                          fontWeight: FontWeight.w800,
                        ),
                        cursorColor: const Color(0xFFFF2D55),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: hintText,
                          hintStyle: TextStyle(
                            color: isLight
                                ? const Color(0xFF8B93A7)
                                : Colors.white.withOpacity(0.45),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    if (showClear)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          controller.clear();
                          onClear?.call();
                          onChanged('');
                        },
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: Center(
                            child: Icon(
                              Icons.close,
                              size: 18,
                              color: isLight
                                  ? const Color(0xFF8B93A7)
                                  : Colors.white.withOpacity(0.50),
                            ),
                          ),
                        ),
                      ),
                    if (onMapPin != null)
                      GestureDetector(
                        onTap: onMapPin,
                        child: Container(
                          width: 36,
                          height: 36,
                          margin: const EdgeInsets.only(left: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: isLight
                                ? const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [Color(0xFFEFF2F8), Color(0xFFE3E8F2)],
                                  )
                                : const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
                                  ),
                          ),
                          child: Icon(
                            Icons.location_on,
                            size: 20,
                            color: isLight ? const Color(0xFF1F2534) : Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _TariffZone { mkad, outsideMkad, outsideCkad }

enum _PaymentMethod { sbp, cash }

enum _OrderFlowState { selecting, searching, assigned, enroute, arrived, started, completed }

// ── МКАД polygon — 108 km markers (lat, lon) ────────────────────────
const _mkadPolygon = <List<double>>[
  [55.774558, 37.842762],[55.76522, 37.842789],[55.755723, 37.842627],
  [55.747399, 37.841828],[55.739103, 37.841217],[55.730482, 37.840175],
  [55.721939, 37.83916],[55.712203, 37.837121],[55.703048, 37.83262],
  [55.694287, 37.829512],[55.68529, 37.831353],[55.675945, 37.834605],
  [55.667752, 37.837597],[55.658667, 37.839348],[55.650053, 37.833842],
  [55.643713, 37.824787],[55.637347, 37.814564],[55.62913, 37.802473],
  [55.623758, 37.794235],[55.617713, 37.781928],[55.611755, 37.771139],
  [55.604956, 37.758725],[55.599677, 37.747945],[55.594143, 37.734785],
  [55.589234, 37.723062],[55.583983, 37.709425],[55.578834, 37.696256],
  [55.574019, 37.683167],[55.571999, 37.668911],[55.573093, 37.647765],
  [55.573928, 37.633419],[55.574732, 37.616719],[55.575816, 37.60107],
  [55.5778, 37.586536],[55.581271, 37.571938],[55.585143, 37.555732],
  [55.587509, 37.545132],[55.5922, 37.526366],[55.594728, 37.516108],
  [55.60249, 37.502274],[55.609685, 37.49391],[55.617424, 37.484846],
  [55.625801, 37.474668],[55.630207, 37.469925],[55.641041, 37.456864],
  [55.648794, 37.448195],[55.654675, 37.441125],[55.660424, 37.434424],
  [55.670701, 37.42598],[55.67994, 37.418712],[55.686873, 37.414868],
  [55.695697, 37.407528],[55.702805, 37.397952],[55.709657, 37.388969],
  [55.718273, 37.383283],[55.728581, 37.378369],[55.735201, 37.374991],
  [55.744789, 37.370248],[55.75435, 37.369188],[55.762936, 37.369053],
  [55.771444, 37.369619],[55.779722, 37.369853],[55.789542, 37.372943],
  [55.79723, 37.379824],[55.805796, 37.386876],[55.814629, 37.390397],
  [55.823606, 37.393236],[55.83251, 37.395275],[55.840376, 37.394709],
  [55.850141, 37.393056],[55.858801, 37.397314],[55.867051, 37.405588],
  [55.872703, 37.416601],[55.877041, 37.429429],[55.881091, 37.443596],
  [55.882828, 37.459065],[55.884625, 37.473096],[55.888897, 37.48861],
  [55.894232, 37.5016],[55.899578, 37.513206],[55.90526, 37.527597],
  [55.907687, 37.543443],[55.909388, 37.559577],[55.910907, 37.575531],
  [55.909257, 37.590344],[55.905472, 37.604637],[55.901637, 37.619603],
  [55.898533, 37.635961],[55.896973, 37.647648],[55.895449, 37.667878],
  [55.894868, 37.681721],[55.893884, 37.698807],[55.889094, 37.712363],
  [55.883555, 37.723636],[55.877501, 37.735791],[55.874698, 37.741261],
  [55.862464, 37.764519],[55.861979, 37.765992],[55.850257, 37.788216],
  [55.850383, 37.788522],[55.844167, 37.800586],[55.832707, 37.822819],
  [55.828789, 37.829754],[55.821072, 37.837148],[55.811599, 37.838926],
  [55.802781, 37.840004],[55.793991, 37.840965],[55.785017, 37.841576],
];

/// Ray-casting point-in-polygon test for MKAD.
bool _isInsideMkad(double lat, double lon) {
  final poly = _mkadPolygon;
  final n = poly.length;
  bool inside = false;
  for (int i = 0, j = n - 1; i < n; j = i++) {
    final yi = poly[i][0], xi = poly[i][1];
    final yj = poly[j][0], xj = poly[j][1];
    if (((yi > lat) != (yj > lat)) &&
        (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)) {
      inside = !inside;
    }
  }
  return inside;
}

bool _isToday(DateTime d) {
  final now = DateTime.now();
  return d.year == now.year && d.month == now.month && d.day == now.day;
}

/// Haversine distance between two points in km.
double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const R = 6371.0;
  final dLat = (lat2 - lat1) * (math.pi / 180.0);
  final dLon = (lon2 - lon1) * (math.pi / 180.0);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * (math.pi / 180.0)) *
          math.cos(lat2 * (math.pi / 180.0)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Find the approximate MKAD boundary crossing point via binary search.
/// [pIn] is the point inside MKAD, [pOut] is the point outside.
/// Returns the approximate boundary point (outside side).
List<double> _findMkadCrossing(double latIn, double lonIn, double latOut, double lonOut) {
  double iLat = latIn, iLon = lonIn;
  double oLat = latOut, oLon = lonOut;
  // 8 iterations → accuracy ~1/256 of segment (~4m for 1km segment)
  for (int iter = 0; iter < 8; iter++) {
    final mLat = (iLat + oLat) / 2;
    final mLon = (iLon + oLon) / 2;
    if (_isInsideMkad(mLat, mLon)) {
      iLat = mLat;
      iLon = mLon;
    } else {
      oLat = mLat;
      oLon = mLon;
    }
  }
  return [oLat, oLon];
}

/// Calculate km outside MKAD for pricing.
/// Counts distance outside MKAD from each endpoint to its nearest MKAD
/// crossing along the polyline.
double _calcKmOutsideMkad(List<Point> points) {
  if (points.length < 2) return 0.0;

  final originOutside =
      !_isInsideMkad(points.first.latitude, points.first.longitude);
  final destOutside =
      !_isInsideMkad(points.last.latitude, points.last.longitude);

  if (!originOutside && !destOutside) return 0.0;

  // If both endpoints are outside MKAD, check whether route enters MKAD
  if (originOutside && destOutside) {
    bool anyInside = false;
    for (final p in points) {
      if (_isInsideMkad(p.latitude, p.longitude)) {
        anyInside = true;
        break;
      }
    }
    if (!anyInside) {
      // Entire route outside MKAD — count once, not twice
      double totalKm = 0;
      for (int i = 0; i < points.length - 1; i++) {
        totalKm += _haversineKm(points[i].latitude, points[i].longitude,
            points[i + 1].latitude, points[i + 1].longitude);
      }
      return totalKm;
    }
  }

  double outsideKm = 0.0;

  // ── Origin outside MKAD: walk forward until entering MKAD ─────
  if (originOutside) {
    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      if (_isInsideMkad(p2.latitude, p2.longitude)) {
        final cross = _findMkadCrossing(
            p2.latitude, p2.longitude, p1.latitude, p1.longitude);
        outsideKm += _haversineKm(
            p1.latitude, p1.longitude, cross[0], cross[1]);
        break;
      }
      outsideKm += _haversineKm(
          p1.latitude, p1.longitude, p2.latitude, p2.longitude);
    }
  }

  // ── Destination outside MKAD: walk backward until entering MKAD ─
  if (destOutside) {
    double destKm = 0.0;
    for (int i = points.length - 1; i > 0; i--) {
      final p1 = points[i];
      final p2 = points[i - 1];
      if (_isInsideMkad(p2.latitude, p2.longitude)) {
        final cross = _findMkadCrossing(
            p2.latitude, p2.longitude, p1.latitude, p1.longitude);
        destKm += _haversineKm(
            p1.latitude, p1.longitude, cross[0], cross[1]);
        break;
      }
      destKm += _haversineKm(
          p1.latitude, p1.longitude, p2.latitude, p2.longitude);
    }
    outsideKm += destKm;
  }

  return outsideKm;
}

class _TariffQuote {
  const _TariffQuote({
    required this.zone,
    required this.title,
    required this.leftLines,
    required this.priceFrom,
    required this.bottomLine,
    this.kmOutsideMkad = 0.0,
  });

  final _TariffZone zone;
  final String title;
  final List<String> leftLines;
  final int priceFrom;
  final String bottomLine;
  final double kmOutsideMkad;

  static _TariffQuote? tryBuild({
    required int serviceIndex,
    required Point from,
    required Point to,
    double? routeDistanceMeters,
    double? routeEtaSeconds,
    double kmOutsideMkad = 0.0,
  }) {
    final minutes = _routeMinutes(routeEtaSeconds);

    // ── Личный водитель (index 1) — без км ──────────────────────
    if (serviceIndex == 1) {
      const includedMin = 5 * 60;
      final extraMin = math.max(0, minutes - includedMin);
      final price = 9000 + extraMin * 25;
      return _TariffQuote(
        zone: _TariffZone.mkad,
        title: 'Личный водитель',
        leftLines: const ['5 часов - 9000 ₽'],
        priceFrom: price,
        bottomLine: 'Далее 25 ₽/мин.',
        kmOutsideMkad: kmOutsideMkad,
      );
    }

    // ── Общая логика для serviceIndex 0 (Трезвый) и 2 (Перегон) ─
    final bool outsideMkad = kmOutsideMkad > 0.5; // > 500 m — считаем выездом
    const includedMin = 60;
    final extraMin = math.max(0, minutes - includedMin);
    final base = outsideMkad ? 2900 : 2500;
    final kmFee = outsideMkad ? _kmFee(kmOutsideMkad) : 0;
    final price = base + extraMin * 25 + kmFee;
    final zone = outsideMkad ? _TariffZone.outsideMkad : _TariffZone.mkad;
    final tariffName = serviceIndex == 2 ? 'Перегон автомобиля' : 'Трезвый водитель';

    if (!outsideMkad) {
      return _TariffQuote(
        zone: zone,
        title: tariffName,
        leftLines: const ['В пределах МКАД'],
        priceFrom: price,
        bottomLine: '1 час / далее 25 ₽/мин.',
        kmOutsideMkad: kmOutsideMkad,
      );
    }

    return _TariffQuote(
      zone: zone,
      title: tariffName,
      leftLines: const ['За пределы МКАД'],
      priceFrom: price,
      bottomLine: '1 час / далее 25 ₽/мин. + 50 ₽/км',
      kmOutsideMkad: kmOutsideMkad,
    );
  }

  static int _routeMinutes(double? seconds) {
    final s = (seconds ?? 0.0).toDouble();
    if (s <= 0) return 0;
    return (s / 60.0).ceil();
  }

  static int _kmFee(double km) {
    final k = km <= 0 ? 0 : km.ceil();
    return k * 50;
  }

  static double _degToRad(double deg) => deg * (math.pi / 180.0);
}

class _TariffCard extends StatelessWidget {
  const _TariffCard({required this.quote, required this.discountPercent});

  final _TariffQuote quote;
  final int discountPercent;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF2D55).withOpacity(0.18),
            blurRadius: 26,
            offset: const Offset(0, 16),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.30),
            blurRadius: 22,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18.6),
            gradient: isLight
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFFFFFF), Color(0xFFF2F5FA)],
                  )
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF141723), Color(0xFF0B0D12)],
                  ),
            border: Border.all(
              color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF222636),
              width: 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18.6),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              quote.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isLight ? const Color(0xFF1F2534) : _white95,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.1,
                              ),
                            ),
                            if (quote.leftLines.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              ...quote.leftLines.map(
                                (t) => Text(
                                  t,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isLight
                                        ? const Color(0xFF5C6477)
                                        : Colors.white.withOpacity(0.74),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Text(
                              quote.bottomLine,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF7A8296)
                                    : Colors.white.withOpacity(0.62),
                                fontWeight: FontWeight.w800,
                                fontSize: 11.5,
                                height: 1.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'от',
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF7A8296)
                                  : Colors.white.withOpacity(0.60),
                              fontWeight: FontWeight.w900,
                              fontSize: 11,
                            ),
                          ),
                          Text(
                            '${_applyDiscount(quote.priceFrom, discountPercent)} ₽',
                            style: TextStyle(
                              color: isLight
                                  ? const Color(0xFF1F2534)
                                  : Colors.white.withOpacity(0.97),
                              fontWeight: FontWeight.w900,
                              fontSize: 22,
                              height: 1.05,
                            ),
                          ),
                          if (discountPercent > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${quote.priceFrom} ₽  ·  -$discountPercent%',
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF7A8296)
                                    : Colors.white.withOpacity(0.62),
                                fontWeight: FontWeight.w800,
                                fontSize: 11,
                                decoration: TextDecoration.lineThrough,
                                decorationColor: isLight ? const Color(0xFFB9C1D1) : _white50,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class _MapBlock extends StatefulWidget {
  const _MapBlock({
    required this.initialPoint,
    required this.enabled,
    this.mapObjects = const <MapObject>[],
    this.onMapCreated,
    this.onCameraPositionChanged,
    this.onMapLongTap,
    this.onMapDoubleTap,
  });

  final Point initialPoint;
  final bool enabled;
  final List<MapObject> mapObjects;
  final ValueChanged<YandexMapController>? onMapCreated;
  final void Function(CameraPosition, CameraUpdateReason, bool)? onCameraPositionChanged;
  final ValueChanged<Point>? onMapLongTap;
  final ValueChanged<Point>? onMapDoubleTap;

  @override
  State<_MapBlock> createState() => _MapBlockState();
}

class _MapBlockState extends State<_MapBlock> {
  DateTime? _lastMapTapTime;
  Point? _lastMapTapPoint;
  bool _mapReady = false; // Карта создается отложенно — после перехода

  @override
  void initState() {
    super.initState();
    // Откладываем создание тяжёлого нативного YandexMap
    // чтобы переход страницы был мгновенным
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Даём анимации перехода завершиться, потом создаём карту
      Future.delayed(const Duration(milliseconds: 80), () {
        if (!mounted) return;
        setState(() { _mapReady = true; });
      });
    });
  }

  void _handleMapTap(Point point) {
    final now = DateTime.now();
    final lastTime = _lastMapTapTime;
    if (lastTime != null && now.difference(lastTime).inMilliseconds < 400) {
      _lastMapTapTime = null;
      _lastMapTapPoint = null;
      widget.onMapDoubleTap?.call(point);
      return;
    }
    _lastMapTapTime = now;
    _lastMapTapPoint = point;
  }

  static final bool _isMobilePlatform =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static const _placeholder = DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF1A1D33), Color(0xFF0B0D14)],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_isMobilePlatform || !widget.enabled || !_mapReady) {
      return _placeholder;
    }

    return RepaintBoundary(
      child: YandexMap(
        onMapCreated: (controller) async {
          await controller.moveCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(target: widget.initialPoint, zoom: 12),
            ),
          );
          widget.onMapCreated?.call(controller);
        },
        onCameraPositionChanged: widget.onCameraPositionChanged,
        onMapLongTap: widget.onMapLongTap,
        onMapTap: _handleMapTap,
        mapObjects: widget.mapObjects,
        mapType: MapType.map,
        nightModeEnabled: Theme.of(context).brightness == Brightness.dark,
        fastTapEnabled: true,
        mode2DEnabled: true,
        scrollGesturesEnabled: true,
        zoomGesturesEnabled: true,
        tiltGesturesEnabled: false,
        rotateGesturesEnabled: false,
      ),
    );
  }
}

class _MapGeoButton extends StatelessWidget {
  const _MapGeoButton({required this.onTap, required this.loading});

  final VoidCallback onTap;
  final bool loading;

  static final _borderRadius = BorderRadius.circular(999);
  static final _decoration = BoxDecoration(
    color: _black42,
    borderRadius: BorderRadius.circular(999),
    border: Border.all(color: _white12, width: 1),
    boxShadow: const [
      BoxShadow(
        color: _black35,
        blurRadius: 10,
        offset: Offset(0, 6),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: _borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: _borderRadius,
        onTap: loading ? null : onTap,
        child: Ink(
          width: 44,
          height: 44,
          decoration: _decoration,
          child: Center(
            child: loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _white90,
                      ),
                    ),
                  )
                : Transform.rotate(
                    angle: -0.35,
                    child: Icon(
                      Icons.near_me,
                      size: 22,
                      color: _white92,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _CenterPickupPin extends StatelessWidget {
  const _CenterPickupPin({
    required this.dragging,
  });

  final bool dragging;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Center(
      child: Transform.translate(
        offset: const Offset(0, -20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 2,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withOpacity(0.0),
                    isLight ? const Color(0xFF9AA3B5) : _white85,
                  ],
                ),
              ),
            ),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isLight ? const Color(0xFF1F2534) : Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: _black45,
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Плавающий чип с адресом над пином (как на скринах)
class _FloatingAddressChip extends StatelessWidget {
  const _FloatingAddressChip({
    required this.label,
    required this.address,
    required this.onEditTap,
  });

  final String label;
  final String address;
  final VoidCallback onEditTap;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: isLight
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFFFFF), Color(0xFFF2F5FA)],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1E2333), Color(0xFF0E1017)],
              ),
        border: Border.all(
          color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF2A2F3A),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isLight ? const Color(0x22000000) : Colors.black.withOpacity(0.50),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: isLight ? const Color(0xFF7A8296) : Colors.white.withOpacity(0.50),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isLight ? const Color(0xFF1F2534) : _white95,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onEditTap,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: isLight ? const Color(0xFFEAF0FA) : Colors.white.withOpacity(0.08),
              ),
              child: Icon(
                Icons.edit,
                color: isLight ? const Color(0xFF5C6477) : Colors.white.withOpacity(0.70),
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Нижняя панель "Куда поедете?"
class _WhereToBar extends StatelessWidget {
  const _WhereToBar({required this.onTap});

  final VoidCallback onTap;

  static final _borderRadius = BorderRadius.circular(22);
  static final _decoration = BoxDecoration(
    borderRadius: BorderRadius.circular(22),
    gradient: const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
    ),
    border: Border.all(color: const Color(0xFF1C2030), width: 1),
    boxShadow: const [
      BoxShadow(
        color: Color(0x80000000),
        blurRadius: 14,
        offset: Offset(0, 8),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      gradient: isLight
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFFFFF), Color(0xFFF1F3F8)],
            )
          : const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
            ),
      border: Border.all(
        color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: isLight ? const Color(0x1A000000) : const Color(0x80000000),
          blurRadius: 14,
          offset: const Offset(0, 8),
        ),
      ],
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: _borderRadius,
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
          decoration: decoration,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Куда поедете?',
                  style: TextStyle(
                    color: isLight ? const Color(0xFF1F2534) : Colors.white.withOpacity(0.55),
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: isLight ? const Color(0xFF7A8296) : Colors.white.withOpacity(0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenterDropoffPin extends StatelessWidget {
  const _CenterDropoffPin({
    required this.dragging,
  });

  final bool dragging;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Transform.translate(
        offset: const Offset(0, -20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 2,
              height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFFFF3D00).withOpacity(0.0),
                    const Color(0xFFFF3D00).withOpacity(0.90),
                  ],
                ),
              ),
            ),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFF3D00),
                boxShadow: [
                  BoxShadow(
                    color: _black45,
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Мгновенный переход страниц — без анимации, 0 задержки
class _FastPageRoute<T> extends PageRouteBuilder<T> {
  _FastPageRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => builder(context),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: const Duration(milliseconds: 100),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // Обратная анимация — быстрый fade для плавного возврата
            if (secondaryAnimation.status == AnimationStatus.forward) {
              return child;
            }
            return FadeTransition(opacity: animation, child: child);
          },
        );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  static final _darkTheme = ThemeData(
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFFB90E0E),
      brightness: Brightness.dark,
    ),
  );

  static final _lightTheme = ThemeData(
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFFB90E0E),
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: const Color(0xFFF2F2F5),
  );

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(_themeModeKey);
    if (!mounted) return;
    setState(() {
      _themeMode = mode == 'light' ? ThemeMode.light : ThemeMode.dark;
    });
  }

  void _setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_themeModeKey, mode == ThemeMode.light ? 'light' : 'dark');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Трезвый водитель',
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: _themeMode,
      home: _AuthGate(
        onThemeModeChanged: _setThemeMode,
        childBuilder: (token, onLogout, onThemeModeChanged) => MyHomePage(
          title: 'Трезвый водитель',
          token: token,
          onLogout: onLogout,
          onThemeModeChanged: onThemeModeChanged,
        ),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.title,
    required this.token,
    required this.onLogout,
    required this.onThemeModeChanged,
  });

  final String title;
  final String token;
  final VoidCallback onLogout;
  final void Function(ThemeMode) onThemeModeChanged;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  static const _initialPoint = Point(latitude: 55.751244, longitude: 37.618423);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureLocationPermissionForMaps();
    });
  }

  Future<void> _ensureLocationPermissionForMaps() async {
    if (kIsWeb) return;
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) return;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
    } catch (_) {}
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

  void _openProfile() {
    Navigator.of(context).push(_FastPageRoute(
      builder: (_) => ProfilePage(
        token: widget.token,
        onLogout: widget.onLogout,
        onThemeModeChanged: widget.onThemeModeChanged,
      ),
    ));
  }

  void _openOrder() {
    Navigator.of(context).push(_FastPageRoute(
      builder: (_) => OrderPage(
        token: widget.token,
        onLogout: widget.onLogout,
        onThemeModeChanged: widget.onThemeModeChanged,
      ),
    ));
  }

  void _openMainPrices() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B0D12),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Стоимость',
                style: TextStyle(
                  color: _white95,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'В пределах МКАД — 2500₽ / 1 час, далее 25₽/мин.',
                style: TextStyle(color: _white80, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'За пределы МКАД (Москва → область) — 2900₽ / 1 час, далее 25₽/мин + 50₽/км.',
                style: TextStyle(color: _white80, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Из области в Москву — 2900₽ / 1 час, далее 25₽/мин + 50₽/км.',
                style: TextStyle(color: _white80, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'За пределы ЦКАД — 2900₽ / 1 час, далее 25₽/мин.',
                style: TextStyle(color: _white80, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: _PrimaryGlowButton(
                  label: 'ПОНЯТНО',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openMainOrders() {
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          final primary = isLight ? const Color(0xFF1F2534) : _white95;
          final secondary = isLight ? const Color(0xFF5C6477) : _white70;
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                'История заказов',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            body: FutureBuilder<String?>(
              future: SharedPreferences.getInstance().then((p) => p.getString(_orderHistoryKey)),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Ошибка загрузки', style: TextStyle(color: secondary)));
                }
                final raw = snapshot.data;
                List<dynamic> items;
                try { items = raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>); }
                catch (_) { items = <dynamic>[]; }
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      'История пока пустая',
                      style: TextStyle(color: secondary, fontWeight: FontWeight.w700),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemBuilder: (context, index) {
                    final item = items[index] as Map<String, dynamic>;
                    final from = item['from']?.toString() ?? '';
                    final to = item['to']?.toString() ?? '';
                    final price = item['price']?.toString() ?? '';
                    return _GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              from,
                              style: TextStyle(color: primary, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              to,
                              style: TextStyle(color: secondary, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '$price ₽',
                              style: TextStyle(color: primary, fontWeight: FontWeight.w900),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemCount: items.length,
                );
              },
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          Positioned.fill(
            child: Stack(
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF12162B), Color(0xFF05060A)],
                    ),
                  ),
                ),
                const _MapBlock(initialPoint: _initialPoint, enabled: true),
              ],
            ),
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x2E000000), // 0.18
                      Color(0x1F000000), // 0.12
                      Color(0xD9000000), // 0.85
                    ],
                    stops: [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: Column(
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final gap = constraints.maxWidth < 120 ? 6.0 : 10.0;
                        return Row(
                          children: [
                            _TopIconButton(
                              icon: Icons.person_outline,
                              onTap: _openProfile,
                            ),
                            SizedBox(width: gap),
                            Expanded(
                              child: Center(
                                child: ColorFiltered(
                                  colorFilter: const ColorFilter.matrix(<double>[
                                    1, 0, 0, 0, 0,
                                    0, 1, 0, 0, 0,
                                    0, 0, 1, 0, 0,
                                    1.2756, 4.2912, 0.4332, 0, 0,
                                  ]),
                                  child: Image.asset(
                                    'assets/images/logo.png',
                                    height: 47,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.high,
                                    isAntiAlias: true,
                                    errorBuilder: (context, error, stackTrace) {
                                      return const Text(
                                        'Трезвый водитель',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 18,
                                          color: Colors.white,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: gap),
                            // Невидимый элемент для балансировки (та же ширина что у кнопки профиля)
                            const SizedBox(width: 40, height: 40),
                          ],
                        );
                      },
                    ),
                    const Spacer(),
                    _GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Трезвый водитель',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Theme.of(context).brightness == Brightness.light
                                          ? const Color(0xFF1F2534)
                                          : _white95,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                                const _NeonPill(text: '24/7'),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Вы отдыхаете — мы за рулём',
                              style: TextStyle(
                                color: Theme.of(context).brightness == Brightness.light
                                    ? const Color(0xFF5C6477)
                                    : _white65,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: _SecondaryActionButton(
                                    icon: Icons.sell,
                                    label: 'ЦЕНЫ',
                                    onTap: _openMainPrices,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _SecondaryActionButton(
                                    icon: Icons.receipt_long,
                                    label: 'ЗАКАЗЫ',
                                    showBadge: true,
                                    onTap: _openMainOrders,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _PrimaryGlowButton(
                              label: 'ВЫЗВАТЬ ВОДИТЕЛЯ',
                              onTap: _openOrder,
                            ),
                            Offstage(offstage: true, child: Text('$_counter')),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class OrderPage extends StatefulWidget {
  const OrderPage({
    super.key,
    required this.token,
    required this.onLogout,
    required this.onThemeModeChanged,
  });

  final String token;
  final VoidCallback onLogout;
  final void Function(ThemeMode) onThemeModeChanged;

  @override
  State<OrderPage> createState() => _OrderPageState();
}

class _OrderPageState extends State<OrderPage> with WidgetsBindingObserver {
  static const _initialPoint = Point(latitude: 55.751244, longitude: 37.618423);
  int _selectedType = 0;
  String? _comment;
  String? _wish;
  _PaymentMethod _paymentMethod = _PaymentMethod.sbp;
  _OrderFlowState _orderFlow = _OrderFlowState.selecting;
  Timer? _orderTimer;
  Timer? _driverFoundTimer;
  Timer? _statusPollTimer;
  final ValueNotifier<int> _searchSecondsNotifier = ValueNotifier<int>(0);
  int get _searchSeconds => _searchSecondsNotifier.value;
  set _searchSeconds(int v) => _searchSecondsNotifier.value = v;
  int _arrivalMinutes = 7;
  int _arrivalSeconds = 0;
  int _arrivalRemainingSeconds = 0;
  DateTime? _arrivalUpdatedAt;
  Timer? _arrivalCountdownTimer;
  int _completedPriceRub = 0;
  int _completedTripMinutes = 0;
  final ValueNotifier<String> _fromAddressNotifier = ValueNotifier<String>('Моё местоположение');
  String get _fromAddress => _fromAddressNotifier.value;
  set _fromAddress(String v) => _fromAddressNotifier.value = v;
  Point _fromPoint = _initialPoint;
  final ValueNotifier<String?> _toAddressNotifier = ValueNotifier<String?>(null);
  String? get _toAddress => _toAddressNotifier.value;
  set _toAddress(String? v) => _toAddressNotifier.value = v;
  Point? _toPoint;
  _TariffQuote? _quote;
  int _promoDiscountPercent = 0;
  String? _promoCode;
  String? _clientId;
  int _referralCount = 0;
  int _bonusBalance = 0;
  String? _currentOrderId;
  String? _driverPhone;
  IO.Socket? _socket;
  bool _socketConnected = true; // true пока не было первого disconnect
  bool _socketEverConnected = false;
  bool _creatingOrder = false;
  List<Map<String, dynamic>> _tariffs = const [];
  String? _completedOrderId;
  bool _ratingDialogOpen = false;
  Point? _driverPoint;
  BitmapDescriptor? _driverIcon;
  Uint8List? _driverAvatarBytes;
  String? _driverAvatarPhone;
  String? _driverName;
  double? _driverRating;
  int? _driverRatingCount;
  DateTime? _driverProfileFetchedAt;
  String? _searchDelayMessage;
  DateTime? _scheduledAt;

  DrivingSession? _etaDrivingSession;
  int _etaRequestId = 0;
  DateTime? _etaRequestedAt;
  Point? _etaFrom;
  Point? _etaTo;

  DrivingSession? _drivingSession;
  int _drivingRequestId = 0;
  bool _routeLoading = false;
  String? _routeSummary;
  double? _routeDistanceMeters;
  double? _routeEtaSeconds;
  double _kmOutsideMkad = 0.0;
  Point? _routeFrom;
  Point? _routeTo;
  Polyline? _routePolyline;

  YandexMapController? _mapController;
  bool _locating = false;
  bool _draggingPickup = false;
  bool _pickupEditing = false;
  bool _draggingDropoff = false;
  bool _dropoffEditing = false;
  Point _lastCameraTarget = _initialPoint;
  Timer? _pickupDebounce;
  Timer? _pickupDragThrottle;
  Point? _pendingPickupPoint;
  Timer? _dropoffDebounce;

  // Сохранённые адреса пользователя
  String _savedAddressHome = '';
  String _savedAddressWork = '';
  String _savedAddressFav = '';
  Timer? _dropoffDragThrottle;
  Point? _pendingDropoffPoint;
  int _pickupRequestId = 0;
  int _pickupAddressRequestId = 0;
  int _dropoffAddressRequestId = 0;
  Point? _myPoint;
  bool _pickupPinEnabled = false;

  // --- Инкрементальные объекты карты (через ValueNotifier — обновление карты без rebuild всего UI) ---
  PolylineMapObject? _mo_route;
  PlacemarkMapObject? _mo_pickup;
  PlacemarkMapObject? _mo_dropoff;
  PlacemarkMapObject? _mo_driver;
  CircleMapObject? _mo_myLocation;
  final ValueNotifier<List<MapObject>> _mapObjectsNotifier =
      ValueNotifier<List<MapObject>>(const <MapObject>[]);

  /// Обновить карту без полного rebuild виджета
  void _notifyMapObjects() {
    _mapObjectsNotifier.value = <MapObject>[
      if (_mo_myLocation != null) _mo_myLocation!,
      if (_mo_route != null) _mo_route!,
      if (_mo_pickup != null) _mo_pickup!,
      if (_mo_dropoff != null) _mo_dropoff!,
      if (_mo_driver != null) _mo_driver!,
    ];
  }

  BitmapDescriptor? _pickupPinIcon;
  BitmapDescriptor? _finishFlagIcon;
  bool _initialLocateAttempted = false;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Все тяжёлые инициализации — ПОСЛЕ первого кадра,
    // чтобы переход страницы не тормозил
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initAll();
    });
  }

  /// Пакетная инициализация — вместо 5 отдельных async вызовов в initState
  Future<void> _initAll() async {
    // Быстрые операции — SharedPreferences + иконки
    unawaited(_preloadMapIcons());
    unawaited(_loadSavedAddresses());
    await _loadPromo(); // одна setState

    // Сетевые операции — параллельно
    unawaited(_initRealtime());
    unawaited(_loadTariffs());
    unawaited(_loadActiveOrder());

    // Геолокация — самая тяжёлая, последняя
    if (mounted) _maybeInitMyLocation();
  }

  /// Предзагрузка всех иконок карты при старте — убирает async overhead при обновлениях
  Future<void> _preloadMapIcons() async {
    try { await _ensureStickPinWhite(); } catch (_) {}
    try { await _ensureStickPinOrange(); } catch (_) {}
    try { await _ensureNavArrowIcon(); } catch (_) {}
    try { await _ensureFinishFlagIcon(); } catch (_) {}
    try { await _ensurePickupPinIcon(); } catch (_) {}
  }

  Future<void> _loadSavedAddresses() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _savedAddressHome = prefs.getString(_addressHomeKey) ?? '';
      _savedAddressWork = prefs.getString(_addressWorkKey) ?? '';
      _savedAddressFav = prefs.getString(_addressFavKey) ?? '';
    });
  }

  Future<void> _initRealtime() async {
    final clientId = await _getOrCreateClientId();
    final prefs = await SharedPreferences.getInstance();
    final notificationsEnabled = prefs.getBool(_notificationsEnabledKey) ?? true;
    if (!mounted) return;
    _clientId = clientId;
    _connectSocket(clientId);
    unawaited(_syncClientPushToken(widget.token, clientId, enabled: notificationsEnabled));
    unawaited(
      Future<void>.delayed(
        const Duration(seconds: 5),
        () => _syncClientPushToken(widget.token, clientId, enabled: notificationsEnabled),
      ),
    );
  }

  Future<void> _loadPromo() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _promoCode = prefs.getString(_promoCodeKey);
      _promoDiscountPercent = prefs.getInt(_promoDiscountKey) ?? 0;
    });
  }

  Future<void> _loadTariffs() async {
    try {
      final res = await http.get(Uri.parse('$_apiBaseUrl/api/tariffs'));
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final list = map['tariffs'];
      if (list is List) {
        setState(() {
          _tariffs = list.cast<Map<String, dynamic>>();
        });
      }
    } catch (_) {}
  }

  Future<String> _getOrCreateClientId() async {
    final phone = _phoneFromJwt(widget.token);
    if (phone != null && phone.trim().isNotEmpty) {
      return phone.trim();
    }
    const key = 'client_id';
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(key);
    if (existing != null && existing.trim().isNotEmpty) return existing;
    final seed = DateTime.now().millisecondsSinceEpoch.toString();
    final suffix = math.Random().nextInt(1 << 32).toString();
    final next = 'client_$seed$suffix';
    await prefs.setString(key, next);
    return next;
  }

  void _connectSocket(String clientId) {
    final opts = IO.OptionBuilder()
        .setTransports(['websocket'])
        .setPath('/socket.io/')
        .setAuth({'token': widget.token, 'clientId': clientId})
        .disableAutoConnect()
        .enableReconnection()
        .setReconnectionDelay(1000)
        .setReconnectionDelayMax(5000)
        .setReconnectionAttempts(double.maxFinite.toInt())
        .build();

    final s = IO.io(_apiBaseUrl, opts);
    s.onConnect((_) {
      if (!mounted) return;
      setState(() {
        _socketConnected = true;
        _socketEverConnected = true;
      });
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
      unawaited(_loadActiveOrder());
    });
    s.on('order:status', (data) {
      if (data is Map) {
        _handleOrderStatus(Map<String, dynamic>.from(data));
      }
    });
    s.on('driver:location', (data) {
      if (data is Map) {
        _handleDriverLocation(Map<String, dynamic>.from(data));
      }
    });
    s.on('order:delay', (data) {
      if (data is Map) {
        _handleOrderDelay(Map<String, dynamic>.from(data));
      }
    });
    s.onConnectError((data) {
      final msg = data?.toString().toLowerCase() ?? '';
      if (msg.contains('unauthorized') || msg.contains('jwt') || msg.contains('token')) {
        _handleSessionExpired();
      }
    });
    s.onError((_) {});
    _socket = s;
    s.connect();
  }

  Future<void> _loadCompletedDetails(String orderId) async {
    try {
      final res = await http.get(Uri.parse('$_apiBaseUrl/api/orders/$orderId'));
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final order = map['order'] as Map?;
      if (order == null) return;
      final priceFinal = int.tryParse(order['priceFinal']?.toString() ?? '') ?? 0;
      final tripMinutes = int.tryParse(order['tripMinutes']?.toString() ?? '') ?? 0;
      if (!mounted) return;
      setState(() {
        _completedPriceRub = priceFinal;
        _completedTripMinutes = tripMinutes;
      });
    } catch (_) {}
  }

  Future<void> _loadActiveOrder() async {
    try {
      final clientId = await _ensureClientId();
      final res = await http.get(
        Uri.parse('$_apiBaseUrl/api/orders/active/client?clientId=$clientId'),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final order = map['order'] as Map?;
      if (order == null) return;
      final status = (order['status'] ?? '').toString();
      if (status == 'canceled' || status == 'completed') return;

      final from = order['from'] as Map? ?? const {};
      final to = order['to'] as Map? ?? const {};
      double? toDouble(dynamic v) {
        if (v == null) return null;
        if (v is num) return v.toDouble();
        return double.tryParse(v.toString());
      }

      final fromLat = toDouble(from['lat'] ?? from['latitude']);
      final fromLng = toDouble(from['lng'] ?? from['lon'] ?? from['longitude']);
      final toLat = toDouble(to['lat'] ?? to['latitude']);
      final toLng = toDouble(to['lng'] ?? to['lon'] ?? to['longitude']);

      final fromPoint =
          (fromLat != null && fromLng != null) ? Point(latitude: fromLat, longitude: fromLng) : null;
      final toPoint =
          (toLat != null && toLng != null) ? Point(latitude: toLat, longitude: toLng) : null;

      final createdAt = DateTime.tryParse((order['createdAt'] ?? '').toString());
      final elapsed = createdAt != null ? DateTime.now().difference(createdAt).inSeconds : 0;
      final driverPhone = (order['driverPhone'] ?? '').toString();
      final routeDistance = toDouble(order['routeDistanceMeters']);
      final routeEta = toDouble(order['routeEtaSeconds']);

      if (!mounted) return;
      setState(() {
        _currentOrderId = (order['id'] ?? '').toString();
        if (fromPoint != null) _fromPoint = fromPoint;
        if (toPoint != null) _toPoint = toPoint;
        if ((order['fromAddress'] ?? '').toString().trim().isNotEmpty) {
          _fromAddress = (order['fromAddress'] ?? '').toString();
        }
        if ((order['toAddress'] ?? '').toString().trim().isNotEmpty) {
          _toAddress = (order['toAddress'] ?? '').toString();
        }
        _routeDistanceMeters = routeDistance ?? _routeDistanceMeters;
        _routeEtaSeconds = routeEta ?? _routeEtaSeconds;
        _driverPhone = driverPhone.isNotEmpty ? driverPhone : _driverPhone;
        _orderFlow = switch (status) {
          'searching' => _OrderFlowState.searching,
          'accepted' => _OrderFlowState.assigned,
          'enroute' => _OrderFlowState.enroute,
          'arrived' => _OrderFlowState.arrived,
          'started' => _OrderFlowState.started,
          _ => _orderFlow,
        };
        if (elapsed > 0 && _orderFlow == _OrderFlowState.searching) {
          _searchSeconds = elapsed;
        }
      });

      if (_orderFlow == _OrderFlowState.searching) {
        _orderTimer?.cancel();
        _orderTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          if (_orderFlow != _OrderFlowState.searching) return;
          _searchSeconds += 1; // ValueNotifier — без full rebuild
        });
      }

      if (_orderFlow == _OrderFlowState.assigned ||
          _orderFlow == _OrderFlowState.enroute) {
        // Водитель едет к клиенту — запустить таймер ожидания
        _startArrivalCountdown();
      } else if (_orderFlow == _OrderFlowState.started) {
        // Поездка — сбросить таймер ожидания; ETA до назначения придёт от driver:location
        _arrivalMinutes = 0;
        _arrivalSeconds = 0;
        _arrivalRemainingSeconds = 0;
        _startArrivalCountdown();
      } else if (_orderFlow == _OrderFlowState.arrived) {
        // Водитель на месте — таймер не нужен
        _arrivalMinutes = 0;
        _arrivalSeconds = 0;
        _arrivalRemainingSeconds = 0;
        _stopArrivalCountdown();
      }
      _startOrderStatusPolling();
      if (driverPhone.isNotEmpty && driverPhone != _driverAvatarPhone) {
        unawaited(_loadDriverProfile(driverPhone));
      }
    } catch (_) {}
  }

  Future<String> _ensureClientId() async {
    if (_clientId != null && _clientId!.trim().isNotEmpty) return _clientId!;
    final id = await _getOrCreateClientId();
    _clientId = id;
    return id;
  }

  Future<void> _rateOrder(String orderId, int rating) async {
    try {
      final clientId = await _ensureClientId();
      await http.post(
        Uri.parse('$_apiBaseUrl/api/orders/$orderId/rate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'clientId': clientId, 'rating': rating}),
      );
    } catch (_) {}
  }

  Future<void> _finishTripAndReturn() async {
    if (!mounted) return;
    setState(() {
      _orderFlow = _OrderFlowState.selecting;
      _searchSeconds = 0;
      _arrivalMinutes = 0;
      _arrivalSeconds = 0;
      _arrivalRemainingSeconds = 0;
      _arrivalUpdatedAt = null;
      _currentOrderId = null;
      _driverPhone = null;
      _completedOrderId = null;
      _driverPoint = null;
      _searchDelayMessage = null;
      _clearDriverProfile();
    });
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _openRatingDialog(String orderId) async {
    if (_ratingDialogOpen || !mounted) return;
    _ratingDialogOpen = true;
    int selected = 5;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: const Color(0xFF151825),
              title: const Text(
                'Поездка завершена',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Оцените водителя',
                    style: TextStyle(color: _white75),
                  ),
                  const SizedBox(height: 12),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (i) {
                        final idx = i + 1;
                        return IconButton(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          constraints: const BoxConstraints(),
                          onPressed: () => setLocal(() => selected = idx),
                          icon: Icon(
                            idx <= selected ? Icons.star : Icons.star_border,
                            color: const Color(0xFFFFD400),
                            size: 32,
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Позже'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await _rateOrder(orderId, selected);
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  child: const Text('Отправить'),
                ),
              ],
            );
          },
        );
      },
    );
    _ratingDialogOpen = false;
  }

  void _handleOrderStatus(Map<String, dynamic> data) {
    final orderId = (data['orderId'] ?? '').toString();
    if (_currentOrderId == null && _orderFlow == _OrderFlowState.searching && orderId.isNotEmpty) {
      _currentOrderId = orderId;
    }
    if (_currentOrderId == null || orderId != _currentOrderId) return;
    final status = (data['status'] ?? '').toString();
    final driverPhone = (data['driverPhone'] ?? '').toString();
    final alreadyAssigned = _orderFlow == _OrderFlowState.assigned ||
        _orderFlow == _OrderFlowState.enroute ||
        _orderFlow == _OrderFlowState.arrived ||
        _orderFlow == _OrderFlowState.started;

    if (!mounted) return;
    if (status == 'accepted') {
      if (alreadyAssigned) {
        if (driverPhone.isNotEmpty && driverPhone != _driverAvatarPhone) {
          unawaited(_loadDriverProfile(driverPhone));
        }
        return;
      }
      // Предзаказ: если scheduledAt в будущем (>10 мин) — не запускаем ETA
      final isPreorder = _scheduledAt != null &&
          _scheduledAt!.isAfter(DateTime.now().add(const Duration(minutes: 10)));
      setState(() {
        _driverPhone = driverPhone.isNotEmpty ? driverPhone : _driverPhone;
        _orderFlow = _OrderFlowState.assigned;
        _searchDelayMessage = null;
        if (isPreorder) {
          _arrivalMinutes = 0;
          _arrivalSeconds = 0;
          _arrivalRemainingSeconds = 0;
        } else {
          // Начальная оценка ~5 мин пока реальный ETA не придёт
          _arrivalMinutes = 5;
          _arrivalSeconds = 0;
          _arrivalRemainingSeconds = 300;
        }
      });
      if (driverPhone.isNotEmpty && driverPhone != _driverAvatarPhone) {
        unawaited(_loadDriverProfile(driverPhone));
      }
      if (!isPreorder) {
        _startArrivalCountdown();
        // Сразу запросить координаты водителя и ETA
        unawaited(_fetchDriverLocationAndEta(orderId));
      }
      _orderTimer?.cancel();
      _orderTimer = null;
      _startOrderStatusPolling();
      return;
    }

    if (status == 'enroute' || status == 'arrived' || status == 'started') {
      final prevFlow = _orderFlow;
      setState(() {
        _driverPhone = driverPhone.isNotEmpty ? driverPhone : _driverPhone;
        _orderFlow = switch (status) {
          'enroute' => _OrderFlowState.enroute,
          'arrived' => _OrderFlowState.arrived,
          _ => _OrderFlowState.started,
        };
        _searchDelayMessage = null;
      });

      if (status == 'started') {
        // Поездка началась → сбросить таймер и рассчитать ETA до точки назначения
        final toPoint = _toPoint;
        final driverPt = _driverPoint;
        if (toPoint != null && driverPt != null) {
          // Сбросить текущий таймер ожидания водителя
          setState(() {
            _arrivalMinutes = 0;
            _arrivalSeconds = 0;
            _arrivalRemainingSeconds = 0;
            _arrivalUpdatedAt = null;
          });
          // Запросить ETA от текущего положения водителя до точки назначения
          _requestArrivalEtaUpdate(from: driverPt, to: toPoint, orderId: orderId);
          // Запустить навигацию — маршрут от водителя до назначения
          unawaited(_updateLiveRoute(driverPt, toPoint));
        } else if (toPoint != null) {
          // Нет позиции водителя — используем routeEtaSeconds если есть
          if ((_routeEtaSeconds ?? 0) > 0) {
            setState(() {
              _applyArrivalEstimateSeconds((_routeEtaSeconds ?? 0).round());
            });
          } else {
            setState(() {
              _arrivalMinutes = 0;
              _arrivalSeconds = 0;
              _arrivalRemainingSeconds = 0;
              _arrivalUpdatedAt = null;
            });
          }
        }
        _startArrivalCountdown();
      } else if (status == 'arrived') {
        // Водитель приехал → остановить таймер, он не нужен
        setState(() {
          _arrivalMinutes = 0;
          _arrivalSeconds = 0;
          _arrivalRemainingSeconds = 0;
          _arrivalUpdatedAt = null;
        });
        _stopArrivalCountdown();
      } else {
        // enroute — таймер ожидания водителя продолжает тикать
        if (_arrivalMinutes <= 0) {
          // Начальная оценка ~5 мин пока реальный ETA не придёт
          setState(() {
            _arrivalMinutes = 5;
            _arrivalSeconds = 0;
            _arrivalRemainingSeconds = 300;
          });
        }
        _startArrivalCountdown();
        // Сразу запросить свежий ETA
        unawaited(_fetchDriverLocationAndEta(orderId));
      }

      if (driverPhone.isNotEmpty && driverPhone != _driverAvatarPhone) {
        unawaited(_loadDriverProfile(driverPhone));
      }
      _startOrderStatusPolling();
      return;
    }

    if (status == 'completed') {
      setState(() {
        _orderFlow = _OrderFlowState.completed;
        _searchDelayMessage = null;
        _clearDriverProfile();
        _arrivalMinutes = 0;
        _arrivalSeconds = 0;
        _arrivalRemainingSeconds = 0;
        _arrivalUpdatedAt = null;
      });
      _stopArrivalCountdown();
      _stopOrderStatusPolling();
      unawaited(_loadCompletedDetails(orderId));
      if (_completedOrderId != orderId) {
        _completedOrderId = orderId;
        _openRatingDialog(orderId);
      }
      return;
    }

    if (status == 'canceled') {
      setState(() {
        _orderFlow = _OrderFlowState.selecting;
        _searchSeconds = 0;
        _searchDelayMessage = null;
        _clearDriverProfile();
        _arrivalMinutes = 0;
        _arrivalSeconds = 0;
        _arrivalRemainingSeconds = 0;
        _arrivalUpdatedAt = null;
      });
      _orderTimer?.cancel();
      _driverFoundTimer?.cancel();
      _stopArrivalCountdown();
      _stopOrderStatusPolling();
      _currentOrderId = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Заказ отменен')),
        );
      }
    }
  }

  Future<BitmapDescriptor> _ensureDriverIcon() async {
    if (_driverIcon != null) return _driverIcon!;
    _driverIcon = _navArrowIcon ?? await _ensureNavArrowIcon();
    return _driverIcon!;
  }

  Timer? _driverLocThrottle;

  void _handleDriverLocation(Map<String, dynamic> data) async {
    final orderId = (data['orderId'] ?? '').toString();
    if (_currentOrderId == null || orderId != _currentOrderId) return;
    final lat = double.tryParse(data['lat']?.toString() ?? '');
    final lng = double.tryParse(data['lng']?.toString() ?? '');
    if (lat == null || lng == null) return;
    final driverPhone = (data['driverPhone'] ?? '').toString();
    final status = (data['status'] ?? '').toString();
    final driverPoint = Point(latitude: lat, longitude: lng);
    final target = status == 'started' && _toPoint != null ? _toPoint! : _fromPoint;
    if (!mounted) return;

    // Сохраняем точку без setState — UI обновится через throttle ниже
    _driverPoint = driverPoint;

    if (driverPhone.trim().isNotEmpty && driverPhone.trim() != _driverAvatarPhone) {
      unawaited(_loadDriverProfile(driverPhone));
    }
    _requestArrivalEtaUpdate(from: driverPoint, to: target, orderId: orderId);

    // Throttle UI-обновления позиции водителя — не чаще раза в 2 сек
    if (_driverLocThrottle?.isActive ?? false) return;
    _driverLocThrottle = Timer(const Duration(seconds: 2), () {});

    // Во время поездки — обновляем маршрут от водителя до назначения
    if (_orderFlow == _OrderFlowState.started && _toPoint != null) {
      unawaited(_updateLiveRoute(driverPoint, _toPoint!));
    } else {
      _updateDriverPlacemark(driverPoint);
    }

    final controller = _mapController;
    if (controller != null &&
        (_orderFlow == _OrderFlowState.assigned ||
            _orderFlow == _OrderFlowState.enroute ||
            _orderFlow == _OrderFlowState.arrived ||
            _orderFlow == _OrderFlowState.started)) {
      final zoom = _orderFlow == _OrderFlowState.started ? 16.0 : 15.0;
      await controller.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: driverPoint, zoom: zoom),
        ),
      );
      if (!mounted) return;
    }
  }

  /// Перестроить маршрут от текущей позиции водителя до назначения (навигация)
  Timer? _liveRouteThrottle;
  int _liveRouteRequestId = 0;

  Future<void> _updateLiveRoute(Point driverPoint, Point destination) async {
    // Троттлинг — не чаще раза в 8 сек
    if (_liveRouteThrottle?.isActive ?? false) {
      _updateDriverPlacemark(driverPoint);
      return;
    }
    _liveRouteThrottle = Timer(const Duration(seconds: 8), () {});

    final requestId = ++_liveRouteRequestId;
    try {
      // Запрос маршрута от водителя до пункта назначения
      final points = <RequestPoint>[
        RequestPoint(point: driverPoint, requestPointType: RequestPointType.wayPoint),
        RequestPoint(point: destination, requestPointType: RequestPointType.wayPoint),
      ];
      final (session, futureResult) = await YandexDriving.requestRoutes(
        points: points,
        drivingOptions: DrivingOptions(routesCount: 1),
      );
      DrivingSessionResult result;
      try {
        result = await futureResult;
      } finally {
        try { await session.close(); } catch (_) {}
      }
      if (!mounted || requestId != _liveRouteRequestId) return;

      final routes = result.routes ?? const <DrivingRoute>[];
      Polyline routeLine;
      if (routes.isNotEmpty) {
        routeLine = routes.first.geometry;
      } else {
        routeLine = Polyline(points: [driverPoint, destination]);
      }

      // Используем предзагруженные иконки (без await)
      final navArrow = _navArrowIcon ?? await _ensureNavArrowIcon();
      final toStick = _stickPinOrangeIcon ?? await _ensureStickPinOrange();

      if (!mounted || requestId != _liveRouteRequestId) return;

      _mo_route = PolylineMapObject(
        mapId: const MapObjectId('route'),
        polyline: routeLine,
        strokeColor: const Color(0xFF4FC3F7),
        strokeWidth: 5.0,
        outlineColor: const Color(0xFF01579B),
        outlineWidth: 1.5,
        isInnerOutlineEnabled: true,
        arcApproximationStep: 1.0,
        zIndex: 0.5,
      );
      _mo_dropoff = PlacemarkMapObject(
        mapId: const MapObjectId('to'),
        point: destination,
        isVisible: true,
        opacity: 1.0,
        zIndex: 3.0,
        icon: PlacemarkIcon.single(
          PlacemarkIconStyle(
            image: toStick,
            scale: 1.2,
            anchor: const Offset(0.5, 1.0),
          ),
        ),
      );
      _mo_driver = PlacemarkMapObject(
        mapId: const MapObjectId('driver'),
        point: driverPoint,
        isVisible: true,
        opacity: 1.0,
        zIndex: 6.0,
        icon: PlacemarkIcon.single(
          PlacemarkIconStyle(
            image: navArrow,
            scale: 0.85,
            anchor: const Offset(0.5, 0.5),
          ),
        ),
      );
      _mo_pickup = null;
      _mo_myLocation = null;
      _notifyMapObjects();
    } catch (_) {
      _updateDriverPlacemark(driverPoint);
    }
  }

  void _updateDriverPlacemark(Point point) {
    final icon = _driverIcon ?? _navArrowIcon;
    if (icon == null) return;
    _mo_driver = PlacemarkMapObject(
      mapId: const MapObjectId('driver'),
      point: point,
      isVisible: true,
      opacity: 1.0,
      zIndex: 6.0,
      icon: PlacemarkIcon.single(
        PlacemarkIconStyle(
          image: icon,
          scale: 0.8,
          anchor: const Offset(0.5, 0.5),
        ),
      ),
    );
    _notifyMapObjects();
  }

  void _handleOrderDelay(Map<String, dynamic> data) {
    final orderId = (data['orderId'] ?? '').toString();
    if (_currentOrderId == null || orderId != _currentOrderId) return;
    final message = (data['message'] ?? '').toString().trim();
    if (message.isEmpty || !mounted) return;
    // Обновляем без setState — ValueListenableBuilder подхватит на след. тике
    _searchDelayMessage = message;
  }

  Future<void> _loadDriverProfile(String phone) async {
    final normalized = phone.trim();
    if (normalized.isEmpty) return;
    final digits = normalized.replaceAll(RegExp(r'\D'), '');
    final queryPhone = digits.isNotEmpty ? digits : normalized;
    final lastAt = _driverProfileFetchedAt;
    if (_driverAvatarPhone == queryPhone &&
        lastAt != null &&
        DateTime.now().difference(lastAt).inSeconds < 20) {
      return;
    }
    _driverAvatarPhone = queryPhone;
    _driverProfileFetchedAt = DateTime.now();
    try {
      final res = await http.get(
        Uri.parse('$_apiBaseUrl/api/driver/profile?phone=$queryPhone'),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final profile = map['profile'] as Map? ?? const {};
      final avatarBase64 = profile?['avatarBase64']?.toString();
      final nameRaw = profile?['fullName']?.toString().trim();
      final ratingRaw = profile?['rating'];
      final rating = ratingRaw is num ? ratingRaw.toDouble() : double.tryParse(ratingRaw?.toString() ?? '');
      final ratingCountRaw = profile?['ratingCount'];
      final ratingCount =
          ratingCountRaw is num ? ratingCountRaw.toInt() : int.tryParse(ratingCountRaw?.toString() ?? '');
      final bytes =
          (avatarBase64 == null || avatarBase64.isEmpty) ? null : base64Decode(avatarBase64);
      if (!mounted) return;
      setState(() {
        _driverAvatarBytes = bytes;
        _driverName = (nameRaw != null && nameRaw.isNotEmpty) ? nameRaw : null;
        _driverRating = rating;
        _driverRatingCount = ratingCount;
      });
    } catch (_) {}
  }

  void _clearDriverProfile() {
    _driverAvatarPhone = null;
    _driverAvatarBytes = null;
    _driverName = null;
    _driverRating = null;
    _driverRatingCount = null;
    _driverProfileFetchedAt = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pickupDebounce?.cancel();
    _pickupDragThrottle?.cancel();
    _dropoffDebounce?.cancel();
    _dropoffDragThrottle?.cancel();
    _driverLocThrottle?.cancel();
    _liveRouteThrottle?.cancel();
    _orderTimer?.cancel();
    _driverFoundTimer?.cancel();
    _statusPollTimer?.cancel();
    _stopArrivalCountdown();
    final socket = _socket;
    if (socket != null) {
      socket.dispose();
    }
    final session = _drivingSession;
    if (session != null) {
      unawaited(session.close());
      _drivingSession = null;
    }
    final etaSession = _etaDrivingSession;
    if (etaSession != null) {
      unawaited(etaSession.close());
      _etaDrivingSession = null;
    }
    _mapObjectsNotifier.dispose();
    _searchSecondsNotifier.dispose();
    _fromAddressNotifier.dispose();
    _toAddressNotifier.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_loadActiveOrder());
    }
  }

  static String _formatMmSs(int seconds) {
    final s = math.max(0, seconds);
    final m = s ~/ 60;
    final ss = s % 60;
    return '${m.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
  }

  void _applyArrivalEstimateMinutes(int minutes) {
    final clamped = math.max(1, minutes);
    _arrivalMinutes = clamped;
    _arrivalSeconds = clamped * 60;
    _arrivalRemainingSeconds = 0;
    _arrivalUpdatedAt = DateTime.now();
  }

  void _applyArrivalEstimateSeconds(int seconds) {
    final clamped = math.max(1, seconds);
    _arrivalSeconds = clamped;
    _arrivalMinutes = (clamped / 60).ceil();
    _arrivalRemainingSeconds = 0;
    _arrivalUpdatedAt = DateTime.now();
  }

  void _startArrivalCountdown() {
    _stopArrivalCountdown();
  }

  void _stopArrivalCountdown() {
    _arrivalCountdownTimer?.cancel();
    _arrivalCountdownTimer = null;
  }

  bool _shouldRequestEta(Point from, Point to) {
    final now = DateTime.now();
    final lastAt = _etaRequestedAt;
    if (lastAt == null) return true;
    final age = now.difference(lastAt).inSeconds;
    if (age >= 10) return true;
    final lastFrom = _etaFrom;
    final lastTo = _etaTo;
    if (lastFrom == null || lastTo == null) return true;
    if (!_samePoint(to, lastTo)) return true;
    final movedKm = _haversineKm(from.latitude, from.longitude, lastFrom.latitude, lastFrom.longitude);
    return movedKm >= 0.25;
  }

  Future<int?> _estimateDrivingEtaSeconds({required Point from, required Point to}) async {
    final requestId = ++_etaRequestId;
    try {
      await _etaDrivingSession?.cancel();
    } catch (_) {}
    try {
      await _etaDrivingSession?.close();
    } catch (_) {}
    _etaDrivingSession = null;

    final points = <RequestPoint>[
      RequestPoint(point: from, requestPointType: RequestPointType.wayPoint),
      RequestPoint(point: to, requestPointType: RequestPointType.wayPoint),
    ];

    final (session, futureResult) = await YandexDriving.requestRoutes(
      points: points,
      drivingOptions: DrivingOptions(routesCount: 1),
    );

    _etaDrivingSession = session;

    DrivingSessionResult result;
    try {
      result = await futureResult;
    } finally {
      try {
        await session.close();
      } catch (_) {}
      if (identical(_etaDrivingSession, session)) {
        _etaDrivingSession = null;
      }
    }

    if (!mounted || requestId != _etaRequestId) return null;
    final err = result.error ?? '';
    final routes = result.routes ?? const <DrivingRoute>[];
    if (err.isNotEmpty || routes.isEmpty) return null;
    final w = routes.first.metadata.weight;
    final seconds = (w.timeWithTraffic.value ?? w.time.value ?? 0).round();
    return seconds > 0 ? seconds : null;
  }

  Future<void> _fetchDriverLocationAndEta(String orderId) async {
    // Повторяем до 6 раз с интервалом 3 сек, пока не получим координаты водителя
    for (var attempt = 0; attempt < 6; attempt++) {
      if (!mounted || _currentOrderId != orderId) return;
      // Если ETA уже есть (пришёл через driver:location), выходим
      if (_arrivalMinutes > 0) return;
      try {
        final res = await http.get(Uri.parse('$_apiBaseUrl/api/orders/$orderId'));
        if (res.statusCode < 200 || res.statusCode >= 300) break;
        final map = jsonDecode(res.body) as Map<String, dynamic>;
        final dLat = double.tryParse(map['driverLat']?.toString() ?? '');
        final dLng = double.tryParse(map['driverLng']?.toString() ?? '');
        if (dLat != null && dLng != null) {
          if (!mounted || _currentOrderId != orderId) return;
          final driverPoint = Point(latitude: dLat, longitude: dLng);
          setState(() {
            _driverPoint = driverPoint;
          });
          _etaRequestedAt = null;
          _requestArrivalEtaUpdate(from: driverPoint, to: _fromPoint, orderId: orderId);
          return;
        }
      } catch (_) {}
      // Подождать 3 секунды перед следующей попыткой
      await Future.delayed(const Duration(seconds: 3));
    }
  }

  void _requestArrivalEtaUpdate({
    required Point from,
    required Point to,
    required String orderId,
  }) {
    if (!_shouldRequestEta(from, to)) return;
    _etaRequestedAt = DateTime.now();
    _etaFrom = from;
    _etaTo = to;
    unawaited(() async {
      final etaSeconds = await _estimateDrivingEtaSeconds(from: from, to: to);
      if (etaSeconds == null) return;
      if (!mounted || _currentOrderId != orderId) return;
      if (etaSeconds <= 0) return;
      setState(() {
        _applyArrivalEstimateSeconds(etaSeconds);
      });
    }());
  }

  static bool _samePoint(Point a, Point b) {
    return a.latitude.toStringAsFixed(6) == b.latitude.toStringAsFixed(6) &&
        a.longitude.toStringAsFixed(6) == b.longitude.toStringAsFixed(6);
  }

  static String _formatDistanceMeters(num meters) {
    final m = meters.toDouble();
    if (m >= 1000) {
      final km = m / 1000.0;
      if (km >= 10) return '${km.round()} км';
      return '${km.toStringAsFixed(1).replaceAll('.0', '')} км';
    }
    return '${m.round()} м';
  }

  static String _formatDurationSeconds(num seconds) {
    final d = Duration(seconds: seconds.round());
    final totalMin = d.inMinutes;
    if (totalMin < 60) return '$totalMin мин';
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    return m == 0 ? '$h ч' : '$h ч $m мин';
  }

  Future<void> _clearRouteState() async {
    try {
      await _drivingSession?.cancel();
    } catch (_) {}
    try {
      await _drivingSession?.close();
    } catch (_) {}
    _drivingSession = null;
    _routeLoading = false;
    _routeSummary = null;
    _routeDistanceMeters = null;
    _routeEtaSeconds = null;
    _routeFrom = null;
    _routeTo = null;
    _routePolyline = null;
  }

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

    try {
      await _drivingSession?.cancel();
    } catch (_) {}
    try {
      await _drivingSession?.close();
    } catch (_) {}
    _drivingSession = null;

    if (mounted) {
      setState(() {
        _routeLoading = true;
      });
    }

    final snappedFrom = await _snapPointForRouting(from);
    final snappedTo = await _snapPointForRouting(to);

    final points = <RequestPoint>[
      RequestPoint(point: snappedFrom, requestPointType: RequestPointType.wayPoint),
      RequestPoint(point: snappedTo, requestPointType: RequestPointType.wayPoint),
    ];

    final (session, futureResult) = await YandexDriving.requestRoutes(
      points: points,
      drivingOptions: DrivingOptions(routesCount: 1),
    );

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
      setState(() {
        _routeLoading = false;
        _routeSummary = null;
        _routeFrom = from;
        _routeTo = to;
        _routePolyline = Polyline(points: <Point>[from, to]);
      });
      return _routePolyline!;
    }

    final route = routes.first;
    final routePolyline = route.geometry;

    final combined = <Point>[];
    if (!_samePoint(from, snappedFrom)) {
      combined
        ..add(from)
        ..add(snappedFrom);
    }

    final routePts = routePolyline.points;
    if (routePts.isEmpty) {
      combined
        ..add(snappedFrom)
        ..add(snappedTo);
    } else {
      if (combined.isNotEmpty && _samePoint(combined.last, routePts.first)) {
        combined.addAll(routePts.skip(1));
      } else {
        combined.addAll(routePts);
      }
    }

    if (!_samePoint(snappedTo, to)) {
      if (combined.isEmpty || !_samePoint(combined.last, to)) {
        combined.add(to);
      }
    }

    final polyline = Polyline(points: combined);

    final w = route.metadata.weight;
    final distanceMeters = w.distance.value ?? 0.0;
    final timeSeconds = w.time.value ?? 0.0;
    final timeWithTrafficSeconds = w.timeWithTraffic.value ?? 0.0;

    // Для оценки цены используем время С пробками — ближе к реальности.
    // Итоговая цена (priceFinal) всё равно считается по факту поездки.
    final eta = timeWithTrafficSeconds > 0 ? timeWithTrafficSeconds : timeSeconds;
    final summary = distanceMeters > 0 && eta > 0
        ? '${_formatDistanceMeters(distanceMeters)} · ${_formatDurationSeconds(eta)}'
        : null;

    // ── Рассчитать км вне МКАД по реальной полилинии ──────────
    final outsideKm = _calcKmOutsideMkad(combined);
    debugPrint('[PRICING] polyline points: ${combined.length}, '
        'routeKm: ${(distanceMeters / 1000).toStringAsFixed(1)}, '
        'kmOutsideMkad: ${outsideKm.toStringAsFixed(2)}, '
        'eta min: ${(eta / 60).toStringAsFixed(1)}');

    final quote = _buildTariffQuote(
      serviceIndex: _selectedType,
      from: from,
      to: to,
      routeDistanceMeters: distanceMeters,
      routeEtaSeconds: eta,
      kmOutsideMkad: outsideKm,
    );

    setState(() {
      _routeLoading = false;
      _routeSummary = summary;
      _routeDistanceMeters = distanceMeters;
      _routeEtaSeconds = eta;
      _kmOutsideMkad = outsideKm;
      _routeFrom = from;
      _routeTo = to;
      _routePolyline = polyline;
      _quote = quote;
    });

    return polyline;
  }

  void _updatePickupPlacemarkPoint(Point point) {
    final existing = _mo_pickup;
    if (existing == null) return;
    _mo_pickup = PlacemarkMapObject(
      mapId: existing.mapId,
      point: point,
      isVisible: existing.isVisible,
      opacity: existing.opacity,
      zIndex: existing.zIndex,
      icon: existing.icon,
    );
  }

  void _updateDropoffPlacemarkPoint(Point point) {
    final existing = _mo_dropoff;
    if (existing == null) return;
    _mo_dropoff = PlacemarkMapObject(
      mapId: existing.mapId,
      point: point,
      isVisible: existing.isVisible,
      opacity: existing.opacity,
      zIndex: existing.zIndex,
      icon: existing.icon,
    );
  }

  void _onCameraPositionChanged(
    CameraPosition cameraPosition,
    CameraUpdateReason reason,
    bool finished,
  ) {
    if (reason != CameraUpdateReason.gestures) return;

    if (_dropoffEditing) {
      _lastCameraTarget = cameraPosition.target;
      _pendingDropoffPoint = _lastCameraTarget;
      if (!mounted) return;
      if (_draggingDropoff != !finished) {
        setState(() { _draggingDropoff = !finished; });
      }
      if (finished) {
        _toPoint = _lastCameraTarget;
        _updateDropoffPlacemarkPoint(_toPoint!);
        setState(() {});
        _scheduleDropoffAddressUpdate(_lastCameraTarget);
        return;
      }
      // Во время drag — только сохраняем координату, без rebuild (пин по центру экрана)
      _toPoint = _lastCameraTarget;
      _scheduleDropoffAddressUpdate(_lastCameraTarget);
      return;
    }

    if (_toPoint != null && !_pickupEditing) {
      _pickupDebounce?.cancel();
      if (_draggingPickup) {
        setState(() {
          _draggingPickup = false;
        });
      }
      return;
    }

    // Когда в selecting режиме и нет точки назначения — всегда обновляем pickup
    if (_orderFlow == _OrderFlowState.selecting && _toPoint == null && !_pickupEditing) {
      _lastCameraTarget = cameraPosition.target;
      _pendingPickupPoint = _lastCameraTarget;
      if (!mounted) return;
      if (_draggingPickup != !finished) {
        setState(() { _draggingPickup = !finished; });
      }
      if (finished) {
        _fromPoint = _lastCameraTarget;
        _updatePickupPlacemarkPoint(_fromPoint);
        setState(() {});
        _schedulePickupAddressUpdate(_fromPoint);
        return;
      }
      // Во время drag — только сохраняем координату, без rebuild
      _fromPoint = _lastCameraTarget;
      _schedulePickupAddressUpdate(_fromPoint);
      return;
    }

    if (_pickupEditing) {
      _lastCameraTarget = cameraPosition.target;
      _pendingPickupPoint = _lastCameraTarget;
      if (!mounted) return;
      if (_draggingPickup != !finished) {
        setState(() { _draggingPickup = !finished; });
      }
      if (finished) {
        _fromPoint = _lastCameraTarget;
        _updatePickupPlacemarkPoint(_fromPoint);
        setState(() {});
        _schedulePickupAddressUpdate(_fromPoint);
        return;
      }
      // Во время drag — только сохраняем координату, без rebuild (пин по центру экрана)
      _fromPoint = _lastCameraTarget;
      _schedulePickupAddressUpdate(_fromPoint);
      return;
    }

    if (_draggingPickup) {
      setState(() {
        _draggingPickup = false;
      });
    }

    return;
  }

  Future<void> _applyPickupPoint(
    Point point, {
    required bool rebuildRoute,
  }) async {
    final requestId = ++_pickupRequestId;
    final to = _toPoint;
    final nextQuote = to == null
        ? null
        : _buildTariffQuote(
            serviceIndex: _selectedType,
            from: point,
            to: to,
            routeDistanceMeters: _routeDistanceMeters,
            routeEtaSeconds: _routeEtaSeconds,
          );

    if (!mounted) return;
    setState(() {
      _fromPoint = point;
      _quote = nextQuote;
    });

    if (rebuildRoute) {
      await _updateRoutePreview(moveCamera: false);
    }

    unawaited(() async {
      final address = await _reverseGeocode(point);
      if (!mounted || requestId != _pickupRequestId) return;

      final nextAddress = (address == null || address.trim().isEmpty)
          ? 'Точка подачи'
          : address.trim();

      _fromAddress = nextAddress; // ValueNotifier — обновит только адресный чип
    }());
  }

  void _schedulePickupAddressUpdate(Point point) {
    _pickupDebounce?.cancel();
    final requestId = ++_pickupAddressRequestId;
    _pickupDebounce = Timer(const Duration(milliseconds: 480), () async {
      final address = await _reverseGeocode(point);
      if (!mounted || requestId != _pickupAddressRequestId) return;
      final nextAddress =
          (address == null || address.trim().isEmpty) ? 'Точка подачи' : address.trim();
      _fromAddress = nextAddress; // ValueNotifier — без full rebuild
    });
  }

  Future<void> _applyDropoffPoint(Point point) async {
    final nextQuote = _buildTariffQuote(
      serviceIndex: _selectedType,
      from: _fromPoint,
      to: point,
      routeDistanceMeters: _routeDistanceMeters,
      routeEtaSeconds: _routeEtaSeconds,
    );
    if (!mounted) return;
    setState(() {
      _toPoint = point;
      _quote = nextQuote;
      _pickupEditing = false;
    });

    await _updateRoutePreview(moveCamera: false);

    unawaited(() async {
      final address = await _reverseGeocode(point);
      if (!mounted) return;
      final nextAddress =
          (address == null || address.trim().isEmpty) ? 'Точка назначения' : address.trim();
      _toAddress = nextAddress; // ValueNotifier — без full rebuild
    }());
  }

  void _scheduleDropoffAddressUpdate(Point point) {
    _dropoffDebounce?.cancel();
    final requestId = ++_dropoffAddressRequestId;
    _dropoffDebounce = Timer(const Duration(milliseconds: 480), () async {
      final address = await _reverseGeocode(point);
      if (!mounted || requestId != _dropoffAddressRequestId) return;
      final nextAddress =
          (address == null || address.trim().isEmpty) ? 'Точка назначения' : address.trim();
      _toAddress = nextAddress; // ValueNotifier — без full rebuild
    });
  }

  Future<void> _startDropoffEdit(Point point) async {
    if (!mounted) return;
    setState(() {
      _toPoint = point;
      _lastCameraTarget = point;
      _dropoffEditing = true;
      _toAddress = 'Точка назначения';
    });
    _scheduleDropoffAddressUpdate(point);
    await _updateRoutePreview(moveCamera: false);
    final controller = _mapController;
    if (controller != null) {
      await controller.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: point, zoom: 16),
        ),
      );
    }
  }

  Future<void> _finishDropoffEdit() async {
    _dropoffDebounce?.cancel();
    final point = _lastCameraTarget;
    if (!mounted) return;

    setState(() {
      _dropoffEditing = false;
    });

    await _applyDropoffPoint(point);
  }

  Future<void> _startPickupEdit() async {
    final controller = _mapController;
    if (controller != null) {
      await controller.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _fromPoint, zoom: 16),
        ),
      );
    }
    if (!mounted) return;
    setState(() {
      _lastCameraTarget = _fromPoint;
      _pickupEditing = true;
    });
  }

  Future<void> _finishPickupEdit() async {
    _pickupDebounce?.cancel();
    final point = _lastCameraTarget;
    if (!mounted) return;

    setState(() {
      _pickupEditing = false;
    });

    await _applyPickupPoint(point, rebuildRoute: false);
    await _updateRoutePreview(moveCamera: false);
  }

  Future<void> _maybeInitMyLocation() async {
    if (_initialLocateAttempted) return;
    _initialLocateAttempted = true;
    await _useMyLocation(silent: true);
  }

  Future<Point> _getCurrentPoint() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        return Point(latitude: last.latitude, longitude: last.longitude);
      }
      throw StateError('Location service disabled');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission denied');
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      return Point(latitude: pos.latitude, longitude: pos.longitude);
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        return Point(latitude: last.latitude, longitude: last.longitude);
      }
      rethrow;
    }
  }



  Future<String?> _reverseGeocode(Point point) async {
    try {
      final (session, futureResult) = await YandexSearch.searchByPoint(
        point: point,
        zoom: 16,
        searchOptions: SearchOptions(
          searchType: SearchType.geo,
          resultPageSize: 1,
          userPosition: point,
        ),
      );
      final result = await futureResult;
      await session.close();
      final items = result.items;
      if (items != null && items.isNotEmpty) {
        final item = items.first;
        final formatted = item.toponymMetadata?.address.formattedAddress;
        if (formatted != null && formatted.trim().isNotEmpty) {
          return _shortenAddress(formatted);
        }
        final name = item.name;
        if (name.trim().isNotEmpty) return _shortenAddress(name);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<BitmapDescriptor> _ensurePickupPinIcon() async {
    final cached = _pickupPinIcon;
    if (cached != null) return cached;

    final built = await _buildPickupMarkerIcon();
    _pickupPinIcon = built;
    return built;
  }

  Future<BitmapDescriptor> _buildFallbackDot(Color color) async {
    const size = 48.0;
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    final paint = Paint()..color = color;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2.4, paint);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ImageByteFormat.png);
    if (byteData == null) {
      const transparentPngBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9YlGg0QAAAAASUVORK5CYII=';
      return BitmapDescriptor.fromBytes(base64Decode(transparentPngBase64));
    }
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }

  // Палочка-пин для точки на карте (без надписи)
  BitmapDescriptor? _stickPinWhiteIcon;
  BitmapDescriptor? _stickPinOrangeIcon;
  BitmapDescriptor? _navArrowIcon;

  Future<BitmapDescriptor> _buildStickPinIcon(Color color) async {
    const w = 24.0;
    const h = 80.0;
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

    // Палочка с градиентом (прозрачная сверху → цвет снизу)
    final stickPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x00FFFFFF), Color(0xDDFFFFFF)],
      ).createShader(Rect.fromLTWH(w / 2 - 1.5, 0, 3, h - 12));
    stickPaint.color = color.withOpacity(0.0);
    final stickGradient = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withOpacity(0.0), color.withOpacity(0.90)],
      ).createShader(Rect.fromLTWH(w / 2 - 1.5, 4, 3, h - 16));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w / 2 - 1.5, 4, 3, h - 16),
        const Radius.circular(1.5),
      ),
      stickGradient,
    );

    // Кружок внизу
    final dotPaint = Paint()..color = color;
    canvas.drawCircle(Offset(w / 2, h - 6), 6, dotPaint);

    // Белая обводка кружка
    final borderPaint = Paint()
      ..color = _white85
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(Offset(w / 2, h - 6), 6, borderPaint);

    // Тень под кружком
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.30)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(Offset(w / 2, h - 4), 4, shadowPaint);

    final picture = recorder.endRecording();
    final image = await picture.toImage(w.toInt(), h.toInt());
    final byteData = await image.toByteData(format: ImageByteFormat.png);
    if (byteData == null) return _buildFallbackDot(color);
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }

  Future<BitmapDescriptor> _ensureStickPinWhite() async {
    return _stickPinWhiteIcon ??= await _buildStickPinIcon(Colors.white);
  }

  Future<BitmapDescriptor> _ensureStickPinOrange() async {
    return _stickPinOrangeIcon ??= await _buildStickPinIcon(const Color(0xFFFF3D00));
  }

  // Стрелка навигации для водителя (как в Яндекс Навигаторе)
  Future<BitmapDescriptor> _buildNavArrowIcon() async {
    const size = 72.0;
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));

    final center = Offset(size / 2, size / 2);

    // Тень
    final shadowPaint = Paint()
      ..color = _black35
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final shadowPath = Path()
      ..moveTo(center.dx, center.dy - 26)
      ..lineTo(center.dx + 18, center.dy + 20)
      ..lineTo(center.dx, center.dy + 10)
      ..lineTo(center.dx - 18, center.dy + 20)
      ..close();
    canvas.drawPath(shadowPath.shift(const Offset(0, 2)), shadowPaint);

    // Основная стрелка — тёмный фон
    final arrowPath = Path()
      ..moveTo(center.dx, center.dy - 28)       // верхний кончик
      ..lineTo(center.dx + 20, center.dy + 22)  // правый угол
      ..lineTo(center.dx, center.dy + 10)       // нижняя выемка
      ..lineTo(center.dx - 20, center.dy + 22)  // левый угол
      ..close();

    // Градиент на стрелке
    final arrowPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFCFD8DC), Color(0xFF90A4AE)],
      ).createShader(Rect.fromLTWH(0, center.dy - 28, size, 50));
    canvas.drawPath(arrowPath, arrowPaint);

    // Обводка
    final strokePaint = Paint()
      ..color = _white90
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(arrowPath, strokePaint);

    // Внутренняя маленькая стрелка (highlight)
    final innerPath = Path()
      ..moveTo(center.dx, center.dy - 18)
      ..lineTo(center.dx + 10, center.dy + 12)
      ..lineTo(center.dx, center.dy + 5)
      ..lineTo(center.dx - 10, center.dy + 12)
      ..close();
    final innerPaint = Paint()
      ..color = Colors.white.withOpacity(0.25);
    canvas.drawPath(innerPath, innerPaint);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ImageByteFormat.png);
    if (byteData == null) return _buildFallbackDot(const Color(0xFFCFD8DC));
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }

  Future<BitmapDescriptor> _ensureNavArrowIcon() async {
    return _navArrowIcon ??= await _buildNavArrowIcon();
  }

  Future<BitmapDescriptor> _ensureFinishFlagIcon() async {
    final cached = _finishFlagIcon;
    if (cached != null) return cached;

    final built = await _buildFinishFlagIcon();
    _finishFlagIcon = built;
    return built;
  }

  Future<Point> _snapPointForRouting(Point point) async {
    try {
      final (session, futureResult) = await YandexSearch.searchByPoint(
        point: point,
        zoom: 18,
        searchOptions: SearchOptions(
          searchType: SearchType.geo,
          geometry: true,
          resultPageSize: 1,
          userPosition: point,
        ),
      );

      final result = await futureResult;
      await session.close();

      final items = result.items;
      if (items == null || items.isEmpty) return point;
      final item = items.first;
      final geometryPoint = item.geometry
          .map((g) => g.point)
          .firstWhere((p) => p != null, orElse: () => null);
      return item.toponymMetadata?.balloonPoint ?? geometryPoint ?? point;
    } catch (_) {
      return point;
    }
  }

  Future<BitmapDescriptor> _buildPickupMarkerIcon() async {
    const size = 96.0;
    const viewW = 200.0;
    const viewH = 260.0;

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));

    canvas.save();
    final scale = size / viewH;
    final dx = (size - viewW * scale) / 2;
    canvas.translate(dx, 0);
    canvas.scale(scale, scale);

    final outer = Path()
      ..moveTo(100, 20)
      ..cubicTo(58, 20, 30, 50, 30, 92)
      ..cubicTo(30, 140, 70, 170, 92, 220)
      ..cubicTo(96, 232, 104, 232, 108, 220)
      ..cubicTo(130, 170, 170, 140, 170, 92)
      ..cubicTo(170, 50, 142, 20, 100, 20)
      ..close();

    final hole = Path()
      ..addOval(
        Rect.fromCircle(
          center: const Offset(100, 90),
          radius: 42,
        ),
      );

    final pinPath = Path.combine(PathOperation.difference, outer, hole);

    final paint = Paint()
      ..shader = Gradient.linear(
        const Offset(20, 20),
        const Offset(180, 240),
        const [
          Color(0xFF6A00FF),
          Color(0xFFFF3DB8),
          Color(0xFFFF8A00),
          Color(0xFFFFFFFF),
          Color(0xFFFF0000),
        ],
        const [0.0, 0.25, 0.45, 0.65, 1.0],
      );

    canvas.drawShadow(pinPath, Colors.black.withOpacity(0.28), 16, true);
    canvas.drawPath(pinPath, paint);
    canvas.restore();

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ImageByteFormat.png);
    if (byteData == null) {
      return _buildFallbackDot(const Color(0xFF6A00FF));
    }
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }

  Future<BitmapDescriptor> _buildFinishFlagIcon() async {
    const size = 96.0;

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));

    final gradient = Gradient.linear(
      const Offset(0, 0),
      const Offset(size, size),
      const [Color(0xFF2E5BFF), Color(0xFF9B2CFF)],
    );

    final pinStroke = Paint()
      ..shader = gradient
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final pinPath = Path()
      ..moveTo(size * 0.5, size * 0.12)
      ..cubicTo(size * 0.30, size * 0.12, size * 0.18, size * 0.30, size * 0.18, size * 0.48)
      ..cubicTo(size * 0.18, size * 0.70, size * 0.34, size * 0.82, size * 0.44, size * 0.92)
      ..cubicTo(size * 0.48, size * 0.96, size * 0.52, size * 0.96, size * 0.56, size * 0.92)
      ..cubicTo(size * 0.66, size * 0.82, size * 0.82, size * 0.70, size * 0.82, size * 0.48)
      ..cubicTo(size * 0.82, size * 0.30, size * 0.70, size * 0.12, size * 0.5, size * 0.12)
      ..close();

    canvas.drawPath(pinPath, pinStroke);

    final ringPaint = Paint()
      ..shader = gradient
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;

    final ringCenter = Offset(size * 0.5, size * 0.40);
    canvas.drawCircle(ringCenter, size * 0.16, ringPaint);

    final innerPaint = Paint()
      ..shader = Gradient.radial(
        ringCenter,
        size * 0.10,
        const [Color(0xFF8FD3FF), Color(0xFF9B57FF)],
      );
    canvas.drawCircle(ringCenter, size * 0.08, innerPaint);

    final baseRect = Rect.fromCenter(
      center: Offset(size * 0.5, size * 0.92),
      width: size * 0.38,
      height: size * 0.12,
    );
    canvas.drawOval(baseRect, ringPaint);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ImageByteFormat.png);
    if (byteData == null) {
      return _buildFallbackDot(const Color(0xFF2E5BFF));
    }
    return BitmapDescriptor.fromBytes(byteData.buffer.asUint8List());
  }

  void _setType(int index) {
    final to = _toPoint;
    final nextQuote = to == null
        ? null
        : _buildTariffQuote(
            serviceIndex: index,
            from: _fromPoint,
            to: to,
            routeDistanceMeters: _routeDistanceMeters,
            routeEtaSeconds: _routeEtaSeconds,
          );

    setState(() {
      _selectedType = index;
      _quote = nextQuote;
    });
  }

  _TariffQuote? _buildTariffQuote({
    required int serviceIndex,
    required Point from,
    required Point to,
    double? routeDistanceMeters,
    double? routeEtaSeconds,
    double? kmOutsideMkad,
  }) {
    final outsideKm = kmOutsideMkad ?? _kmOutsideMkad;
    if (_tariffs.isEmpty) {
      return _TariffQuote.tryBuild(
        serviceIndex: serviceIndex,
        from: from,
        to: to,
        routeDistanceMeters: routeDistanceMeters,
        routeEtaSeconds: routeEtaSeconds,
        kmOutsideMkad: outsideKm,
      );
    }
    if (serviceIndex < 0 || serviceIndex >= _tariffs.length) return null;
    final t = _tariffs[serviceIndex];
    final mode = (t['mode'] ?? '').toString().trim().toLowerCase();
    if (mode != 'custom') {
      return _TariffQuote.tryBuild(
        serviceIndex: serviceIndex,
        from: from,
        to: to,
        routeDistanceMeters: routeDistanceMeters,
        routeEtaSeconds: routeEtaSeconds,
        kmOutsideMkad: outsideKm,
      );
    }
    final name = (t['name'] ?? '').toString().trim();
    final base = double.tryParse(t['base']?.toString() ?? '') ?? 0;
    final perKm = double.tryParse(t['perKm']?.toString() ?? '') ?? 0;
    final perMin = double.tryParse(t['perMin']?.toString() ?? '') ?? 0;
    final includedMin = double.tryParse(t['includedMin']?.toString() ?? '') ?? 0;
    final minutes = _TariffQuote._routeMinutes(routeEtaSeconds).toDouble();
    final extraMin = math.max(0, minutes - includedMin);
    final distanceKm = math.max(0, (routeDistanceMeters ?? 0) / 1000.0);
    final price = (base + perKm * distanceKm + perMin * extraMin).round();
    final baseLine = includedMin > 0 && perMin > 0
        ? '${includedMin.toStringAsFixed(0)} мин / далее ${perMin.toStringAsFixed(0)} ₽/мин'
        : (perMin > 0 ? '${perMin.toStringAsFixed(0)} ₽/мин' : 'Базовый тариф');
    return _TariffQuote(
      zone: _TariffZone.mkad,
      title: name.isEmpty ? 'Тариф' : name,
      leftLines: [distanceKm > 0 ? '${distanceKm.toStringAsFixed(1)} км' : ''],
      priceFrom: price,
      bottomLine: baseLine,
    );
  }

  void _notReady() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Скоро будет доступно')),
    );
  }

  void _startOrder() {
    if (_toPoint == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите пункт назначения')),
      );
      return;
    }

    _createOrder();
  }

  void _openOrderHistory() {
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          final primary = isLight ? const Color(0xFF1F2534) : _white95;
          final secondary = isLight ? const Color(0xFF5C6477) : _white70;
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                'История заказов',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            body: FutureBuilder<String?>(
              future: SharedPreferences.getInstance().then((p) => p.getString(_orderHistoryKey)),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Ошибка загрузки', style: TextStyle(color: secondary)));
                }
                final raw = snapshot.data;
                List<dynamic> items;
                try { items = raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>); }
                catch (_) { items = <dynamic>[]; }
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      'История пока пустая',
                      style: TextStyle(color: secondary, fontWeight: FontWeight.w700),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemBuilder: (context, index) {
                    final item = items[index] as Map<String, dynamic>;
                    final from = item['from']?.toString() ?? '';
                    final to = item['to']?.toString() ?? '';
                    final price = item['price']?.toString() ?? '';
                    return _GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              from,
                              style: TextStyle(color: primary, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              to,
                              style: TextStyle(color: secondary, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '$price ₽',
                              style: TextStyle(color: primary, fontWeight: FontWeight.w900),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemCount: items.length,
                );
              },
            ),
          );
        },
      ),
    );
  }

  void _openServiceInfo({
    required String title,
    required String description,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B0D12),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Drag handle
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: const Color(0xFF2A2F3A),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: _white95,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    description,
                    style: const TextStyle(
                      color: _white78,
                      fontWeight: FontWeight.w700,
                      height: 1.45,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: _PrimaryGlowButton(
                    label: 'ПОНЯТНО',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _createOrder() async {
    // Защита от двойного тапа
    if (_creatingOrder) return;
    _creatingOrder = true;

    final clientId = _clientId ?? await _getOrCreateClientId();
    final toPoint = _toPoint;
    if (toPoint == null) { _creatingOrder = false; return; }

    _orderTimer?.cancel();
    _driverFoundTimer?.cancel();
    _statusPollTimer?.cancel();

    setState(() {
      _orderFlow = _OrderFlowState.searching;
      _searchSeconds = 0;
      _arrivalMinutes = 0;
      _arrivalSeconds = 0;
      _arrivalRemainingSeconds = 0;
      _arrivalUpdatedAt = null;
      _completedPriceRub = 0;
      _completedTripMinutes = 0;
      _searchDelayMessage = null;
      _clearDriverProfile();
    });

    try {
      final res = await http.post(
        Uri.parse('$_apiBaseUrl/api/orders'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'clientId': clientId,
          'from': {'lat': _fromPoint.latitude, 'lng': _fromPoint.longitude},
          'to': {'lat': toPoint.latitude, 'lng': toPoint.longitude},
          'fromAddress': _fromAddress,
          'toAddress': _toAddress,
          'comment': _comment,
          'wish': _wish,
          'serviceIndex': _selectedType,
          'routeDistanceMeters': _routeDistanceMeters,
          'routeEtaSeconds': _routeEtaSeconds,
          'kmOutsideMkad': _kmOutsideMkad,
          'paymentMethod': _paymentMethod == _PaymentMethod.cash ? 'cash' : 'sbp',
          if (_promoDiscountPercent > 0) 'discountPercent': _promoDiscountPercent,
          if (_scheduledAt != null) 'scheduledAt': _scheduledAt!.toIso8601String(),
        }),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception(res.body);
      }
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final order = (map['order'] as Map).cast<String, dynamic>();
      _currentOrderId = order['id']?.toString();
      if (_promoDiscountPercent > 0) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_promoCodeKey, '');
        await prefs.setInt(_promoDiscountKey, 0);
        if (mounted) {
          setState(() {
            _promoCode = '';
            _promoDiscountPercent = 0;
          });
        }
      }
      _startOrderStatusPolling();
      await _saveOrderHistory();
    } catch (_) {
      _creatingOrder = false;
      if (!mounted) return;
      setState(() {
        _orderFlow = _OrderFlowState.selecting;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось создать заказ')),
      );
      return;
    }

    _creatingOrder = false;
    _orderTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_orderFlow != _OrderFlowState.searching) return;
      _searchSeconds += 1; // ValueNotifier — без full rebuild
    });
  }

  void _startOrderStatusPolling() {
    _statusPollTimer?.cancel();
    _statusPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted) return;
      if (_orderFlow == _OrderFlowState.selecting) return;
      try {
        final clientId = await _ensureClientId();
        final orderId = _currentOrderId;
        if (orderId == null || orderId.isEmpty) {
          final res = await http.get(
            Uri.parse('$_apiBaseUrl/api/orders/active/client?clientId=$clientId'),
          );
          if (res.statusCode < 200 || res.statusCode >= 300) return;
          final map = jsonDecode(res.body) as Map<String, dynamic>;
          final order = map['order'] as Map?;
          if (order != null) {
            final status = (order['status'] ?? '').toString();
            final id = (order['id'] ?? '').toString();
            final driverPhone = (order['driverPhone'] ?? '').toString();
            // Подхватить координаты водителя
            // Обновляем координаты водителя только если заказ принят (не во время поиска)
            if (status != 'searching') {
              final dLat = double.tryParse(map['driverLat']?.toString() ?? '');
              final dLng = double.tryParse(map['driverLng']?.toString() ?? '');
              if (dLat != null && dLng != null && mounted) {
                final dp = Point(latitude: dLat, longitude: dLng);
                setState(() {
                  _driverPoint = dp;
                });
                if (id.isNotEmpty) {
                  final target = status == 'started' && _toPoint != null ? _toPoint! : _fromPoint;
                  _requestArrivalEtaUpdate(from: dp, to: target, orderId: id);
                }
              }
            }
            _handleOrderStatus({'orderId': id, 'status': status, 'driverPhone': driverPhone});
          }
          return;
        }
        final res = await http.get(Uri.parse('$_apiBaseUrl/api/orders/$orderId'));
        if (res.statusCode < 200 || res.statusCode >= 300) return;
        final map = jsonDecode(res.body) as Map<String, dynamic>;
        final order = map['order'] as Map?;
        if (order != null) {
          final status = (order['status'] ?? '').toString();
          final driverPhone = (order['driverPhone'] ?? '').toString();
          if (status == 'completed') {
            final priceFinal = int.tryParse(order['priceFinal']?.toString() ?? '') ?? 0;
            final tripMinutes = int.tryParse(order['tripMinutes']?.toString() ?? '') ?? 0;
            if (mounted) {
              setState(() {
                _completedPriceRub = priceFinal;
                _completedTripMinutes = tripMinutes;
              });
            }
          }
          // Обновляем координаты водителя только если заказ принят (не во время поиска)
          if (status != 'searching') {
            final dLat = double.tryParse(map['driverLat']?.toString() ?? '');
            final dLng = double.tryParse(map['driverLng']?.toString() ?? '');
            if (dLat != null && dLng != null && mounted) {
              final dp = Point(latitude: dLat, longitude: dLng);
              setState(() {
                _driverPoint = dp;
              });
              final target = status == 'started' && _toPoint != null ? _toPoint! : _fromPoint;
              _requestArrivalEtaUpdate(from: dp, to: target, orderId: orderId);
            }
          }
          _handleOrderStatus({'orderId': orderId, 'status': status, 'driverPhone': driverPhone});
        }
      } catch (_) {}
    });
  }

  void _stopOrderStatusPolling() {
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
  }

  Future<void> _saveOrderHistory() async {
    final quote = _quote;
    final toAddress = _toAddress;
    if (quote == null || toAddress == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_orderHistoryKey);
    List<dynamic> list;
    try { list = raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>); }
    catch (_) { list = <dynamic>[]; }
    final price = _applyDiscount(quote.priceFrom, _promoDiscountPercent);
    list.insert(0, {
      'from': _fromAddress,
      'to': toAddress,
      'price': price,
      'discount': _promoDiscountPercent,
      'ts': DateTime.now().toIso8601String(),
    });
    await prefs.setString(_orderHistoryKey, jsonEncode(list.take(50).toList()));
  }

  void _cancelTrip() {
    _orderTimer?.cancel();
    _driverFoundTimer?.cancel();
    _orderTimer = null;
    _driverFoundTimer = null;
    _stopOrderStatusPolling();

    if (!mounted) return;
    setState(() {
      _orderFlow = _OrderFlowState.selecting;
      _searchSeconds = 0;
      _arrivalMinutes = 0;
      _arrivalSeconds = 0;
      _arrivalRemainingSeconds = 0;
      _arrivalUpdatedAt = null;
      _searchDelayMessage = null;
      _clearDriverProfile();
    });

    final orderId = _currentOrderId;
    final clientId = _clientId;
    if (orderId != null && clientId != null) {
      unawaited(
        http.post(
          Uri.parse('$_apiBaseUrl/api/orders/$orderId/cancel'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'clientId': clientId}),
        ),
      );
    }
    _currentOrderId = null;
  }

  Future<void> _callDriver() async {
    final phone = _driverPhone;
    if (phone == null || phone.trim().isEmpty) return;
    var digits = phone.trim().replaceAll(RegExp(r'\D'), '');
    if (digits.length == 11 && digits.startsWith('8')) {
      digits = '7${digits.substring(1)}';
    }
    if (digits.length == 10) {
      digits = '7$digits';
    }
    final normalized = digits.startsWith('7') ? '+$digits' : phone.trim();
    final uri = Uri(scheme: 'tel', path: normalized);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _callSupportFromOrder() async {
    const phone = '+79060424241';
    final uri = Uri(scheme: 'tel', path: phone);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _openComment() async {
    final result = await _openTextBottomSheet(
      title: 'Комментарий водителю',
      initialValue: _comment,
      hintText: 'Комментарий',
    );

    if (!mounted) return;
    final trimmed = result?.trim() ?? '';
    setState(() {
      _comment = trimmed.isEmpty ? null : trimmed;
    });
  }

  Future<void> _openWish() async {
    final result = await _openTextBottomSheet(
      title: 'Комментарий к заказу',
      initialValue: _wish,
      hintText: 'Комментарий',
    );

    if (!mounted) return;
    final trimmed = result?.trim() ?? '';
    setState(() {
      _wish = trimmed.isEmpty ? null : trimmed;
    });
  }

  Future<void> _openScheduleSheet() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: _black58,
      builder: (ctx) {
        return _ScheduleBottomSheet(
          initialWish: _wish,
          initialScheduledAt: _scheduledAt,
        );
      },
    );
    if (!mounted || result == null) return;
    setState(() {
      _wish = (result['wish'] as String?)?.trim().isNotEmpty == true
          ? (result['wish'] as String).trim()
          : null;
      _scheduledAt = result['scheduledAt'] as DateTime?;
    });
  }

  Future<void> _openPaymentPicker() async {
    final result = await showModalBottomSheet<_PaymentMethod>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: _black58,
      builder: (ctx) {
        return _PaymentPickerSheet(selected: _paymentMethod);
      },
    );

    if (!mounted || result == null) return;
    setState(() {
      _paymentMethod = result;
    });
  }

  Future<String?> _openTextBottomSheet({
    required String title,
    required String? initialValue,
    required String hintText,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: _black58,
      builder: (ctx) {
        return _OrderTextBottomSheet(
          title: title,
          initialValue: initialValue,
          hintText: hintText,
        );
      },
    );
  }

  Future<void> _openRoutePicker({_RouteField activeField = _RouteField.to}) async {
    if (_fromAddress == 'Моё местоположение' && _fromPoint == _initialPoint) {
      await _useMyLocation(silent: true);
    }

    final result = await showModalBottomSheet<_RouteSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: _black58,
      builder: (ctx) {
        return _RoutePickerBottomSheet(
          initialFromAddress: _fromAddress,
          initialFromPoint: _fromPoint,
          initialToAddress: _toAddress,
          initialToPoint: _toPoint,
          initialActiveField: activeField,
          savedHome: _savedAddressHome,
          savedWork: _savedAddressWork,
          savedFavorite: _savedAddressFav,
          onPickOnMap: () {
            // Запустить выбор точки назначения на карте
            final center = _lastCameraTarget ?? _fromPoint;
            unawaited(_startDropoffEdit(center));
          },
          onPickFromOnMap: () {
            unawaited(_startPickupEdit());
          },
        );
      },
    );

    if (!mounted || result == null) return;

    final nextQuote = _buildTariffQuote(
      serviceIndex: _selectedType,
      from: result.fromPoint,
      to: result.toPoint,
      routeDistanceMeters: _routeDistanceMeters,
      routeEtaSeconds: _routeEtaSeconds,
    );

    setState(() {
      _fromAddress = result.fromAddress;
      _fromPoint = result.fromPoint;
      _toAddress = result.toAddress;
      _toPoint = result.toPoint;
      _quote = nextQuote;
    });

    await _updateRoutePreview();
  }

  /// Кнопка «Назад»: если выбран адрес назначения — сбрасываем его
  /// вместо полного закрытия страницы
  void _handleBack() {
    if (_orderFlow != _OrderFlowState.selecting) {
      // Если заказ в процессе — не выходим, а отменяем
      return;
    }
    if (_dropoffEditing) {
      setState(() { _dropoffEditing = false; });
      return;
    }
    if (_pickupEditing) {
      setState(() { _pickupEditing = false; });
      return;
    }
    if (_toPoint != null) {
      // Сбрасываем маршрут → показываем выбор адреса
      setState(() {
        _toPoint = null;
        _toAddress = null;
        _quote = null;
        _routeSummary = null;
        _routePolyline = null;
        _mo_route = null;
        _mo_pickup = null;
        _mo_dropoff = null;
        _notifyMapObjects();
      });
      return;
    }
    Navigator.of(context).maybePop();
  }

  void _handleMapLongTap(Point point) {
    // Отключено — выбор точки назначения только через UI
  }

  void _handleMapDoubleTap(Point point) {
    // Отключено — выбор точки назначения только через UI
  }

  Future<void> _updateRoutePreview({bool moveCamera = true}) async {
    final to = _toPoint;
    final myPoint = _myPoint;
    if (to == null) {
      await _clearRouteState();

      if (!mounted) return;
      _mo_route = null;
      _mo_pickup = null;
      _mo_dropoff = null;
      _mo_driver = null;
      _mo_myLocation = (myPoint != null && _pickupPinEnabled)
          ? CircleMapObject(
              mapId: const MapObjectId('my_location'),
              circle: Circle(center: myPoint, radius: 8),
              strokeColor: const Color(0xFF1A73E8),
              fillColor: const Color(0xFF1A73E8).withOpacity(0.25),
              strokeWidth: 2,
              zIndex: 1.0,
            )
          : null;
      _notifyMapObjects();
      return;
    }

    final from = _fromPoint;
    final routeLine = await _ensureDrivingRoute(from: from, to: to);
    BitmapDescriptor? driverIcon;
    if (_driverPoint != null) {
      driverIcon = _driverIcon ?? _navArrowIcon ?? await _ensureNavArrowIcon();
      _driverIcon ??= driverIcon;
    }

    // Используем предзагруженные иконки (без await если уже готовы)
    final pickupStick = _stickPinWhiteIcon ?? await _ensureStickPinWhite();
    final destStick = _stickPinOrangeIcon ?? await _ensureStickPinOrange();

    if (!mounted) return;
    _mo_myLocation = myPoint != null
        ? CircleMapObject(
            mapId: const MapObjectId('my_location'),
            circle: Circle(center: myPoint, radius: 8),
            strokeColor: const Color(0xFF1A73E8),
            fillColor: const Color(0xFF1A73E8).withOpacity(0.25),
            strokeWidth: 2,
            zIndex: 1.0,
          )
        : null;
    _mo_pickup = !_pickupEditing
        ? PlacemarkMapObject(
            mapId: const MapObjectId('pickup'),
            point: _fromPoint,
            isVisible: true,
            opacity: 1.0,
            zIndex: 4.0,
            icon: PlacemarkIcon.single(
              PlacemarkIconStyle(
                image: pickupStick,
                scale: 1.2,
                anchor: const Offset(0.5, 1.0),
              ),
            ),
          )
        : null;
    _mo_dropoff = !_dropoffEditing
        ? PlacemarkMapObject(
            mapId: const MapObjectId('to'),
            point: to,
            isVisible: true,
            opacity: 1.0,
            zIndex: 3.0,
            icon: PlacemarkIcon.single(
              PlacemarkIconStyle(
                image: destStick,
                scale: 1.2,
                anchor: const Offset(0.5, 1.0),
              ),
            ),
          )
        : null;
    _mo_route = PolylineMapObject(
      mapId: const MapObjectId('route'),
      polyline: routeLine,
      strokeColor: const Color(0xFFFF3D00),
      strokeWidth: 4.5,
      outlineColor: const Color(0xFF000000),
      outlineWidth: 2.0,
      isInnerOutlineEnabled: true,
      arcApproximationStep: 1.0,
      zIndex: 0.5,
    );
    _mo_driver = (_driverPoint != null && (driverIcon ?? _driverIcon) != null)
        ? PlacemarkMapObject(
            mapId: const MapObjectId('driver'),
            point: _driverPoint!,
            isVisible: true,
            opacity: 1.0,
            zIndex: 6.0,
            icon: PlacemarkIcon.single(
              PlacemarkIconStyle(
                image: (driverIcon ?? _driverIcon)!,
                scale: 0.85,
                anchor: const Offset(0.5, 0.5),
              ),
            ),
          )
        : null;
    _notifyMapObjects();

    if (moveCamera) {
      await _fitRoute(from: from, to: to);
    }
  }

  Future<void> _fitRoute({required Point from, required Point to}) async {
    final controller = _mapController;
    if (controller == null) return;

    final north = math.max(from.latitude, to.latitude);
    final south = math.min(from.latitude, to.latitude);
    final east = math.max(from.longitude, to.longitude);
    final west = math.min(from.longitude, to.longitude);

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

  Future<void> _useMyLocation({bool silent = false}) async {
    if (_locating) return;

    setState(() {
      _locating = true;
    });

    try {
      final point = await _getCurrentPoint();
      final controller = _mapController;
      if (controller != null) {
        await controller.moveCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: point, zoom: 16),
          ),
        );
      }

      final address = await _reverseGeocode(point);

      if (!mounted) return;
      final to = _toPoint;
      final nextQuote = to == null
          ? null
          : _TariffQuote.tryBuild(
              serviceIndex: _selectedType,
              from: point,
              to: to,
              routeDistanceMeters: _routeDistanceMeters,
              routeEtaSeconds: _routeEtaSeconds,
            );

      // Устанавливаем поля без отдельного setState — _updateRoutePreview вызовет setState
      _myPoint = point;
      _fromPoint = point;
      _fromAddress = (address == null || address.trim().isEmpty) ? 'Моё местоположение' : address.trim();
      _pickupPinEnabled = true;
      _quote = nextQuote;

      await _updateRoutePreview(moveCamera: false);
    } catch (_) {
      if (!silent) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось определить местоположение')),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _locating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final geoButtonBottom = math.max(282.0, MediaQuery.of(context).size.height * 0.35);
    final isSelecting = _orderFlow == _OrderFlowState.selecting;
    final showCenterPin = _pickupEditing || _draggingPickup || (isSelecting && !_dropoffEditing && _toPoint == null);
    final showCenterDropoffPin = _dropoffEditing || _draggingDropoff;
    return PopScope(
      canPop: _orderFlow != _OrderFlowState.selecting || _toPoint == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          Positioned.fill(
            child: Stack(
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF12162B), Color(0xFF05060A)],
                    ),
                  ),
                ),
                ValueListenableBuilder<List<MapObject>>(
                  valueListenable: _mapObjectsNotifier,
                  builder: (context, mapObjects, _) => _MapBlock(
                    initialPoint: _initialPoint,
                    enabled: true,
                    mapObjects: mapObjects,
                    onMapCreated: (c) {
                      _mapController = c;
                      _updateRoutePreview();
                    },
                    onCameraPositionChanged: _onCameraPositionChanged,
                    onMapLongTap: _handleMapLongTap,
                    onMapDoubleTap: _handleMapDoubleTap,
                  ),
                ),
              ],
            ),
          ),
          const Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x14000000), // 0.08
                        Color(0x1A000000), // 0.10
                        Color(0xD1000000), // 0.82
                      ],
                      stops: [0.0, 0.40, 1.0],
                    ),
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
          if (showCenterPin)
            Positioned.fill(
              child: _CenterPickupPin(
                dragging: _draggingPickup,
              ),
            ),
          if (showCenterDropoffPin)
            Positioned.fill(
              child: _CenterDropoffPin(
                dragging: _draggingDropoff,
              ),
            ),
          // Плавающий адрес «Откуда» — ValueListenableBuilder для изоляции от полного rebuild
          if (isSelecting && !_pickupEditing && !_dropoffEditing && _toPoint == null)
            Positioned(
              left: 20, right: 20, top: 0, bottom: 0,
              child: Center(
                child: Transform.translate(
                  offset: const Offset(0, -70),
                  child: IgnorePointer(
                    ignoring: false,
                    child: ValueListenableBuilder<String>(
                      valueListenable: _fromAddressNotifier,
                      builder: (_, addr, __) => _FloatingAddressChip(
                        label: 'ОТКУДА',
                        address: addr,
                        onEditTap: () => _openRoutePicker(activeField: _RouteField.from),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Плавающий адрес «Куда» — ValueListenableBuilder
          if (_dropoffEditing)
            Positioned(
              left: 20, right: 20, top: 0, bottom: 0,
              child: Center(
                child: Transform.translate(
                  offset: const Offset(0, -70),
                  child: IgnorePointer(
                    ignoring: false,
                    child: ValueListenableBuilder<String?>(
                      valueListenable: _toAddressNotifier,
                      builder: (_, addr, __) => _FloatingAddressChip(
                        label: 'КУДА',
                        address: addr ?? 'Точка назначения',
                        onEditTap: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_pickupEditing || _dropoffEditing)
            Positioned(
              top: 84,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _black45,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _white10, width: 1),
                    ),
                    child: Text(
                      'Карту можно двигать',
                      style: TextStyle(
                        color: _white88,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: 14,
            bottom: geoButtonBottom,
            child: SafeArea(
              top: false,
              left: false,
              child: _MapGeoButton(
                onTap: () => _useMyLocation(silent: false),
                loading: _locating,
              ),
            ),
          ),
          RepaintBoundary(
            child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      _TopIconButton(
                        icon: Icons.arrow_back_ios_new,
                        onTap: _handleBack,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Заказ',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _white95,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _TopIconButton(
                        icon: Icons.call,
                        onTap: _callSupportFromOrder,
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (_pickupEditing)
                    _PickupEditSheet(
                      address: _fromAddress,
                      onDone: _finishPickupEdit,
                    )
                  else if (_dropoffEditing)
                    _DropoffEditSheet(
                      address: _toAddress ?? 'Точка назначения',
                      onDone: _finishDropoffEdit,
                    )
                  else if (_orderFlow == _OrderFlowState.searching)
                    ValueListenableBuilder<int>(
                      valueListenable: _searchSecondsNotifier,
                      builder: (_, sec, __) => _OrderSearchingSheet(
                        timeText: _formatMmSs(sec),
                        note: _searchDelayMessage,
                        onCancel: _cancelTrip,
                        showCallSupport: sec >= 180,
                      ),
                    )
                  else if (_orderFlow == _OrderFlowState.assigned || _orderFlow == _OrderFlowState.enroute)
                    Builder(builder: (_) {
                      final isPreorder = _scheduledAt != null &&
                          _scheduledAt!.isAfter(DateTime.now().add(const Duration(minutes: 10)));
                      final schedTime = _scheduledAt != null
                          ? '${_scheduledAt!.hour.toString().padLeft(2, '0')}:${_scheduledAt!.minute.toString().padLeft(2, '0')}'
                          : '';
                      return _OrderAssignedSheet(
                        title: isPreorder ? 'Предзаказ принят' : 'Водитель в пути',
                        subtitle: isPreorder
                            ? 'Подача в $schedTime'
                            : (_arrivalMinutes > 0
                                ? 'Прибудет через $_arrivalMinutes мин'
                                : 'Едет к вам'),
                        timeText: isPreorder ? schedTime : (_arrivalMinutes > 0 ? '$_arrivalMinutes мин' : '...'),
                        onCancel: _cancelTrip,
                        onCall: _callDriver,
                        driverPhone: _driverPhone,
                        driverAvatarBytes: _driverAvatarBytes,
                        driverName: _driverName,
                        driverRating: _driverRating,
                        driverRatingCount: _driverRatingCount,
                      );
                    })
                  else if (_orderFlow == _OrderFlowState.arrived)
                    _OrderStatusSheet(
                      title: 'Водитель на месте',
                      subtitle: 'Можно выходить',
                      onCancel: _cancelTrip,
                      onCall: _callDriver,
                      showCancel: true,
                    )
                  else if (_orderFlow == _OrderFlowState.started)
                    _OrderStatusSheet(
                      title: 'Поездка',
                      subtitle: _arrivalMinutes > 0
                          ? 'До места ≈ $_arrivalMinutes мин'
                          : 'В пути',
                      onCancel: _cancelTrip,
                      onCall: _callDriver,
                      showCancel: false,
                    )
                  else if (_orderFlow == _OrderFlowState.completed)
                    _OrderCompletedSheet(
                      priceRub: _completedPriceRub,
                      tripMinutes: _completedTripMinutes,
                      onDone: _finishTripAndReturn,
                    )
                  else if (_toPoint == null)
                    _WhereToBar(onTap: _openRoutePicker)
                  else
                    _OrderBottomSheet(
                      quote: _quote,
                      discountPercent: _promoDiscountPercent,
                      ridePrices: _tariffs.isEmpty
                          ? _systemRidePrices
                          : List.generate(
                              3,
                              (i) {
                                final t = _tariffs.length > i ? _tariffs[i] : null;
                                if (t == null) return '—';
                                final mode = (t['mode'] ?? '').toString().trim().toLowerCase();
                                if (mode != 'custom') {
                                  return i < _systemRidePrices.length ? _systemRidePrices[i] : '—';
                                }
                                final base = double.tryParse(t['base']?.toString() ?? '') ?? 0;
                                final perKm = double.tryParse(t['perKm']?.toString() ?? '') ?? 0;
                                final km = math.max(0, (_routeDistanceMeters ?? 0) / 1000.0);
                                final price = (base + perKm * km).round();
                                return 'от $price₽';
                              },
                            ),
                      selectedType: _selectedType,
                      onSelectType: _setType,
                      onOrderTap: _startOrder,
                      paymentMethod: _paymentMethod,
                      onPaymentTap: _openPaymentPicker,
                      onScheduleTap: _openScheduleSheet,
                      scheduledAt: _scheduledAt,
                      onHistoryTap: _openOrderHistory,
                      onInfoTrezvy: () {
                        _openServiceInfo(
                          title: '🚗 Трезвый водитель',
                          description:
                              'Выпили или устали?\n'
                              'Мы довезём вас и ваш автомобиль.',
                        );
                      },
                      onInfoPersonal: () {
                        _openServiceInfo(
                          title: '🧑‍✈️ Личный водитель',
                          description:
                              'Много поездок за день?\n'
                              'Водитель работает только на вас.',
                        );
                      },
                      onInfoTransfer: () {
                        _openServiceInfo(
                          title: '🔑 Перегон автомобиля',
                          description:
                              'Нужно доставить машину?\n'
                              'Водитель отвезёт её без вашего участия.',
                        );
                      },
                      routeSummary: _routeSummary,
                      routeLoading: _routeLoading,
                      fromAddress: _fromAddress,
                      toAddress: _toAddress,
                      onFromTap: () => _openRoutePicker(activeField: _RouteField.from),
                      onToTap: () => _openRoutePicker(activeField: _RouteField.to),
                    ),
                ],
              ),
            ),
          ),
          ),
        ],
      ),
    ),
    );
  }
}

class _PickupEditSheet extends StatelessWidget {
  const _PickupEditSheet({required this.address, required this.onDone});

  final String address;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
        ),
        border: Border.all(color: const Color(0xFF1C2030), width: 1),
        boxShadow: [
          BoxShadow(
            color: _black55,
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Точка отправления',
                    style: TextStyle(
                      color: _white92,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _white68,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: _PrimaryGlowButton(label: 'ГОТОВО', onTap: onDone),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DropoffEditSheet extends StatelessWidget {
  const _DropoffEditSheet({required this.address, required this.onDone});

  final String address;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
        ),
        border: Border.all(color: const Color(0xFF1C2030), width: 1),
        boxShadow: [
          BoxShadow(
            color: _black55,
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Точка назначения',
                    style: TextStyle(
                      color: _white92,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _white68,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: _PrimaryGlowButton(label: 'ГОТОВО', onTap: onDone),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DestinationBar extends StatelessWidget {
  const _DestinationBar({required this.onTap, required this.from, required this.to});

  final VoidCallback onTap;
  final String from;
  final String to;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
            ),
            border: Border.all(color: const Color(0xFF1C2030), width: 1),
            boxShadow: [
              BoxShadow(
                color: _black45,
                blurRadius: 26,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 42,
                child: Column(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.70),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        width: 2,
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(99),
                          color: const Color(0xFF2A2F3A),
                        ),
                      ),
                    ),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      from,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.62),
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      to,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.94),
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.55)),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderBottomSheet extends StatelessWidget {
  const _OrderBottomSheet({
    required this.quote,
    required this.discountPercent,
    required this.ridePrices,
    required this.selectedType,
    required this.onSelectType,
    required this.onOrderTap,
    required this.paymentMethod,
    required this.onPaymentTap,
    required this.onScheduleTap,
    this.scheduledAt,
    required this.onHistoryTap,
    required this.onInfoTrezvy,
    required this.onInfoPersonal,
    required this.onInfoTransfer,
    required this.routeSummary,
    required this.routeLoading,
    required this.fromAddress,
    required this.toAddress,
    this.onFromTap,
    this.onToTap,
    this.onEntranceTap,
  });

  final _TariffQuote? quote;
  final int discountPercent;
  final List<String> ridePrices;
  final int selectedType;
  final ValueChanged<int> onSelectType;
  final VoidCallback onOrderTap;
  final _PaymentMethod paymentMethod;
  final VoidCallback onPaymentTap;
  final VoidCallback onScheduleTap;
  final DateTime? scheduledAt;
  final VoidCallback onHistoryTap;
  final VoidCallback onInfoTrezvy;
  final VoidCallback onInfoPersonal;
  final VoidCallback onInfoTransfer;
  final String? routeSummary;
  final bool routeLoading;
  final String fromAddress;
  final String? toAddress;
  final VoidCallback? onFromTap;
  final VoidCallback? onToTap;
  final VoidCallback? onEntranceTap;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: isLight
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFF8FAFD), Color(0xFFEEF2F8)],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
              ),
        border: Border.all(
          color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isLight ? const Color(0x1A000000) : _black55,
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── A / B addresses ───────────────────────────
                  _AddressRow(
                    marker: 'A',
                    markerColor: const Color(0xFFF5A623),
                    address: fromAddress,
                    onTap: onFromTap,
                    trailing: onEntranceTap != null
                        ? GestureDetector(
                            onTap: onEntranceTap,
                            child: Text(
                              'Подъезд',
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF7A8296)
                                    : Colors.white.withOpacity(0.45),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : null,
                  ),
                  Divider(
                    color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1E2230),
                    height: 1,
                    thickness: 1,
                  ),
                  _AddressRow(
                    marker: 'B',
                    markerColor: const Color(0xFFF5A623),
                    address: toAddress ?? 'Точка назначения',
                    onTap: onToTap,
                    trailing: GestureDetector(
                      onTap: onToTap,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isLight ? const Color(0xFFE4E8F0) : const Color(0xFF1E2230),
                        ),
                        child: Icon(
                          Icons.add,
                          color: isLight ? const Color(0xFF364055) : Colors.white.withOpacity(0.7),
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (quote != null) ...[
                    _TariffCard(quote: quote!, discountPercent: discountPercent),
                    const SizedBox(height: 10),
                  ],
                  if (routeLoading || routeSummary != null) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              routeLoading
                                  ? 'Строим маршрут…'
                                  : (routeSummary ?? ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isLight
                                    ? const Color(0xFF5C6477)
                                    : Colors.white.withOpacity(0.70),
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: isLight ? const Color(0xFFD4DAE6) : const Color(0xFF2A2F3A),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 78,
                          child: _RideTypeCard(
                            title: 'Трезвый\nводитель',
                            price: ridePrices.isNotEmpty ? ridePrices[0] : '—',
                            selected: selectedType == 0,
                            onTap: () => onSelectType(0),
                            onInfoTap: onInfoTrezvy,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(
                          height: 78,
                          child: _RideTypeCard(
                            title: 'Личный\nводитель',
                            price: ridePrices.length > 1 ? ridePrices[1] : '—',
                            selected: selectedType == 1,
                            onTap: () => onSelectType(1),
                            onInfoTap: onInfoPersonal,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(
                          height: 78,
                          child: _RideTypeCard(
                            title: 'Перегон\nа/м',
                            price: ridePrices.length > 2 ? ridePrices[2] : '—',
                            selected: selectedType == 2,
                            onTap: () => onSelectType(2),
                            onInfoTap: onInfoTransfer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 68,
                          child: _SheetActionButton(
                            icon: paymentMethod == _PaymentMethod.sbp
                                ? _SbpIcon(size: 18, dark: isLight)
                                : Icon(
                                    Icons.payments_outlined,
                                    color: isLight ? const Color(0xFF1F2534) : _white90,
                                    size: 18,
                                  ),
                            label: paymentMethod == _PaymentMethod.sbp
                                ? 'Оплата:\nСБП'
                                : 'Оплата:\nНаличные',
                            onTap: onPaymentTap,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SizedBox(
                          height: 68,
                          child: _SheetActionButton(
                            icon: Icon(
                              Icons.tune_rounded,
                              color: scheduledAt != null
                                  ? const Color(0xFFB07CFF)
                                  : (isLight ? const Color(0xFF1F2534) : _white90),
                              size: 17,
                            ),
                            label: scheduledAt != null
                                ? 'Дополнительно\n${scheduledAt!.hour.toString().padLeft(2, '0')}:${scheduledAt!.minute.toString().padLeft(2, '0')}${_isToday(scheduledAt!) ? '' : ' ${scheduledAt!.day.toString().padLeft(2, '0')}.${scheduledAt!.month.toString().padLeft(2, '0')}'}'
                                : 'Дополнительно',
                            onTap: onScheduleTap,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: _PrimaryGlowButton(label: 'ЗАКАЗАТЬ', onTap: onOrderTap),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RideTypeCard extends StatelessWidget {
  const _RideTypeCard({
    required this.title,
    required this.price,
    required this.selected,
    required this.onTap,
    required this.onInfoTap,
  });

  final String title;
  final String price;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onInfoTap;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
                  )
                : (isLight
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFDCE2EB), Color(0xFFD0D8E8)],
                      )
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF2A2F3A), Color(0xFF161925)],
                      )),
            boxShadow: [
              BoxShadow(
                color: selected
                    ? const Color(0xFFFF2D55).withOpacity(isLight ? 0.18 : 0.22)
                    : Colors.black.withOpacity(isLight ? 0.08 : 0.35),
                blurRadius: selected ? 18 : 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(1.4),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16.6),
                gradient: selected
                    ? (isLight
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFFFFFFF), Color(0xFFF8FAFD)],
                          )
                        : const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF1E2333), Color(0xFF0E1017)],
                          ))
                    : (isLight
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFFFFFFFF), Color(0xFFF3F6FC)],
                          )
                        : const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF141723), Color(0xFF0B0D12)],
                          )),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16.6),
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected
                                  ? (isLight ? const Color(0xFFFF3D00) : Colors.white.withOpacity(0.96))
                                  : (isLight
                                      ? const Color(0xFF1F2534)
                                      : Colors.white.withOpacity(0.84)),
                              fontWeight: FontWeight.w900,
                              height: 1.05,
                              letterSpacing: 0.1,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            price,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected
                                  ? (isLight ? const Color(0xFFFF3D00).withOpacity(0.7) : Colors.white.withOpacity(0.78))
                                  : (isLight
                                      ? const Color(0xFF5C6477)
                                      : Colors.white.withOpacity(0.60)),
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onInfoTap,
                          borderRadius: BorderRadius.circular(999),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Ink(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: isLight
                                    ? const LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [Color(0xFFEAF0FA), Color(0xFFDDE5F4)],
                                      )
                                    : const LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [Color(0xFF3E465C), Color(0xFF2B3142)],
                                      ),
                              ),
                              child: Center(
                                child: Text(
                                  '!',
                                  style: TextStyle(
                                    color: isLight ? const Color(0xFF1F2534) : _white85,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetActionButton extends StatelessWidget {
  const _SheetActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: isLight
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFFFFFF), Color(0xFFF3F6FC)],
                  )
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1A1C25), Color(0xFF0B0C10)],
                  ),
            border: Border.all(
              color: isLight ? const Color(0xFFD8DFEA) : const Color(0xFF222636),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: isLight ? const Color(0x14000000) : _black55,
                blurRadius: 22,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(height: 5),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isLight
                        ? const Color(0xFF1F2534)
                        : Colors.white.withOpacity(0.82),
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    height: 1.05,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _openAppSettings(BuildContext context) {
  Navigator.of(context).push(
    _FastPageRoute<void>(
      builder: (context) {
        final isLight = Theme.of(context).brightness == Brightness.light;
        final primary = isLight ? const Color(0xFF1F2534) : _white95;
        final secondary = isLight ? const Color(0xFF5C6477) : _white65;
        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              'Настройки приложения',
              style: TextStyle(
                color: primary,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: _GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Уведомления',
                      style: TextStyle(
                        color: primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Настройки уведомлений появятся в следующей версии.',
                      style: TextStyle(
                        color: secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.token,
    required this.onLogout,
    required this.onThemeModeChanged,
  });

  final String token;
  final VoidCallback onLogout;
  final void Function(ThemeMode) onThemeModeChanged;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _picker = ImagePicker();
  String _displayName = '';
  String _fullName = '';
  String _phoneOverride = '';
  String _avatarBase64 = '';
  Uint8List? _avatarBytes; // кешированный decode аватара
  String _promoCode = '';
  int _promoDiscountPercent = 0;
  bool _notificationsEnabled = true;
  String _addressHome = '';
  String _addressWork = '';
  String _addressFav = '';
  bool _loadingName = true;
  int _referralCount = 0;
  int _bonusBalance = 0;
  String? _clientId;

  @override
  void initState() {
    super.initState();
    _loadDisplayName();
    _loadReferralData();
  }

  Future<void> _loadReferralData() async {
    final phone = _phoneFromJwt(widget.token);
    if (phone == null || phone.trim().isEmpty) return;
    _clientId = phone.trim();
    try {
      final uri = Uri.parse('$_apiBaseUrl/client/profile?clientId=$_clientId');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['ok'] == true && mounted) {
          final bonus = data['bonus'] ?? {};
          final referral = data['referral'] ?? {};
          setState(() {
            _bonusBalance = (bonus['available'] ?? 0) as int;
            _referralCount = (referral['count'] ?? 0) as int;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _loadDisplayName() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_profileNameKey) ?? '';
    final fullName = prefs.getString(_profileFullNameKey) ?? '';
    final phone = prefs.getString(_profilePhoneKey) ?? '';
    final avatar = prefs.getString(_profileAvatarKey) ?? '';
    final promoCode = prefs.getString(_promoCodeKey) ?? '';
    final discount = prefs.getInt(_promoDiscountKey) ?? 0;
    final notifications = prefs.getBool(_notificationsEnabledKey) ?? true;
    final home = prefs.getString(_addressHomeKey) ?? '';
    final work = prefs.getString(_addressWorkKey) ?? '';
    final fav = prefs.getString(_addressFavKey) ?? '';
    if (!mounted) return;
    setState(() {
      _displayName = name;
      _fullName = fullName;
      _phoneOverride = phone;
      _avatarBase64 = avatar;
      _avatarBytes = avatar.isEmpty ? null : base64Decode(avatar);
      _promoCode = promoCode;
      _promoDiscountPercent = discount;
      _notificationsEnabled = notifications;
      _addressHome = home;
      _addressWork = work;
      _addressFav = fav;
      _loadingName = false;
    });
  }

  Future<void> _saveDisplayName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileNameKey, name);
    if (!mounted) return;
    setState(() => _displayName = name);
  }

  Future<void> _saveFullName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileFullNameKey, name);
    if (!mounted) return;
    setState(() => _fullName = name);
  }

  Future<void> _savePhone(String phone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profilePhoneKey, phone);
    if (!mounted) return;
    setState(() => _phoneOverride = phone);
  }

  Future<void> _saveAvatarBase64(String base64) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileAvatarKey, base64);
    if (!mounted) return;
    setState(() {
      _avatarBase64 = base64;
      _avatarBytes = base64.isEmpty ? null : base64Decode(base64);
    });
  }

  Future<void> _savePromo(String code, int discount) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_promoCodeKey, code);
    await prefs.setInt(_promoDiscountKey, discount);
    if (!mounted) return;
    setState(() {
      _promoCode = code;
      _promoDiscountPercent = discount;
    });
  }

  Future<void> _saveNotifications(bool enabled) async {
    if (enabled) {
      // Request actual notification permission on Android 13+ / iOS
      final status = await Permission.notification.request();
      if (!mounted) return;
      if (status.isDenied || status.isPermanentlyDenied) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Разрешите уведомления в настройках телефона'),
            action: SnackBarAction(
              label: 'Настройки',
              onPressed: () => openAppSettings(),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
        return; // Don't turn on if permission denied
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationsEnabledKey, enabled);
    final clientId = _clientId ?? _phoneFromJwt(widget.token)?.trim();
    if (clientId != null && clientId.isNotEmpty) {
      unawaited(_syncClientPushToken(widget.token, clientId, enabled: enabled));
    }
    if (!mounted) return;
    setState(() => _notificationsEnabled = enabled);
  }

  Future<void> _saveAddresses({
    required String home,
    required String work,
    required String favorite,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_addressHomeKey, home);
    await prefs.setString(_addressWorkKey, work);
    await prefs.setString(_addressFavKey, favorite);
    if (!mounted) return;
    setState(() {
      _addressHome = home;
      _addressWork = work;
      _addressFav = favorite;
    });
  }

  void _openAccountScreen(BuildContext context) {
    final phoneRaw = _phoneOverride.trim().isNotEmpty
        ? _phoneOverride.trim()
        : (_phoneFromJwt(widget.token) ?? '');
    final phone = _formatPhoneForDisplay(phoneRaw);
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          final primary = isLight ? const Color(0xFF1F2534) : _white95;
          final secondary = isLight ? const Color(0xFF5C6477) : _white75;
          final hint = isLight ? const Color(0xFF8B93A7) : _white50;
          final fieldFill = isLight ? const Color(0xFFF1F3F8) : _white06;
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                'Учетная запись',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Номер телефона',
                        style: TextStyle(
                          color: secondary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: TextEditingController(text: phoneRaw),
                        keyboardType: TextInputType.phone,
                        onChanged: (value) => _savePhone(value),
                        style: TextStyle(
                          color: primary,
                          fontWeight: FontWeight.w900,
                        ),
                        decoration: InputDecoration(
                          hintText: phone,
                          hintStyle: TextStyle(color: hint),
                          filled: true,
                          fillColor: fieldFill,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Изменение сохраняется только в приложении.',
                        style: TextStyle(
                          color: hint,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openAvatarPicker(BuildContext context) async {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final sheetBg = isLight ? const Color(0xFFF5F6FA) : const Color(0xFF0E0E12);
    final textColor = isLight ? const Color(0xFF1F2534) : _white92;
    final iconColor = isLight ? const Color(0xFF364055) : Colors.white.withOpacity(0.9);
    final result = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: iconColor),
              title: Text(
                'Выбрать из галереи',
                style: TextStyle(color: textColor, fontWeight: FontWeight.w800),
              ),
              onTap: () => Navigator.of(context).pop(0),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: iconColor),
              title: Text(
                'Удалить фото',
                style: TextStyle(color: textColor, fontWeight: FontWeight.w800),
              ),
              onTap: () => Navigator.of(context).pop(1),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (result == null) return;
    if (result == 1) {
      await _saveAvatarBase64('');
      return;
    }

    try {
      final file = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await _saveAvatarBase64(base64Encode(bytes));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выбрать фото')),
      );
    }
  }

  void _openPersonalDataScreen(BuildContext context) {
    final nameController = TextEditingController(text: _displayName);
    final fioController = TextEditingController(text: _fullName);
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          final primary = isLight ? const Color(0xFF1F2534) : _white95;
          final secondary = isLight ? const Color(0xFF5C6477) : _white60;
          final fieldFill = isLight ? const Color(0xFFF1F3F8) : _white06;
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                'Личные данные',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await _saveDisplayName(nameController.text);
                    await _saveFullName(fioController.text);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text(
                    'Сохранить',
                    style: TextStyle(
                      color: primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: nameController,
                        style: TextStyle(
                          color: primary,
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Имя',
                          labelStyle: TextStyle(color: secondary),
                          filled: true,
                          fillColor: fieldFill,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: fioController,
                        style: TextStyle(
                          color: primary,
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Отчество',
                          labelStyle: TextStyle(color: secondary),
                          filled: true,
                          fillColor: fieldFill,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openPromoScreen(BuildContext context) {
    final controller = TextEditingController(text: _promoCode);
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          final primary = isLight ? const Color(0xFF1F2534) : _white95;
          final secondary = isLight ? const Color(0xFF5C6477) : _white60;
          final fieldFill = isLight ? const Color(0xFFF1F3F8) : _white06;
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                'Промокоды',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: controller,
                        style: TextStyle(color: primary, fontWeight: FontWeight.w700),
                        decoration: InputDecoration(
                          labelText: 'Промокод',
                          labelStyle: TextStyle(color: secondary),
                          filled: true,
                          fillColor: fieldFill,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: _PrimaryGlowButton(
                          label: 'АКТИВИРОВАТЬ',
                          onTap: () async {
                            final code = controller.text.trim();
                            if (code.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Введите промокод')),
                              );
                              return;
                            }
                            final clientId = _clientId ?? _phoneFromJwt(widget.token) ?? '';
                            if (clientId.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Не удалось определить клиента')),
                              );
                              return;
                            }
                            try {
                              final res = await http
                                  .post(
                                    Uri.parse('$_apiBaseUrl/api/client/promo/activate'),
                                    headers: {'Content-Type': 'application/json'},
                                    body: jsonEncode({'clientId': clientId, 'code': code}),
                                  )
                                  .timeout(const Duration(seconds: 10));
                              if (res.statusCode < 200 || res.statusCode >= 300) {
                                throw Exception(res.body);
                              }
                              final data = jsonDecode(res.body) as Map<String, dynamic>;
                              final rawDiscount = data['discount'];
                              final discount = (rawDiscount is num ? rawDiscount.toInt() : int.tryParse(rawDiscount?.toString() ?? '') ?? 0).clamp(0, 100);
                              await _savePromo(code, discount);
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Промокод активирован: -$discount%')),
                              );
                            } catch (_) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Промокод не найден или недействителен')),
                              );
                            }
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_promoDiscountPercent > 0)
                        Text(
                          'Активна скидка: -$_promoDiscountPercent%',
                          style: TextStyle(
                            color: secondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openReferralScreen(BuildContext context) {
    final clientId = _clientId ?? '';
    final referralCode = clientId.replaceAll(RegExp(r'\D'), '');
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          final primary = isLight ? const Color(0xFF1F2534) : _white95;
          final secondary = isLight ? const Color(0xFF5C6477) : _white70;
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                'Пригласить друзей',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ваш код приглашения',
                            style: TextStyle(
                              color: isLight ? const Color(0xFF7A8296) : _white60,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  referralCode.isNotEmpty ? referralCode : 'Загрузка...',
                                  style: TextStyle(
                                    color: primary,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 22,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: referralCode.isEmpty
                                    ? null
                                    : () async {
                                        await Clipboard.setData(ClipboardData(text: referralCode));
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Код скопирован')),
                                        );
                                      },
                                icon: Icon(
                                  Icons.copy,
                                  color: secondary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.card_giftcard,
                                color: Color(0xFFFFD400),
                                size: 28,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Бонусный баланс',
                                  style: TextStyle(
                                    color: primary,
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              Text(
                                '$_bonusBalance ₽',
                                style: const TextStyle(
                                  color: Color(0xFFFFD400),
                                  fontWeight: FontWeight.w900,
                                  fontSize: 20,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Приглашено друзей: $_referralCount / 3',
                            style: TextStyle(
                              color: secondary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                            value: (_referralCount % 3) / 3,
                            backgroundColor: isLight ? const Color(0xFFE1E6EF) : Colors.white.withOpacity(0.1),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFFD400)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Как это работает?',
                            style: TextStyle(
                              color: primary,
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _ReferralStep(
                            number: '1',
                            text: 'Поделитесь кодом с друзьями',
                          ),
                          const SizedBox(height: 8),
                          _ReferralStep(
                            number: '2',
                            text: 'Друг вводит код при регистрации',
                          ),
                          const SizedBox(height: 8),
                          _ReferralStep(
                            number: '3',
                            text: 'За каждые 3 друга — 500₽ на баланс',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    child: _PrimaryGlowButton(
                      label: 'ПОДЕЛИТЬСЯ КОДОМ',
                      onTap: () async {
                        await Clipboard.setData(ClipboardData(
                          text: 'Присоединяйся к Трезвый водитель! Мой код: $referralCode',
                        ));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Текст скопирован')),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openHistoryScreen(BuildContext context) {
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          final primary = isLight ? const Color(0xFF1F2534) : _white95;
          final secondary = isLight ? const Color(0xFF5C6477) : _white70;
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                'История заказов',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            body: FutureBuilder<String?>(
              future: SharedPreferences.getInstance().then((p) => p.getString(_orderHistoryKey)),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Ошибка загрузки', style: TextStyle(color: secondary)));
                }
                final raw = snapshot.data;
                List<dynamic> items;
                try { items = raw == null ? <dynamic>[] : (jsonDecode(raw) as List<dynamic>); }
                catch (_) { items = <dynamic>[]; }
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      'История пока пустая',
                      style: TextStyle(color: secondary, fontWeight: FontWeight.w700),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemBuilder: (context, index) {
                    final item = items[index] as Map<String, dynamic>;
                    final from = item['from']?.toString() ?? '';
                    final to = item['to']?.toString() ?? '';
                    final price = item['price']?.toString() ?? '';
                    return _GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              from,
                              style: TextStyle(color: primary, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              to,
                              style: TextStyle(color: secondary, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '$price ₽',
                              style: TextStyle(color: primary, fontWeight: FontWeight.w900),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemCount: items.length,
                );
              },
            ),
          );
        },
      ),
    );
  }

  void _openAddressesScreen(BuildContext context) {
    final homeController = TextEditingController(text: _addressHome);
    final workController = TextEditingController(text: _addressWork);
    final favController = TextEditingController(text: _addressFav);
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          final primary = isLight ? const Color(0xFF1F2534) : _white95;
          final secondary = isLight ? const Color(0xFF5C6477) : _white60;
          final fieldFill = isLight ? const Color(0xFFF1F3F8) : _white06;
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                'Адреса',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await _saveAddresses(
                      home: homeController.text.trim(),
                      work: workController.text.trim(),
                      favorite: favController.text.trim(),
                    );
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text(
                    'Сохранить',
                    style: TextStyle(color: primary, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: _GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: homeController,
                        style: TextStyle(color: primary, fontWeight: FontWeight.w700),
                        decoration: InputDecoration(
                          labelText: 'Дом',
                          labelStyle: TextStyle(color: secondary),
                          filled: true,
                          fillColor: fieldFill,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: workController,
                        style: TextStyle(color: primary, fontWeight: FontWeight.w700),
                        decoration: InputDecoration(
                          labelText: 'Работа',
                          labelStyle: TextStyle(color: secondary),
                          filled: true,
                          fillColor: fieldFill,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: favController,
                        style: TextStyle(color: primary, fontWeight: FontWeight.w700),
                        decoration: InputDecoration(
                          labelText: 'Избранное',
                          labelStyle: TextStyle(color: secondary),
                          filled: true,
                          fillColor: fieldFill,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openSettingsScreen(BuildContext context) {
    final onThemeChanged = widget.onThemeModeChanged;
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) {
          final isLight = Theme.of(context).brightness == Brightness.light;
          return Scaffold(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                'Настройки приложения',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _GlassCard(
                    child: Column(
                      children: [
                        SwitchListTile(
                          value: isLight,
                          onChanged: (value) {
                            onThemeChanged(value ? ThemeMode.light : ThemeMode.dark);
                          },
                          title: Text(
                            'Светлая тема',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            isLight ? 'Включена' : 'Выключена',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          activeColor: const Color(0xFFFF3D00),
                          inactiveTrackColor: Colors.white.withOpacity(0.2),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          value: _notificationsEnabled,
                          onChanged: (value) => _saveNotifications(value),
                          title: Text(
                            'Уведомления',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            _notificationsEnabled ? 'Включены' : 'Отключены',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          activeColor: const Color(0xFFFF3D00),
                          inactiveTrackColor: Colors.white.withOpacity(0.2),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openAboutCompanyScreen(BuildContext context) {
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) => _AboutCompanyScreen(),
      ),
    );
  }

  void _openPrivacyPolicyScreen(BuildContext context) {
    Navigator.of(context).push(
      _FastPageRoute<void>(
        builder: (context) => _PrivacyPolicyScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rawPhone = _phoneOverride.trim().isNotEmpty
        ? _phoneOverride.trim()
        : (_phoneFromJwt(widget.token) ?? '');
    final displayPhone = _formatPhoneForDisplay(rawPhone);
    final title = _displayName.trim().isNotEmpty
        ? _displayName.trim()
        : (_fullName.trim().isNotEmpty ? _fullName.trim() : displayPhone);
    final subtitle = displayPhone;
    final avatarBytes = _avatarBytes;
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: isLight
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFF4F6FB), Color(0xFFEAF0FA)],
                      )
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF101326), Color(0xFF05060A)],
                      ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      _TopIconButton(
                        icon: Icons.arrow_back_ios_new,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Профиль',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLight ? const Color(0xFF1F2534) : _white95,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      const SizedBox(width: 44, height: 44),
                      // placeholder to keep title centered (support button removed)
                    ],
                  ),
                  const SizedBox(height: 14),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => _openAccountScreen(context),
                      child: _GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                      child: Row(
                        children: [
                              GestureDetector(
                                onTap: () => _openAvatarPicker(context),
                                child: Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFFF2D55).withOpacity(0.35),
                                  blurRadius: 20,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                                  clipBehavior: Clip.antiAlias,
                                  child: avatarBytes == null
                                      ? const Icon(
                              Icons.person,
                              color: Colors.white,
                              size: 26,
                                        )
                                      : Image.memory(avatarBytes, fit: BoxFit.cover),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                    if (_loadingName)
                                Text(
                                        'Загрузка…',
                                        style: TextStyle(
                                          color: isLight ? const Color(0xFF1F2534) : _white95,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      )
                                    else
                                      Text(
                                        title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isLight ? const Color(0xFF1F2534) : _white95,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                      subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isLight ? const Color(0xFF6A7388) : _white65,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: isLight ? const Color(0xFF9AA3B5) : Colors.white.withOpacity(0.55),
                          ),
                        ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        _ProfileSection(
                          title: 'Аккаунт',
                          children: [
                            _ProfileTile(
                              icon: Icons.person_outline,
                              title: 'Учетная запись',
                              subtitle: 'Телефон, безопасность',
                              onTap: () => _openAccountScreen(context),
                            ),
                            _ProfileTile(
                              icon: Icons.badge_outlined,
                              title: 'Личные данные',
                              subtitle: 'Имя, отчество',
                              onTap: () => _openPersonalDataScreen(context),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _ProfileSection(
                          title: 'Бонусы',
                          children: [
                            _ProfileTile(
                              icon: Icons.local_offer_outlined,
                              title: 'Промокоды',
                              subtitle: 'Активировать и история',
                              onTap: () => _openPromoScreen(context),
                            ),
                            _ProfileTile(
                              icon: Icons.card_giftcard_outlined,
                              title: 'Пригласить друзей',
                              subtitle: '3 друга = 500₽ на поездки',
                              onTap: () => _openReferralScreen(context),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _ProfileSection(
                          title: 'Заказы',
                          children: [
                            _ProfileTile(
                              icon: Icons.receipt_long_outlined,
                              title: 'История заказов',
                              subtitle: 'Чеки и детали поездок',
                              onTap: () => _openHistoryScreen(context),
                            ),
                            _ProfileTile(
                              icon: Icons.place_outlined,
                              title: 'Адреса',
                              subtitle: 'Дом, работа и избранные',
                              onTap: () => _openAddressesScreen(context),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _ProfileSection(
                          title: 'Настройки',
                          children: [
                            _ProfileTile(
                              icon: Icons.settings_outlined,
                              title: 'Настройки приложения',
                              subtitle: 'Уведомления и интерфейс',
                              onTap: () => _openSettingsScreen(context),
                            ),
                            _ProfileTile(
                              icon: Icons.business_center_outlined,
                              title: 'О компании',
                              subtitle: 'Контакты, бонусы, реклама',
                              onTap: () => _openAboutCompanyScreen(context),
                            ),
                            _ProfileTile(
                              icon: Icons.privacy_tip_outlined,
                              title: 'Политика конфиденциальности',
                              subtitle: 'Обработка персональных данных',
                              onTap: () => _openPrivacyPolicyScreen(context),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        // Контакт поддержки
                        _GlassCard(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            child: Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
                                    ),
                                  ),
                                  child: const Icon(Icons.phone, color: Colors.white, size: 20),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Поддержка',
                                        style: TextStyle(
                                          color: isLight ? const Color(0xFF1F2534) : _white92,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '+7 (906) 042-42-41',
                                        style: TextStyle(
                                          color: isLight ? const Color(0xFF5C6477) : _white65,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () async {
                                    final uri = Uri(scheme: 'tel', path: '+79060424241');
                                    try { await launchUrl(uri, mode: LaunchMode.externalApplication); } catch (_) {}
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      gradient: const LinearGradient(
                                        colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
                                      ),
                                    ),
                                    child: const Text(
                                      'Позвонить',
                                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _GlassCard(
                          child: _ProfileTile(
                            icon: Icons.logout,
                            title: 'Выйти',
                            subtitle: 'Завершить сессию',
                            showChevron: false,
                            onTap: () {
                              widget.onLogout();
                              if (context.mounted) Navigator.of(context).pop();
                            },
                          ),
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
    );
  }
}

class _AboutCompanyScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final surface = Theme.of(context).scaffoldBackgroundColor;
    final accent = const Color(0xFFFF3D00);
    final cardBg = isLight ? const Color(0xFFF4F6FB) : const Color(0xFF161A24);
    final muted = isLight ? const Color(0xFF5C6477) : const Color(0xFF9AA3B5);

    Future<void> openUrl(String url) async {
      final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }

    Future<void> openTel(String phone) async {
      final digits = phone.replaceAll(RegExp(r'\D'), '');
      final path = digits.startsWith('7') ? '+$digits' : '+7$digits';
      try {
        await launchUrl(Uri(scheme: 'tel', path: path), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }

    return Scaffold(
      backgroundColor: surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'О компании',
          style: TextStyle(
            color: onSurface,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Контакты — карточка
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(20),
                border: isLight ? Border.all(color: const Color(0xFFE2E8F0)) : null,
                boxShadow: isLight
                    ? [BoxShadow(color: const Color(0x0D000000), blurRadius: 20, offset: const Offset(0, 6))]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 4,
                        height: 22,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Контакты',
                        style: TextStyle(
                          color: onSurface,
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Сайт, телефон и Telegram — всегда на связи.',
                    style: TextStyle(color: muted, fontSize: 14, height: 1.35),
                  ),
                  const SizedBox(height: 12),
                  _LinkTile(
                    icon: '🌐',
                    label: 'www.trezv777.ru',
                    onTap: () => openUrl('https://www.trezv777.ru'),
                  ),
                  _LinkTile(
                    icon: '☎️',
                    label: '8-906-042-42-41',
                    onTap: () => openTel('89060424241'),
                  ),
                  _LinkTile(
                    icon: '💎',
                    label: 'https://t.me/ttrezv777',
                    onTap: () => openUrl('https://t.me/ttrezv777'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Бонусы
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(20),
                border: isLight ? Border.all(color: const Color(0xFFE2E8F0)) : null,
                boxShadow: isLight
                    ? [BoxShadow(color: const Color(0x0D000000), blurRadius: 20, offset: const Offset(0, 6))]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 4,
                        height: 22,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Бонусная программа',
                        style: TextStyle(
                          color: onSurface,
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Поездили — получили промокод. Делитесь с друзьями: за каждого друга по 200 ₽ на счёт вам и ему. Количество приглашённых не ограничено.',
                    style: TextStyle(
                      color: muted,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Сотрудничество
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(20),
                border: isLight ? Border.all(color: const Color(0xFFE2E8F0)) : null,
                boxShadow: isLight
                    ? [BoxShadow(color: const Color(0x0D000000), blurRadius: 20, offset: const Offset(0, 6))]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 4,
                        height: 22,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Сотрудничество',
                        style: TextStyle(
                          color: onSurface,
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Работаем с заведениями: кафе, рестораны, клубы. Обсудим условия — напишите или позвоните.',
                    style: TextStyle(color: muted, fontSize: 14, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  _LinkTile(
                    icon: '',
                    label: 'Trezv777@yandex.ru',
                    onTap: () => openUrl('mailto:Trezv777@yandex.ru'),
                  ),
                  _PhoneTile(
                    number: '89060424241',
                    onTap: () => openTel('89060424241'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Реклама
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(20),
                border: isLight ? Border.all(color: const Color(0xFFE2E8F0)) : null,
                boxShadow: isLight
                    ? [BoxShadow(color: const Color(0x0D000000), blurRadius: 20, offset: const Offset(0, 6))]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 4,
                        height: 22,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Реклама',
                        style: TextStyle(
                          color: onSurface,
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Хотите разместить рекламу? Звоните по номеру ниже.',
                    style: TextStyle(color: muted, fontSize: 14, height: 1.4),
                  ),
                  const SizedBox(height: 6),
                  _PhoneTile(
                    number: '89060424242',
                    onTap: () => openTel('89060424242'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyPolicyScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    Future<void> openUrl(String url) async {
      final uri = Uri.parse(url.startsWith('http') ? url : 'https://$url');
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }

    final isLight = Theme.of(context).brightness == Brightness.light;
    final primary = isLight ? const Color(0xFF1F2534) : _white95;
    final body = isLight ? const Color(0xFF5C6477) : _white85;
    final strong = isLight ? const Color(0xFF1F2534) : _white90;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Политика конфиденциальности',
          style: TextStyle(color: primary, fontWeight: FontWeight.w900, fontSize: 16),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: _GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Оформление заказа при помощи данного приложения означает согласие с условиями политики конфиденциальности, которые вы можете прочитать, пройдя по ссылке ',
                  style: TextStyle(color: body, fontSize: 14, height: 1.45),
                ),
                const SizedBox(height: 6),
                _PolicyLink(
                  label: 'Политика конфиденциальности',
                  onTap: () => openUrl('https://www.trezv777.ru/privacy'),
                ),
                const SizedBox(height: 12),
                Text(
                  'а так же согласие с условиями обработки персональных данных в личном кабинете приложения, с которыми вы можете ознакомиться, пройдя по ссылке ',
                  style: TextStyle(color: body, fontSize: 14, height: 1.45),
                ),
                _PolicyLink(
                  label: 'Согласие пользователя на обработку персональных данных в ЛК',
                  onTap: () => openUrl('https://www.trezv777.ru/personal-data-lk'),
                ),
                const SizedBox(height: 8),
                Text(
                  'и согласие на обработку персональных данных при использовании услуг ',
                  style: TextStyle(color: body, fontSize: 14, height: 1.45),
                ),
                _PolicyLink(
                  label: 'Согласие пользователя на обработку персональных данных',
                  onTap: () => openUrl('https://www.trezv777.ru/personal-data'),
                ),
                const SizedBox(height: 16),
                Text(
                  'Водители и клиенты при регистрации в приложении дают согласие на обработку персональных данных в соответствии с указанными документами.',
                  style: TextStyle(
                    color: strong,
                    fontSize: 14,
                    height: 1.45,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PolicyLink extends StatelessWidget {
  const _PolicyLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
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

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.icon, required this.label, required this.onTap});

  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              if (icon.isNotEmpty) Text(icon, style: const TextStyle(fontSize: 18)),
              if (icon.isNotEmpty) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: const Color(0xFF4A9EFF),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline,
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

class _PhoneTile extends StatelessWidget {
  const _PhoneTile({required this.number, required this.onTap});

  final String number;
  final VoidCallback onTap;

  static String _formatPhone(String n) {
    if (n.length == 11 && (n.startsWith('7') || n.startsWith('8'))) {
      return '+7 (${n.substring(1, 4)}) ${n.substring(4, 7)}-${n.substring(7, 9)}-${n.substring(9)}';
    }
    if (n.length == 10 && n.startsWith('9')) {
      return '+7 (${n.substring(0, 3)}) ${n.substring(3, 6)}-${n.substring(6, 8)}-${n.substring(8)}';
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.phone, size: 20, color: const Color(0xFF4A9EFF)),
              const SizedBox(width: 10),
              Text(
                _formatPhone(number),
                style: const TextStyle(
                  color: Color(0xFF4A9EFF),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileSection extends StatelessWidget {
  const _ProfileSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return _GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                color: isLight ? const Color(0xFF222938) : _white75,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.showChevron = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: isLight
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFFFFFFF), Color(0xFFF0F3F8)],
                    )
                  : const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF1A1B22), Color(0xFF0B0C10)],
                    ),
              boxShadow: [
                BoxShadow(
                  color: isLight ? const Color(0x14000000) : _black35,
                  blurRadius: 14,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Icon(
              icon,
              color: isLight ? const Color(0xFF1F2534) : _white92,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isLight ? const Color(0xFF1F2534) : _white92,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isLight
                        ? const Color(0xFF5C6477)
                        : Colors.white.withOpacity(0.60),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (showChevron)
            Icon(
              Icons.chevron_right,
              color: isLight
                  ? const Color(0xFF9AA3B5)
                  : Colors.white.withOpacity(0.45),
            ),
        ],
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: child,
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});

  final Widget child;

  static final _borderRadius = BorderRadius.circular(24);

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      gradient: isLight
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFFFFF), Color(0xFFF1F3F8)],
            )
          : const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF161A24), Color(0xFF0B0D12)],
            ),
      border: Border.all(
        color: isLight ? const Color(0xFFDCE2EB) : const Color(0xFF1C2030),
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: isLight ? const Color(0x1A000000) : _black45,
          blurRadius: isLight ? 10 : 16,
          offset: const Offset(0, 8),
        ),
      ],
    );
    return DecoratedBox(
      decoration: decoration,
      child: ClipRRect(
        borderRadius: _borderRadius,
        child: child,
      ),
    );
  }
}

class _GlossyOverlay extends StatelessWidget {
  const _GlossyOverlay({required this.radius});

  final double radius;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: [0.0, 0.35, 1.0],
              colors: [
                _white18,
                _white04,
                Colors.transparent,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopIconButton extends StatelessWidget {
  const _TopIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  static final _borderRadius = BorderRadius.circular(18);

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      gradient: isLight
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFFFFF), Color(0xFFF0F3F8)],
            )
          : const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1A1B22), Color(0xFF0B0C10)],
            ),
      border: Border.all(
        color: isLight ? const Color(0xFFD8DFEA) : const Color(0xFF222636),
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: isLight ? const Color(0x14000000) : _black35,
          blurRadius: 10,
          offset: const Offset(0, 6),
        ),
      ],
    );
    return Material(
      color: Colors.transparent,
      borderRadius: _borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: _borderRadius,
        onTap: onTap,
        child: Ink(
          width: 44,
          height: 44,
          decoration: decoration,
          child: Center(
            child: Icon(
              icon,
              color: isLight ? const Color(0xFF1F2534) : _white92,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

class _NeonPill extends StatelessWidget {
  const _NeonPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: const LinearGradient(
          colors: [Color(0xFFFF2D55), Color(0xFFFF3D00)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF2D55).withOpacity(0.35),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.marker,
    required this.markerColor,
    required this.address,
    this.onTap,
    this.trailing,
  });

  final String marker;
  final Color markerColor;
  final String address;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: markerColor,
              ),
              alignment: Alignment.center,
              child: Text(
                marker,
                style: const TextStyle(
                  color: Color(0xFF0B0D12),
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isLight ? const Color(0xFF1F2534) : Colors.white.withOpacity(0.92),
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _PrimaryGlowButton extends StatelessWidget {
  const _PrimaryGlowButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  static final _borderRadius = BorderRadius.circular(22);

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      gradient: isLight
          ? const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              stops: [0.0, 0.55, 1.0],
              colors: [
                Color(0xFFFF6A3D),
                Color(0xFFFF4D5A),
                Color(0xFFFF3D00),
              ],
            )
          : const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              stops: [0.0, 0.55, 1.0],
              colors: [
                Color(0xFF7C3AED),
                Color(0xFFFF2D55),
                Color(0xFFFF3D00),
              ],
            ),
      border: Border.all(
        color: isLight ? const Color(0x26FF3D00) : const Color(0x33FFFFFF),
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: isLight ? const Color(0x33FF4D5A) : const Color(0x477C3AED),
          blurRadius: 18,
          offset: const Offset(0, 10),
        ),
        BoxShadow(
          color: isLight ? const Color(0x22000000) : _black40,
          blurRadius: 14,
          offset: const Offset(0, 8),
        ),
      ],
    );
    return SizedBox(
      height: 60,
      child: Material(
        color: Colors.transparent,
        borderRadius: _borderRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: _borderRadius,
          onTap: onTap,
          child: Ink(
            decoration: decoration,
            child: Center(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryActionButton extends StatelessWidget {
  const _SecondaryActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.showBadge = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool showBadge;

  static final _borderRadius = BorderRadius.circular(18);

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      gradient: isLight
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFFFFF), Color(0xFFF0F3F8)],
            )
          : const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1A1C25), Color(0xFF0B0C10)],
            ),
      border: Border.all(
        color: isLight ? const Color(0xFFD8DFEA) : const Color(0xFF222636),
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: isLight ? const Color(0x14000000) : _black55,
          blurRadius: 12,
          offset: const Offset(0, 8),
        ),
      ],
    );
    return Material(
      color: Colors.transparent,
      borderRadius: _borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: _borderRadius,
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: decoration,
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: isLight
                          ? const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFFDFEFF), Color(0xFFE9EEF7)],
                            )
                          : const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF1A1B22), Color(0xFF0B0C10)],
                            ),
                    ),
                    child: Icon(
                      icon,
                      size: 18,
                      color: isLight ? const Color(0xFF1F2534) : _white92,
                    ),
                  ),
                  if (showBadge)
                    Positioned(
                      top: -1,
                      right: -1,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF2D55),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isLight ? const Color(0xFF1F2534) : _white90,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    letterSpacing: 0.3,
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

class _ReferralStep extends StatelessWidget {
  const _ReferralStep({required this.number, required this.text});

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFFFD400).withOpacity(0.2),
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                color: Color(0xFFFFD400),
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: isLight ? const Color(0xFF5C6477) : _white80,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Schedule / Pre-order Bottom Sheet  —  Premium Redesign
// ═══════════════════════════════════════════════════════════════════

class _ScheduleBottomSheet extends StatefulWidget {
  const _ScheduleBottomSheet({
    this.initialWish,
    this.initialScheduledAt,
  });

  final String? initialWish;
  final DateTime? initialScheduledAt;

  @override
  State<_ScheduleBottomSheet> createState() => _ScheduleBottomSheetState();
}

class _ScheduleBottomSheetState extends State<_ScheduleBottomSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _wishController;
  bool _isPreorder = false;

  late List<DateTime> _days;
  late int _selectedDayIndex;
  late int _selectedHour;
  late int _selectedMinuteSlot;

  late FixedExtentScrollController _dayScrollCtrl;
  late FixedExtentScrollController _hourScrollCtrl;
  late FixedExtentScrollController _minScrollCtrl;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _wishController = TextEditingController(text: widget.initialWish ?? '');

    _buildDays();

    if (widget.initialScheduledAt != null) {
      _isPreorder = true;
      _tabController.index = 1;
      final sa = widget.initialScheduledAt!;
      _selectedDayIndex = 0;
      for (int i = 0; i < _days.length; i++) {
        if (_days[i].year == sa.year &&
            _days[i].month == sa.month &&
            _days[i].day == sa.day) {
          _selectedDayIndex = i;
          break;
        }
      }
      _selectedHour = sa.hour;
      _selectedMinuteSlot = (sa.minute / 5).round().clamp(0, 11);
    } else {
      final now = DateTime.now().add(const Duration(minutes: 45));
      _selectedDayIndex = 0;
      _selectedHour = now.hour;
      _selectedMinuteSlot = (now.minute / 5).round().clamp(0, 11);
    }

    _dayScrollCtrl = FixedExtentScrollController(initialItem: _selectedDayIndex);
    _hourScrollCtrl = FixedExtentScrollController(initialItem: _selectedHour);
    _minScrollCtrl = FixedExtentScrollController(initialItem: _selectedMinuteSlot);
  }

  void _buildDays() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _days = List.generate(14, (i) => today.add(Duration(days: i)));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _wishController.dispose();
    _dayScrollCtrl.dispose();
    _hourScrollCtrl.dispose();
    _minScrollCtrl.dispose();
    super.dispose();
  }

  DateTime? get _pickedDateTime {
    if (!_isPreorder) return null;
    final day = _days[_selectedDayIndex];
    final minute = _selectedMinuteSlot * 5;
    return DateTime(day.year, day.month, day.day, _selectedHour, minute);
  }

  void _applyQuick(int addMinutes) {
    final target = DateTime.now().add(Duration(minutes: addMinutes));
    setState(() {
      _isPreorder = true;
      for (int i = 0; i < _days.length; i++) {
        if (_days[i].year == target.year &&
            _days[i].month == target.month &&
            _days[i].day == target.day) {
          _selectedDayIndex = i;
          _dayScrollCtrl.animateToItem(i,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut);
          break;
        }
      }
      _selectedHour = target.hour;
      _hourScrollCtrl.animateToItem(target.hour,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      final slot = (target.minute / 5).ceil().clamp(0, 11);
      _selectedMinuteSlot = slot;
      _minScrollCtrl.animateToItem(slot,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    });
  }

  void _clearSchedule() {
    setState(() => _isPreorder = false);
  }

  void _confirm() {
    Navigator.of(context).pop<Map<String, dynamic>>({
      'wish': _wishController.text,
      'scheduledAt': _pickedDateTime,
    });
  }

  String _dayLabel(int index) {
    final d = _days[index];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (d == today) return 'Сегодня';
    final tomorrow = today.add(const Duration(days: 1));
    if (d == tomorrow) return 'Завтра';
    const weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    const months = [
      'янв.', 'февр.', 'марта', 'апр.', 'мая', 'июня',
      'июля', 'авг.', 'сент.', 'окт.', 'нояб.', 'дек.',
    ];
    return '${weekdays[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final sheetBg = isLight
        ? [const Color(0xFFF8FAFD), const Color(0xFFEEF2F8)]
        : [const Color(0xFF161A26), const Color(0xFF0D0F16)];
    final handleColor = isLight ? const Color(0xFFD0D8E8) : _white18;
    final tabBg = isLight ? const Color(0xFFEBEFF7) : const Color(0xFF1A1E2C);
    final tabBorder = isLight ? const Color(0xFFDCE2EB) : _white06;
    final unselectedTabColor = isLight ? const Color(0xFF5C6477) : _white50;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.78,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: sheetBg,
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: isLight
            ? const Border(
                top: BorderSide(color: Color(0xFFDCE2EB), width: 1),
                left: BorderSide(color: Color(0xFFDCE2EB), width: 1),
                right: BorderSide(color: Color(0xFFDCE2EB), width: 1),
              )
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: handleColor,
              ),
            ),
            const SizedBox(height: 16),
            // ── Segmented tabs ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: tabBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: tabBorder, width: 1),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicator: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF7C3AED), Color(0xFFFF2D55)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF7C3AED).withOpacity(0.35),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicatorPadding: const EdgeInsets.all(3),
                  dividerColor: Colors.transparent,
                  dividerHeight: 0,
                  labelColor: Colors.white,
                  unselectedLabelColor: unselectedTabColor,
                  labelStyle: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    letterSpacing: 0.3,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  tabs: const [
                    Tab(text: 'Комментарий'),
                    Tab(text: 'Предзаказ'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildExtrasTab(context),
                  _buildTimeTab(context),
                ],
              ),
            ),
            // ── Confirm ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
              child: SizedBox(
                width: double.infinity,
                child: _PrimaryGlowButton(
                  label: 'ГОТОВО',
                  onTap: _confirm,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExtrasTab(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final primary = isLight ? const Color(0xFF1F2534) : _white90;
    final fieldFill = isLight ? const Color(0xFFFFFFFF) : const Color(0xFF1A1E2C);
    final fieldBorder = isLight ? const Color(0xFFDCE2EB) : _white06;
    final hintColor = isLight ? const Color(0xFF9AA3B5) : _white40;
    final textColor = isLight ? const Color(0xFF1F2534) : _white95;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF7C3AED).withOpacity(0.2),
                      const Color(0xFFFF2D55).withOpacity(0.2),
                    ],
                  ),
                ),
                child: const Icon(Icons.auto_awesome, color: Color(0xFFB07CFF), size: 17),
              ),
              const SizedBox(width: 10),
              Text(
                'Комментарий к заказу',
                style: TextStyle(
                  color: primary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _wishController,
            style: TextStyle(color: textColor, fontSize: 15),
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'Комментарий к заказу',
              hintStyle: TextStyle(color: hintColor, fontSize: 14),
              filled: true,
              fillColor: fieldFill,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: fieldBorder, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: Color(0xFF7C3AED), width: 1.5),
              ),
              contentPadding: const EdgeInsets.all(16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeTab(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final primary = isLight ? const Color(0xFF1F2534) : _white90;
    final toggleBg = isLight ? const Color(0xFFFFFFFF) : const Color(0xFF1A1E2C);
    final toggleBorder = isLight ? const Color(0xFFDCE2EB) : _white06;
    final inactiveIconBg = isLight ? const Color(0xFFEAF0FA) : const Color(0xFF252A38);
    final inactiveIconColor = isLight ? const Color(0xFF5C6477) : _white50;
    final pickerBg = isLight ? const Color(0xFFFFFFFF) : const Color(0xFF1A1E2C);
    final pickerBorder = isLight ? const Color(0xFFDCE2EB) : _white06;
    final sepColor = isLight ? const Color(0xFFDCE2EB) : _white06;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Column(
        children: [
          // ── Toggle row ──
          GestureDetector(
            onTap: () => setState(() => _isPreorder = !_isPreorder),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: toggleBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isPreorder
                      ? const Color(0xFF7C3AED).withOpacity(0.5)
                      : toggleBorder,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      gradient: _isPreorder
                          ? const LinearGradient(
                              colors: [Color(0xFF7C3AED), Color(0xFFFF2D55)],
                            )
                          : null,
                      color: _isPreorder ? null : inactiveIconBg,
                    ),
                    child: Icon(
                      Icons.schedule_rounded,
                      color: _isPreorder ? Colors.white : inactiveIconColor,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Предварительный заказ',
                      style: TextStyle(
                        color: primary,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 48, height: 28,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: _isPreorder
                          ? const LinearGradient(
                              colors: [Color(0xFF7C3AED), Color(0xFFFF2D55)],
                            )
                          : null,
                      color: _isPreorder ? null : inactiveIconBg,
                    ),
                    child: AnimatedAlign(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeInOut,
                      alignment: _isPreorder
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        width: 22, height: 22,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: _black40,
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // ── Quick buttons ──
          Row(
            children: [
              _ScheduleQuickChip(
                label: 'Сейчас',
                icon: Icons.flash_on_rounded,
                selected: !_isPreorder,
                onTap: _clearSchedule,
              ),
              const SizedBox(width: 8),
              _ScheduleQuickChip(
                label: '45 мин',
                selected: false,
                onTap: () => _applyQuick(45),
              ),
              const SizedBox(width: 8),
              _ScheduleQuickChip(
                label: '50 мин',
                selected: false,
                onTap: () => _applyQuick(50),
              ),
              const SizedBox(width: 8),
              _ScheduleQuickChip(
                label: '60 мин',
                selected: false,
                onTap: () => _applyQuick(60),
              ),
            ],
          ),
          // ── Scroll pickers ──
          if (_isPreorder) ...[
            const SizedBox(height: 18),
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: pickerBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: pickerBorder, width: 1),
              ),
              child: Stack(
                children: [
                  // Selection highlight band
                  Center(
                    child: Container(
                      height: 44,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          colors: [
                            const Color(0xFF7C3AED).withOpacity(0.15),
                            const Color(0xFFFF2D55).withOpacity(0.10),
                          ],
                        ),
                        border: Border.all(
                          color: const Color(0xFF7C3AED).withOpacity(0.3),
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                  // Pickers
                  Row(
                    children: [
                      Expanded(
                        flex: 4,
                        child: _ScheduleWheel(
                          controller: _dayScrollCtrl,
                          itemCount: _days.length,
                          selectedIndex: _selectedDayIndex,
                          onChanged: (i) =>
                              setState(() => _selectedDayIndex = i),
                          labelBuilder: _dayLabel,
                          isLight: isLight,
                        ),
                      ),
                      Container(width: 1, height: 100, color: sepColor),
                      Expanded(
                        flex: 2,
                        child: _ScheduleWheel(
                          controller: _hourScrollCtrl,
                          itemCount: 24,
                          selectedIndex: _selectedHour,
                          onChanged: (i) =>
                              setState(() => _selectedHour = i),
                          labelBuilder: (i) => i.toString().padLeft(2, '0'),
                          isLight: isLight,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(':', style: TextStyle(
                          color: isLight ? const Color(0xFF5C6477) : _white50,
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                        )),
                      ),
                      Expanded(
                        flex: 2,
                        child: _ScheduleWheel(
                          controller: _minScrollCtrl,
                          itemCount: 12,
                          selectedIndex: _selectedMinuteSlot,
                          onChanged: (i) =>
                              setState(() => _selectedMinuteSlot = i),
                          labelBuilder: (i) =>
                              (i * 5).toString().padLeft(2, '0'),
                          isLight: isLight,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScheduleWheel extends StatelessWidget {
  const _ScheduleWheel({
    required this.controller,
    required this.itemCount,
    required this.selectedIndex,
    required this.onChanged,
    required this.labelBuilder,
    this.isLight = false,
  });

  final FixedExtentScrollController controller;
  final int itemCount;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final String Function(int) labelBuilder;
  final bool isLight;

  @override
  Widget build(BuildContext context) {
    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: 44,
      diameterRatio: 1.3,
      perspective: 0.003,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: onChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: itemCount,
        builder: (context, index) {
          final selected = index == selectedIndex;
          return Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                color: selected
                    ? (isLight ? const Color(0xFF1F2534) : Colors.white)
                    : (isLight ? const Color(0xFFB0BAD0) : _white40),
                fontWeight: selected ? FontWeight.w900 : FontWeight.w500,
                fontSize: selected ? 18 : 14,
                letterSpacing: selected ? 0.5 : 0,
              ),
              child: Text(labelBuilder(index)),
            ),
          );
        },
      ),
    );
  }
}

class _ScheduleQuickChip extends StatelessWidget {
  const _ScheduleQuickChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final unselBg = isLight ? const Color(0xFFEAF0FA) : const Color(0xFF1A1E2C);
    final unselBorder = isLight ? const Color(0xFFDCE2EB) : const Color(0xFF2A2F3A);
    final unselText = isLight ? const Color(0xFF5C6477) : _white70;
    final unselIcon = isLight ? const Color(0xFF5C6477) : _white60;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: selected
                ? const LinearGradient(
                    colors: [Color(0xFF7C3AED), Color(0xFFFF2D55)],
                  )
                : null,
            color: selected ? null : unselBg,
            border: Border.all(
              color: selected ? Colors.transparent : unselBorder,
              width: 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: const Color(0xFF7C3AED).withOpacity(0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: selected ? Colors.white : unselIcon),
                const SizedBox(width: 3),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: selected ? Colors.white : unselText,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
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
