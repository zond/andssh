import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'session_manager.dart';

void _log(String msg) => developer.log(msg, name: 'andssh');

const _channelId = 'andssh_sessions';
const _channelName = 'Active SSH sessions';
const _channelDesc = 'Ongoing notification while andssh has open connections';
const _groupKey = 'andssh_sessions';
const _notificationId = 4201;

// Process-global name used by the notification action receiver isolate to
// reach the main isolate's SessionManager. flutter_local_notifications
// always routes action-button taps through a separate background isolate
// — even when the app is foregrounded — so the foreground response
// callback never sees them. We bridge across isolates via IsolateNameServer.
const _actionPortName = 'andssh_notification_actions';

/// Maintains a single summary notification that lists every active
/// session, plus one entry per session with a "Disconnect" action. Taps
/// and action taps are delivered to [onOpen]/[onDisconnect].
class NotificationService {
  NotificationService();

  final _plugin = FlutterLocalNotificationsPlugin();
  SessionManager? _manager;
  ValueChanged<String>? _onOpen;
  bool _fgRunning = false;
  ReceivePort? _actionPort;
  StreamSubscription<dynamic>? _actionSub;

  Future<void> initialize({
    required SessionManager manager,
    required ValueChanged<String> onOpen,
  }) async {
    _manager = manager;
    _onOpen = onOpen;

    // Bridge from the action-receiver isolate. Drop any previously
    // registered SendPort first — hot restart leaves stale mappings around.
    IsolateNameServer.removePortNameMapping(_actionPortName);
    final port = ReceivePort();
    IsolateNameServer.registerPortWithName(port.sendPort, _actionPortName);
    _actionPort = port;
    _actionSub = port.listen(_handleActionMessage);

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      settings: const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: _handleResponse,
      onDidReceiveBackgroundNotificationResponse:
          notificationTapBackground,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    manager.addListener(_refresh);
    await _refresh();
  }

  Future<void> dispose() async {
    _manager?.removeListener(_refresh);
    await _actionSub?.cancel();
    _actionSub = null;
    _actionPort?.close();
    _actionPort = null;
    IsolateNameServer.removePortNameMapping(_actionPortName);
    await _stopForegroundService();
    await _plugin.cancelAll();
  }

  void _handleActionMessage(dynamic message) {
    if (message is! Map) return;
    if (message['kind'] == 'disconnect') {
      final id = message['id'];
      if (id is! String) return;
      _log('disconnect routed from notification action: $id');
      unawaited(_manager?.disconnect(id).catchError((Object e) {
            _log('disconnect from notification failed: $e');
          }) ??
          Future<void>.value());
    }
  }

  Future<void> _refresh() async {
    final mgr = _manager;
    if (mgr == null) return;
    final sessions = mgr.sessions;
    if (sessions.isEmpty) {
      await _stopForegroundService();
      await _plugin.cancelAll();
      return;
    }

    // Promote the process to a foreground service so Android doesn't
    // freeze our networking when the app is backgrounded. The service's
    // notification doubles as our summary — its content updates whenever
    // the set of sessions changes.
    await _startOrUpdateForegroundService(sessions);

    // One per-session notification with a targeted Disconnect action. We
    // skip rendering this for the sole session — the foreground-service
    // notification already covers it — to avoid duplicate shade entries.
    if (sessions.length > 1) {
      for (final s in sessions) {
        final details = AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          importance: Importance.low,
          priority: Priority.low,
          // Hide content on secure lockscreens — the system shows a
          // "Notification hidden" placeholder instead of our title /
          // host / username. Full content is visible once unlocked.
          visibility: NotificationVisibility.private,
          groupKey: _groupKey,
          actions: <AndroidNotificationAction>[
            AndroidNotificationAction(
              'disconnect:${s.connection.id}',
              'Disconnect',
              cancelNotification: false,
            ),
          ],
        );
        await _plugin.show(
          id: _idFor(s.connection.id),
          title: 'Connected: ${s.connection.name}',
          body: '${s.connection.username}@${s.connection.host}',
          notificationDetails: NotificationDetails(android: details),
          payload: 'open:${s.connection.id}',
        );
      }
    } else {
      // Clean up any per-session notifications from a previous state
      // where we had >1 session.
      for (final s in sessions) {
        await _plugin.cancel(id: _idFor(s.connection.id));
      }
    }
  }

  Future<void> _startOrUpdateForegroundService(
      List<ActiveSession> sessions) async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    final single = sessions.length == 1 ? sessions.first : null;
    final title = single != null
        ? 'Connected: ${single.connection.name}'
        : 'andssh: ${sessions.length} active sessions';
    final body = single != null
        ? '${single.connection.username}@${single.connection.host}'
        : sessions.map((s) => s.connection.name).join(', ');
    final payload = single != null ? 'open:${single.connection.id}' : '';
    final details = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true,
      importance: Importance.low,
      priority: Priority.low,
      // Lockscreen privacy: system shows a placeholder instead of
      // host/username until the device is unlocked.
      visibility: NotificationVisibility.private,
      groupKey: _groupKey,
      setAsGroupSummary: sessions.length > 1,
      actions: single != null
          ? <AndroidNotificationAction>[
              AndroidNotificationAction(
                'disconnect:${single.connection.id}',
                'Disconnect',
                cancelNotification: false,
              ),
            ]
          : const <AndroidNotificationAction>[],
    );
    await android.startForegroundService(
      id: _notificationId,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
      foregroundServiceTypes: const {
        AndroidServiceForegroundType.foregroundServiceTypeDataSync,
      },
    );
    _fgRunning = true;
  }

  Future<void> _stopForegroundService() async {
    if (!_fgRunning) return;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.stopForegroundService();
    _fgRunning = false;
  }

  int _idFor(String connectionId) =>
      _notificationId + 1 + connectionId.hashCode.abs() % 10000;

  Future<void> _handleResponse(NotificationResponse response) async {
    final actionId = response.actionId;
    if (actionId != null && actionId.startsWith('disconnect:')) {
      final id = actionId.substring('disconnect:'.length);
      _log('notification disconnect action for $id');
      try {
        await _manager?.disconnect(id);
      } catch (e) {
        _log('disconnect from notification failed: $e');
      }
      return;
    }
    final payload = response.payload;
    if (payload != null && payload.startsWith('open:')) {
      final id = payload.substring('open:'.length);
      _log('notification tap for $id');
      _onOpen?.call(id);
    }
  }
}

// Top-level entry point required by flutter_local_notifications. Runs in
// a background isolate spawned by ActionBroadcastReceiver — even when the
// app is foregrounded, action-button taps land here rather than in the
// foreground response callback. We forward "disconnect" actions to the
// main isolate via IsolateNameServer; the SessionManager lives there and
// owns the SSH session we need to close.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  final actionId = response.actionId;
  if (actionId != null && actionId.startsWith('disconnect:')) {
    final id = actionId.substring('disconnect:'.length);
    final port = IsolateNameServer.lookupPortByName(_actionPortName);
    if (port == null) {
      if (kDebugMode) {
        developer.log(
          'background disconnect for $id: main isolate port missing',
          name: 'andssh',
        );
      }
      return;
    }
    port.send(<String, String>{'kind': 'disconnect', 'id': id});
    return;
  }
  if (kDebugMode) {
    developer.log(
      'background notification response: actionId=${response.actionId} '
      'payload=${response.payload}',
      name: 'andssh',
    );
  }
}
