import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';

class ChatScreen extends StatefulWidget {
  final String senderId;
  final String receiverId;
  final String receiverName;
  final VoidCallback onComplete;

  const ChatScreen({
    super.key,
    required this.senderId,
    required this.receiverId,
    required this.receiverName,
    required this.onComplete,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
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

  @override
  void initState() {
    super.initState();
    _fetchMessages();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (timer) => _fetchMessages());
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

  Future<void> _fetchMessages() async {
    if (_isSending) return; // don't overwrite optimistic message mid-send
    try {
      final response = await http.get(Uri.parse(
          "$_baseUrl/chat?sender_id=${widget.senderId}&receiver_id=${widget.receiverId}"));
      if (response.statusCode == 200 && mounted) {
        final newMessages = jsonDecode(response.body);
        if (jsonEncode(_messages) != jsonEncode(newMessages)) {
          setState(() {
            _messages = newMessages;
          });
          _scrollToBottom();
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
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      final bytes = await File(image.path).readAsBytes();
      final base64Image = base64Encode(bytes);
      _sendMessage(imageBase64: base64Image);
    }
  }

  Future<void> _pickVideo() async {
    final XFile? video = await _picker.pickVideo(source: ImageSource.gallery);
    if (video != null) {
      _uploadMedia(File(video.path), 'video');
    }
  }

  Future<void> _pickDocument() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null) {
      _uploadMedia(File(result.files.single.path!), 'document');
    }
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final directory = await getApplicationDocumentsDirectory();
        final path = '${directory.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
        const config = RecordConfig();
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
      if (path != null) {
        _uploadMedia(File(path), 'audio');
      }
    } catch (e) {
      debugPrint("Error stopping recording: $e");
    }
  }

  Future<void> _uploadMedia(File file, String type) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse("$_baseUrl/upload-media"));
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

