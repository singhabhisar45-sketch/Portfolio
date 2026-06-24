import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:open_filex/open_filex.dart';
import 'package:intl/intl.dart';

class PrivateChatScreen extends StatefulWidget {
  final String senderId;
  final String receiverId;
  final String receiverName;
  final String? receiverPhone;
  final String? receiverPhotoUrl;
  final String? title;
  final VoidCallback onComplete;

  const PrivateChatScreen({
    super.key,
    required this.senderId,
    required this.receiverId,
    required this.receiverName,
    this.receiverPhone,
    this.receiverPhotoUrl,
    this.title,
    required this.onComplete,
  });

  @override
  State<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends State<PrivateChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<dynamic> _messages = [];
  List<dynamic> _processedMessages = [];
  List<dynamic> _rawMessages = [];
  bool _isSending = false;
  Timer? _timer;
  final String _baseUrl = "http://52.64.182.123:8080";
  final ImagePicker _picker = ImagePicker();

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecording = false;
  bool _isOnline = false;
  String? _currentReceiverPhotoUrl;

  String? _playingUrl;

  @override
  void initState() {
    super.initState();
    _currentReceiverPhotoUrl = widget.receiverPhotoUrl;
    _loadCachedMessages();
    _fetchData();
    _markMessagesAsRead();
    _timer = Timer.periodic(
        const Duration(milliseconds: 500), (timer) => _fetchData());

    _audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) setState(() => _playingUrl = null);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  String get _cacheKey =>
      "cache_chat_${widget.senderId}_${widget.receiverId}";

