import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:open_filex/open_filex.dart';
import 'package:intl/intl.dart';

class RoomChatScreen extends StatefulWidget {
  final int roomId;
  final String roomName;
  final String userId;
  final String userName;

  const RoomChatScreen({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.userId,
    required this.userName,
  });

  @override
  State<RoomChatScreen> createState() => _RoomChatScreenState();
}

class _RoomChatScreenState extends State<RoomChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<dynamic> _messages = [];
  Timer? _timer;
  bool _isSending = false;
  final String _baseUrl = "http://52.64.182.123:8080";
  final ImagePicker _picker = ImagePicker();

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isRecording = false;

  String? _playingUrl;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadCachedMessages();
    _fetchMessages();
    _markMessagesAsRead();
    _timer = Timer.periodic(
        const Duration(milliseconds: 500), (timer) => _fetchMessages());

    _audioPlayer.onDurationChanged
        .listen((d) { if (mounted) setState(() => _duration = d); });
    _audioPlayer.onPositionChanged
        .listen((p) { if (mounted) setState(() => _position = p); });
    _audioPlayer.onPlayerComplete.listen((event) {
      if (mounted) setState(() { _playingUrl = null; _position = Duration.zero; });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    _messageController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  String get _cacheKey => "cache_room_${widget.roomId}";

  Future<void> _loadCachedMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedData = prefs.getString(_cacheKey);
      if (cachedData != null && mounted) {
        setState(() {
          _messages = jsonDecode(cachedData);
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint("Error loading room cache: $e");
    }
  }

  Future<void> _saveMessagesToCache(List<dynamic> messages) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(messages));
    } catch (e) {
      debugPrint("Error saving room cache: $e");
    }
  }

  Future<void> _markMessagesAsRead() async {
    try {
      await http.post(
        Uri.parse("$_baseUrl/mark-read"),
        body: jsonEncode({
          "sender_id": widget.userId,
          "room_id": widget.roomId,
        }),
        headers: {"Content-Type": "application/json"},
      );
    } catch (e) {
      debugPrint("Error marking read: $e");
    }
  }

  Future<void> _fetchMessages() async {
    if (_isSending) return; // don't overwrite optimistic message mid-send
    try {
      final response =
      await http.get(Uri.parse("$_baseUrl/chat?room_id=${widget.roomId}"));
      if (response.statusCode == 200 && mounted) {
        final newMessages = jsonDecode(response.body) as List;
        if (jsonEncode(_messages) != jsonEncode(newMessages)) {
          setState(() { _messages = newMessages; });
          _scrollToBottom();
          _saveMessagesToCache(newMessages);
          bool hasNewIncoming = newMessages
              .any((m) => m['sender_id'] != widget.userId && m['is_read'] != true);
          if (hasNewIncoming) _markMessagesAsRead();
        }
      }
    } catch (e) {
      debugPrint("Error fetching messages: $e");
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _pickImage() async {
    final XFile? image =
    await _picker.pickImage(source: ImageSource.gallery, imageQuality: 50);
    if (image != null) {
      final bytes = await File(image.path).readAsBytes();
      final base64Image = base64Encode(bytes);
      await _sendMessage(imageBase64: base64Image, mediaType: 'image');
    }
  }

  Future<void> _pickVideo() async {
    final XFile? video =
    await _picker.pickVideo(source: ImageSource.gallery);
    if (video != null) _uploadMedia(File(video.path), 'video');
  }

  Future<void> _pickDocument() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null) _uploadMedia(File(result.files.single.path!), 'document');
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
      request.files.add(await http.MultipartFile.fromPath('file', file.path));
      var response = await request.send();
      if (response.statusCode == 200) {
        var responseData = await response.stream.bytesToString();
        var jsonResponse = jsonDecode(responseData);
        _sendMessage(mediaUrl: jsonResponse['url'], mediaType: type);
      }
    } catch (e) {
      debugPrint("Error uploading $type: $e");
    }
  }

  Future<void> _sendMessage(
      {String? imageBase64, String? mediaUrl, String? mediaType}) async {
    final text = _messageController.text.trim();
    if (text.isEmpty &&
        (imageBase64 == null || imageBase64.isEmpty) &&
        mediaUrl == null) return;
    if (_isSending) return;

    setState(() => _isSending = true);
    if (imageBase64 == null && mediaUrl == null) _messageController.clear();

    try {
      setState(() {
        _messages.add({
          "id": DateTime.now().millisecondsSinceEpoch,
          "room_id": widget.roomId,
          "sender_id": widget.userId,
          "sender_name": widget.userName,
          "text": text,
          "image_base64": imageBase64,
          "media_url": mediaUrl,
          "media_type": mediaType,
          "created_at": DateTime.now().toIso8601String(),
          "is_read": false,
        });
      });

      _scrollToBottom();
      final response = await http.post(
        Uri.parse("$_baseUrl/chat"),
        body: jsonEncode({
          "room_id": widget.roomId,
          "sender_id": widget.userId,
          "text": text,
          "image_base64": imageBase64,
          "media_url": mediaUrl,
          "media_type": mediaType,
        }),
        headers: {"Content-Type": "application/json"},
      );
    } catch (e) {
      debugPrint("Error sending message: $e");
    } finally {
      if (mounted) setState(() => _isSending = false);
      _fetchMessages();
    }
  }

  void _showDeleteDialog(dynamic msgId) {
    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: AlertDialog(
          backgroundColor: Colors.white.withOpacity(0.9),
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text("Delete Message?"),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel")),
            TextButton(
              onPressed: () {
                _deleteMessage(msgId);
                Navigator.pop(context);
              },
              child:
              const Text("Delete", style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMessage(dynamic msgId) async {
    try {
      final response = await http.delete(
          Uri.parse("$_baseUrl/chat?id=$msgId&sender_id=${widget.userId}"));
      if (response.statusCode == 200) _fetchMessages();
    } catch (e) {
      debugPrint("Error deleting message: $e");
    }
  }

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 20)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildActionItem(
                    Icons.image_rounded, "Gallery", Colors.purple, _pickImage),
                _buildActionItem(
                    Icons.videocam_rounded, "Video", Colors.orange, _pickVideo),
                _buildActionItem(Icons.insert_drive_file_rounded, "Document",
                    Colors.blue, _pickDocument),
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

  /// Returns true if message at [index] is the first of a new day.
  bool _showDateSeparator(int index) {
    final current = _parseLocal(_messages[index]['created_at']);
    if (current == null) return false;
    if (index == 0) return true;
    final previous = _parseLocal(_messages[index - 1]['created_at']);
    if (previous == null) return true;
    return !_sameDay(current, previous);
  }

  // ── Date separator widget ──────────────────────────────────────────────────

  Widget _buildDateSeparator(String label, bool isDark) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
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
    final accentColor = const Color(0xFF007AFF);
    final bgColor =
    isDark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);

    return Scaffold(
      backgroundColor: bgColor,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: AppBar(
              backgroundColor: isDark
                  ? Colors.black.withOpacity(0.5)
                  : Colors.white.withOpacity(0.7),
              elevation: 0,
              iconTheme: IconThemeData(
                  color: isDark ? Colors.white : Colors.black),
              title: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    child: Text(widget.roomName[0].toUpperCase(),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.roomName,
                            style: TextStyle(
                                color:
                                isDark ? Colors.white : Colors.black,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        const Text("Group",
                            style: TextStyle(
                                color: Colors.grey, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                IconButton(
                    icon: const Icon(Icons.info_outline_rounded),
                    onPressed: () {}),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 100, 16, 100),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                bool isMe = msg['sender_id'] == widget.userId;
                String senderName = msg['sender_name'] ?? 'Unknown';
                String? senderPhoto = msg['sender_photo'];
                String? mediaUrl = msg['media_url'];
                if (mediaUrl != null && !mediaUrl.startsWith('http'))
                  mediaUrl = "$_baseUrl$mediaUrl";

                final showSep = _showDateSeparator(index);
                final sepLabel = showSep
                    ? _dateLabel(
                    _parseLocal(msg['created_at']) ?? DateTime.now())
                    : null;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showSep && sepLabel != null)
                      _buildDateSeparator(sepLabel, isDark),
                    _buildMessageBubble(msg, isMe, senderName,
                        senderPhoto, mediaUrl, isDark, accentColor),
                  ],
                );
              },
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _buildInputBar(isDark, accentColor),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(dynamic msg, bool isMe, String senderName,
      String? senderPhoto, String? mediaUrl, bool isDark, Color accentColor) {
    String? imageBase64 = msg['image_base64'];
    String? mediaType = msg['media_type'];
    String? text = msg['text'];
    String? createdAt = msg['created_at'];
    bool isRead = msg['is_read'] == true;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: GestureDetector(
          onLongPress: isMe ? () => _showDeleteDialog(msg['id']) : null,
          child: Column(
            crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 10,
                        backgroundImage:
                        senderPhoto != null && senderPhoto.isNotEmpty
                            ? NetworkImage(senderPhoto)
                            : null,
                        child: senderPhoto == null || senderPhoto.isEmpty
                            ? Text(senderName[0].toUpperCase(),
                            style: const TextStyle(fontSize: 8))
                            : null,
                      ),
                      const SizedBox(width: 4),
                      Text(senderName,
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: accentColor.withOpacity(0.8),
                              fontSize: 11)),
                    ],
                  ),
                ),
              Container(
                decoration: BoxDecoration(
                  color: isMe
                      ? accentColor
                      : (isDark
                      ? const Color(0xFF1C1C1E)
                      : Colors.white),
                  borderRadius: BorderRadius.circular(20).copyWith(
                    bottomRight:
                    isMe ? const Radius.circular(4) : null,
                    bottomLeft:
                    !isMe ? const Radius.circular(4) : null,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 5))
                  ],
                ),
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.75),
                padding: const EdgeInsets.all(4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ((imageBase64 != null && imageBase64.isNotEmpty) ||
                        (mediaType == 'image' && mediaUrl != null))
                      GestureDetector(
                        onTap: () =>
                            _openMedia(mediaUrl, imageBase64, 'image'),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            constraints: const BoxConstraints(
                                maxHeight: 250, maxWidth: 250),
                            child: imageBase64 != null &&
                                imageBase64.isNotEmpty
                                ? Image.memory(base64Decode(imageBase64),
                                fit: BoxFit.cover)
                                : Image.network(mediaUrl!,
                                fit: BoxFit.cover),
                          ),
                        ),
                      ),
                    if (mediaType == 'video' && mediaUrl != null)
                      GestureDetector(
                        onTap: () => _openMedia(mediaUrl, null, 'video'),
                        child: Container(
                          height: 180,
                          width: 250,
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.8),
                              borderRadius: BorderRadius.circular(16)),
                          child: const Center(
                              child: Icon(
                                  Icons.play_circle_fill_rounded,
                                  size: 50,
                                  color: Colors.white)),
                        ),
                      ),
                    if (mediaType == 'audio' && mediaUrl != null)
                      IconButton(
                        icon: Icon(
                            (_playingUrl == mediaUrl)
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_filled,
                            color: isMe ? Colors.white : accentColor,
                            size: 36),
                        onPressed: () async {
                          if (_playingUrl == mediaUrl) {
                            await _audioPlayer.stop();
                            setState(() => _playingUrl = null);
                          } else {
                            await _audioPlayer
                                .play(UrlSource(mediaUrl!));
                            setState(() => _playingUrl = mediaUrl);
                          }
                        },
                      ),
                    if (mediaType == 'document' && mediaUrl != null)
                      InkWell(
                        onTap: () => OpenFilex.open(mediaUrl!),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                              color: isMe
                                  ? Colors.white12
                                  : Colors.black.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(16)),
                          child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.insert_drive_file_rounded,
                                    color: isMe
                                        ? Colors.white
                                        : accentColor),
                                const SizedBox(width: 10),
                                const Flexible(
                                    child: Text("Document",
                                        style: TextStyle(
                                            fontWeight:
                                            FontWeight.bold))),
                              ]),
                        ),
                      ),
                    if (text != null && text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Text(text,
                            style: TextStyle(
                                color: isMe
                                    ? Colors.white
                                    : (isDark
                                    ? Colors.white
                                    : Colors.black87),
                                fontSize: 15)),
                      ),
                  ],
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
                      isRead
                          ? Icons.done_all_rounded
                          : Icons.done_rounded,
                      size: 14,
                      color: isRead ? accentColor : Colors.grey,
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

  Widget _buildInputBar(bool isDark, Color accentColor) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1C1C1E).withOpacity(0.9)
            : Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              offset: const Offset(0, 5))
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: _isRecording
                ? _buildRecordingBar(accentColor)
                : _buildNormalInputBar(isDark, accentColor),
          ),
        ),
      ),
    );
  }

  Widget _buildNormalInputBar(bool isDark, Color accentColor) {
    return Row(
      children: [
        IconButton(
            icon: Icon(Icons.add_circle_outline_rounded,
                color: accentColor, size: 28),
            onPressed: _showAttachmentMenu),
        Expanded(
          child: TextField(
            controller: _messageController,
            onChanged: (v) => setState(() {}),
            style:
            TextStyle(color: isDark ? Colors.white : Colors.black),
            decoration: const InputDecoration(
                hintText: "Message...",
                border: InputBorder.none,
                contentPadding:
                EdgeInsets.symmetric(horizontal: 10)),
          ),
        ),
        GestureDetector(
          onLongPress: _startRecording,
          onLongPressUp: _stopRecording,
          child: CircleAvatar(
            backgroundColor: accentColor,
            radius: 22,
            child: IconButton(
              icon: Icon(
                  _messageController.text.isEmpty
                      ? Icons.mic_rounded
                      : Icons.send_rounded,
                  color: Colors.white,
                  size: 20),
              onPressed: () => _messageController.text.isNotEmpty
                  ? _sendMessage()
                  : _startRecording(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecordingBar(Color accentColor) {
    return Row(
      children: [
        const SizedBox(width: 10),
        const Icon(Icons.mic, color: Colors.red),
        const SizedBox(width: 8),
        const Text("Recording...",
            style: TextStyle(
                color: Colors.red, fontWeight: FontWeight.bold)),
        const Spacer(),
        IconButton(
            icon: const Icon(Icons.close, color: Colors.grey),
            onPressed: _cancelRecording),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _stopRecording,
          child: CircleAvatar(
            backgroundColor: Colors.green,
            radius: 20,
            child:
            const Icon(Icons.stop, color: Colors.white, size: 20),
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

// ── Shared widgets ─────────────────────────────────────────────────────────────

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
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: type == 'image'
              ? (base64Image != null && base64Image!.isNotEmpty
              ? Image.memory(base64Decode(base64Image!))
              : Image.network(url!))
              : _VideoViewer(url: url!),
        ),
      ),
    );
  }
}

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
              playedColor: const Color(0xFF007AFF),
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
        _chewieController!
            .videoPlayerController.value.isInitialized
        ? Chewie(controller: _chewieController!)
        : const CircularProgressIndicator(color: Colors.white);
  }
}