  Future<void> _sendMessage({String? text, String? imageBase64, String? mediaUrl, String? mediaType}) async {
    if (text == null && imageBase64 == null && mediaUrl == null && _messageController.text.isEmpty) return;
    final messageText = text ?? _messageController.text;
    if (text == null && imageBase64 == null && mediaUrl == null) _messageController.clear();

    setState(() {
      _isSending = true;
      _messages.add({
        "id": DateTime.now().millisecondsSinceEpoch,
        "sender_id": widget.senderId,
        "receiver_id": widget.receiverId,
        "text": messageText,
        "image_base64": imageBase64,
        "media_url": mediaUrl,
        "media_type": mediaType,
        "created_at": DateTime.now().toIso8601String(),
      });
    });

    _scrollToBottom();

    try {
      await http.post(
        Uri.parse("$_baseUrl/chat"),
        body: jsonEncode({
          "room_id": 0,
          "sender_id": widget.senderId,
          "receiver_id": widget.receiverId,
          "text": messageText,
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
      // Now safe to fetch — optimistic message will be replaced by real one
      _fetchMessages();
    }
  }

  Future<void> _deleteMessage(dynamic msgId) async {
    try {
      final response = await http.delete(
        Uri.parse("$_baseUrl/chat?id=$msgId&sender_id=${widget.senderId}"),
      );
      if (response.statusCode == 200) {
        _fetchMessages();
      }
    } catch (e) {
      debugPrint("Error deleting message: $e");
    }
  }

  void _showDeleteDialog(dynamic msgId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete Message"),
        content: const Text("Are you sure you want to delete this message?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          TextButton(
            onPressed: () {
              _deleteMessage(msgId);
              Navigator.pop(context);
            },
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showAttachmentOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.image, color: Colors.white),
              title: const Text('Image', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickImage(); },
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.white),
              title: const Text('Video', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickVideo(); },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file, color: Colors.white),
              title: const Text('Document', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickDocument(); },
            ),
          ],
        ),
      ),
    );
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

  /// Returns "Today", "Yesterday", or a formatted date like "10 Jun 2025".
  String _dateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    if (d == today) return "Today";
    if (d == today.subtract(const Duration(days: 1))) return "Yesterday";
    return DateFormat('d MMM yyyy').format(date);
  }

  /// Parses the timestamp string to a local DateTime; returns null on failure.
  DateTime? _parseLocal(String? ts) {
    if (ts == null || ts.isEmpty) return null;
    try {
      return DateTime.parse(ts).toLocal();
    } catch (_) {
      return null;
    }
  }

  /// Returns true if message at [index] should have a date separator above it.
  bool _showDateSeparator(int index) {
    final current = _parseLocal(_messages[index]['created_at']);
    if (current == null) return false;
    if (index == 0) return true; // always show for first message
    final previous = _parseLocal(_messages[index - 1]['created_at']);
    if (previous == null) return true;
    return !_sameDay(current, previous);
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // ── Date separator widget ──────────────────────────────────────────────────

  Widget _buildDateSeparator(String label) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: Text("Chat with ${widget.receiverName}", style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.white10,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              // Each message may also render a date separator, so we count items
              // separately below.
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                bool isMe = msg['sender_id'] == widget.senderId;
                String? imageBase64 = msg['image_base64'];
                String? mediaUrl = msg['media_url'];
                String? mediaType = msg['media_type'];
                String? createdAt = msg['created_at'];

                final showSep = _showDateSeparator(index);
                final dateLabel = showSep
                    ? _dateLabel(_parseLocal(createdAt) ?? DateTime.now())
                    : null;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showSep && dateLabel != null)
                      _buildDateSeparator(dateLabel),
                    Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: GestureDetector(
                        onLongPress: isMe ? () => _showDeleteDialog(msg['id']) : null,
                        child: Column(
                          crossAxisAlignment:
                          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: isMe ? Colors.white : Colors.grey.shade400,
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: isMe
                                      ? const Radius.circular(16)
                                      : Radius.zero,
                                  bottomRight: isMe
                                      ? Radius.zero
                                      : const Radius.circular(16),
                                ),
                              ),
                              constraints: BoxConstraints(
                                  maxWidth: MediaQuery.of(context).size.width * 0.75),
                              child: Column(
                                crossAxisAlignment: isMe
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  if (imageBase64 != null && imageBase64.isNotEmpty)
                                    Padding(
                                      padding:
                                      const EdgeInsets.symmetric(vertical: 4.0),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.memory(base64Decode(imageBase64),
                                            fit: BoxFit.cover),
                                      ),
                                    ),
                                  if (mediaType == 'audio' &&
                                      mediaUrl != null &&
                                      mediaUrl.isNotEmpty)
                                    IconButton(
                                      icon: const Icon(Icons.play_arrow,
                                          color: Colors.blueAccent),
                                      onPressed: () async {
                                        await _audioPlayer.play(UrlSource(mediaUrl));
                                      },
                                    ),
                                  if (mediaType == 'video' &&
                                      mediaUrl != null &&
                                      mediaUrl.isNotEmpty)
                                    IconButton(
                                      icon: const Icon(Icons.video_library,
                                          color: Colors.blueAccent),
                                      onPressed: () async {
                                        final uri = Uri.parse(mediaUrl);
                                        if (await canLaunchUrl(uri))
                                          await launchUrl(uri);
                                      },
                                    ),
                                  if (mediaType == 'document' &&
                                      mediaUrl != null &&
                                      mediaUrl.isNotEmpty)
                                    IconButton(
                                      icon: const Icon(Icons.description,
                                          color: Colors.blueAccent),
                                      onPressed: () async {
                                        final uri = Uri.parse(mediaUrl);
                                        if (await canLaunchUrl(uri))
                                          await launchUrl(uri);
                                      },
                                    ),
                                  if (msg['text'] != null &&
                                      msg['text'].toString().isNotEmpty)
                                    Text(
                                      msg['text'] ?? '',
                                      style: const TextStyle(
                                          color: Colors.black, fontSize: 15),
                                    ),
                                  if (createdAt != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        _formatTime(createdAt),
                                        style: TextStyle(
                                            color: Colors.black.withOpacity(0.5),
                                            fontSize: 10),
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
                );
              },
            ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(color: Colors.white10),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.folder, color: Colors.white70),
              onPressed: _showAttachmentOptions,
            ),
            IconButton(
              icon: Icon(_isRecording ? Icons.stop : Icons.mic,
                  color: _isRecording ? Colors.red : Colors.white70),
              onPressed: _isRecording ? _stopRecording : _startRecording,
            ),
            Expanded(
              child: TextField(
                controller: _messageController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: "Message...",
                  hintStyle: const TextStyle(color: Colors.white54),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.05),
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send, color: Colors.blueAccent),
              onPressed: () => _sendMessage(),
            ),
          ],
        ),
      ),
    );
  }
}