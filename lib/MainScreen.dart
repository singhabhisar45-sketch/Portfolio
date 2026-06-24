import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'PrivateChatScreen.dart';
import 'RoomChatScreen.dart';
import 'Signinscreen.dart';
import 'main.dart';
import 'package:intl/intl.dart';

class MainScreen extends StatefulWidget {
  final String userName;
  const MainScreen({super.key, required this.userName});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  final String _baseUrl = "http://52.64.182.123:8080";
  final ImagePicker _picker = ImagePicker();
  
  List<dynamic> users = [];
  List<dynamic> workItems = [];
  List<dynamic> chatRooms = [];
  List<dynamic> broadcasts = [];
  final Map<int, Uint8List> _broadcastImageCache = {};
  Map<String, bool> onlineStatus = {};
  Timer? _fetchTimer;
  Timer? _heartbeatTimer;

  String? _currentUserPhotoUrl;

  @override
  void initState() {
    super.initState();
    _loadAllCache();
    _initialFetch();
    _checkUpdate();
    WidgetsBinding.instance.addObserver(this);
    _sendHeartbeat();
    _startHeartbeat();

    _fetchTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _fetchAllData();
    });
  }

  Future<void> _loadAllCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final cachedUsers = prefs.getString('cache_users');
      if (cachedUsers != null && mounted) {
        setState(() {
          users = jsonDecode(cachedUsers);
          onlineStatus = {for (var u in users) u['id'] as String: u['is_online'] as bool};
          final currentUser = users.firstWhere((u) => u['id'] == widget.userName, orElse: () => null);
          if (currentUser != null) _currentUserPhotoUrl = currentUser['photo_url'];
        });
      }

      final cachedRooms = prefs.getString('cache_rooms');
      if (cachedRooms != null && mounted) setState(() => chatRooms = jsonDecode(cachedRooms));

      final cachedWork = prefs.getString('cache_work');
      if (cachedWork != null && mounted) setState(() => workItems = jsonDecode(cachedWork));

      final cachedBroadcasts = prefs.getString('cache_broadcasts');
      if (cachedBroadcasts != null && mounted) setState(() => broadcasts = jsonDecode(cachedBroadcasts));
    } catch (e) {
      debugPrint("Error loading main cache: $e");
    }
  }

  void _initialFetch() {
    _fetchAllData();
  }

  void _fetchAllData() {
    _fetchUsers();
    _fetchWorkItems();
    _fetchRooms();
    _fetchBroadcasts(notify: true);
    _fetchPrivateMessages(notify: true);
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) => _sendHeartbeat());
  }

  Future<void> _sendHeartbeat() async {
    try {
      await http.post(
        Uri.parse("$_baseUrl/heartbeat"),
        body: jsonEncode({"username": widget.userName}),
        headers: {"Content-Type": "application/json"},
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> _markOffline() async {
    try {
      await http.post(
        Uri.parse("$_baseUrl/logout"),
        body: jsonEncode({"username": widget.userName}),
        headers: {"Content-Type": "application/json"},
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sendHeartbeat();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _markOffline();
    }
  }

  @override
  void dispose() {
    _markOffline();
    _fetchTimer?.cancel();
    _heartbeatTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _fetchUsers() async {
    try {
      final response = await http.get(Uri.parse("$_baseUrl/status?user_id=${widget.userName}"));
      if (response.statusCode == 200) {
        if (!mounted) return;
        final List data = jsonDecode(response.body);
        if (jsonEncode(users) != jsonEncode(data)) {
          setState(() {
            users = data;
            onlineStatus = {for (var u in data) u['id'] as String: u['is_online'] as bool};
            
            final currentUser = users.firstWhere((u) => u['id'] == widget.userName, orElse: () => null);
            if (currentUser != null) {
              _currentUserPhotoUrl = currentUser['photo_url'];
            }
          });
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('cache_users', response.body);
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchWorkItems() async {
    try {
      final response = await http.get(Uri.parse("$_baseUrl/work"));
      if (response.statusCode == 200) {
        if (!mounted) return;
        final List data = jsonDecode(response.body);
        if (jsonEncode(workItems) != jsonEncode(data)) {
          setState(() => workItems = data);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('cache_work', response.body);
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchRooms() async {
    try {
      final response = await http.get(Uri.parse("$_baseUrl/rooms?user_id=${widget.userName}"));
      if (response.statusCode == 200) {
        if (!mounted) return;
        final List data = jsonDecode(response.body);
        if (jsonEncode(chatRooms) != jsonEncode(data)) {
          setState(() => chatRooms = data);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('cache_rooms', response.body);
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchBroadcasts({bool notify = false}) async {
    try {
      final response = await http.get(Uri.parse("$_baseUrl/broadcast"));
      if (response.statusCode == 200) {
        List data = jsonDecode(response.body);
        if (data.isNotEmpty) {
          int latestId = data[0]['id'];
          SharedPreferences prefs = await SharedPreferences.getInstance();
          int lastSeenId = prefs.getInt('last_broadcast_id') ?? 0;
          if (notify && latestId > lastSeenId) {
            _showNotification("New Broadcast", data[0]['text']);
            await prefs.setInt('last_broadcast_id', latestId);
          }
        }
        if (!mounted) return;
        if (jsonEncode(broadcasts) != jsonEncode(data)) {
          setState(() => broadcasts = data);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('cache_broadcasts', response.body);
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchPrivateMessages({bool notify = false}) async {
    try {
      final response = await http.get(Uri.parse("$_baseUrl/chat?receiver_id=${widget.userName}"));
      if (response.statusCode == 200) {
        List data = jsonDecode(response.body);
        SharedPreferences prefs = await SharedPreferences.getInstance();
        int lastCount = prefs.getInt('last_msg_count_${widget.userName}') ?? -1;
        if (notify && lastCount != -1 && data.length > lastCount) {
          var lastMsg = data.last;
          _showNotification("New Message from ${lastMsg['sender_name']}", lastMsg['text'] ?? "Media received");
        }
        await prefs.setInt('last_msg_count_${widget.userName}', data.length);
      }
    } catch (_) {}
  }

  Future<void> _showNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'tds_channel',
      'TDS Notifications',
      importance: Importance.max,
      priority: Priority.high,
    );
    await flutterLocalNotificationsPlugin.show(
      Random().nextInt(100000),
      title,
      body,
      const NotificationDetails(android: androidDetails),
    );
  }

  Future<void> _checkUpdate() async {
    try {
      final response = await http.get(Uri.parse("$_baseUrl/version"));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        PackageInfo packageInfo = await PackageInfo.fromPlatform();
        if (data['version'] != packageInfo.version) {
          _showUpdateDialog(
            data['title'] ?? "Update Available",
            data['content'] ?? "A new version is available.",
            data['download_url'],
          );
        }
      }
    } catch (_) {}
  }

  void _showUpdateDialog(String title, String content, String url) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          elevation: 0,
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              shape: BoxShape.rectangle,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 10))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update_alt, size: 60, color: Color(0xFFEBB44D)),
                const SizedBox(height: 15),
                Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                const SizedBox(height: 15),
                Text(content, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: isDark ? Colors.white70 : Colors.black87)),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text("Later", style: TextStyle(color: isDark ? Colors.white38 : Colors.grey, fontSize: 16)),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _downloadUpdate(url);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEBB44D),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                      child: const Text("Update Now", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _downloadUpdate(String url) async {
    final CancelToken cancelToken = CancelToken();
    final ValueNotifier<double?> progressNotifier = ValueNotifier<double?>(null);
    final ValueNotifier<String> statusNotifier = ValueNotifier<String>("Connecting...");
    final ValueNotifier<String> speedNotifier = ValueNotifier<String>("");
    
    final Stopwatch stopwatch = Stopwatch()..start();
    int lastDownloaded = 0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          title: const Text("System Update", textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              ValueListenableBuilder<double?>(
                valueListenable: progressNotifier,
                builder: (context, value, child) {
                  return Column(
                    children: [
                      LinearProgressIndicator(
                        value: value,
                        backgroundColor: isDark ? Colors.white10 : Colors.grey[200],
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFEBB44D)),
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        value == null ? "Downloading..." : "${(value * 100).toStringAsFixed(1)}%",
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: statusNotifier,
                builder: (context, status, child) => Text(
                  status,
                  style: TextStyle(
                    color: isDark ? Colors.white60 : Colors.black54,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              ValueListenableBuilder<String>(
                valueListenable: speedNotifier,
                builder: (context, speed, child) => speed.isEmpty ? const SizedBox.shrink() : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(speed, style: const TextStyle(color: Color(0xFFEBB44D), fontSize: 12, fontWeight: FontWeight.w500)),
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextButton(
                onPressed: () {
                  cancelToken.cancel();
                  Navigator.pop(context);
                },
                child: const Text("CANCEL", style: TextStyle(color: Colors.red, fontSize: 14, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        );
      },
    );

    try {
      if (Platform.isAndroid) {
        var status = await Permission.requestInstallPackages.status;
        if (!status.isGranted) {
          status = await Permission.requestInstallPackages.request();
          if (!status.isGranted) {
            if (mounted) Navigator.pop(context);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text("Install permission is required to update."),
                backgroundColor: Colors.redAccent,
              ));
            }
            return;
          }
        }
      }

      final directory = await getTemporaryDirectory();
      final filePath = "${directory.path}/update.apk";
      
      final file = File(filePath);
      if (await file.exists()) await file.delete();

      await Dio().download(
        url,
        filePath,
        cancelToken: cancelToken,
        options: Options(
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(minutes: 5),
        ),
        onReceiveProgress: (count, total) {
          if (total > 0) {
            progressNotifier.value = count / total;
            statusNotifier.value = "${(count / (1024 * 1024)).toStringAsFixed(2)} MB / ${(total / (1024 * 1024)).toStringAsFixed(2)} MB";
          } else {
            progressNotifier.value = null;
            statusNotifier.value = "${(count / (1024 * 1024)).toStringAsFixed(2)} MB downloaded";
          }
          
          if (stopwatch.elapsedMilliseconds > 500) {
            double speed = (count - lastDownloaded) / (stopwatch.elapsedMilliseconds / 1000.0) / 1024.0; // KB/s
            if (speed > 1024) {
              speedNotifier.value = "${(speed / 1024.0).toStringAsFixed(1)} MB/s";
            } else {
              speedNotifier.value = "${speed.toStringAsFixed(0)} KB/s";
            }
            lastDownloaded = count;
            stopwatch.reset();
            stopwatch.start();
          }
        },
      );
      
      if (mounted) Navigator.pop(context);

      if (await file.exists()) {
        final result = await OpenFilex.open(
          filePath,
          type: "application/vnd.android.package-archive",
        );

        debugPrint("OPEN RESULT: ${result.type}");
        debugPrint("OPEN MESSAGE: ${result.message}");

        if (result.type != ResultType.done) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text("Could not open installer: ${result.message}"),
              backgroundColor: Colors.redAccent,
              ));
          }
        }
      } else {
        throw Exception("Downloaded file not found.");
      }
    } catch (e) {
      if (mounted && !cancelToken.isCancelled) {
        if (Navigator.canPop(context)) Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Download Error: ${e.toString()}"),
          backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      stopwatch.stop();
    }
  }

  Future<void> _uploadProfilePhoto() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 50);
    if (image != null) {
      try {
        var request = http.MultipartRequest('POST', Uri.parse("$_baseUrl/upload-photo"));
        request.fields['username'] = widget.userName;
        request.files.add(await http.MultipartFile.fromPath('photo', image.path));
        
        var response = await request.send();
        if (response.statusCode == 200) {
          var responseData = await response.stream.bytesToString();
          var jsonResponse = jsonDecode(responseData);
          setState(() {
            _currentUserPhotoUrl = jsonResponse['photo_url'];
          });
          _fetchUsers();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Profile photo updated!")));
        }
      } catch (e) {
        debugPrint("Error uploading profile photo: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      body: Stack(
        children: [
          SafeArea(child: _pages[_selectedIndex]),
          _buildBottomNavBar(),
        ],
      ),
    );
  }

  Widget _buildBottomNavBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Positioned(
      bottom: 30,
      left: 20,
      right: 20,
      child: Container(
        height: 70,
        decoration: BoxDecoration(
          color: isDark ? Colors.grey[900] : Colors.white,
          borderRadius: BorderRadius.circular(40),
          boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 20, spreadRadius: 5)],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _navIcon(0, Icons.chat_bubble_outline, Icons.chat_bubble),
            _navIcon(1, Icons.groups_outlined, Icons.groups),
            _navIcon(2, Icons.assignment_outlined, Icons.assignment),
            _navIcon(3, Icons.campaign_outlined, Icons.campaign),
            _navIcon(4, Icons.person_outline, Icons.person),
          ],
        ),
      ),
    );
  }

  Widget _navIcon(int index, IconData icon, IconData activeIcon) {
    bool isSelected = _selectedIndex == index;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => setState(() => _selectedIndex = index),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFEBB44D) : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          isSelected ? activeIcon : icon,
          color: isSelected ? Colors.white : (isDark ? Colors.white38 : Colors.black38),
          size: 26,
        ),
      ),
    );
  }

  List<Widget> get _pages => [
    _buildChatListScreen(),
    _buildWorkspaceScreen(),
    _buildWorkScreen(),
    _buildBroadcastScreen(),
    _buildProfileScreen(),
  ];

  Widget _buildChatListScreen() {
    final otherUsers = users.where((u) => u['id'] != widget.userName).toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text("Message", style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: TextField(
            style: TextStyle(color: isDark ? Colors.white : Colors.black),
            decoration: InputDecoration(
              hintText: "Search here",
              hintStyle: TextStyle(color: isDark ? Colors.white38 : Colors.black26),
              prefixIcon: Icon(Icons.search, color: isDark ? Colors.white38 : Colors.black26),
              filled: true,
              fillColor: isDark ? Colors.grey[900] : const Color(0xFFF8F8F8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
            ),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 100,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: otherUsers.length,
            itemBuilder: (context, index) {
              final u = otherUsers[index];
              bool isOnline = u['is_online'] == true;
              String? photoUrl = u['photo_url'];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 32, 
                          backgroundColor: isDark ? Colors.grey[800] : Colors.grey[200], 
                          backgroundImage: photoUrl != null && photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
                          child: photoUrl == null || photoUrl.isEmpty ? Text(u['display_name'][0], style: const TextStyle(fontSize: 20)) : null,
                        ),
                        if (isOnline)
                          Positioned(right: 2, bottom: 2, child: Container(width: 14, height: 14, decoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle, border: Border.all(color: isDark ? Colors.black : Colors.white, width: 2)))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(u['display_name'], style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  ],
                ),
              );
            },
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 100),
            itemCount: otherUsers.length,
            itemBuilder: (context, index) {
              final u = otherUsers[index];
              String? photoUrl = u['photo_url'];
              String lastMsg = u['last_msg'] ?? "";
              String lastTime = u['last_msg_at'] ?? "";
              return ListTile(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => PrivateChatScreen(senderId: widget.userName, receiverId: u['id'], receiverName: u['display_name'], receiverPhone: u['phone_number'], receiverPhotoUrl: u['photo_url'], onComplete: () {}))),
                contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                leading: CircleAvatar(
                  radius: 30, 
                  backgroundColor: isDark ? Colors.grey[800] : Colors.grey[100], 
                  backgroundImage: photoUrl != null && photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
                  child: photoUrl == null || photoUrl.isEmpty ? Text(u['display_name'][0], style: const TextStyle(fontSize: 22)) : null,
                ),
                title: lastMsg.isEmpty
                    ? Text(
                  u['display_name'],
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                )
                    : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      u['display_name'],
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      lastMsg,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isDark
                            ? Colors.white54
                            : Colors.black54,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildWorkspaceScreen() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Group Workspace", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              IconButton(onPressed: _showAddRoomDialog, icon: const Icon(Icons.add_circle, color: Color(0xFFEBB44D), size: 30)),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 110),
            itemCount: chatRooms.length,
            itemBuilder: (context, index) {
              final room = chatRooms[index];
              final bool canDelete = room['creator'] == widget.userName || widget.userName == 'abhi14905';
              return Card(
                elevation: 0, color: isDark ? Colors.grey[900] : const Color(0xFFF5F5F5),
                margin: const EdgeInsets.only(bottom: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                child: ListTile(
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => RoomChatScreen(roomId: room['id'], roomName: room['name'], userId: widget.userName, userName: widget.userName))),
                  title: Text(room['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("Created by: ${room['creator']}", style: TextStyle(color: isDark ? Colors.white38 : Colors.black54)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (canDelete)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                          onPressed: () => _confirmDeleteRoom(room['id']),
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDeleteRoom(int roomId) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete Group"),
        content: const Text("Are you sure you want to delete this group workspace?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Delete", style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (result == true) {
      try {
        final response = await http.delete(Uri.parse("$_baseUrl/rooms?id=$roomId&requested_by=${widget.userName}"));
        if (response.statusCode == 200) {
          _fetchRooms();
        } else {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Failed to delete room.")));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error connecting to server.")));
      }
    }
  }

  Widget _buildWorkScreen() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Your Work", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              if (widget.userName == 'abhi14905') IconButton(onPressed: _showAddWorkDialog, icon: const Icon(Icons.add_task, color: Color(0xFFEBB44D))),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 110),
            itemCount: workItems.length,
            itemBuilder: (context, index) {
              final item = workItems[index];
              return Card(
                elevation: 0, color: isDark ? Colors.grey[900] : const Color(0xFFF9F9F9),
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                child: ListTile(
                  title: Text(item['title'], style: TextStyle(decoration: item['is_done'] ? TextDecoration.lineThrough : null, fontWeight: FontWeight.bold)),
                  subtitle: Text("Assignee: ${item['assignee']}", style: TextStyle(color: isDark ? Colors.white38 : Colors.black54)),
                  trailing: Checkbox(
                    value: item['is_done'],
                    onChanged: widget.userName == 'abhi14905' ? (v) => _updateWorkStatus(item['id'], v!) : null,
                    activeColor: const Color(0xFFEBB44D),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBroadcastScreen() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Broadcasts", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              if (widget.userName == 'abhi14905') IconButton(onPressed: _showBroadcastDialog, icon: const Icon(Icons.campaign, color: Color(0xFFEBB44D))),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 110),
            itemCount: broadcasts.length,
            itemBuilder: (context, index) {
              final b = broadcasts[index];
              final int bId = b['id'];
              final String? base64String = b['image_base64'];
              final hasImage = base64String != null && base64String.isNotEmpty;
              
              if (hasImage && !_broadcastImageCache.containsKey(bId)) {
                try {
                  _broadcastImageCache[bId] = base64Decode(base64String);
                } catch (_) {}
              }

              return GestureDetector(
                onLongPress: widget.userName == 'abhi14905' ? () => _confirmDeleteBroadcast(bId) : null,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 15),
                  decoration: BoxDecoration(color: isDark ? Colors.grey[900] : Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: isDark ? Colors.white12 : Colors.black12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (hasImage && _broadcastImageCache.containsKey(bId)) 
                        ClipRRect(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)), 
                          child: Image.memory(
                            _broadcastImageCache[bId]!, 
                            width: double.infinity, 
                            height: 180, 
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(b['text'], style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 8),
                            Text(
                              DateFormat('dd MMM yyyy • hh:mm a').format(
                                DateTime.parse(b['created_at']).toLocal(),
                              ),
                              style: TextStyle(
                                color: isDark ? Colors.white38 : Colors.black45,
                                fontSize: 12,
                              ),
                            )
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDeleteBroadcast(int bId) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete Broadcast"),
        content: const Text("Are you sure you want to delete this broadcast?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Delete", style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (result == true) {
      try {
        final response = await http.delete(Uri.parse("$_baseUrl/broadcast?id=$bId&requested_by=${widget.userName}"));
        if (response.statusCode == 200) {
          _fetchBroadcasts();
        } else {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Failed to delete broadcast.")));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error connecting to server.")));
      }
    }
  }

  Widget _buildProfileScreen() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 60, 
                backgroundColor: const Color(0xFFEBB44D), 
                backgroundImage: _currentUserPhotoUrl != null && _currentUserPhotoUrl!.isNotEmpty ? NetworkImage(_currentUserPhotoUrl!) : null,
                child: _currentUserPhotoUrl == null || _currentUserPhotoUrl!.isEmpty ? Text(widget.userName[0].toUpperCase(), style: const TextStyle(fontSize: 50, color: Colors.white)) : null,
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  onTap: _uploadProfilePhoto,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(color: Color(0xFFEBB44D), shape: BoxShape.circle),
                    child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(widget.userName, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 40),
          _profileOption(Icons.photo_library, "Upload Profile Photo", _uploadProfilePhoto),
          _profileOption(
            isDark ? Icons.dark_mode : Icons.light_mode, 
            "Dark Mode", 
            () async {
              themeNotifier.value = isDark ? ThemeMode.light : ThemeMode.dark;
              SharedPreferences prefs = await SharedPreferences.getInstance();
              await prefs.setBool('isDarkMode', !isDark);
            },
            trailing: Switch(
              value: isDark,
              onChanged: (val) async {
                themeNotifier.value = val ? ThemeMode.dark : ThemeMode.light;
                SharedPreferences commissioners = await SharedPreferences.getInstance();
                await commissioners.setBool('isDarkMode', val);
              },
              activeColor: const Color(0xFFEBB44D),
            )
          ),
          if (widget.userName == 'abhi14905')
            _profileOption(Icons.device_hub, "Reset Devices", _showResetDeviceDialog),
          _profileOption(Icons.logout, "Logout", () async {
            SharedPreferences prefs = await SharedPreferences.getInstance();
            await prefs.remove('saved_username');
            await prefs.remove('saved_password');
            await _markOffline();

            await Future.delayed(
              const Duration(milliseconds: 500),
            );

            if (!mounted) return;

            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (context) => const Signinscreen(),
              ),
                  (route) => false,
            );
          }, isDestructive: true),
        ],
      ),
    );
  }

  Widget _profileOption(IconData icon, String label, VoidCallback onTap, {bool isDestructive = false, Widget? trailing}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: isDestructive ? Colors.red : (isDark ? Colors.white : Colors.black)),
      title: Text(label, style: TextStyle(color: isDestructive ? Colors.red : (isDark ? Colors.white : Colors.black), fontWeight: FontWeight.w500)),
      trailing: trailing ?? const Icon(Icons.chevron_right, size: 20),
    );
  }

  void _showAddRoomDialog() {
    TextEditingController nameCtrl = TextEditingController();
    List<String> selectedMembers = [widget.userName];
    final availableUsers = users.where((u) => u['id'] != widget.userName).toList();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text("Create Room"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(hintText: "Room name")),
              const SizedBox(height: 10),
              const Text("Select members:", style: TextStyle(fontSize: 12, color: Colors.grey)),
              SizedBox(
                height: 200,
                width: double.maxFinite,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: availableUsers.length,
                  itemBuilder: (context, index) {
                    final u = availableUsers[index];
                    return CheckboxListTile(
                      title: Text(u['display_name']),
                      value: selectedMembers.contains(u['id']),
                      onChanged: (val) => setDialogState(() => val! ? selectedMembers.add(u['id']) : selectedMembers.remove(u['id'])),
                    );
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
            TextButton(onPressed: () async {
              if (nameCtrl.text.isEmpty) return;
              await http.post(Uri.parse("$_baseUrl/rooms"), body: jsonEncode({"name": nameCtrl.text, "creator": widget.userName, "members": selectedMembers}), headers: {"Content-Type": "application/json"});
              _fetchRooms();
              Navigator.pop(ctx);
            }, child: const Text("Create")),
          ],
        ),
      ),
    );
  }

  void _showAddWorkDialog() {
    TextEditingController ctrl = TextEditingController();
    String? selectedId;
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
      title: const Text("Assign Task"),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctrl, decoration: const InputDecoration(hintText: "Task description")),
        DropdownButton<String>(
          value: selectedId, isExpanded: true, hint: const Text("Select User"),
          items: users.map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['display_name']))).toList(),
          onChanged: (v) => setS(() => selectedId = v),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () async {
          if (ctrl.text.isNotEmpty && selectedId != null) {
            await http.post(Uri.parse("$_baseUrl/work"), body: jsonEncode({"title": ctrl.text, "assignee_id": selectedId, "assigned_by": widget.userName}), headers: {"Content-Type": "application/json"});
            _fetchWorkItems();
            Navigator.pop(ctx);
          }
        }, child: const Text("Assign")),
      ],
    )));
  }

  Future<void> _updateWorkStatus(int id, bool isDone) async {
    await http.patch(Uri.parse("$_baseUrl/work"), body: jsonEncode({"id": id, "is_done": isDone, "user": widget.userName}), headers: {"Content-Type": "application/json"});
    _fetchWorkItems();
  }

  void _showBroadcastDialog() {
    TextEditingController ctrl = TextEditingController();
    XFile? pickedImage;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Create Broadcast"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: ctrl, decoration: const InputDecoration(hintText: "Enter broadcast message")),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () async {
                  final XFile? image = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 50);
                  if (image != null) setDialogState(() => pickedImage = image);
                },
                child: Container(
                  height: 100,
                  width: double.infinity,
                  decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10)),
                  child: pickedImage == null ? const Icon(Icons.add_a_photo, color: Colors.grey) : ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(File(pickedImage!.path), fit: BoxFit.cover)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
            TextButton(
              onPressed: () async {
                if (ctrl.text.isNotEmpty) {
                  String? base64Image;
                  if (pickedImage != null) base64Image = base64Encode(await pickedImage!.readAsBytes());
                  
                  Map<String, dynamic> body = {
                    "text": ctrl.text,
                    "sender_id": widget.userName,
                  };
                  if (base64Image != null && base64Image.isNotEmpty) {
                    body["image_base64"] = base64Image;
                  }

                  await http.post(Uri.parse("$_baseUrl/broadcast"), body: jsonEncode(body), headers: {"Content-Type": "application/json"});
                  _fetchBroadcasts();
                  if (mounted) Navigator.pop(ctx);
                }
              },
              child: const Text("Broadcast"),
            )
          ],
        ),
      ),
    );
  }

  void _showResetDeviceDialog() {
    String selected = 'all';
    showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
      title: const Text("Reset Device Lock"),
      content: DropdownButton<String>(
        value: selected, isExpanded: true,
        items: [{'name': 'All', 'id': 'all'}, ...users.map((u) => {'name': u['display_name'], 'id': u['id']})].map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['name'] as String))).toList(),
        onChanged: (v) => setS(() => selected = v!),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        TextButton(onPressed: () async {
          await http.post(Uri.parse("$_baseUrl/reset-devices"), headers: {"Content-Type": "application/json"}, body: jsonEncode({"username": selected, "requested_by": widget.userName}));
          Navigator.pop(ctx);
        }, child: const Text("Reset", style: TextStyle(color: Colors.red))),
      ],
    )));
  }
}