  Future<void> _loadCachedMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedData = prefs.getString(_cacheKey);
      if (cachedData != null && mounted) {
        final List<dynamic> newMsgs = jsonDecode(cachedData);
        setState(() {
          _rawMessages = newMsgs;
          _messages = List.from(newMsgs.reversed);
          _processMessages();
        });
      }
    } catch (e) {
      debugPrint("Error loading cache: $e");
    }
  }

  Future<void> _saveMessagesToCache(List<dynamic> messages) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(messages));
    } catch (e) {
      debugPrint("Error saving cache: $e");
    }
  }

  void _fetchData() {
    _fetchMessages();
    _fetchOnlineStatus();
  }

  Future<void> _markMessagesAsRead() async {
    try {
      await http.post(
        Uri.parse("$_baseUrl/mark-read"),
        body: jsonEncode({
          "sender_id": widget.receiverId,
          "receiver_id": widget.senderId,
        }),
        headers: {"Content-Type": "application/json"},
      );
    } catch (e) {
      debugPrint("Error marking read: $e");
    }
  }

  Future<void> _fetchOnlineStatus() async {
    try {
      final response = await http
          .get(Uri.parse("$_baseUrl/status?user_id=${widget.receiverId}"));
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        final user = data.firstWhere(
                (u) => u['id'] == widget.receiverId,
            orElse: () => null);
        if (user != null && mounted) {
          bool online = user['is_online'] == true;
          String? photoUrl = user['photo_url'];
          if (_isOnline != online || _currentReceiverPhotoUrl != photoUrl) {
            setState(() {
              _isOnline = online;
              if (photoUrl != null && photoUrl.isNotEmpty) {
                _currentReceiverPhotoUrl = photoUrl;
              }
            });
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchMessages() async {
    if (_isSending) return;
    try {
      final response = await http.get(Uri.parse(
          "$_baseUrl/chat?sender_id=${widget.senderId}&receiver_id=${widget.receiverId}"));
      if (response.statusCode == 200) {
        if (mounted) {
          final newMsgs = jsonDecode(response.body);
          if (jsonEncode(_rawMessages) != jsonEncode(newMsgs)) {
            setState(() {
              _rawMessages = newMsgs;
              _messages = List.from(newMsgs.reversed);
              _processMessages();
            });
            _saveMessagesToCache(newMsgs);
            _markMessagesAsRead();
          }
        }
      }
    } catch (e) {
      debugPrint("Error fetching messages: $e");
    }
  }

  void _processMessages() {
    List<dynamic> grouped = [];
    for (int i = 0; i < _messages.length; i++) {
      var msg = _messages[i];
      bool isImage =
          (msg['image_base64'] != null && msg['image_base64'].isNotEmpty) ||
              (msg['media_type'] == 'image');

      if (isImage) {
        List<dynamic> group = [msg];
        int j = i + 1;
        while (j < _messages.length) {
          var nextMsg = _messages[j];
          bool nextIsImage =
              (nextMsg['image_base64'] != null &&
                  nextMsg['image_base64'].isNotEmpty) ||
                  (nextMsg['media_type'] == 'image');
          if (nextIsImage && nextMsg['sender_id'] == msg['sender_id']) {
            group.add(nextMsg);
            j++;
          } else {
            break;
          }
        }
        if (group.length > 1) {
          grouped.add({
            'type': 'image_group',
            'messages': group,
            'sender_id': msg['sender_id'],
            'created_at': msg['created_at'],
            'is_read': msg['is_read'],
            'id': 'group_${msg['id'] ?? i}'
          });
          i = j - 1;
        } else {
          grouped.add(msg);
        }
      } else {
        grouped.add(msg);
      }
    }
    _processedMessages = grouped;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(0,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutQuart);
      }
    });
  }

  Future<void> _makeCall() async {
    if (widget.receiverPhone == null || widget.receiverPhone!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Phone number not available.")),
      );
      return;
    }
    final Uri launchUri = Uri(scheme: 'tel', path: widget.receiverPhone);
    if (await canLaunchUrl(launchUri)) await launchUrl(launchUri);
  }

  Future<void> _pickImage() async {
    final List<XFile> images =
    await _picker.pickMultiImage(imageQuality: 50);
    if (images.isNotEmpty) {
      for (var image in images) {
        final bytes = await File(image.path).readAsBytes();
        final base64Image = base64Encode(bytes);
        await _sendMessage(imageBase64: base64Image, mediaType: 'image');
      }
    }
  }

  Future<void> _pickVideo() async {
    final XFile? video =
    await _picker.pickVideo(source: ImageSource.gallery);
    if (video != null) _uploadMedia(File(video.path), 'video');
  }

  Future<void> _pickDocument() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null)
      _uploadMedia(File(result.files.single.path!), 'document');
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final directory = await getApplicationDocumentsDirectory();
        final path =
            '${directory.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
        const config = RecordConfig(
            encoder: AudioEncoder.aacLc,
            bitRate: 128000,
            sampleRate: 44100,
            numChannels: 1);
        await _audioRecorder.start(config, path: path);
        setState(() => _isRecording = true);
      }
    } catch (e) {
      debugPrint("Error starting recording: $e");
    }
  }

  Future<void> _stopRecording() async {
    try {
      final path = await _audioRecorder.stop();
      setState(() => _isRecording = false);
      if (path != null) _uploadMedia(File(path), 'audio');
    } catch (e) {
      debugPrint("Error stopping recording: $e");
    }
  }

  Future<void> _cancelRecording() async {
    try {
      await _audioRecorder.stop();
      setState(() => _isRecording = false);
    } catch (e) {
      debugPrint("Error cancelling recording: $e");
    }
  }

  Future<void> _uploadMedia(File file, String type) async {
    try {
      var request =
      http.MultipartRequest('POST', Uri.parse("$_baseUrl/upload-media"));
      request.fields['type'] = type;
      request.files
          .add(await http.MultipartFile.fromPath('file', file.path));
      var response = await request.send();
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var jsonResponse = jsonDecode(responseData);
        _sendMessage(mediaUrl: jsonResponse['url'], mediaType: type);
      }
    } catch (e) {
      debugPrint("Error uploading: $e");
    }
  }

  Future<void> _sendMessage({
    String? text,
    String? imageBase64,
    String? mediaUrl,
    String? mediaType,
  }) async {
    final content = text ?? _messageController.text.trim();
    if (content.isEmpty && imageBase64 == null && mediaUrl == null) return;
    if (text == null && imageBase64 == null && mediaUrl == null) {
      _messageController.clear();
    }

    setState(() {
      _isSending = true;
      _messages.insert(0, {
        "sender_id": widget.senderId,
        "receiver_id": widget.receiverId,
        "text": content,
        "image_base64": imageBase64,
        "media_url": mediaUrl,
        "media_type": mediaType,
        "created_at": DateTime.now().toIso8601String(),
        "is_read": false,
      });
      _processMessages();
    });

    _scrollToBottom();

    try {
      await http.post(
        Uri.parse("$_baseUrl/chat"),
        body: jsonEncode({
          "room_id": 0,
          "sender_id": widget.senderId,
          "receiver_id": widget.receiverId,
          "text": content,
          "image_base64": imageBase64,
          "media_url": mediaUrl,
          "media_type": mediaType,
        }),
        headers: {"Content-Type": "application/json"},
      );
    } catch (e) {
      debugPrint("Error sending: $e");
    } finally {
      if (mounted) setState(() => _isSending = false);
      _fetchMessages();
    }
  }

  void _showDeleteDialog(dynamic msg) {
    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: AlertDialog(
          backgroundColor: Theme.of(context).cardColor.withOpacity(0.9),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          title: const Text("Delete Message?"),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel")),
            TextButton(
                onPressed: () {
                  _deleteMessage(msg);
                  Navigator.pop(context);
                },
                child: const Text("Delete",
                    style: TextStyle(color: Colors.red))),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMessage(dynamic msg) async {
    try {
      final msgId = msg['id'];
      final isBroadcast =
          msg['is_broadcast'] == true || msg['room_id'] != 0;
      final url = isBroadcast
          ? "$_baseUrl/broadcast?id=$msgId&sender_id=${widget.senderId}"
          : "$_baseUrl/chat?id=$msgId&sender_id=${widget.senderId}";
      final response = await http.delete(Uri.parse(url));
      if (response.statusCode != 200 && isBroadcast) {
        await http.delete(Uri.parse(
            "$_baseUrl/chat?id=$msgId&sender_id=${widget.senderId}"));
      }
      _fetchMessages();
    } catch (e) {
      debugPrint("Error deleting: $e");
    }
  }

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(32),
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 20)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(10)),
                margin: const EdgeInsets.only(bottom: 24)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildActionItem(Icons.image_rounded, "Gallery",
                    Colors.purple, _pickImage),
                _buildActionItem(Icons.videocam_rounded, "Video",
                    Colors.orange, _pickVideo),
                _buildActionItem(Icons.insert_drive_file_rounded,
                    "Document", Colors.blue, _pickDocument),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionItem(
      IconData icon, String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: color.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }

  void _openMedia(String? url, String? base64, String type) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => FullscreenMediaViewer(
                url: url, base64Image: base64, type: type)));
  }

  // ── Date/time helpers ──────────────────────────────────────────────────────

  String _formatTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return "";
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      return DateFormat('h:mm a').format(dt);
    } catch (_) {
      return "";
    }
  }

  String _dateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    if (d == today) return "Today";
    if (d == today.subtract(const Duration(days: 1))) return "Yesterday";
    return DateFormat('d MMM yyyy').format(date);
  }

  DateTime? _parseLocal(String? ts) {
    if (ts == null || ts.isEmpty) return null;
    try {
      return DateTime.parse(ts).toLocal();
    } catch (_) {
      return null;
    }
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _showDateSeparatorBelow(int index) {
    final current =
    _parseLocal(_processedMessages[index]['created_at']);
    if (current == null) return false;
    if (index == _processedMessages.length - 1) return true;
    final older =
    _parseLocal(_processedMessages[index + 1]['created_at']);
    if (older == null) return true;
    return !_sameDay(current, older);
  }

  // ── Date separator widget ──────────────────────────────────────────────────

  Widget _buildDateSeparator(String label, bool isDark) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withOpacity(0.10)
              : Colors.black.withOpacity(0.07),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
              color: isDark ? Colors.white70 : Colors.black54,
              fontSize: 12,
              fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = const Color(0xFF6366F1);
    final bgColor =
    isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);

    return Scaffold(
      backgroundColor: bgColor,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: AppBar(
              backgroundColor:
              (isDark ? Colors.black : Colors.white).withOpacity(0.7),
              elevation: 0,
              iconTheme: IconThemeData(
                  color: isDark ? Colors.white : Colors.black87),
              title: Row(
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundImage: _currentReceiverPhotoUrl != null &&
                            _currentReceiverPhotoUrl!.isNotEmpty
                            ? NetworkImage(_currentReceiverPhotoUrl!)
                            : null,
                        child: _currentReceiverPhotoUrl == null ||
                            _currentReceiverPhotoUrl!.isEmpty
                            ? Text(
                            widget.receiverName[0].toUpperCase(),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16))
                            : null,
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: _isOnline
                                ? Colors.green
                                : Colors.grey,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: isDark
                                    ? Colors.black
                                    : Colors.white,
                                width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.receiverName,
                            style: TextStyle(
                                color: isDark
                                    ? Colors.white
                                    : Colors.black,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        Text(_isOnline ? "Online" : "Offline",
                            style: TextStyle(
                                color: _isOnline
                                    ? Colors.green
                                    : Colors.grey,
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                IconButton(
                    icon: const Icon(Icons.call_rounded, size: 22),
                    onPressed: _makeCall),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              reverse: true,
              padding: const EdgeInsets.fromLTRB(16, 100, 16, 4),
              itemCount: _processedMessages.length,
              itemBuilder: (context, index) {
                final item = _processedMessages[index];
                bool isMe = item['sender_id'] == widget.senderId;

                final showSep = _showDateSeparatorBelow(index);
                final sepLabel = showSep
                    ? _dateLabel(
                    _parseLocal(item['created_at']) ?? DateTime.now())
                    : null;

                String? mediaUrl = item['media_url'];
                if (mediaUrl != null && !mediaUrl.startsWith('http'))
                  mediaUrl = "$_baseUrl$mediaUrl";

                Widget bubble;
                if (item['type'] == 'image_group') {
                  bubble = _buildImageGroup(
                      item, isMe, isDark, primaryColor, index == 0);
                } else {
                  bubble = _buildModernBubble(
                    msg: item,
                    isMe: isMe,
                    mediaUrl: mediaUrl,
                    isDark: isDark,
                    primaryColor: primaryColor,
                    isLast: index == 0,
                    key: ValueKey(item['id'] ?? index),
                  );
                }

                return Column(
                  children: [
                    bubble,
                    if (showSep && sepLabel != null)
                      _buildDateSeparator(sepLabel, isDark),
                  ],
                );
              },
            ),
          ),
          _buildInputBar(isDark, primaryColor),
        ],
      ),
    );
  }

  // ── WhatsApp-style image group ─────────────────────────────────────────────

  Widget _buildImageGroup(dynamic group, bool isMe, bool isDark,
      Color primaryColor, bool isLast) {
    final List<dynamic> messages = List<dynamic>.from(group['messages']);
    final bool isReadByReceiver = group['is_read'] == true;
    final String? createdAt = group['created_at'];

    final int total = messages.length;
    final List<dynamic> tiles =
    total > 4 ? messages.take(4).toList() : messages.take(total).toList();
    final int overflow = total > 4 ? total - 4 : 0;

    String? _url(dynamic msg) {
      String? u = msg['media_url'];
      if (u != null && !u.startsWith('http')) u = "$_baseUrl$u";
      return u;
    }

    String? _b64(dynamic msg) => msg['image_base64'];

    Widget tile(dynamic msg,
        {BorderRadius? radius, bool showOverlay = false}) {
      final url = _url(msg);
      final b64 = _b64(msg);
      return WaImageCell(
        url: url,
        base64Image: b64,
        borderRadius: radius ?? BorderRadius.circular(4),
        overflowCount: showOverlay ? overflow : 0,
        onTap: () => _openMedia(url, b64, 'image'),
      );
    }

    Widget grid;

    switch (tiles.length) {
    // ── 1 image: natural aspect ratio ──────────────────────────────────
      case 1:
        grid = ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 80,
            height: 80,
            child: ChatImage(
              imageBase64: _b64(tiles[0]),
              mediaUrl: _url(tiles[0]),
            ),
          ),
        );
        break;
    // ── 2 images: side-by-side ──────────────────────────────────────────
      case 2:
        grid = WaTwoUp(
          left: tile(tiles[0],
              radius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  bottomLeft: Radius.circular(16))),
          right: tile(tiles[1],
              radius: const BorderRadius.only(
                  topRight: Radius.circular(16),
                  bottomRight: Radius.circular(16))),
        );
        break;

    // ── 3 images: 1 large top + 2 below ────────────────────────────────
      case 3:
        grid = WaThreeUp(
          top: tile(tiles[0],
              radius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16))),
          bottomLeft: tile(tiles[1],
              radius: const BorderRadius.only(
                  bottomLeft: Radius.circular(16))),
          bottomRight: tile(tiles[2],
              radius: const BorderRadius.only(
                  bottomRight: Radius.circular(16))),
        );
        break;

    // ── 4+ images: 2×2 grid ─────────────────────────────────────────────
      default:
        grid = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                  child: tile(tiles[0],
                      radius: const BorderRadius.only(
                          topLeft: Radius.circular(16)))),
              const SizedBox(width: 2),
              Expanded(
                  child: tile(tiles[1],
                      radius: const BorderRadius.only(
                          topRight: Radius.circular(16)))),
            ]),
            const SizedBox(height: 2),
            Row(children: [
              Expanded(
                  child: tile(tiles[2],
                      radius: const BorderRadius.only(
                          bottomLeft: Radius.circular(16)))),
              const SizedBox(width: 2),
              Expanded(
                  child: tile(tiles[3],
                      radius: const BorderRadius.only(
                          bottomRight: Radius.circular(16)),
                      showOverlay: overflow > 0)),
            ]),
          ],
        );
    }

    return Padding(
      key: ValueKey(group['id']),
      padding: EdgeInsets.only(bottom: isLast ? 8 : 12),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              constraints: tiles.length == 1
                  ? const BoxConstraints(maxWidth: 250)
                  : const BoxConstraints(maxWidth: 260),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 10,
                      offset: const Offset(0, 4)),
                ],
              ),
              padding: tiles.length == 1
                  ? EdgeInsets.zero
                  : const EdgeInsets.all(4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: grid,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_formatTime(createdAt),
                    style:
                    const TextStyle(color: Colors.grey, fontSize: 10)),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  Icon(
                    isReadByReceiver ? Icons.done_all : Icons.done,
                    size: 14,
                    color: isReadByReceiver ? Colors.blue : Colors.grey,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Modern bubble ──────────────────────────────────────────────────────────

  Widget _buildModernBubble({
    required dynamic msg,
    required bool isMe,
    required String? mediaUrl,
    required bool isDark,
    required Color primaryColor,
    required bool isLast,
    Key? key,
  }) {
    String? imageBase64 = msg['image_base64'];
    String? mediaType = msg['media_type'];
    String? text = msg['text'];
    String? createdAt = msg['created_at'];
    bool isReadByReceiver = msg['is_read'] == true;

    if ((imageBase64 != null && imageBase64.isNotEmpty) ||
        (mediaType == 'image' && mediaUrl != null)) {
      return Padding(
        key: key,
        padding: EdgeInsets.only(bottom: isLast ? 8 : 12),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Column(
            crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => _openMedia(mediaUrl, imageBase64, 'image'),
                child: WaSingleImage(

                  url: mediaUrl,
                  base64Image: imageBase64,
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _openMedia(mediaUrl, imageBase64, 'image'),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_formatTime(createdAt),
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 10)),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    Icon(
                      isReadByReceiver ? Icons.done_all : Icons.done,
                      size: 14,
                      color: isReadByReceiver
                          ? Colors.blue
                          : Colors.grey,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      key: key,
      padding: EdgeInsets.only(bottom: isLast ? 8 : 12),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: isMe ? () => _showDeleteDialog(msg) : null,
          child: Column(
            crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  gradient: isMe
                      ? LinearGradient(
                      colors: [
                        primaryColor,
                        primaryColor.withOpacity(0.8)
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight)
                      : null,
                  color: isMe
                      ? null
                      : (isDark
                      ? const Color(0xFF1E293B)
                      : Colors.white),
                  borderRadius: BorderRadius.circular(22).copyWith(
                    bottomRight:
                    isMe ? const Radius.circular(4) : null,
                    bottomLeft:
                    !isMe ? const Radius.circular(4) : null,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 5))
                  ],
                ),
                constraints: BoxConstraints(
                    maxWidth:
                    MediaQuery.of(context).size.width * 0.78),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (mediaType == 'video' && mediaUrl != null)
                      GestureDetector(
                        onTap: () =>
                            _openMedia(mediaUrl, null, 'video'),
                        child: Container(
                          height: 150,
                          width: 200,
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius:
                              BorderRadius.circular(18)),
                          child: const Center(
                              child: Icon(
                                  Icons.play_circle_fill_rounded,
                                  size: 50,
                                  color: Colors.white)),
                        ),
                      ),
                    if (mediaType == 'audio' && mediaUrl != null)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                  (_playingUrl == mediaUrl)
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_filled,
                                  color: isMe
                                      ? Colors.white
                                      : primaryColor,
                                  size: 36),
                              onPressed: () async {
                                if (_playingUrl == mediaUrl) {
                                  await _audioPlayer.stop();
                                  setState(
                                          () => _playingUrl = null);
                                } else {
                                  await _audioPlayer
                                      .play(UrlSource(mediaUrl!));
                                  setState(
                                          () => _playingUrl = mediaUrl);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    if (text != null && text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Text(text,
                            style: TextStyle(
                                color: isMe
                                    ? Colors.white
                                    : (isDark
                                    ? Colors.white
                                    : Colors.black87),
                                fontSize: 15,
                                height: 1.4)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_formatTime(createdAt),
                      style: const TextStyle(
                          color: Colors.grey, fontSize: 10)),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    Icon(
                      isReadByReceiver ? Icons.done_all : Icons.done,
                      size: 14,
                      color: isReadByReceiver
                          ? Colors.blue
                          : Colors.grey,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Input bar ──────────────────────────────────────────────────────────────

  Widget _buildInputBar(bool isDark, Color primaryColor) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 5),
      child: _isRecording
          ? _buildRecordingUI(primaryColor)
          : _buildNormalInputUI(isDark, primaryColor),
    );
  }

  Widget _buildNormalInputUI(bool isDark, Color primaryColor) {
    return Container(
      margin: const EdgeInsets.only(bottom: 25),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
                color: primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(15)),
            child: IconButton(
                icon: Icon(Icons.add_rounded, color: primaryColor),
                onPressed: _showAttachmentMenu),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF334155)
                    : Colors.black12,
                borderRadius: BorderRadius.circular(20),
              ),
              child: TextField(
                controller: _messageController,
                style: TextStyle(
                    color: isDark ? Colors.white : Colors.black),
                onChanged: (v) => setState(() {}),
                decoration: const InputDecoration(
                    hintText: "Write a message...",
                    hintStyle:
                    TextStyle(color: Colors.grey, fontSize: 14),
                    border: InputBorder.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onLongPress: _startRecording,
            onLongPressUp: _stopRecording,
            child: Container(
              height: 48,
              width: 48,
              decoration: BoxDecoration(
                  color: primaryColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: primaryColor.withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4))
                  ]),
              child: IconButton(
                icon: Icon(
                    _messageController.text.isEmpty
                        ? Icons.mic_rounded
                        : Icons.send_rounded,
                    color: Colors.white,
                    size: 22),
                onPressed: () {
                  if (_messageController.text.isNotEmpty) {
                    _sendMessage();
                  } else {
                    _startRecording();
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingUI(Color primaryColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.05),
          borderRadius: BorderRadius.circular(30)),
      child: Row(
        children: [
          const Icon(Icons.mic, color: Colors.red),
          const SizedBox(width: 10),
          const Text("Recording...",
              style: TextStyle(
                  color: Colors.red, fontWeight: FontWeight.bold)),
          const Spacer(),
          IconButton(
              icon: const Icon(Icons.close, color: Colors.grey),
              onPressed: _cancelRecording),
          const SizedBox(width: 10),
          IconButton(
              icon: const Icon(Icons.stop,
                  color: Colors.green, size: 30),
              onPressed: _stopRecording),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Shared widgets
// ══════════════════════════════════════════════════════════════════════════════

// ── WaSingleImage ─────────────────────────────────────────────────────────────
/// Renders a single image at its natural aspect ratio (max 250 wide).
class WaSingleImage extends StatefulWidget {
  final double width;
  final double height;
  final String? url;
  final String? base64Image;
  final BorderRadius borderRadius;
  final VoidCallback onTap;

  const WaSingleImage({
    super.key,
    this.width = 80,
    this.height = 80,

    this.url,
    this.base64Image,
    required this.borderRadius,
    required this.onTap,
  });

  @override
  State<WaSingleImage> createState() => _WaSingleImageState();
}

class _WaSingleImageState extends State<WaSingleImage> {
  double? _aspectRatio;

  @override
  void initState() {
    super.initState();
    _resolveAspectRatio();
  }

  @override
  void didUpdateWidget(WaSingleImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.base64Image != oldWidget.base64Image ||
        widget.url != oldWidget.url) {
      _resolveAspectRatio();
    }
  }

  void _resolveAspectRatio() {
    ImageProvider? provider;
    if (widget.base64Image != null && widget.base64Image!.isNotEmpty) {
      try {
        provider = MemoryImage(base64Decode(widget.base64Image!));
      } catch (_) {}
    }
    provider ??= widget.url != null ? NetworkImage(widget.url!) : null;
    if (provider == null) return;

    final stream = provider.resolve(ImageConfiguration.empty);
    stream.addListener(ImageStreamListener((info, _) {
      if (mounted) {
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (h > 0) setState(() => _aspectRatio = w / h);
      }
    }, onError: (_, __) {}));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 120,
        height: 120,
        child: ClipRRect(
          borderRadius: widget.borderRadius,
          child: ChatImage(
            imageBase64: widget.base64Image,
            mediaUrl: widget.url,
          ),
        ),
      ),
    );
  }
}

// ── WaTwoUp ───────────────────────────────────────────────────────────────────
/// Two images side-by-side with equal width.
class WaTwoUp extends StatelessWidget {
  final Widget left;
  final Widget right;

  const WaTwoUp({super.key, required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: left),
          const SizedBox(width: 2),
          Expanded(child: right),
        ],
      ),
    );
  }
}

