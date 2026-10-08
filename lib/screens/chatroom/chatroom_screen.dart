import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/host_api_config.dart';
import '../../providers/app_provider.dart';
import '../../services/chatroom_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sidebar.dart';

/// Phase G — emergency chatroom screen.
///
/// Replaces the Phase B local-list mock with a real WebSocket-backed
/// client (`ChatroomService`). Messages, presence updates, and
/// connection state are all streams the screen subscribes to. The SOS
/// button calls `sendSos`, which is rate-limited server-side so a
/// panicked user mashing it doesn't degrade the room for everyone else.
class ChatroomScreen extends StatefulWidget {
  const ChatroomScreen({super.key});

  @override
  State<ChatroomScreen> createState() => _ChatroomScreenState();
}

class _ChatroomScreenState extends State<ChatroomScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  late final ChatroomService _chatroom;
  StreamSubscription<ChatMessage>? _messagesSub;
  StreamSubscription<ChatroomConnection>? _connectionSub;

  final List<ChatMessage> _messages = [];
  ChatroomConnection _connection = const ChatroomConnection(
    state: ChatroomConnectionState.disconnected,
  );

  @override
  void initState() {
    super.initState();
    _chatroom = ChatroomService();
    _messagesSub = _chatroom.messages.listen((msg) {
      setState(() => _messages.add(msg));
      _scrollToEnd();
    });
    _connectionSub = _chatroom.connection.listen((c) {
      setState(() => _connection = c);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<AppProvider>();
      final name = provider.currentUser?.name ??
          'guest-${DateTime.now().millisecondsSinceEpoch % 9999}';
      final base =
          provider.connectedHostBaseUrl ?? HostApiConfig.defaultBaseUrl;
      await _chatroom.connect(baseUrl: base, displayName: name);
    });
  }

  @override
  void dispose() {
    _messagesSub?.cancel();
    _connectionSub?.cancel();
    _chatroom.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    Future.delayed(const Duration(milliseconds: 80), () {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _chatroom.sendText(text);
    _messageController.clear();
  }

  void _shareLocation() {
    final provider = context.read<AppProvider>();
    final lat = provider.currentLatitude;
    final lon = provider.currentLongitude;
    if (lat == null || lon == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Location not available — open the location screen first.'),
      ));
      return;
    }
    _chatroom.shareLocation(lat: lat, lon: lon);
  }

  void _showSOS() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Confirm Emergency',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('Are you sure this is an emergency?',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final provider = context.read<AppProvider>();
              _chatroom.sendSos(
                'EMERGENCY: please check on this user',
                lat: provider.currentLatitude,
                lon: provider.currentLongitude,
              );
            },
            child: const Text('Confirm Emergency'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final role = provider.selectedRole.isEmpty ? 'guest' : provider.selectedRole;

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth > 800;
      return Scaffold(
        backgroundColor: AppColors.background,
        drawer: isWide ? null : Sidebar(role: role, currentRoute: '/chatroom'),
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          leading: isWide
              ? null
              : Builder(
                  builder: (ctx) => IconButton(
                    icon: const Icon(Icons.menu, color: AppColors.textPrimary),
                    onPressed: () => Scaffold.of(ctx).openDrawer(),
                  ),
                ),
          title: Row(
            children: [
              const Text('Emergency Chatroom'),
              const SizedBox(width: 8),
              _connectionDot(),
            ],
          ),
          actions: [
            Container(
              margin: const EdgeInsets.only(right: 16, top: 8, bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(20),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.primary.withAlpha(80)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi, color: AppColors.primary, size: 12),
                  SizedBox(width: 4),
                  Text('LAN Only',
                      style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        ),
        body: Row(
          children: [
            if (isWide) Sidebar(role: role, currentRoute: '/chatroom'),
            Expanded(
              child: Column(
                children: [
                  _connectionBanner(),
                  Expanded(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final m = _messages[index];
                        if (m.type == 'system') return _systemBubble(m);
                        if (m.type == 'sos') return _sosBubble(m);
                        if (m.type == 'location') return _locationBubble(m);
                        return _messageBubble(m, provider);
                      },
                    ),
                  ),
                  _inputBar(),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _connectionDot() {
    Color color;
    switch (_connection.state) {
      case ChatroomConnectionState.connected:
        color = const Color(0xFF22C55E);
        break;
      case ChatroomConnectionState.connecting:
      case ChatroomConnectionState.reconnecting:
        color = const Color(0xFFFFB300);
        break;
      case ChatroomConnectionState.disconnected:
        color = const Color(0xFFEF4444);
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _connectionBanner() {
    String text;
    Color bg;
    Color fg;
    switch (_connection.state) {
      case ChatroomConnectionState.connected:
        text =
            '🟢 Connected${_connection.hostName == null ? '' : ' to ${_connection.hostName}'}';
        bg = const Color(0xFF103018);
        fg = const Color(0xFF22C55E);
        break;
      case ChatroomConnectionState.connecting:
        text = '🟡 Connecting…';
        bg = const Color(0xFF1A1500);
        fg = const Color(0xFFFFB300);
        break;
      case ChatroomConnectionState.reconnecting:
        final s = _connection.backoff?.inSeconds ?? 0;
        text = '🟡 Reconnecting (${s}s)';
        bg = const Color(0xFF1A1500);
        fg = const Color(0xFFFFB300);
        break;
      case ChatroomConnectionState.disconnected:
        text = '🔴 Offline — chat server unreachable';
        bg = const Color(0xFF300505);
        fg = const Color(0xFFEF4444);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: bg,
      child: Text(text, style: TextStyle(color: fg, fontSize: 12)),
    );
  }

  Widget _inputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.location_on_outlined,
                color: AppColors.textSecondary),
            onPressed: _shareLocation,
          ),
          Expanded(
            child: TextField(
              controller: _messageController,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Type a message...',
                hintStyle: const TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.card,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send, color: Colors.black, size: 18),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _showSOS,
            child: Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.sos, color: Colors.white, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  Widget _systemBubble(ChatMessage m) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${m.text ?? ''} · ${_formatTime(m.ts)}',
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sosBubble(ChatMessage m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF300505),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEF4444)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sos, color: Color(0xFFEF4444), size: 18),
                const SizedBox(width: 8),
                Text('SOS · ${m.from}',
                    style: const TextStyle(
                        color: Color(0xFFEF4444),
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(_formatTime(m.ts),
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 10)),
              ],
            ),
            if (m.text != null) ...[
              const SizedBox(height: 6),
              Text(m.text!,
                  style: const TextStyle(color: AppColors.textPrimary)),
            ],
            if (m.lat != null && m.lon != null) ...[
              const SizedBox(height: 6),
              Text(
                'Location: ${m.lat!.toStringAsFixed(4)}, ${m.lon!.toStringAsFixed(4)}',
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _locationBubble(ChatMessage m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          const Icon(Icons.location_on, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Text(
            '${m.from} shared location · ${_formatTime(m.ts)}',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _messageBubble(ChatMessage m, AppProvider provider) {
    final isSent = m.from == (provider.currentUser?.name ?? 'guest');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isSent ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isSent) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.primary.withAlpha(25),
              child: Text(
                m.from.isNotEmpty ? m.from[0].toUpperCase() : '?',
                style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Column(
            crossAxisAlignment:
                isSent ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!isSent)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 2),
                  child: Text(m.from,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 11)),
                ),
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.65,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isSent ? AppColors.primary : AppColors.card,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isSent ? 16 : 4),
                    bottomRight: Radius.circular(isSent ? 4 : 16),
                  ),
                ),
                child: Text(
                  m.text ?? '',
                  style: TextStyle(
                    color: isSent ? Colors.black : AppColors.textPrimary,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
                child: Text(_formatTime(m.ts),
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 10)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) =>
      '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}