// ── WaThreeUp ─────────────────────────────────────────────────────────────────
/// One large image on top; two equal images below.
class WaThreeUp extends StatelessWidget {
  final Widget top;
  final Widget bottomLeft;
  final Widget bottomRight;

  const WaThreeUp({
    super.key,
    required this.top,
    required this.bottomLeft,
    required this.bottomRight,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(aspectRatio: 16 / 9, child: top),
        const SizedBox(height: 2),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: bottomLeft),
              const SizedBox(width: 2),
              Expanded(child: bottomRight),
            ],
          ),
        ),
      ],
    );
  }
}

// ── WaImageCell ───────────────────────────────────────────────────────────────
/// Square tile used inside multi-image grids with optional "+N" overlay.
class WaImageCell extends StatelessWidget {
  final String? url;
  final String? base64Image;
  final BorderRadius borderRadius;
  final int overflowCount;
  final VoidCallback onTap;

  const WaImageCell({
    super.key,
    this.url,
    this.base64Image,
    required this.borderRadius,
    required this.onTap,
    this.overflowCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: AspectRatio(
          aspectRatio: 1.0,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ChatImage(imageBase64: base64Image, mediaUrl: url),
              if (overflowCount > 0)
                Container(
                  color: Colors.black54,
                  child: Center(
                    child: Text(
                      '+$overflowCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
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

// ── ChatImage ─────────────────────────────────────────────────────────────────
class ChatImage extends StatefulWidget {
  final String? imageBase64;
  final String? mediaUrl;
  const ChatImage({super.key, this.imageBase64, this.mediaUrl});

  @override
  State<ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends State<ChatImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(ChatImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageBase64 != oldWidget.imageBase64) _decode();
  }

  void _decode() {
    if (widget.imageBase64 != null && widget.imageBase64!.isNotEmpty) {
      try {
        setState(() => _bytes = base64Decode(widget.imageBase64!));
      } catch (_) {
        _bytes = null;
      }
    } else {
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true);
    } else if (widget.mediaUrl != null) {
      return Image.network(widget.mediaUrl!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
          const Icon(Icons.broken_image, color: Colors.grey));
    }
    return const SizedBox.shrink();
  }
}

// ── FullscreenMediaViewer ─────────────────────────────────────────────────────
class FullscreenMediaViewer extends StatelessWidget {
  final String? url;
  final String? base64Image;
  final String type;

  const FullscreenMediaViewer(
      {super.key, this.url, this.base64Image, required this.type});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white)),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: type == 'image'
              ? (base64Image != null && base64Image!.isNotEmpty
              ? Image.memory(base64Decode(base64Image!),
              gaplessPlayback: true)
              : Image.network(url!,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return const CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2);
              }))
              : _VideoViewer(url: url!),
        ),
      ),
    );
  }
}

// ── _VideoViewer ──────────────────────────────────────────────────────────────
class _VideoViewer extends StatefulWidget {
  final String url;
  const _VideoViewer({required this.url});

  @override
  State<_VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<_VideoViewer> {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _videoPlayerController =
        VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _videoPlayerController.initialize().then((_) {
      setState(() {
        _chewieController = ChewieController(
          videoPlayerController: _videoPlayerController,
          autoPlay: true,
          looping: false,
          aspectRatio: _videoPlayerController.value.aspectRatio,
          allowFullScreen: true,
          showControls: true,
          materialProgressColors: ChewieProgressColors(
              playedColor: const Color(0xFF6366F1),
              bufferedColor: Colors.white24),
        );
      });
    });
  }

  @override
  void dispose() {
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _chewieController != null &&
        _chewieController!.videoPlayerController.value.isInitialized
        ? Chewie(controller: _chewieController!)
        : const CircularProgressIndicator(
        color: Colors.white, strokeWidth: 2);
  }
}